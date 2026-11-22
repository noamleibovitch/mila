import Foundation
import AVFoundation
import MilaKit
import Darwin

/// Side-effect-free inspection. Unlike RecordingStore.load(), never repairs
/// files, mints IDs, publishes a pointer, writes transcripts or enqueues work.
enum RecordingLibraryInspection {
    struct Layout: Equatable {
        let directory: URL
        let index: URL
        let folders: URL
        let isDefault: Bool

        init(directory: URL, defaultRoot: URL) throws {
            guard directory.isFileURL, defaultRoot.isFileURL else { throw Problem.unsafeLocation }
            let root = defaultRoot.standardizedFileURL.resolvingSymlinksInPath()
            let chosen = directory.standardizedFileURL.resolvingSymlinksInPath()
            let defaultDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
            guard chosen == defaultDirectory ||
                    (!Self.contains(root, chosen) && !Self.contains(chosen, root)),
                  !Self.contains(root.appendingPathComponent("Models").resolvingSymlinksInPath(), chosen) else {
                throw Problem.unsafeLocation
            }
            self.directory = chosen
            self.isDefault = chosen == defaultDirectory
            self.index = (isDefault ? root : chosen).appendingPathComponent("recordings.json")
            self.folders = (isDefault ? root : chosen).appendingPathComponent("folders.json")
        }

        static func contains(_ parent: URL, _ child: URL) -> Bool {
            let prefix = parent.standardizedFileURL.pathComponents
            return child.standardizedFileURL.pathComponents.starts(with: prefix)
        }

        func isSeparate(from other: Layout) -> Bool {
            !Self.contains(directory, other.directory) && !Self.contains(other.directory, directory)
        }
    }

    struct Snapshot {
        let layout: Layout
        let indexBytes: Data
        let foldersBytes: Data?
        let recordings: [Recording]
        let folderNames: [String]
        let files: [RecordingLibraryFileCopy.Entry]
        let directoryNames: Set<String>
        let emptyAudioFiles: Int
        var byteCount: UInt64 { files.reduce(0) { $0 + $1.size } }
    }

    enum Result {
        case empty
        case existing(Snapshot)
    }

    enum Problem: Error, Equatable {
        case unsafeLocation, unreadableList, unsettledRecordings, duplicateIdentity
        case unsafeName, sharedFiles, missingAudio, unrelatedFiles, changed
        case incompleteCopy
    }

    private static let ignoredNames: Set<String> = [".DS_Store"]
    private static let maxMetadataBytes = 128 * 1024 * 1024

    static func inspect(_ layout: Layout, cancellation: () throws -> Void = {}) throws -> Result {
        try cancellation()
        let fm = FileManager.default
        guard layout.directory == layout.directory.resolvingSymlinksInPath(),
              try fm.attributesOfItem(atPath: layout.directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Problem.unsafeLocation
        }
        let names = Set(try fm.contentsOfDirectory(atPath: layout.directory.path))
        guard names.count <= 100_000 else { throw Problem.unrelatedFiles }
        if names.contains(where: { $0.hasPrefix(".mila-copy-") }) { throw Problem.incompleteCopy }
        let hasIndex = fm.fileExists(atPath: layout.index.path)
        if !hasIndex {
            guard names.subtracting(ignoredNames).isEmpty, !fm.fileExists(atPath: layout.folders.path) else {
                throw Problem.unreadableList
            }
            return .empty
        }
        let indexBytes = try metadata(layout.index)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var records = try? decoder.decode([Recording].self, from: indexBytes), records.count <= 50_000 else {
            throw Problem.unreadableList
        }
        guard Set(records.map(\.id)).count == records.count else { throw Problem.duplicateIdentity }
        guard records.allSatisfy({ $0.status != .pending && $0.status != .running }) else {
            throw Problem.unsettledRecordings
        }
        var sources = [layout.index]
        var capturedMetadata: [URL: Data] = [layout.index: indexBytes]
        var ownedNames: Set<String> = layout.isDefault ? [] : ["recordings.json"]
        var canonicalNames: Set<String> = []
        for offset in records.indices {
            try cancellation()
            let record = records[offset]
            let fileNames = [record.audioFileName, record.transcriptFileName,
                             record.summaryFileName, record.subtitleFileName]
            guard ["wav", "m4a"].contains((record.audioFileName as NSString).pathExtension.lowercased()) else {
                throw Problem.unsafeName
            }
            for name in fileNames {
                guard validName(name) else { throw Problem.unsafeName }
                let key = name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive],
                                                                         locale: Locale(identifier: "en_US_POSIX"))
                guard canonicalNames.insert(key).inserted else { throw Problem.sharedFiles }
                let url = layout.directory.appendingPathComponent(name)
                if names.contains(name) { sources.append(url); ownedNames.insert(name) }
            }
            guard names.contains(record.audioFileName) else { throw Problem.missingAudio }
            let textURL = layout.directory.appendingPathComponent(record.transcriptFileName)
            if names.contains(record.transcriptFileName) {
                let textBytes = try metadata(textURL)
                capturedMetadata[textURL] = textBytes
                guard let text = String(data: textBytes, encoding: .utf8) else { throw Problem.unreadableList }
                records[offset].fullText = text
            } else if record.fullText.isEmpty && !record.segments.isEmpty {
                records[offset].fullText = TranscriptFormatter.joinedFullText(segments: record.segments)
            }
        }
        let folderBytes: Data?
        var folderNames = Set(records.compactMap(\.folder).filter { !$0.isEmpty })
        if fm.fileExists(atPath: layout.folders.path) {
            let data = try metadata(layout.folders)
            guard let decoded = try? JSONDecoder().decode([String].self, from: data), decoded.count <= 50_000 else {
                throw Problem.unreadableList
            }
            folderBytes = data; folderNames.formUnion(decoded); sources.append(layout.folders)
            capturedMetadata[layout.folders] = data
            if !layout.isDefault { ownedNames.insert("folders.json") }
        } else { folderBytes = nil }
        var emptyCount = 0
        for name in names.subtracting(ownedNames).subtracting(ignoredNames) {
            try cancellation()
            let url = layout.directory.appendingPathComponent(name)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            // Preserve inert crash leftovers as bytes. The app's recovery gate
            // ignores these small zero-frame WAVs; larger loose audio refuses.
            guard validName(name), url == url.resolvingSymlinksInPath(),
                  (name as NSString).pathExtension.lowercased() == "wav",
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.intValue, size <= 4096,
                  (try? AVAudioFile(forReading: url).length) == 0 else { throw Problem.unrelatedFiles }
            sources.append(url); emptyCount += 1
        }
        let files = try RecordingLibraryFileCopy.inspect(sources, cancellation: cancellation)
        guard names == Set(try fm.contentsOfDirectory(atPath: layout.directory.path)) else { throw Problem.changed }
        for (url, data) in capturedMetadata {
            guard try metadata(url) == data else { throw Problem.changed }
        }
        return .existing(Snapshot(layout: layout, indexBytes: indexBytes, foldersBytes: folderBytes,
                                  recordings: records, folderNames: folderNames.sorted(), files: files,
                                  directoryNames: names, emptyAudioFiles: emptyCount))
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private static func metadata(_ url: URL) throws -> Data {
        guard url == url.resolvingSymlinksInPath() else { throw Problem.unreadableList }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Problem.unreadableList }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maxMetadataBytes else { throw Problem.unreadableList }
        let data = try handle.read(upToCount: maxMetadataBytes + 1) ?? Data()
        guard data.count <= maxMetadataBytes, data.count == info.st_size else { throw Problem.changed }
        return data
    }
}
