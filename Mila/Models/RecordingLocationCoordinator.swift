import Foundation
import AppKit
import Combine

@MainActor
final class RecordingLocationProgressModel: ObservableObject {
    @Published private(set) var progress: RecordingLocationCoordinator.Progress?

    func update(_ progress: RecordingLocationCoordinator.Progress?) {
        self.progress = progress
    }
}

/// Owns the Settings folder-change flow: provisional folder picking,
/// side-effect-free inspection, the copy/fresh/adopt decision, off-main copy,
/// exclusive publication and the final no-await selection flip.
@MainActor
final class RecordingLocationCoordinator: ObservableObject {
    enum Choice: String, CaseIterable, Identifiable, Equatable {
        case copy
        case startFresh
        case useExisting

        var id: String { rawValue }

        var title: String {
            switch self {
            case .copy: return "Copy recordings and switch"
            case .startFresh: return "Start fresh"
            case .useExisting: return "Use this folder"
            }
        }
    }

    enum DestinationKind: Equatable {
        case empty
        case existing(recordings: Int, folders: Int, missingAudio: Int)
        case incompleteCopy
    }

    struct Preview: Equatable {
        let destinationPath: String
        let sourcePath: String
        let isDefaultDestination: Bool
        let destination: DestinationKind
        let sourceRecordings: Int
        let sourceFolders: Int
        let sourceMissingAudio: Int
        let choices: [Choice]
        let copyIsAvailable: Bool
        let requiredBytes: UInt64
        let availableBytes: UInt64?
    }

    struct Progress: Equatable {
        let copiedBytes: UInt64
        let totalBytes: UInt64
        let doneFiles: Int
        let totalFiles: Int
    }

