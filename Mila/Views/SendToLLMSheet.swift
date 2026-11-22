import SwiftUI
import MilaKit

/// Sheet shown when the user right-clicks a recording and picks
/// "Send to <LLM>…". Surfaces the prompt that will be sent (editable for
/// one-off tweaks — defaults to `LLMSettings.postActionPrompt`) and a
/// read-only preview of the transcript, then runs the LLM call in the
/// background just like the RenameRecordingSheet's "Send" path.
struct SendToLLMSheet: View {
    let recording: Recording
    /// The library epoch captured when the presenting menu was built. The
    /// sheet never refreshes this: if the library moved under it, the send is
    /// refused instead of targeting a same-UUID row in the new library.
    let libraryContext: RecordingLibraryActivity.Context?

    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var llm: LLMSettings
    @EnvironmentObject private var postRecording: PostRecordingCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""

    /// Live recording from the store so an in-flight re-transcription
    /// updates the preview without the sheet needing to be reopened. While
    /// the captured library is no longer current, keep the immutable
    /// presentation snapshot instead of resolving the same UUID elsewhere.
    private var liveRecording: Recording {
        guard let libraryContext, store.admitLibraryInput(libraryContext) else {
            return recording
        }
        return store.recordings.first(where: { $0.id == recording.id }) ?? recording
    }

    private var transcript: String {
        TranscriptFormatter.plainText(segments: liveRecording.segments,
                                      fallback: liveRecording.fullText,
                                      names: liveRecording.speakerNames)
    }

    private var belongsToCurrentLibrary: Bool {
        guard let libraryContext else { return false }
        return store.admitLibraryInput(libraryContext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            promptEditor
            transcriptPreview
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send to \(llm.tool.displayName)") { send() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!belongsToCurrentLibrary
                              || transcript.isEmpty
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .onAppear {
            // Seed with the saved action prompt; user can edit just for this
            // run without overwriting Settings.
            if prompt.isEmpty {
                prompt = llm.postActionPrompt
            }
        }
        .accessibilityIdentifier("sendtollm.sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Send transcript to \(llm.tool.displayName)")
                .font(.title3.weight(.semibold))
            Text(liveRecording.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prompt").font(.callout.weight(.semibold))
                Spacer()
                Button("Reset to saved") {
                    prompt = llm.postActionPrompt
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(prompt == llm.postActionPrompt)
            }
            TextEditor(text: $prompt)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .accessibilityIdentifier("sendtollm.prompt.field")
        }
    }

    private var transcriptPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcript")
                .font(.callout.weight(.semibold))
            ScrollView {
                Text(transcript.isEmpty ? "(no transcript yet — wait for it to finish, then try again)" : transcript)
                    .font(.system(.callout))
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func send() {
        // Recheck immediately before the hand-off; the sheet can outlive a
        // folder switch even though the button above is disabled in that case.
        guard belongsToCurrentLibrary else {
            dismiss()
            return
        }
        let recordingID = liveRecording.id
        let promptSnapshot = prompt
        let transcriptSnapshot = transcript
        // Include any Live-AI summary so the LLM sees the gist before the
        // raw transcript. Empty when this recording ran without Live AI —
        // LLMRunner.composedPrompt then collapses to the old transcript-only
        // wire format.
        let summarySnapshot = (liveRecording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executableOverride = llm.executablePath.isEmpty ? nil : llm.executablePath
        let tool = llm.tool
        dismiss()
        // Hand off to the app-lifetime coordinator so the call is owned +
        // cancellable rather than spawned as a fire-and-forget detached
        // Task. The Send button here is already gated on a non-empty
        // transcript, so the snapshot is populated and the coordinator
        // runs it immediately (no transcript wait).
        postRecording.sendToLLM(recordingID: recordingID,
                                tool: tool,
                                prompt: promptSnapshot,
                                transcript: transcriptSnapshot,
                                summary: summarySnapshot,
                                executableOverride: executableOverride,
                                extraArgs: llm.extraArgsTokens,
                                cliTimeout: llm.cliTimeout)
    }
}
