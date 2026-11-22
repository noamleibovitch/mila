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
        /// Rows whose audio is already gone. They are preserved exactly as
        /// metadata (never fabricated, dropped or rewritten) so a user can
        /// switch back to a library that has a historically missing file.
        let missingAudioCount: Int
        var byteCount: UInt64 { files.reduce(0) { $0 + $1.size } }
    }

    enum Result {
        case empty
        case existing(Snapshot)
    }

    enum Problem: Error, Equatable {
        case unsafeLocation, unreadableList, unsettledRecordings, duplicateIdentity
        case unsafeName, sharedFiles, unrelatedFiles, changed
        case incompleteCopy
    }

    private static let ignoredNames: Set<String> = [".DS_Store"]
    private static let maxMetadataBytes = 128 * 1024 * 1024

    static func inspect(_ layout: Layout,
                        allowingOwnedStage: Bool = false,
                        cancellation: () throws -> Void = {}) throws -> Result {
        try cancellation()
        let fm = FileManager.default
        guard layout.directory == layout.directory.resolvingSymlinksInPath(),
              try fm.attributesOfItem(atPath: layout.directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Problem.unsafeLocation
        }
        let names = Set(try fm.contentsOfDirectory(atPath: layout.directory.path))
        guard names.count <= 100_000 else { throw Problem.unrelatedFiles }
        let stageNames = Set(names.filter { $0.hasPrefix(RecordingLibraryMigration.stagePrefix) })
        let hasIndex = fm.fileExists(atPath: layout.index.path)
        // A published index means the copy is complete (index is published
        // last); the hidden stage is only a leftover ownership marker. It is
        // not an incomplete library we may delete. Without an index the
        // destination is genuinely incomplete and must be cleaned explicitly.
        if !stageNames.isEmpty, !allowingOwnedStage, !hasIndex { throw Problem.incompleteCopy }
        let libraryNames = names.subtracting(stageNames)
        if !hasIndex {
            let folderOnly = fm.fileExists(atPath: layout.folders.path)
            guard libraryNames.subtracting(ignoredNames).subtracting(Set(folderOnly ? ["folders.json"] : [])).isEmpty else {
                throw Problem.unreadableList
            }
            // A source can legitimately contain only its folder metadata:
            // an empty but named folder list is still data worth preserving
            // and is a meaningful copy case. It is not the same as a folder
            // with no Mila data at all.
            if fm.fileExists(atPath: layout.folders.path) {
                let folderBytes = try metadata(layout.folders)
                guard let decoded = try? JSONDecoder().decode([String].self, from: folderBytes),
                      decoded.count <= 50_000 else { throw Problem.unreadableList }
                let files = try RecordingLibraryFileCopy.inspect([layout.folders], cancellation: cancellation)
                return .existing(Snapshot(layout: layout, indexBytes: Data(), foldersBytes: folderBytes,
                                          recordings: [], folderNames: decoded.sorted(), files: files,
                                          directoryNames: names, emptyAudioFiles: 0,
                                          missingAudioCount: 0))
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
        var missingAudioCount = 0
        for offset in records.indices {
            try cancellation()
            var record = records[offset]
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
            // A recorded row keeps its raw metadata even when its audio was
            // already lost (an older Mila, a manual Finder delete). The copy
            // preserves the row and every sidecar byte; it never invents an
            // audio file or drops the UUID, and the preview reports the count
            // so the user can switch back honestly.
            if !names.contains(record.audioFileName) {
                missingAudioCount += 1
            }
            let textURL = layout.directory.appendingPathComponent(record.transcriptFileName)
            if names.contains(record.transcriptFileName) {
                let textBytes = try metadata(textURL)
                capturedMetadata[textURL] = textBytes
                guard let text = String(data: textBytes, encoding: .utf8) else { throw Problem.unreadableList }
                record.fullText = text
            } else if record.fullText.isEmpty && !record.segments.isEmpty {
                record.fullText = TranscriptFormatter.joinedFullText(segments: record.segments)
            }
            records[offset] = record
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
        for name in libraryNames.subtracting(ownedNames).subtracting(ignoredNames) {
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
                                  directoryNames: names, emptyAudioFiles: emptyCount,
                                  missingAudioCount: missingAudioCount))
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
            && !name.contains("\\") && !name.contains(":") && !name.contains("\0")
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