    enum Phase: Equatable {
        case idle
        case checking
        case presenting
        case copying(Progress)
        case publishing
        case removingIncompleteCopy
        case finishing
        case stopping
        case success(String)
        case failure(String)
        case canceled(String)
        case noOp(String)
        case incompleteCopy(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview: Preview?
    @Published var selectedChoice: Choice?
    /// Copy progress rides on its own small object observed only by the
    /// sheet. The coordinator itself is App-level; a 4 Hz @Published here
    /// would re-evaluate MilaApp.body with every chunk.
    let progressModel = RecordingLocationProgressModel()
    @Published private(set) var isSheetPresented = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var mcpPauseWarning: String?

    private let store: RecordingStore
    private let storage: RecordingStorageSettings
    private let readiness: RecordingLibraryReadiness
    private let capacity: (URL) -> UInt64?
    /// Optional deterministic slow-inspection seam for native verification.
    /// It runs only inside the detached inspection task. Production leaves it
    /// nil, so the existing inspection path is unchanged.
    private let beforeInspection: (@Sendable () -> Void)?
    /// Optional deterministic verification boundary for held-worker tests.
    /// Production leaves it nil; no suspension is added to the commit turn.
    private let beforeFinalVerification: (@MainActor () async -> Void)?
    /// Optional deterministic chunk-write fault seam for held-worker tests.
    /// Production leaves it nil, so the real `FileHandle.write` is used.
    private let chunkWrite: (@Sendable (FileHandle, Data) throws -> Void)?
    private let commitFolderSelection: (RecordingStorageSettings.PreparedSelection) -> Bool
    private let fileManager = FileManager.default

    private var sourceSnapshot: RecordingLibraryInspection.Snapshot?
    private var destinationSnapshot: RecordingLibraryInspection.Snapshot?
    private var destinationLayout: RecordingLibraryInspection.Layout?
    private var selectedURL: URL?
    private var preparedSelection: RecordingStorageSettings.PreparedSelection?
    private var capturedReadiness: RecordingLibraryReadiness.Snapshot?
    private var capturedStoreActivity: RecordingLibraryActivity.Snapshot?
    private var incompleteStage: URL?
    private var incompleteReceipt: RecordingLibraryMigration.Receipt?
    private var operationTask: Task<Void, Never>?
    private let cancellation = RecordingLocationCancellation()
    private var provisionalAccessURL: URL?

    private var isActive = false
    private var isChecking = false
    private var isStartingCopy = false
    private var isRemovingIncompleteCopy = false
    private var pickerInFlight = false

    typealias FolderPicker = @MainActor (_ current: URL) async -> URL?
    var folderPicker: FolderPicker?
    /// Read lazily so consent changes are honoured without a cached value.
    var isMCPEnabled: @MainActor () -> Bool = { false }

    init(store: RecordingStore,
         storage: RecordingStorageSettings,
         readiness: RecordingLibraryReadiness,
         capacity: @escaping (URL) -> UInt64? = RecordingLibraryMigration.availableCapacity,
         beforeInspection: (@Sendable () -> Void)? = nil,
         commitSelection: ((RecordingStorageSettings.PreparedSelection) -> Bool)? = nil,
         beforeFinalVerification: (@MainActor () async -> Void)? = nil,
         chunkWrite: (@Sendable (FileHandle, Data) throws -> Void)? = nil) {
        self.beforeInspection = beforeInspection
        self.beforeFinalVerification = beforeFinalVerification
        self.chunkWrite = chunkWrite
        self.capacity = capacity
        self.commitFolderSelection = commitSelection ?? { storage.commitSelection($0) }
        self.store = store
        self.storage = storage
        self.readiness = readiness
    }

    var isWorking: Bool {
        switch phase {
        case .checking, .presenting, .copying, .publishing, .removingIncompleteCopy, .finishing, .stopping,
             .incompleteCopy:
            return true
        default:
            return false
        }
    }

    var isSettlingCopy: Bool {
        switch phase {
        case .copying, .publishing, .removingIncompleteCopy, .finishing, .stopping: return true
        default: return false
        }
    }

    var canDismissSheet: Bool {
        switch phase {
        case .presenting, .failure, .canceled, .success, .noOp, .incompleteCopy: return true
        default: return false
        }
    }

    var title: String {
        if preview?.isDefaultDestination == true { return "Use the default recordings folder?" }
        return "Change recordings folder?"
    }

    // MARK: - Entry points

    func chooseFolder() {
        guard !isActive, !pickerInFlight else { return }
        pickerInFlight = true
        Task { @MainActor in
            defer { pickerInFlight = false }
            let current = storage.customDirectory ?? store.recordingsDirectory
            let picker = folderPicker ?? { current in
                await Self.presentOpenPanel(current: current)
            }
            guard let url = await picker(current) else { return }
            await inspectSelection(url)
        }
    }

    func useDefaultLocation() {
        guard !isActive, !pickerInFlight else { return }
        pickerInFlight = true
        Task { @MainActor in
            defer { pickerInFlight = false }
            await inspectSelection(store.defaultRecordingsDirectory)
        }
    }

    /// Test seam and the shared implementation used by both buttons.
    func inspectSelection(_ url: URL) async {
        guard !isActive else { return }
        endProvisionalAccess()
        isActive = true
        cancellation.reset()
        isChecking = true
        defer { isChecking = false }
        store.setChangingRecordingsLocation(true)
        phase = .checking
        isSheetPresented = true
        preview = nil
        selectedChoice = nil
        mcpPauseWarning = nil
        lastMessage = nil
        sourceSnapshot = nil
        destinationSnapshot = nil
        destinationLayout = nil
        preparedSelection = nil
        incompleteStage = nil
        incompleteReceipt = nil
        capturedReadiness = readiness.snapshot()
        capturedStoreActivity = store.libraryActivity.snapshot
        let selected = url.standardizedFileURL.resolvingSymlinksInPath()
        selectedURL = selected

        do {
            let destination = try RecordingLibraryInspection.Layout(
                directory: selected, defaultRoot: store.originalRootDirectory)
            if selected.startAccessingSecurityScopedResource() { provisionalAccessURL = selected }
            if destination.directory == store.recordingsDirectory.standardizedFileURL.resolvingSymlinksInPath() {
                phase = .noOp("Mila is already using this folder.")
                isSheetPresented = false
                isActive = false
                endProvisionalAccess()
                store.setChangingRecordingsLocation(false)
                return
            }
            guard fileManager.isWritableFile(atPath: destination.directory.path) else {
                throw Problem.busy("Mila can’t save to this folder. Check its permissions in Finder, or choose another folder.")
            }
            if !destination.isSeparate(from: try currentLayout()) {
                phase = .noOp("Choose a folder outside your current recordings folder so the copies don’t end up inside each other.")
                isActive = false
                endProvisionalAccess()
                store.setChangingRecordingsLocation(false)
                return
            }
            if let (stage, receipt) = try RecordingLibraryMigration.loadReceipt(in: destination),
               !fileManager.fileExists(atPath: destination.index.path) {
                incompleteStage = stage
                incompleteReceipt = receipt
                destinationLayout = destination
                preview = Preview(destinationPath: destination.directory.path,
                                  sourcePath: store.recordingsDirectory.path,
                                  isDefaultDestination: destination.isDefault,
                                  destination: .incompleteCopy,
                                  sourceRecordings: store.recordings.count,
                                  sourceFolders: store.folders.count,
                                  sourceMissingAudio: 0,
                                  choices: [],
                                  copyIsAvailable: false,
                                  requiredBytes: 0,
                                  availableBytes: nil)
                phase = .incompleteCopy("Mila found an incomplete copy from an earlier attempt. Remove the incomplete copy to use this folder, or choose another folder.")
                isSheetPresented = true
                return
            }
            try await inspectDestination(destination)
        } catch is CancellationError {
            phase = .canceled("Folder check canceled. Mila is still using the current folder. No files were changed.")
            isActive = false
            endProvisionalAccess()
            store.setChangingRecordingsLocation(false)
        } catch let error as RecordingLibraryInspection.Problem {
            fail(inspectionMessage(error), active: false)
        } catch let error as RecordingLocationCoordinator.Problem {
            fail(error.message, active: false)
        } catch {
            fail("Mila can’t check that folder right now. Choose another folder.", active: false)
        }
    }

    private enum Problem: Error {
        case busy(String)
        case sourceChanged
        case bookmark
        case cleanupFailed
        var message: String {
            switch self {
            case .busy(let reason): return reason
            case .sourceChanged: return "Your recordings changed while Mila was copying, so Mila is still using the current folder. Nothing was deleted."
            case .bookmark: return "Mila couldn’t save that folder choice. Mila is still using the current recordings folder."
            case .cleanupFailed: return "Mila couldn’t remove the incomplete copy safely. Choose another folder."
            }
        }
    }

    // MARK: - Inspection

    private func currentLayout() throws -> RecordingLibraryInspection.Layout {
        try RecordingLibraryInspection.Layout(directory: store.recordingsDirectory,
                                               defaultRoot: store.originalRootDirectory)
    }

    private func inspectDestination(_ destination: RecordingLibraryInspection.Layout) async throws {
        let beforeInspection = self.beforeInspection
        let result = try await Task.detached(priority: .userInitiated) {
            beforeInspection?()
            return try RecordingLibraryInspection.inspect(destination)
        }.value
        try Self.checkCancellation(cancellation)
        if let blocker = capturedReadiness?.firstBlocker, !blocker.isIdle {
            throw Problem.busy("Finish \(blocker.owner.lowercased()) before changing folders.")
        }
        guard let capturedReadiness,
              readiness.snapshot() == capturedReadiness, readiness.isIdle else {
            throw Problem.busy("Another Mila task started while the folder was being checked. Try again when it finishes.")
        }
        guard let capturedStoreActivity,
              store.libraryActivity.snapshot == capturedStoreActivity else {
            throw Problem.busy("Mila’s library changed while the folder was being checked. Try again.")
        }
        let sourceLayout = try currentLayout()
        let sourceResult = try await Task.detached(priority: .userInitiated) {
            try RecordingLibraryInspection.inspect(sourceLayout, allowingOwnedStage: true)
        }.value
        try Self.checkCancellation(cancellation)
        let source: RecordingLibraryInspection.Snapshot?
        switch sourceResult {
        case .empty:
            source = nil
        case .existing(let snapshot):
            source = snapshot
        }
        sourceSnapshot = source
        destinationLayout = destination
        do {
            preparedSelection = try storage.prepareSelection(
                for: destination.isDefault ? nil : destination.directory)
        } catch {
            throw Problem.bookmark
        }

        switch result {
        case .empty:
            let hasSourceMetadata = source != nil
            let choices: [Choice] = hasSourceMetadata ? [.copy, .startFresh] : [.useExisting]
            let required = source?.byteCount ?? 0
            let available = capacity(destination.directory)
            let copyAvailable = hasSourceMetadata && (available.map { $0 >= required + RecordingLibraryMigration.metadataOverhead } ?? true)
            preview = Preview(destinationPath: destination.directory.path,
                              sourcePath: store.recordingsDirectory.path,
                              isDefaultDestination: destination.isDefault,
                              destination: .empty,
                              sourceRecordings: source?.recordings.count ?? 0,
                              sourceFolders: source?.folderNames.count ?? 0,
                              sourceMissingAudio: source?.missingAudioCount ?? 0,
                              choices: choices,
                              copyIsAvailable: copyAvailable,
                              requiredBytes: required + RecordingLibraryMigration.metadataOverhead,
                              availableBytes: available)
            destinationSnapshot = nil
        case .existing(let snapshot):
            destinationSnapshot = snapshot
            preview = Preview(destinationPath: destination.directory.path,
                              sourcePath: store.recordingsDirectory.path,
                              isDefaultDestination: destination.isDefault,
                              destination: .existing(recordings: snapshot.recordings.count,
                                                     folders: snapshot.folderNames.count,
                                                     missingAudio: snapshot.missingAudioCount),
                              sourceRecordings: source?.recordings.count ?? 0,
                              sourceFolders: source?.folderNames.count ?? 0,
                              sourceMissingAudio: source?.missingAudioCount ?? 0,
                              choices: [.useExisting],
                              copyIsAvailable: false,
                              requiredBytes: 0,
                              availableBytes: nil)
        }
        phase = .presenting
        isSheetPresented = true
    }

    private func inspectionMessage(_ problem: RecordingLibraryInspection.Problem) -> String {
        switch problem {
        case .unsettledRecordings:
            return "This folder has recordings waiting to finish processing. Finish or stop those tasks in Mila, then try again."
        case .unrelatedFiles:
            return "This folder already contains other files. Choose an empty folder or an existing Mila recordings folder so nothing gets mixed together."
        case .unreadableList, .duplicateIdentity, .sharedFiles, .unsafeName:
            return "Mila can’t read the recordings list in this folder. Choose another folder."
        case .unsafeLocation:
            return "Choose a folder outside your current recordings folder so the copies don’t end up inside each other."
        case .incompleteCopy:
            return "Mila found an incomplete copy from an earlier attempt."
        case .changed:
            return "The folder changed while Mila was checking it. Try again."
        }
    }

    // MARK: - User actions

    func select(_ choice: Choice) {
        guard preview?.choices.contains(choice) == true else { return }
        if choice == .copy, preview?.copyIsAvailable == false { return }
        selectedChoice = choice
    }

    func continueSelection() async {
        guard case .presenting = phase, !isSettlingCopy,
              let choice = selectedChoice,
              let destination = destinationLayout,
              let destinationURL = selectedURL else { return }
        guard let preview else { return }
        if choice == .copy, !preview.copyIsAvailable { return }
        isActive = true
        lastMessage = nil
        capturedReadiness = readiness.snapshot()
        capturedStoreActivity = store.libraryActivity.snapshot
        guard readiness.isIdle, store.libraryActivity.snapshot.outstandingCount == 0 else {
            fail("Finish recording or processing before changing folders.", active: false)
            return
        }
        switch choice {
        case .useExisting:
            if destinationSnapshot != nil {
                phase = .finishing
                await activateExisting(destination: destination, url: destinationURL)
            } else {
                phase = .finishing
                await activateFresh(destination: destination, url: destinationURL)
            }
        case .startFresh:
            phase = .finishing
            await activateFresh(destination: destination, url: destinationURL)
        case .copy:
            await copyAndActivate(destination: destination, url: destinationURL)
        }
    }

    func cancel() {
        if isChecking || isStartingCopy || isRemovingIncompleteCopy {
            cancellation.cancel()
            phase = .stopping
            return
        }
        switch phase {
        case .checking, .copying, .publishing:
            cancellation.cancel()
            phase = .stopping
        default:
            return
        }
    }

    func dismiss() {
        guard canDismissSheet else { return }
        isActive = false
        isSheetPresented = false
        phase = .idle
        endProvisionalAccess()
        preview = nil
        selectedChoice = nil
        progressModel.update(nil)
        sourceSnapshot = nil
        destinationSnapshot = nil
        destinationLayout = nil
        selectedURL = nil
        preparedSelection = nil
        incompleteStage = nil
        incompleteReceipt = nil
        store.setChangingRecordingsLocation(false)
    }

    /// Test seam and quit path: wait until the copy/cancel settlement has
    /// produced its final phase. Never used by the UI to poll.
    func awaitOperationSettled() async {
        await operationTask?.value
    }

    func cleanupIncompleteCopy() async {
        guard case .incompleteCopy = phase,
              let stage = incompleteStage, let receipt = incompleteReceipt else { return }
        cancellation.reset()
        isRemovingIncompleteCopy = true
        phase = .removingIncompleteCopy
        // Quit and repeated actions must wait for deletion to settle, just as
        // they wait for the copy worker. Cancellation never retires that task.
        let task = Task { @MainActor in
            await runIncompleteCopyCleanup(stage: stage, receipt: receipt)
        }
        operationTask = task
        await task.value
        isRemovingIncompleteCopy = false
    }

    private func runIncompleteCopyCleanup(stage: URL,
                                          receipt: RecordingLibraryMigration.Receipt) async {
        var removed = false
        do {
            try Self.checkCancellation(cancellation)
            try await Task.detached(priority: .userInitiated) {
                try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt)
            }.value
            removed = true
            incompleteStage = nil
            incompleteReceipt = nil
            phase = .checking
            try Self.checkCancellation(cancellation)
            let destination = try RecordingLibraryInspection.Layout(
                directory: stage.deletingLastPathComponent(),
                defaultRoot: store.originalRootDirectory)
            try await inspectDestination(destination)
        } catch is CancellationError {
            phase = .canceled(removed
                ? "Mila removed the incomplete copy. The folder check was canceled; Mila is still using the current recordings folder."
                : "Removal canceled. No files were changed; Mila is still using the current recordings folder.")
            isActive = false
            endProvisionalAccess()
            store.setChangingRecordingsLocation(false)
        } catch {
            fail(removed
                 ? "Mila removed the incomplete copy but couldn’t check the folder. Mila is still using the current recordings folder. Try choosing the folder again."
                 : "Mila couldn’t remove the incomplete copy safely. Choose another folder.", active: false)
        }
    }

