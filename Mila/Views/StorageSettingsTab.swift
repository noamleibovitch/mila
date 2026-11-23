import SwiftUI
import AppKit

/// Settings → Storage. Lets the user redirect new recordings (and their
/// `recordings.json` / sidecar metadata) to a directory of their choosing
/// — typical use cases are `~/Documents/Meetings`, an external drive, or
/// a cloud-sync folder (Dropbox, iCloud Drive, Google Drive).
///
/// The chosen folder is persisted via a security-scoped bookmark; see
/// `RecordingStorageSettings` for the resolution / fallback rules.
///
/// A folder choice is provisional until the user confirms one explicit
/// choice in the change sheet. Mila can copy the existing library, start an
/// empty list, or adopt a complete existing library; it never merges two
/// folders and never deletes the originals. The copy and its verification run
/// off the main actor.
struct StorageSettingsTab: View {
    @EnvironmentObject private var storage: RecordingStorageSettings
    @EnvironmentObject private var store: RecordingStore
    /// Watched so the location affordances can refuse while a real writer is
    /// active. The coordinator aggregates every owner's full-lifetime state.
    @EnvironmentObject private var actions: QuickActionsController
    @EnvironmentObject private var coordinator: RecordingLocationCoordinator
    @EnvironmentObject private var readiness: RecordingLibraryReadiness

    private enum LocationControl: Hashable { case choose, useDefault }
    @State private var locationInvoker: LocationControl = .choose
    @State private var pendingLocationFocusRestore = false
    @FocusState private var locationFocus: LocationControl?
    @AccessibilityFocusState private var accessibleLocationFocus: LocationControl?

    @State private var isCompressing = false
    @State private var compressStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                currentLocationCard
                storageLimitCard
                autoDropCard
                if storage.lastResolutionWasStale {
                    staleBookmarkNotice
                }
                if case .noOp(let message) = coordinator.phase {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !coordinator.isSheetPresented, case .failure(let message) = coordinator.phase {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isStaticText)
                }
                // Obsidian vault destination lives under Storage rather than
                // in a top-level tab (originally to keep the tab bar from
                // overflowing), and renders as one more card in this stack
                // rather than a titled section — off by default, it's a
                // single toggle. It expands itself once enabled; see
                // `ObsidianSettingsSection`.
                //
                // #177 removed the overflow constraint, so the original
                // reason for parking it here is gone and promoting it to its
                // own sidebar destination is now possible. Deliberately NOT
                // done here (this is a container change only) — it's a
                // separate, reviewable UX call.
                ObsidianSettingsSection()
                // Same reasoning as Obsidian above: an opt-in destination for
                // transcripts, one toggle wide until enabled, parked here
                // instead of a tab of its own.
                MCPAccessSettingsSection()
                // And the generic one: hand each finished recording to a
                // command of the user's own. Off by default, one toggle wide.
                PostRecordingCommandSettingsSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Settings-local polling only; it never publishes from the App
            // scene and stops when the tab goes away.
            while !Task.isCancelled {
                readiness.refresh()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
        .sheet(isPresented: Binding(get: { coordinator.isSheetPresented },
                                    set: { if !$0 { coordinator.dismiss() } }), onDismiss: {
            pendingLocationFocusRestore = true
            restoreLocationFocusIfPossible()
        }) {
            RecordingLocationChangeSheet(coordinator: coordinator)
        }
        .onChange(of: isLocationBusy) { _, busy in
            if !busy { restoreLocationFocusIfPossible() }
        }
    }

    private func prepareLocationFocus(_ control: LocationControl) {
        locationInvoker = control
        pendingLocationFocusRestore = false
        locationFocus = nil
        accessibleLocationFocus = nil
    }

