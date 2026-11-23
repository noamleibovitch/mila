import Foundation
import CryptoKit
import Darwin

/// Builds and publishes a byte-preserving copy of an already inspected Mila
/// library. All heavy I/O is synchronous and must run off the main actor.
/// Sources are never modified. The index is published last; a crash before it
/// leaves an incomplete, non-empty destination that strict inspection refuses.
enum RecordingLibraryMigration {
    static let stagePrefix = ".mila-copy-"
    static let receiptName = ".mila-receipt.json"
    static let stageFilesName = ".mila-copy-files"
    static let metadataOverhead: UInt64 = 64 * 1024

    struct Receipt: Codable, Equatable {
        /// Filesystem identity captured from the descriptor that created the
        /// file. A matching identity is proof that the path still names the
        /// file this operation created; a digest alone is not ownership.
        struct FileIdentity: Codable, Equatable {
            let device: UInt64
            let inode: UInt64
        }
        struct Item: Codable, Equatable {
            let name: String
            let relativePath: String
            let size: UInt64
            let digest: String
            /// Identity of the staged copy, captured at O_EXCL creation.
            var created: FileIdentity?
            /// Identity of the published file, captured from the successful
            /// link or the O_EXCL fallback. Absent means publication was not
            /// proven durable, so cleanup must retain that destination path.
            var published: FileIdentity?

            init(name: String, relativePath: String, size: UInt64, digest: String,
                 created: FileIdentity? = nil, published: FileIdentity? = nil) {
                self.name = name
                self.relativePath = relativePath
                self.size = size
                self.digest = digest
                self.created = created
                self.published = published
            }
        }
        let version: Int
        let operationID: UUID
        let createdAt: Date
        let sourceIdentity: String
        let destinationIdentity: String
        let isIndexLast: Bool
        let items: [Item]
    }

    struct Plan {
        let source: RecordingLibraryInspection.Snapshot
        let destination: RecordingLibraryInspection.Layout
        let operationID: UUID
        let files: [RecordingLibraryFileCopy.Entry]
        let destinations: [String: URL]

        var requiredBytes: UInt64 {
            files.reduce(0) { $0 + $1.size } + metadataOverhead
        }
    }

    enum Problem: Error, Equatable {
        case unsafeDestination, destinationNotEmpty, destinationExists
        case sourceChanged, invalidReceipt, unsafeReceipt, insufficientSpace
        case ioFailure
    }

    static func makePlan(source: RecordingLibraryInspection.Snapshot,
                         destination: RecordingLibraryInspection.Layout,
                         operationID: UUID = UUID()) throws -> Plan {
        guard source.layout.isSeparate(from: destination) else { throw Problem.unsafeDestination }
        let fm = FileManager.default
        guard destination.directory == destination.directory.resolvingSymlinksInPath(),
              try fm.attributesOfItem(atPath: destination.directory.path)[.type] as? FileAttributeType == .typeDirectory,
              try fm.contentsOfDirectory(atPath: destination.directory.path).allSatisfy({ $0 == ".DS_Store" }) else {
            throw Problem.destinationNotEmpty
        }
        if destination.isDefault {
            // The app-support root also holds Models and global state. It is
            // the default *layout*, not an empty folder; emptiness is scoped
            // to the recordings list and its audio. App-global siblings stay
            // where they are and are never copied, deleted or treated as
            // recordings.
            guard !fm.fileExists(atPath: destination.index.path),
                  !fm.fileExists(atPath: destination.folders.path) else {
                throw Problem.destinationNotEmpty
            }
        }
        var destinations: [String: URL] = [:]
        var seen = Set<String>()
        for entry in source.files {
            let url: URL
            switch entry.name {
            case "recordings.json": url = destination.index
            case "folders.json": url = destination.folders
            default: url = destination.directory.appendingPathComponent(entry.name)
            }
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { throw Problem.destinationExists }
            destinations[entry.name] = url
        }
        return Plan(source: source, destination: destination, operationID: operationID,
                    files: source.files, destinations: destinations)
    }