    // MARK: - Outcome paths

    private func activateExisting(destination: RecordingLibraryInspection.Layout, url: URL) async {
        guard let expected = destinationSnapshot else { return }
        do {
            let final = try await recheckDestination(destination)
            guard sameLibrary(expected, final) else { throw Problem.busy("The folder changed before Mila could switch. Try again.") }
            try await activate(snapshot: final, isDefault: destination.isDefault,
                               url: url, sourceWasCopied: false,
                               sourcePath: store.recordingsDirectory.path)
        } catch let problem as Problem {
            fail(problem.message, active: false)
        } catch let problem as RecordingLibraryInspection.Problem {
            fail(inspectionMessage(problem), active: false)
        } catch {
            fail("Mila couldn’t change the recordings folder. Mila is still using the current folder. Your original recordings were not changed.", active: false)
        }
    }

    private func activateFresh(destination: RecordingLibraryInspection.Layout, url: URL) async {
        var wroteIndex = false
        do {
            let empty = try JSONEncoder().encode([Recording]())
            if fileManager.fileExists(atPath: destination.index.path) {
                throw Problem.busy("This folder changed while Mila was checking it. Try again.")
            }
            let parent = destination.index.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            // Foundation traps when atomic and withoutOverwriting are combined.
            // This is a new destination only: exclusive creation preserves a
            // racing index, and inspection must decode the complete list
            // before the bookmark or live library can switch.
            try empty.write(to: destination.index, options: .withoutOverwriting)
            wroteIndex = true
            let final = try await recheckDestination(destination)
            try await activate(snapshot: final, isDefault: destination.isDefault,
                               url: url, sourceWasCopied: false,
                               sourcePath: store.recordingsDirectory.path)
        } catch let problem as Problem {
            if wroteIndex { lastMessage = "Mila left the recordings list in the selected folder. Its files were not removed." }
            fail(problem.message, active: false)
        } catch let problem as RecordingLibraryInspection.Problem {
            if wroteIndex { lastMessage = "Mila left the recordings list in the selected folder. Its files were not removed." }
            fail(inspectionMessage(problem), active: false)
        } catch {
            if wroteIndex { lastMessage = "Mila left the recordings list in the selected folder. Its files were not removed." }
            fail("Mila couldn’t change the recordings folder. Mila is still using the current folder. Your original recordings were not changed.", active: false)
        }
    }

