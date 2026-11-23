import SwiftUI
import AppKit
import Foundation

/// The one deliberate radio-choice + Continue sheet for changing recordings
/// location. Nothing is selected initially, Cancel is the default Return
/// action until a choice is made, and no option switches by itself.
struct RecordingLocationChangeSheet: View {
    @ObservedObject var coordinator: RecordingLocationCoordinator
    @ObservedObject var progressModel: RecordingLocationProgressModel
    @FocusState private var cancelFocused: Bool
    @AccessibilityFocusState private var resultFocus: ResultFocus?
    @State private var confirmingRemoval = false
    @State private var checkingSlow = false
    @State private var lastProgressAnnouncement = Date.distantPast

    private enum ResultFocus: Hashable { case heading, error }

    init(coordinator: RecordingLocationCoordinator) {
        self.coordinator = coordinator
        self.progressModel = coordinator.progressModel
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heading
                    if coordinator.isWorking {
                        Text("Finish changing the recordings folder before recording. Cancel to record first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                    }
                    if coordinator.preview != nil {
                        pathCard
                    }
                    switch coordinator.phase {
                    case .presenting:
                        choices
                    case .checking:
                        status(checkingSlow ? "Still checking… Large or cloud folders can take a while." : "Checking folder…")
                    case .copying:
                        copyProgress(progressModel.progress ?? RecordingLocationCoordinator.Progress(
                            copiedBytes: 0, totalBytes: 0, doneFiles: 0, totalFiles: 0))
                    case .publishing:
                        status("Checking the copies…")
                    case .removingIncompleteCopy:
                        status("Removing the incomplete copy… Your original recordings are unchanged.")
                    case .finishing:
                        status("Finishing the folder change… This can’t be canceled.")
                    case .stopping:
                        status("Waiting for folder work to finish…")
                    case .incompleteCopy(let message):
                        incomplete(message)
                    case .success(let message), .failure(let message),
                         .canceled(let message), .noOp(let message):
                        outcome(message)
                    case .idle:
                        EmptyView()
                    }
                    if let warning = coordinator.mcpPauseWarning {
                        notice(warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if let missing = missingAudioNotice {
                        notice(missing, systemImage: "waveform.slash", tint: .orange)
                    }
                    if let message = coordinator.lastMessage {
                        notice(message, systemImage: "info.circle.fill", tint: .gray)
                    }
                }
                .padding(20)
                .frame(maxWidth: 480, alignment: .leading)
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 480)
        }
        .frame(minWidth: 420, maxWidth: 520, minHeight: 300)
        .background(RecordingLocationTerminationBridge(
            allowsTerminationRequest: coordinator.isSettlingCopy))
        .interactiveDismissDisabled(!coordinator.canDismissSheet)
        .onExitCommand {
            if coordinator.canDismissSheet {
                coordinator.dismiss()
            } else if case .checking = coordinator.phase {
                coordinator.cancel()
            } else if case .copying = coordinator.phase {
                coordinator.cancel()
            } else if case .publishing = coordinator.phase {
                coordinator.cancel()
            } else if case .removingIncompleteCopy = coordinator.phase {
                coordinator.cancel()
            }
        }
        .onAppear {
            cancelFocused = true
            announce("\(coordinator.title). Choose an option, then Continue.")
        }
        .task(id: coordinator.phase == .checking) {
            guard case .checking = coordinator.phase else { checkingSlow = false; return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if case .checking = coordinator.phase { checkingSlow = true }
        }
        .onChange(of: coordinator.phase) { _, phase in
            switch phase {
            case .presenting:
                resultFocus = .heading
                announce(coordinator.previewSummaryAnnouncement)
            case .failure(let message), .canceled(let message),
                 .success(let message), .noOp(let message):
                resultFocus = .error
                announce(message)
            case .copying, .publishing, .finishing, .stopping:
                break
            default:
                break
            }
        }
        .confirmationDialog("Remove the incomplete copy?", isPresented: $confirmingRemoval,
                            titleVisibility: .visible) {
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            Button("Remove incomplete copy", role: .destructive) {
                Task { await coordinator.cleanupIncompleteCopy() }
            }
        } message: {
            Text("Only Mila’s unchanged incomplete copy is removed. Your original recordings are not removed.")
        }
        .onChange(of: progressModel.progress) { _, progress in
            guard let progress, progress.totalBytes > 0 else { return }
            let now = Date()
            guard now.timeIntervalSince(lastProgressAnnouncement) >= 5 else { return }
            lastProgressAnnouncement = now
            announce("Copying recordings. \(progress.doneFiles) of \(progress.totalFiles) files.")
        }
        .onChange(of: coordinator.selectedChoice) { _, choice in
            guard let preview = coordinator.preview, let choice else { return }
            announce(consequence(for: choice, preview: preview))
        }
    }

    private var heading: some View {
        Text(coordinator.title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("storage.changeSheet.title")
            .accessibilityFocused($resultFocus, equals: .heading)
    }

    private var pathCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            pathRow("Current folder", coordinator.preview?.sourcePath ?? "")
            pathRow(coordinator.preview?.isDefaultDestination == true ? "Default location" : "New folder",
                    coordinator.preview?.destinationPath ?? "")
            if let preview = coordinator.preview, preview.destination == .empty {
                Text("This location has no recordings yet. Mila’s settings and models stay where they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel("\(label): \(path)")
        }
    }

    @ViewBuilder
    private var choices: some View {
        if let preview = coordinator.preview {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recording folder")
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Picker("Recording folder", selection: choiceBinding) {
                    ForEach(preview.choices.filter { $0 != .copy || preview.copyIsAvailable }) { choice in
                        Text(choice.title).tag(Optional(choice))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("storage.changeSheet.choice")
                if let choice = coordinator.selectedChoice {
                    Text(consequence(for: choice, preview: preview))
                        .accessibilityIdentifier("storage.changeSheet.consequence")
                        .accessibilityLabel(consequence(for: choice, preview: preview))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if preview.choices.contains(.copy) {
                    if preview.copyIsAvailable {
                        Text(copySpaceSummary(preview))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        notice(copySpaceWarning(preview), systemImage: "internaldrive", tint: .orange)
                            .accessibilityIdentifier("storage.changeSheet.spaceWarning")
                            .accessibilityLabel(copySpaceWarning(preview))
                    }
                }
                if let choice = coordinator.selectedChoice,
                   case .existing(_, _, let missing) = preview.destination,
                   choice == .useExisting {
                    let extras = existingConsequence(missing: missing, preview: preview)
                    if !extras.isEmpty {
                        Text(extras)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func copyProgress(_ progress: RecordingLocationCoordinator.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress.totalBytes == 0 ? 0 : Double(progress.copiedBytes) / Double(progress.totalBytes))
                .progressViewStyle(.linear)
            Text("Copying recordings… \(progress.doneFiles) of \(progress.totalFiles) files")
                .font(.callout)
            Text("\(byteString(progress.copiedBytes)) of \(byteString(progress.totalBytes))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storage.changeSheet.copyProgress")
        .accessibilityLabel("Copying recordings. \(progress.doneFiles) of \(progress.totalFiles) files, \(byteString(progress.copiedBytes)) of \(byteString(progress.totalBytes))")
    }

    private func incomplete(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            notice(message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                .accessibilityIdentifier("storage.changeSheet.incompleteWarning")
                .accessibilityLabel(message)
            HStack(spacing: 10) {
                Button("Remove incomplete copy") { confirmingRemoval = true }
                    .accessibilityHint("Removes only the unchanged files Mila copied earlier. Your original recordings are not removed.")
                Button("Choose another folder…") {
                    coordinator.dismiss()
                    coordinator.chooseFolder()
                }
            }
        }
    }

    private func outcome(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: coordinator.phase.isFailure ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(coordinator.phase.isFailure ? .red : .green)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("storage.changeSheet.outcome")
        }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($resultFocus, equals: .error)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch coordinator.phase {
            case .presenting:
                if coordinator.selectedChoice == nil {
                    Button("Cancel") { coordinator.dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .focused($cancelFocused)
                } else {
                    Button("Cancel") { coordinator.dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .focused($cancelFocused)
                }
                ContinueButton(coordinator: coordinator, selected: coordinator.selectedChoice != nil)
            case .copying, .publishing, .removingIncompleteCopy:
                Button("Cancel") { coordinator.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops the copy and removes only Mila’s incomplete copy. Your original recordings are unchanged.")
            case .stopping:
                Button("Cancel") { }
                    .disabled(true)
            case .finishing:
                Button("Cancel") { }
                    .disabled(true)
                    .accessibilityHint("The folder change is finishing and can’t be canceled.")
            case .failure, .noOp:
                Button("Choose another folder…") {
                    coordinator.dismiss()
                    coordinator.chooseFolder()
                }
                Button("Close") { coordinator.dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .success, .canceled, .incompleteCopy:
                Button("Close") { coordinator.dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .checking:
                Button("Cancel") { coordinator.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
            case .idle:
                EmptyView()
            }
        }
    }

    private struct ContinueButton: View {
        @ObservedObject var coordinator: RecordingLocationCoordinator
        let selected: Bool
        var body: some View {
            Group {
                if selected {
                    Button("Continue") { Task { await coordinator.continueSelection() } }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("storage.changeSheet.continue")
                        .accessibilityHint("Applies the selected choice.")
                } else {
                    Button("Continue") { }
                        .disabled(true)
                        .accessibilityIdentifier("storage.changeSheet.continue")
                        .accessibilityHint("Choose an option first.")
                }
            }
        }
    }

    private var choiceBinding: Binding<RecordingLocationCoordinator.Choice?> {
        Binding(get: { coordinator.selectedChoice },
                set: { choice in
                    guard let choice else { return }
                    coordinator.select(choice)
                })
    }

    private var missingAudioNotice: String? {
        guard let preview = coordinator.preview else { return nil }
        var missing = preview.sourceMissingAudio
        if case .existing(_, _, let inDestination) = preview.destination {
            missing = max(missing, inDestination)
        }
        guard missing > 0 else { return nil }
        return "\(missing) recording\(missing == 1 ? " already has" : "s already have") no audio file; \(missing == 1 ? "its" : "their") details will be kept."
    }

    private func consequence(for choice: RecordingLocationCoordinator.Choice,
                             preview: RecordingLocationCoordinator.Preview) -> String {
        let source = preview.sourcePath
        switch choice {
        case .copy:
            return "Mila will copy your recordings, transcripts, speaker labels and folders here, then show them from this folder. Your original recordings stay in \(source); nothing is deleted."
        case .startFresh:
            return "Mila will use an empty recordings list here. Your current recordings stay in \(source) and are not deleted. To see them again, choose \(source) in Settings > Storage."
        case .useExisting:
            switch preview.destination {
            case .empty:
                return "Your current folder has no recordings. Mila can use this folder for new recordings. Nothing is deleted."
            case .existing(let count, _, _):
                if count == 0 {
                    return "This folder has an empty Mila recordings list. Mila will show that empty list. Your current recordings stay in \(source). To see them again, choose \(source) in Settings > Storage."
                }
                if preview.isDefaultDestination {
                    return "The default folder already has \(count) recording\(count == 1 ? "" : "s"). Mila will show those instead of the recordings you’re using now. It won’t combine the two folders. Your current recordings stay in \(source). To see them again, choose \(source) in Settings > Storage."
                }
                return "Mila will show the \(count) recording\(count == 1 ? "" : "s") here instead of the ones you’re using now. It won’t combine the two folders. Your current recordings stay in \(source). To see them again, choose \(source) in Settings > Storage."
            case .incompleteCopy:
                return ""
            }
        }
    }

    private func existingConsequence(missing: Int,
                                     preview: RecordingLocationCoordinator.Preview) -> String {
        var parts: [String] = []
        if missing > 0 {
            parts.append("\(missing) recording\(missing == 1 ? " has" : "s have") no audio file; the details are kept.")
        }
        if preview.sourceRecordings > 0 {
            parts.append("To copy your current recordings, choose an empty folder.")
        }
        return parts.joined(separator: " ")
    }

    private func copySpaceSummary(_ preview: RecordingLocationCoordinator.Preview) -> String {
        if let available = preview.availableBytes {
            return "Needs about \(byteString(preview.requiredBytes)) free on this volume. \(byteString(available)) available."
        }
        return "Mila will check free space before copying."
    }

    private func copySpaceWarning(_ preview: RecordingLocationCoordinator.Preview) -> String {
        let required = byteString(preview.requiredBytes)
        if let available = preview.availableBytes {
            let shortfall = preview.requiredBytes > available ? preview.requiredBytes - available : 0
            return "Not enough space: about \(required) needed, \(byteString(available)) available. Free up about \(byteString(shortfall)) or choose another folder."
        }
        return "Mila couldn’t confirm there is enough space on this volume. Choose another folder."
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
                                  countStyle: .file)
    }

    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}

private extension RecordingLocationCoordinator.Phase {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

extension RecordingLocationCoordinator {
    var previewSummaryAnnouncement: String {
        guard let preview else { return "" }
        switch preview.destination {
        case .empty: return "The folder is empty."
        case .existing(let count, _, _): return "This folder has \(count) recordings."
        case .incompleteCopy: return "This folder has an incomplete copy."
        }
    }
}