    private func restoreLocationFocusIfPossible() {
        guard pendingLocationFocusRestore, !coordinator.isSheetPresented,
              !isLocationBusy else { return }
        pendingLocationFocusRestore = false
        locationFocus = locationInvoker
        accessibleLocationFocus = locationInvoker
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recordings location")
                .font(.title3.weight(.semibold))
            Text("Choose a folder for your recordings. Mila can copy your recordings there, start with an empty list, or use an existing Mila recordings folder. Your current recordings stay where they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentLocationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: displayPath(store.recordingsDirectory))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("storage.currentFolder.path")
                        .accessibilityValue(store.recordingsDirectory.path)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(isCustom ? "Custom location" : "Default location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Choose…") {
                    prepareLocationFocus(.choose)
                    coordinator.chooseFolder()
                }
                .focusable()
                .focused($locationFocus, equals: .choose)
                .accessibilityFocused($accessibleLocationFocus, equals: .choose)
                .disabled(isLocationBusy)
                .help(isLocationBusy ? busyText : "Check a recordings folder before switching.")
                .accessibilityValue(isLocationBusy ? busyText : "Ready")
                .accessibilityIdentifier("storage.chooseFolder.button")
                Button("Reveal in Finder") { revealInFinder() }
                Spacer()
                Button("Use default location…") {
                    prepareLocationFocus(.useDefault)
                    coordinator.useDefaultLocation()
                }
                .focusable()
                .focused($locationFocus, equals: .useDefault)
                .accessibilityFocused($accessibleLocationFocus, equals: .useDefault)
                .disabled(isLocationBusy)
                .help(isLocationBusy ? busyText : "Check the default recordings folder before switching.")
                .accessibilityValue(isLocationBusy ? busyText : "Ready")
                .accessibilityIdentifier("storage.resetDefault.button")
            }
            if isLocationBusy {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.secondary)
                    Text(busyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(busyText)
                .accessibilityIdentifier("storage.busyReason")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var isLocationBusy: Bool {
        coordinator.isWorking || !readiness.latest.isIdle
    }

    private var busyText: String {
        if case .finishing = coordinator.phase {
            return "Finishing the folder change. This can’t be canceled."
        }
        if coordinator.isSettlingCopy {
            return "Finish changing the recordings folder before recording. Cancel to record first."
        }
        if coordinator.isWorking {
            return "Finish checking or choosing the recordings folder before trying again."
        }
        if let reason = readiness.latest.firstBlocker?.reason {
            return "Finish recording or processing before changing folders. \(reason)"
        }
        return "Finish recording or processing before changing folders."
    }

    /// Storage cap: a stepper for the GB limit + the current usage. New
    /// recordings are blocked at the cap (see
    /// `QuickActionsController.storageCapReached`); existing recordings
    /// are never auto-deleted.
    private var storageLimitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.tint)
                Text("Storage limit")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(usageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: Binding(get: { storage.limitGigabytes },
                                   set: { storage.limitGigabytes = $0 }),
                    in: 1...500, step: 1) {
                Text("Cap new recordings at \(Int(storage.limitGigabytes.rounded())) GB")
                    .font(.callout)
            }
            Text("New recordings are blocked once the library reaches this size. Existing recordings are never deleted automatically — reclaim space below or raise the limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 8) {
                Button { compressExisting() } label: {
                    if isCompressing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(compressStatus ?? "Compressing…")
                        }
                    } else {
                        Text("Compress existing recordings")
                    }
                }
                .disabled(isCompressing || actions.isRecording || store.wavRecordingCount() == 0)
                .help(actions.isRecording
                      ? "Stop the current recording before compressing"
                      : "Transcode older WAV recordings to m4a to reclaim disk space")
                .accessibilityIdentifier("storage.compressExisting.button")
                Spacer()
                Text(isCompressing ? (compressStatus ?? "") : reclaimSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Auto-drop threshold: a stepper for the minimum-duration gate that
    /// discards accidental short + empty captures (hotkey misfires, silence)
    /// right after transcription. 0 disables it (keep everything). See
    /// issue #61 / `RecordingStorageSettings.minDuration`.
    private var autoDropCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "scissors")
                    .foregroundStyle(.tint)
                Text("Discard accidental recordings")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            Stepper(value: Binding(get: { storage.minDuration },
                                   set: { storage.minDuration = $0 }),
                    in: 0...60, step: 1) {
                Text(autoDropSummary)
                    .font(.callout)
            }
            .accessibilityIdentifier("storage.minDuration.stepper")
            Text("When a recording finishes with no transcript and is shorter than this, Mila deletes it automatically — those are almost always hotkey misfires or silence. Short recordings that did capture speech are always kept. Set to 0 seconds to keep everything.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var autoDropSummary: String {
        let s = Int(storage.minDuration.rounded())
        if s == 0 { return "Keep all recordings (auto-discard off)" }
        return "Discard empty recordings under \(s) second\(s == 1 ? "" : "s")"
    }

    private var reclaimSummary: String {
        let n = store.wavRecordingCount()
        if n == 0 { return "All recordings compressed" }
        return "\(n) WAV recording\(n == 1 ? "" : "s") can be compressed"
    }

    private func compressExisting() {
        guard !isCompressing, !actions.isRecording else { return }
        isCompressing = true
        compressStatus = "Starting…"
        Task { @MainActor in
            let total = await store.compressAllWAVRecordings { done, count in
                compressStatus = "Compressed \(done) of \(count)…"
            }
            isCompressing = false
            compressStatus = total > 0 ? "Compressed \(total) recording\(total == 1 ? "" : "s")." : nil
        }
    }

    private var usageSummary: String {
        let usedGB = Double(store.currentUsageBytes()) / 1_073_741_824.0
        return String(format: "%.2f GB used", usedGB)
    }

    private var staleBookmarkNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The folder you previously chose was moved or renamed. Mila refreshed the saved reference — if recordings look missing, pick the folder again to be sure.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var isCustom: Bool {
        storage.customDirectory != nil
    }

    private func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func revealInFinder() {
        // Open the directory itself in a Finder window. We can't use
        // `activateFileViewerSelecting([url])` because that highlights
        // the directory inside its parent — handy for files, but for
        // a folder the user usually wants to step _into_ it.
        NSWorkspace.shared.open(store.recordingsDirectory)
    }
}