    private func copyAndActivate(destination: RecordingLibraryInspection.Layout, url: URL) async {
        guard let source = sourceSnapshot else {
            fail("Mila can’t read the current recordings folder, so it can’t copy it. Choose another folder.", active: false)
            return
        }
        cancellation.reset()
        let startProgress = Progress(copiedBytes: 0, totalBytes: source.byteCount,
                                     doneFiles: 0, totalFiles: source.files.count)
        progressModel.update(startProgress)
        isStartingCopy = true
        phase = .copying(startProgress)
        isStartingCopy = false
        let task = Task { @MainActor in
            await self.runCopy(source: source, destination: destination, url: url)
        }
        operationTask = task
    }

    private func runCopy(source: RecordingLibraryInspection.Snapshot,
                         destination: RecordingLibraryInspection.Layout,
                         url: URL) async {
        let operationID = UUID()
        let flag = cancellation
        let writeChunk = chunkWrite
        var stage: URL?
        var receipt: RecordingLibraryMigration.Receipt?
        do {
            let plan = try RecordingLibraryMigration.makePlan(source: source, destination: destination,
                                                              operationID: operationID)
            if let available = capacity(destination.directory), available < plan.requiredBytes {
                throw RecordingLibraryMigration.Problem.insufficientSpace
            }
            let newStage = try await Task.detached(priority: .userInitiated) {
                try RecordingLibraryMigration.createStage(for: plan,
                    cancellation: { try Self.checkCancellation(flag) })
            }.value
            stage = newStage
            receipt = try await Task.detached {
                try RecordingLibraryMigration.loadReceipt(in: destination)?.1
            }.value
            let startProgress = Progress(copiedBytes: 0, totalBytes: source.byteCount,
                                         doneFiles: 0, totalFiles: plan.files.count)
            progressModel.update(startProgress)
            phase = .copying(startProgress)
            let total = plan.files
            try await Task.detached(priority: .userInitiated) { [weak self] in
                var last = Date.distantPast
                var done = 0
                try RecordingLibraryMigration.copy(plan, into: newStage,
                    cancellation: { try Self.checkCancellation(flag) },
                    progress: { copied in
                        let now = Date()
                        guard now.timeIntervalSince(last) >= 0.25 else { return }
                        last = now
                        let completed = done
                        Task { @MainActor [weak self] in
                            self?.publishProgress(copied: copied, total: source.byteCount,
                                                 done: min(completed, total.count), files: total.count)
                        }
                    }, completedFile: { count in done = count },
                    chunkWrite: nil)
            }.value
            publishProgress(copied: source.byteCount, total: source.byteCount,
                            done: total.count, files: total.count)
            try Self.checkCancellation(flag)
            phase = .publishing
            try await Task.detached(priority: .userInitiated) {
                try RecordingLibraryMigration.publish(plan, stage: newStage,
                                                      cancellation: { try Self.checkCancellation(flag) })
                try RecordingLibraryMigration.verifyPublished(plan, stage: newStage)
                try RecordingLibraryFileCopy.recheck(source.files,
                    cancellation: { try Self.checkCancellation(flag) })
            }.value
            if let beforeFinalVerification { await beforeFinalVerification() }
            try Self.checkCancellation(flag)
            guard let capturedReadiness, let capturedStoreActivity,
                  readiness.snapshot() == capturedReadiness,
                  store.libraryActivity.snapshot == capturedStoreActivity else {
                throw Problem.sourceChanged
            }
            let sourceAgain = try await Task.detached(priority: .userInitiated) {
                try RecordingLibraryInspection.inspect(source.layout, allowingOwnedStage: true)
            }.value
            guard case .existing(let sourceFinal) = sourceAgain,
                  sameLibrary(source, sourceFinal) else { throw Problem.sourceChanged }
            let finalDestination = sourcePreparedFrom(source, layout: destination)
            try await activate(snapshot: finalDestination, isDefault: destination.isDefault,
                               url: url, sourceWasCopied: true,
                               sourcePath: source.layout.directory.path,
                               stage: stage, receipt: receipt)
        } catch is CancellationError {
            await settleCancellation(stage: stage, receipt: receipt)
        } catch let problem as Problem {
            await failCopy(problem.message, stage: stage, receipt: receipt)
        } catch let problem as RecordingLibraryMigration.Problem {
            await failCopy(copyMessage(problem), stage: stage, receipt: receipt)
        } catch {
            await failCopy("Mila couldn’t change the recordings folder. Mila is still using the current folder. Your original recordings were not changed.", stage: stage, receipt: receipt)
        }
    }