    /// Check the destination volume before any user-visible copy starts.
    static func availableCapacity(for url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return available >= 0 ? UInt64(available) : nil
    }

    static func requireSpace(for plan: Plan) throws {
        guard let available = availableCapacity(for: plan.destination.directory) else { return }
        guard available >= plan.requiredBytes else { throw Problem.insufficientSpace }
    }

    static func createStage(for plan: Plan,
                            cancellation: () throws -> Void = {}) throws -> URL {
        try cancellation()
        let stage = plan.destination.directory
            .appendingPathComponent(stagePrefix + plan.operationID.uuidString, isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw Problem.destinationExists }
        do {
            let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            var items: [Receipt.Item] = []
            for entry in plan.files {
                items.append(Receipt.Item(name: entry.name,
                                          relativePath: try relativePath(for: entry.name, in: plan.destination),
                                          size: entry.size, digest: entry.digest))
            }
            let receipt = Receipt(version: 2, operationID: plan.operationID, createdAt: createdAt,
                                  sourceIdentity: identity(plan.source.layout),
                                  destinationIdentity: identity(plan.destination),
                                  isIndexLast: true,
                                  items: items)
            try writeReceipt(receipt, in: stage)
        } catch {
            // Retain the hidden directory on preparation failure. Never
            // recursively delete files that may have appeared concurrently.
            throw error
        }
        return stage
    }

