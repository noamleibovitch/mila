import Foundation
import CryptoKit
import Darwin

/// Byte-preserving worker for an already inspected library. The coordinator
/// supplies the complete manifest, owns the hidden staging directory, and runs
/// this synchronous I/O off MainActor. This does not publish or select a folder.
enum RecordingLibraryFileCopy {
    struct Entry: Equatable {
        let source: URL
        let name: String
        let size: UInt64
        let digest: String
        fileprivate let device: UInt64
        fileprivate let inode: UInt64
        fileprivate let modification: Date
    }

    enum Problem: Error, Equatable {
        case invalidName, duplicateName, unsafeFile, changed, destinationExists
        case invalidStage, ioFailure
    }

    static func inspect(_ sources: [URL], cancellation: () throws -> Void = {}) throws -> [Entry] {
        var names = Set<String>()
        return try sources.map { source in
            try cancellation()
            let name = source.lastPathComponent
            try validateName(name)
            let key = name.precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw Problem.duplicateName }
            return try fingerprint(source, name: name, cancellation: cancellation)
        }
    }

    static func recheck(_ entries: [Entry], cancellation: () throws -> Void = {}) throws {
        for entry in entries {
            guard try fingerprint(entry.source, name: entry.name, cancellation: cancellation) == entry else {
                throw Problem.changed
            }
        }
    }

    /// On failure, leaves only newly created files in the owned hidden stage.
    /// Caller cleanup must use the receipt and may never remove the source.
    /// `chunkRead`/`chunkWrite` are per-call deterministic I/O seams for held
    /// worker tests. Production leaves both nil, which uses the real
    /// `FileHandle.read(upToCount:)` and `write(contentsOf:)` calls unchanged.
    static func copy(_ entries: [Entry], into stage: URL,
                     cancellation: () throws -> Void = {},
                     progress: (UInt64) -> Void = { _ in },
                     completedFile: (Int) -> Void = { _ in },
                     created: (String, UInt64, UInt64) -> Void = { _, _, _ in },
                     chunkRead: ((FileHandle, Int) throws -> Data?)? = nil,
                     chunkWrite: ((FileHandle, Data) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        let normalized = stage.standardizedFileURL
        guard normalized == normalized.resolvingSymlinksInPath(),
              normalized.lastPathComponent.hasPrefix(".mila-copy-"),
              try fm.attributesOfItem(atPath: normalized.path)[.type] as? FileAttributeType == .typeDirectory,
              try fm.contentsOfDirectory(atPath: normalized.path).isEmpty else {
            throw Problem.invalidStage
        }
        try recheck(entries, cancellation: cancellation)
        var copiedBytes: UInt64 = 0
        for (index, entry) in entries.enumerated() {
            try cancellation()
            try validateName(entry.name)
            let destination = normalized.appendingPathComponent(entry.name)
            // O_EXCL protects against both pre-existing files and symlinks.
            let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw errno == EEXIST ? Problem.destinationExists : Problem.ioFailure }
            let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
            defer { try? writer.close() }
            var createdInfo = stat()
            guard fstat(output, &createdInfo) == 0,
                  createdInfo.st_mode & S_IFMT == S_IFREG else { throw Problem.ioFailure }
            let createdDevice = UInt64(createdInfo.st_dev)
            let createdInode = UInt64(createdInfo.st_ino)
            let input = open(entry.source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard input >= 0 else { throw Problem.unsafeFile }
            let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
            defer { try? reader.close() }
            var sourceInfo = stat()
            guard fstat(input, &sourceInfo) == 0,
                  sourceInfo.st_mode & S_IFMT == S_IFREG,
                  UInt64(sourceInfo.st_dev) == entry.device,
                  UInt64(sourceInfo.st_ino) == entry.inode,
                  sourceInfo.st_size >= 0, UInt64(sourceInfo.st_size) == entry.size else { throw Problem.changed }
            var hash = SHA256()
            var length: UInt64 = 0
            while true {
                try cancellation()
                let bytes: Data
                if let chunkRead {
                    bytes = try chunkRead(reader, 1_048_576) ?? Data()
                } else {
                    bytes = try reader.read(upToCount: 1_048_576) ?? Data()
                }
                if bytes.isEmpty { break }
                if let chunkWrite {
                    try chunkWrite(writer, bytes)
                } else {
                    try writer.write(contentsOf: bytes)
                }
                hash.update(data: bytes)
                length += UInt64(bytes.count)
                guard length <= entry.size else { throw Problem.changed }
                copiedBytes += UInt64(bytes.count)
                progress(copiedBytes)
            }
            try writer.synchronize()
            try writer.close()
            guard length == entry.size, hex(hash.finalize()) == entry.digest else { throw Problem.changed }
            let copied = try fingerprint(destination, name: entry.name, cancellation: cancellation)
            guard copied.size == entry.size, copied.digest == entry.digest,
                  copied.device == createdDevice, copied.inode == createdInode else {
                throw Problem.changed
            }
            created(entry.name, createdDevice, createdInode)
            completedFile(index + 1)
        }
        try recheck(entries, cancellation: cancellation)
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              !name.contains(":"), !name.contains("\0"),
              (name as NSString).lastPathComponent == name else { throw Problem.invalidName }
    }

    private static func fingerprint(_ source: URL, name: String,
                                    cancellation: () throws -> Void) throws -> Entry {
        try cancellation()
        let fm = FileManager.default
        guard source.isFileURL,
              source.standardizedFileURL == source.resolvingSymlinksInPath().standardizedFileURL else {
            throw Problem.unsafeFile
        }
        let before = try fm.attributesOfItem(atPath: source.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              let size = (before[.size] as? NSNumber)?.uint64Value,
              let device = (before[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (before[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modification = before[.modificationDate] as? Date else { throw Problem.unsafeFile }
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Problem.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var descriptorInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              UInt64(descriptorInfo.st_dev) == device, UInt64(descriptorInfo.st_ino) == inode,
              descriptorInfo.st_mode & S_IFMT == S_IFREG else { throw Problem.changed }
        var hash = SHA256()
        var count: UInt64 = 0
        while true {
            try cancellation()
            let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
            if bytes.isEmpty { break }
            hash.update(data: bytes); count += UInt64(bytes.count)
        }
        let after = try fm.attributesOfItem(atPath: source.path)
        guard count == size, after[.type] as? FileAttributeType == .typeRegular,
              (after[.size] as? NSNumber)?.uint64Value == size,
              (after[.systemFileNumber] as? NSNumber)?.uint64Value == inode,
              (after[.systemNumber] as? NSNumber)?.uint64Value == device,
              after[.modificationDate] as? Date == modification else { throw Problem.changed }
        return Entry(source: source, name: name, size: size, digest: hex(hash.finalize()),
                     device: device, inode: inode, modification: modification)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