    private func activate(snapshot final: RecordingLibraryInspection.Snapshot,
                          isDefault: Bool,
                          url: URL,
                          sourceWasCopied: Bool,
                          sourcePath originalSourcePath: String? = nil,
                          stage: URL? = nil,
                          receipt: RecordingLibraryMigration.Receipt? = nil) async throws {
        phase = .finishing
        guard let capturedReadiness, let capturedStoreActivity,
              readiness.snapshot() == capturedReadiness,
              store.libraryActivity.snapshot == capturedStoreActivity else {
            throw Problem.busy("Processing started before Mila could switch folders. Mila is still using the current folder.")
        }
        guard let prepared = preparedSelection ??
                (try? storage.prepareSelection(for: isDefault ? nil : url)) else {
            throw Problem.bookmark
        }
        let activationExpected = store.libraryActivity.snapshot
        do {
            try store.activatePrepared(
                RecordingStore.PreparedLibraryActivation(
                    layout: try RecordingLibraryInspection.Layout(directory: url, defaultRoot: store.originalRootDirectory),
                    recordings: final.recordings,
                    folders: final.folderNames),
                expectedActivity: activationExpected,
                commitSelection: {
                    guard commitFolderSelection(prepared) else { throw Problem.bookmark }
                })
        } catch let error as RecordingLibraryActivity.CommitError {
            switch error {
            case .busy, .changed, .exhausted:
                throw Problem.busy("Processing started before Mila could switch folders. Mila is still using the current folder.")
            }
        } catch let error as RecordingStore.ActivationError {
            switch error {
            case .bookmark:
                throw Problem.bookmark
            }
        } catch let problem as Problem {
            throw problem
        } catch {
            throw Problem.bookmark
        }
        var stagingCleanupFailed = false
        if sourceWasCopied {
            stagingCleanupFailed = (try? await Task.detached {
                try RecordingLibraryMigration.removeStageOnly(stage)
            }.value) == nil
        }
        mcpPauseWarning = (store.storeLocationIsDiscoverable || !isMCPEnabled()) ? nil
            : "MCP access is paused until Mila can verify the new location. Reopening Mila may restore access."
        let destinationPath = store.recordingsDirectory.path
        let sourcePath = originalSourcePath ?? final.layout.directory.path
        let outcome: String
        if sourceWasCopied {
            outcome = "Mila is now using \(destinationPath). Your original recordings remain in \(sourcePath); nothing was deleted. To use the originals again, choose \(sourcePath) in Settings > Storage."
        } else if final.recordings.isEmpty {
            outcome = "Mila is now using \(destinationPath) with an empty recordings list. Your old files were not deleted. To see them again, choose \(sourcePath) in Settings > Storage."
        } else {
            outcome = "Mila is now using \(destinationPath) with \(final.recordings.count) recording\(final.recordings.count == 1 ? "" : "s"). Mila won’t combine the two folders. Your current files remain in \(sourcePath); to see them again, choose \(sourcePath) in Settings > Storage."
        }
        if final.missingAudioCount > 0 {
            lastMessage = "\(final.missingAudioCount) recording\(final.missingAudioCount == 1 ? " already has" : "s already have") no audio file; \(final.missingAudioCount == 1 ? "its" : "their") details will be kept."
        }
        if stagingCleanupFailed {
            let cleanup = "Mila finished switching but retained a hidden staging copy because it couldn’t verify safe removal. Your recordings are in the selected folder."
            lastMessage = [lastMessage, cleanup].compactMap { $0 }.joined(separator: " ")
        }
        phase = .success(outcome)
        isActive = false
        endProvisionalAccess()
        store.setChangingRecordingsLocation(false)
    }