    /// Copy every verified source byte into the hidden stage. The stage holds
    /// a flat `files/` directory plus the receipt; publication maps each file
    /// to its layout-specific destination.
    /// `chunkWrite` is forwarded to the copy worker as a held-worker I/O seam.
    /// Production leaves it nil, so the worker's real `FileHandle.write` is
    /// used unchanged.
    static func copy(_ plan: Plan, into stage: URL,
                     cancellation: () throws -> Void = {},
                     progress: (UInt64) -> Void = { _ in },
                     completedFile: (Int) -> Void = { _ in },
                     chunkWrite: ((FileHandle, Data) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        guard stage.lastPathComponent.hasPrefix(stagePrefix),
              stage.standardizedFileURL == stage.resolvingSymlinksInPath(),
              try fm.attributesOfItem(atPath: stage.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Problem.unsafeDestination
        }
        let files = stage.appendingPathComponent(stageFilesName, isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        // `RecordingLibraryFileCopy` rechecks source identity, hashes every
        // copied byte, refuses an existing stage item and reports the
        // descriptor identity of each staged file it verified.
        var created: [String: Receipt.FileIdentity] = [:]
        try RecordingLibraryFileCopy.copy(plan.files, into: files,
                                          cancellation: cancellation, progress: progress,
                                          completedFile: completedFile,
                                          created: { name, device, inode in
                                              created[name] = Receipt.FileIdentity(device: device, inode: inode)
                                          },
                                          chunkWrite: chunkWrite)
        // Creation identities become durable only once the whole copy has
        // been verified. A crash or cancellation before this point leaves
        // staged files without ownership proof, so cleanup retains them.
        let receipt = try readReceipt(in: stage)
        guard receipt.operationID == plan.operationID,
              Set(created.keys) == Set(plan.files.map(\.name)) else {
            // Without durable per-file creation identity, cleanup must not
            // infer ownership of the staged bytes.
            throw Problem.invalidReceipt
        }
        let updated = try applying(created: created, to: receipt)
        try writeReceipt(updated, in: stage)
    }

    /// Exclusive, no-overwrite publication, index LAST. The stage must be on
    /// the same volume as the destination (it is created inside the chosen
    /// folder). Hard links make publication atomic; if the volume refuses a
    /// link we copy with O_EXCL, never overwriting anything.
    static func publish(_ plan: Plan, stage: URL,
                        cancellation: () throws -> Void = {}) throws {
        let files = stage.appendingPathComponent(stageFilesName, isDirectory: true)
        let indexName = "recordings.json"
        let ordered = plan.files.filter { $0.name != indexName } + plan.files.filter { $0.name == indexName }
        var receipt = try readReceipt(in: stage)
        guard receipt.operationID == plan.operationID,
              Set(receipt.items.map(\.name)) == Set(plan.files.map(\.name)) else {
            throw Problem.invalidReceipt
        }
        for entry in ordered {
            try cancellation()
            guard let destination = plan.destinations[entry.name] else { throw Problem.invalidReceipt }
            let source = files.appendingPathComponent(entry.name)
            guard try digest(source) == entry.digest else { throw Problem.invalidReceipt }
            guard let item = receipt.items.first(where: { $0.name == entry.name }),
                  let stagedIdentity = item.created,
                  try fileIdentity(at: source) == stagedIdentity else {
                // The staged path no longer names the file we created.
                throw Problem.invalidReceipt
            }
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let publishedIdentity: Receipt.FileIdentity
            if link(source.path, destination.path) == 0 {
                guard let identity = try? fileIdentity(at: destination),
                      identity == stagedIdentity else {
                    // The published path is not the inode we linked there.
                    throw Problem.destinationExists
                }
                publishedIdentity = identity
            } else {
                let linkError = errno
                guard linkError == EXDEV || linkError == EPERM ||
                        linkError == EMLINK || linkError == ENOTSUP else {
                    throw linkError == EEXIST ? Problem.destinationExists : Problem.ioFailure
                }
                // A refusal may mean another process created this path. Do
                // not unlink it on failure; cleanup needs ownership evidence.
                publishedIdentity = try copyExclusive(source: source, destination: destination,
                                                      digest: entry.digest)
            }
            guard try digest(destination) == entry.digest else { throw Problem.sourceChanged }
            guard let identity = try? fileIdentity(at: destination),
                  identity == publishedIdentity else {
                // The path changed between creation and proof; retain it.
                throw Problem.destinationExists
            }
            receipt = try applying(published: publishedIdentity, for: entry.name, to: receipt)
            try writeReceipt(receipt, in: stage)
        }
        try RecordingLibraryFileCopy.recheck(plan.files, cancellation: cancellation)
    }

    /// Verify every published byte and reject unexpected files. The hidden
    /// operation stage is still present until activation succeeds.
    static func verifyPublished(_ plan: Plan, stage: URL) throws {
        let fm = FileManager.default
        var expectedByDirectory: [String: Set<String>] = [:]
        for entry in plan.files {
            guard let destination = plan.destinations[entry.name],
                  FileManager.default.fileExists(atPath: destination.path),
                  (try? digest(destination)) == entry.digest else { throw Problem.sourceChanged }
            expectedByDirectory[destination.deletingLastPathComponent().path, default: []].insert(destination.lastPathComponent)
        }
        let defaultRoot = plan.destination.isDefault
            ? plan.destination.directory.deletingLastPathComponent().standardizedFileURL
            : nil
        for (directory, expected) in expectedByDirectory {
            let directoryURL = URL(fileURLWithPath: directory).standardizedFileURL
            var allowed = expected
            if directoryURL == plan.destination.directory.standardizedFileURL {
                allowed.insert(stage.lastPathComponent)
            }
            let actual = Set(try fm.contentsOfDirectory(atPath: directory)).subtracting([".DS_Store"])
            // The app-support root intentionally holds unrelated global state
            // (models, profiles, MCP files). Only the recordings directory is
            // required to contain exactly the published assets.
            if defaultRoot == nil || directoryURL != defaultRoot! {
                guard actual.isSubset(of: allowed) else { throw Problem.destinationExists }
            }
        }
        try RecordingLibraryFileCopy.recheck(plan.files)
    }

    /// Remove only files this operation provably created after a verified
    /// stop. Each staged and published path must still carry the device/inode
    /// recorded at creation AND the expected bytes; anything replaced,
    /// untracked or ambiguous is retained and cleanup reports failure instead
    /// of inferring ownership from a digest.
    ///
    /// The coordinator captures a receipt before the copy, so it can be stale
    /// (without creation identities). Reload the durable receipt, verify the
    /// immutable binding it shares with the caller's copy, and then use the
    /// refreshed identities. Receipt absolute paths are never trusted: the
    /// destination layout is rebuilt from the stage and validated against the
    /// receipt's identity before any deletion.
    static func cleanup(stage: URL?, receipt: Receipt?) throws {
        guard let stage, let receipt else { return }
        let stageURL = try validatedStage(stage)
        let disk = try readReceipt(in: stageURL)
        try verifyBinding(disk: disk, matches: receipt)
        let binding = try layoutBinding(forStage: stageURL, receipt: disk)
        let fm = FileManager.default
        let files = stageURL.appendingPathComponent(stageFilesName, isDirectory: true)
        let receiptURL = stageURL.appendingPathComponent(receiptName)

        let stageNames = Set(try fm.contentsOfDirectory(atPath: stageURL.path))
        guard stageNames.isSubset(of: [stageFilesName, receiptName]) else {
            throw Problem.unsafeReceipt
        }
        let receiptNames = Set(disk.items.map(\.name))
        if fm.fileExists(atPath: files.path) {
            guard isRealDirectory(files) else { throw Problem.unsafeReceipt }
            let stagedNames = Set(try fm.contentsOfDirectory(atPath: files.path))
            guard stagedNames.isSubset(of: receiptNames) else { throw Problem.unsafeReceipt }
        }

        // Prove every path before deleting any of them.
        var staged: [(URL, Receipt.Item)] = []
        var published: [(URL, Receipt.Item)] = []
        for item in disk.items {
            let stagedURL = files.appendingPathComponent(item.name)
            if fm.fileExists(atPath: stagedURL.path) {
                guard let created = item.created,
                      try fileIdentity(at: stagedURL) == created,
                      try digest(stagedURL) == item.digest else {
                    throw Problem.unsafeReceipt
                }
                staged.append((stagedURL, item))
            }
            let publishedURL = try binding.destination(for: item.name)
            if fm.fileExists(atPath: publishedURL.path) {
                guard let identity = item.published,
                      try fileIdentity(at: publishedURL) == identity,
                      try digest(publishedURL) == item.digest else {
                    throw Problem.unsafeReceipt
                }
                published.append((publishedURL, item))
            }
        }

        for (url, _) in published {
            guard unlink(url.path) == 0 else { throw Problem.ioFailure }
        }
        for (url, _) in staged {
            guard unlink(url.path) == 0 else { throw Problem.ioFailure }
        }
        if fm.fileExists(atPath: files.path) {
            guard rmdir(files.path) == 0 else { throw Problem.unsafeReceipt }
        }
        guard unlink(receiptURL.path) == 0 else { throw Problem.ioFailure }
        guard rmdir(stageURL.path) == 0 else { throw Problem.unsafeReceipt }
    }

    /// Remove the hidden stage only. Used after a successful activation; the
    /// published files are now the live library and must not be touched.
    /// Every staged entry must match its receipt identity and bytes; the
    /// receipt is removed only once the stage contains nothing else. This is
    /// deliberately non-recursive: `unlink` files and `rmdir` directories,
    /// never `removeItem(at:)` on a directory.
    static func removeStageOnly(_ stage: URL?) throws {
        guard let stage else { return }
        let stageURL = try validatedStage(stage)
        let receipt = try readReceipt(in: stageURL)
        _ = try layoutBinding(forStage: stageURL, receipt: receipt)
        let fm = FileManager.default
        let files = stageURL.appendingPathComponent(stageFilesName, isDirectory: true)
        let receiptURL = stageURL.appendingPathComponent(receiptName)

        let stageNames = Set(try fm.contentsOfDirectory(atPath: stageURL.path))
        guard stageNames.isSubset(of: [stageFilesName, receiptName]) else {
            throw Problem.unsafeReceipt
        }
        let receiptNames = Set(receipt.items.map(\.name))
        if fm.fileExists(atPath: files.path) {
            guard isRealDirectory(files) else { throw Problem.unsafeReceipt }
            let stagedNames = Set(try fm.contentsOfDirectory(atPath: files.path))
            // Unknown or replaced contents are retained; nothing is deleted
            // until every staged entry is proven to be ours.
            guard stagedNames.isSubset(of: receiptNames) else { throw Problem.unsafeReceipt }
            for item in receipt.items where stagedNames.contains(item.name) {
                let url = files.appendingPathComponent(item.name)
                guard let created = item.created,
                      try fileIdentity(at: url) == created,
                      try digest(url) == item.digest else {
                    throw Problem.unsafeReceipt
                }
            }
            for item in receipt.items where stagedNames.contains(item.name) {
                guard unlink(files.appendingPathComponent(item.name).path) == 0 else {
                    throw Problem.ioFailure
                }
            }
            guard rmdir(files.path) == 0 else { throw Problem.unsafeReceipt }
        }
        guard unlink(receiptURL.path) == 0 else { throw Problem.ioFailure }
        guard rmdir(stageURL.path) == 0 else { throw Problem.unsafeReceipt }
    }

    static func loadReceipt(in layout: RecordingLibraryInspection.Layout) throws -> (URL, Receipt)? {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: layout.directory.path)
        let stages = names.filter { $0.hasPrefix(stagePrefix) }
        guard stages.count == 1, let name = stages.first else {
            if stages.isEmpty { return nil }
            throw Problem.unsafeReceipt
        }
        let stage = layout.directory.appendingPathComponent(name)
        guard stage.standardizedFileURL == stage.resolvingSymlinksInPath(),
              try fm.attributesOfItem(atPath: stage.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Problem.unsafeReceipt
        }
        let receiptURL = stage.appendingPathComponent(receiptName)
        let data = try readReceiptData(receiptURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let receipt = try? decoder.decode(Receipt.self, from: data),
              receipt.version == 2, receipt.isIndexLast,
              stage.lastPathComponent == stagePrefix + receipt.operationID.uuidString,
              receipt.destinationIdentity == identity(layout),
              Set(receipt.items.map(\.name)).count == receipt.items.count else {
            throw Problem.invalidReceipt
        }
        for item in receipt.items {
            guard !item.name.isEmpty, !item.name.hasPrefix("."),
                  (item.name as NSString).lastPathComponent == item.name,
                  try destinationURL(for: item.name, in: layout).path == item.relativePath else {
                throw Problem.invalidReceipt
            }
        }
        return (stage, receipt)
    }

    static func identity(_ layout: RecordingLibraryInspection.Layout) -> String {
        "\(layout.directory.standardizedFileURL.path)|\(layout.index.standardizedFileURL.path)|\(layout.folders.standardizedFileURL.path)|\(layout.isDefault ? "default" : "custom")"
    }

    private static func relativePath(for name: String,
                                     in layout: RecordingLibraryInspection.Layout) throws -> String {
        try destinationURL(for: name, in: layout).path
    }

    private static func destinationURL(for name: String,
                                       in layout: RecordingLibraryInspection.Layout) throws -> URL {
        switch name {
        case "recordings.json": return layout.index
        case "folders.json": return layout.folders
        default:
            guard !name.isEmpty, !name.hasPrefix("."),
                  (name as NSString).lastPathComponent == name else { throw Problem.invalidReceipt }
            return layout.directory.appendingPathComponent(name)
        }
    }

    private struct LayoutBinding {
        let directory: URL
        let index: URL
        let folders: URL
        let isDefault: Bool

        func destination(for name: String) throws -> URL {
            switch name {
            case "recordings.json": return index
            case "folders.json": return folders
            default:
                guard !name.isEmpty, !name.hasPrefix("."),
                      (name as NSString).lastPathComponent == name else {
                    throw Problem.invalidReceipt
                }
                return directory.appendingPathComponent(name)
            }
        }
    }

    private static func validatedStage(_ stage: URL) throws -> URL {
        let normalized = stage.standardizedFileURL
        guard normalized.lastPathComponent.hasPrefix(stagePrefix),
              normalized == normalized.resolvingSymlinksInPath(),
              isRealDirectory(normalized) else {
            throw Problem.unsafeReceipt
        }
        return normalized
    }

    /// Rebuild the destination layout from where the stage lives and require
    /// the receipt identity to name exactly that layout. Receipt `relativePath`
    /// strings are then checked against the rebuilt layout instead of being
    /// used to choose deletion targets.
    private static func layoutBinding(forStage stage: URL,
                                     receipt: Receipt) throws -> LayoutBinding {
        let directory = stage.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = directory.deletingLastPathComponent()
        let custom = LayoutBinding(directory: directory,
                                   index: directory.appendingPathComponent("recordings.json"),
                                   folders: directory.appendingPathComponent("folders.json"),
                                   isDefault: false)
        let defaultLayout = LayoutBinding(directory: directory,
                                          index: root.appendingPathComponent("recordings.json"),
                                          folders: root.appendingPathComponent("folders.json"),
                                          isDefault: true)
        let candidates = [custom, defaultLayout].filter {
            identity($0) == receipt.destinationIdentity
        }
        guard candidates.count == 1, let binding = candidates.first else {
            throw Problem.invalidReceipt
        }
        for item in receipt.items {
            guard !item.name.isEmpty, !item.name.hasPrefix("."),
                  (item.name as NSString).lastPathComponent == item.name,
                  try binding.destination(for: item.name).path == item.relativePath else {
                throw Problem.invalidReceipt
            }
        }
        return binding
    }

    private static func identity(_ binding: LayoutBinding) -> String {
        "\(binding.directory.standardizedFileURL.path)|\(binding.index.standardizedFileURL.path)|\(binding.folders.standardizedFileURL.path)|\(binding.isDefault ? "default" : "custom")"
    }

    private static func readReceipt(in stage: URL) throws -> Receipt {
        let data = try readReceiptData(stage.appendingPathComponent(receiptName))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let receipt = try? decoder.decode(Receipt.self, from: data),
              receipt.version == 2, receipt.isIndexLast,
              stage.lastPathComponent == stagePrefix + receipt.operationID.uuidString,
              Set(receipt.items.map(\.name)).count == receipt.items.count else {
            throw Problem.invalidReceipt
        }
        return receipt
    }

    private static func readReceiptData(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Problem.invalidReceipt }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 512 * 1024 * 1024 else {
            throw Problem.invalidReceipt
        }
        var data = Data()
        while true {
            let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
            if bytes.isEmpty { break }
            data.append(bytes)
            guard data.count <= 512 * 1024 * 1024 else { throw Problem.invalidReceipt }
        }
        return data
    }

    private static func writeReceipt(_ receipt: Receipt, in stage: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        let receiptURL = stage.appendingPathComponent(receiptName)
        let temporary = stage.appendingPathComponent(
            receiptName + "." + UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Problem.ioFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw Problem.ioFailure
        }
        guard rename(temporary.path, receiptURL.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw Problem.ioFailure
        }
        // Best effort: make the rename durable before cleanup/publication
        // trusts the recorded identities.
        let directoryFD = open(stage.path, O_RDONLY)
        if directoryFD >= 0 {
            fsync(directoryFD)
            close(directoryFD)
        }
    }

    private static func applying(created: [String: Receipt.FileIdentity],
                                 to receipt: Receipt) throws -> Receipt {
        let items = try receipt.items.map { item -> Receipt.Item in
            var updated = item
            if let identity = created[item.name] {
                if let existing = item.created, existing != identity {
                    throw Problem.invalidReceipt
                }
                updated.created = identity
            }
            return updated
        }
        return Receipt(version: receipt.version, operationID: receipt.operationID,
                       createdAt: receipt.createdAt, sourceIdentity: receipt.sourceIdentity,
                       destinationIdentity: receipt.destinationIdentity,
                       isIndexLast: receipt.isIndexLast, items: items)
    }

    private static func applying(published identity: Receipt.FileIdentity,
                                 for name: String,
                                 to receipt: Receipt) throws -> Receipt {
        let items = try receipt.items.map { item -> Receipt.Item in
            var updated = item
            if item.name == name {
                if let existing = item.published, existing != identity {
                    throw Problem.invalidReceipt
                }
                updated.published = identity
            }
            return updated
        }
        return Receipt(version: receipt.version, operationID: receipt.operationID,
                       createdAt: receipt.createdAt, sourceIdentity: receipt.sourceIdentity,
                       destinationIdentity: receipt.destinationIdentity,
                       isIndexLast: receipt.isIndexLast, items: items)
    }

    /// Immutable fields must agree, and an identity recorded by the caller
    /// may not disappear or change on disk. New identities added after the
    /// caller's snapshot are exactly what cleanup needs to refresh.
    private static func verifyBinding(disk: Receipt, matches passed: Receipt) throws {
        guard passed.version == disk.version,
              passed.operationID == disk.operationID,
              passed.createdAt == disk.createdAt,
              passed.sourceIdentity == disk.sourceIdentity,
              passed.destinationIdentity == disk.destinationIdentity,
              passed.isIndexLast == disk.isIndexLast,
              passed.items.count == disk.items.count else {
            throw Problem.invalidReceipt
        }
        for passedItem in passed.items {
            guard let diskItem = disk.items.first(where: { $0.name == passedItem.name }),
                  diskItem.relativePath == passedItem.relativePath,
                  diskItem.size == passedItem.size,
                  diskItem.digest == passedItem.digest,
                  bindingNotContradicted(diskItem.created, passedItem.created),
                  bindingNotContradicted(diskItem.published, passedItem.published) else {
                throw Problem.invalidReceipt
            }
        }
    }

    private static func bindingNotContradicted(_ disk: Receipt.FileIdentity?,
                                               _ passed: Receipt.FileIdentity?) -> Bool {
        guard let passed else { return true }
        return disk == passed
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    private static func fileIdentity(at url: URL) throws -> Receipt.FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw Problem.unsafeReceipt
        }
        return Receipt.FileIdentity(device: UInt64(info.st_dev),
                                    inode: UInt64(info.st_ino))
    }

    private static func copyExclusive(source: URL, destination: URL,
                                      digest expected: String) throws -> Receipt.FileIdentity {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw Problem.ioFailure }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        defer { try? reader.close() }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? Problem.destinationExists : Problem.ioFailure }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? writer.close() }
        var createdInfo = stat()
        guard fstat(fd, &createdInfo) == 0,
              createdInfo.st_mode & S_IFMT == S_IFREG else {
            throw Problem.ioFailure
        }
        let created = Receipt.FileIdentity(device: UInt64(createdInfo.st_dev),
                                           inode: UInt64(createdInfo.st_ino))
        var hash = SHA256()
        while true {
            let bytes = try reader.read(upToCount: 1_048_576) ?? Data()
            if bytes.isEmpty { break }
            try writer.write(contentsOf: bytes)
            hash.update(data: bytes)
        }
        try writer.synchronize()
        try writer.close()
        guard hex(hash.finalize()) == expected else { throw Problem.sourceChanged }
        guard let current = try? fileIdentity(at: destination),
              current == created else { throw Problem.destinationExists }
        return created
    }

    static func digest(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Problem.ioFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
            if bytes.isEmpty { break }
            hash.update(data: bytes)
        }
        return hex(hash.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