    private func settleCancellation(stage: URL?, receipt: RecordingLibraryMigration.Receipt?) async {
        var cleanupSucceeded = false
        if let stage, let receipt {
            cleanupSucceeded = (try? await Task.detached {
                try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt)
            }.value) != nil
        }
        let message: String
        if cleanupSucceeded {
            message = "Copy canceled. Your original recordings are unchanged. Mila removed the incomplete copy."
        } else if stage != nil {
            message = "Copy canceled. Your original recordings are unchanged. Mila retained the incomplete copy because it couldn’t verify safe removal. Choose another folder to try again."
        } else {
            message = "Copy canceled. Your original recordings are unchanged."
        }
        phase = .canceled(message)
        isActive = false
        endProvisionalAccess()
        store.setChangingRecordingsLocation(false)
    }

    private func failCopy(_ message: String, stage: URL?,
                          receipt: RecordingLibraryMigration.Receipt?) async {
        var cleanupSucceeded = stage == nil
        if let stage, let receipt {
            cleanupSucceeded = (try? await Task.detached {
                try RecordingLibraryMigration.cleanup(stage: stage, receipt: receipt)
            }.value) != nil
        }
        let cleanupSuffix = cleanupSucceeded
            ? ""
            : " Mila retained the incomplete copy because it couldn’t verify safe removal. Choose another folder to try again."
        let sourceSuffix = message.contains("still using")
            ? ""
            : " Mila is still using \(store.recordingsDirectory.path)."
        fail(message + sourceSuffix + cleanupSuffix, active: false)
    }

    private func publishProgress(copied: UInt64, total: UInt64, done: Int, files: Int) {
        guard case .copying = phase else { return }
        progressModel.update(Progress(copiedBytes: copied, totalBytes: total,
                                      doneFiles: done, totalFiles: files))
    }

    // MARK: - Helpers

    private func recheckDestination(_ destination: RecordingLibraryInspection.Layout) async throws -> RecordingLibraryInspection.Snapshot {
        let result = try await Task.detached(priority: .userInitiated) {
            try RecordingLibraryInspection.inspect(destination)
        }.value
        guard case .existing(let snapshot) = result else {
            throw Problem.busy("This folder has no recordings list. Try again.")
        }
        return snapshot
    }

    private func sourcePreparedFrom(_ source: RecordingLibraryInspection.Snapshot,
                                    layout: RecordingLibraryInspection.Layout) -> RecordingLibraryInspection.Snapshot {
        RecordingLibraryInspection.Snapshot(
            layout: layout,
            indexBytes: source.indexBytes,
            foldersBytes: source.foldersBytes,
            recordings: source.recordings,
            folderNames: source.folderNames,
            files: source.files,
            directoryNames: Set(source.files.map(\.name)),
            emptyAudioFiles: source.emptyAudioFiles,
            missingAudioCount: source.missingAudioCount)
    }

    private func sameLibrary(_ lhs: RecordingLibraryInspection.Snapshot,
                             _ rhs: RecordingLibraryInspection.Snapshot) -> Bool {
        lhs.indexBytes == rhs.indexBytes
            && lhs.foldersBytes == rhs.foldersBytes
            && lhs.recordings.map(\.id) == rhs.recordings.map(\.id)
            && lhs.folderNames == rhs.folderNames
            && lhs.missingAudioCount == rhs.missingAudioCount
            && Set(lhs.files.map { "\($0.name)|\($0.size)|\($0.digest)" })
                == Set(rhs.files.map { "\($0.name)|\($0.size)|\($0.digest)" })
    }

    private func fail(_ message: String, active: Bool) {
        phase = .failure(message)
        isActive = active
        if !active {
            endProvisionalAccess()
            store.setChangingRecordingsLocation(false)
        }
    }

    private func endProvisionalAccess() {
        if let url = provisionalAccessURL {
            url.stopAccessingSecurityScopedResource()
            provisionalAccessURL = nil
        }
    }

    private func copyMessage(_ problem: RecordingLibraryMigration.Problem) -> String {
        switch problem {
        case .insufficientSpace:
            return "Not enough space for the recordings copy. Free up space or choose another folder. Your original recordings stay where they are."
        case .destinationNotEmpty, .destinationExists:
            return "This folder changed while Mila was copying. Nothing was overwritten."
        case .sourceChanged:
            return "Processing started before Mila could switch folders. Mila is still using the current folder."
        case .unsafeDestination:
            return "Choose a folder outside your current recordings folder so the copies don’t end up inside each other."
        default:
            return "Mila couldn’t copy the recordings. Your original recordings were not changed."
        }
    }

    nonisolated private static func checkCancellation(_ flag: RecordingLocationCancellation) throws {
        if Task.isCancelled || flag.isCancelled { throw CancellationError() }
    }

    private static func presentOpenPanel(current: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a recordings folder"
        panel.message = "Mila will check this folder before switching."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }
}

/// Coordinator-local cancellation shared with its `Task.detached` worker.
/// Reset synchronously before each copy; it does not touch any other owner.
final class RecordingLocationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func reset() {
        lock.lock(); cancelled = false; lock.unlock()
    }
}
