import SwiftUI

/// Directory of all named speakers across the user's recordings.
/// Shows each speaker with their recording count and most recent
/// appearance, and lets the user drill into a speaker's recordings.
struct SpeakersView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject private var store: RecordingStore

    var body: some View {
        Group {
            let speakers = store.allSpeakerNames
            if speakers.isEmpty {
                ContentUnavailableView(
                    "No named speakers",
                    systemImage: "person.3",
                    description: Text("Click a speaker label in any transcription to assign a name. Named speakers will appear here.")
                )
            } else {
                List {
                    ForEach(speakers, id: \.self) { name in
                        let recs = store.recordings(forSpeaker: name)
                        SpeakerRow(
                            name: name,
                            recordingCount: recs.count,
                            lastRecordingDate: recs.map(\.createdAt).max(),
                            recordings: recs,
                            selection: $selection
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Speakers")
    }
}

private struct SpeakerRow: View {
    let name: String
    let recordingCount: Int
    let lastRecordingDate: Date?
    let recordings: [Recording]
    @Binding var selection: SidebarSelection?

    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var profileStore: SpeakerProfileStore
    @State private var isExpanded = false
    @State private var isEditing = false
    @State private var isUpdatingProfile = false
    @State private var profileUpdateStatus: String?
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(recordings) { rec in
                Button {
                    selection = .recording(rec.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(rec.createdAt,
                                 format: .dateTime.month().day().year().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatDuration(rec.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } label: {
            HStack {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    if isEditing {
                        TextField("Speaker name", text: $nameDraft)
                            .font(.body.weight(.medium))
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFieldFocused)
                            .onSubmit { commitName() }
                            .onExitCommand { cancelEdit() }
                            .onChange(of: nameFieldFocused) { _, focused in
                                if !focused { commitName() }
                            }
                    } else {
                        Text(name)
                            .font(.body.weight(.medium))
                            .contentShape(Rectangle())
                            .onTapGesture { beginEdit() }
                            .help("Click to rename speaker")
                    }
                    HStack(spacing: 12) {
                        if isUpdatingProfile {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Updating profile…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let status = profileUpdateStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status.contains("No") ? .orange : .teal)
                                .onAppear {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                        profileUpdateStatus = nil
                                    }
                                }
                        } else {
                            if profileStore.profileExists(name: name) {
                                Label("Voice profile", systemImage: "waveform.badge.person.crop")
                                    .font(.caption)
                                    .foregroundStyle(.teal)
                            }
                            Text("\(recordingCount) recording\(recordingCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let date = lastRecordingDate {
                                Text("Last: \(date, format: .dateTime.month().day())")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("Update Voice Profile") {
                    updateVoiceProfile()
                }
                .disabled(isUpdatingProfile)
                if profileStore.profileExists(name: name) {
                    Button("Delete Voice Profile", role: .destructive) {
                        profileStore.deleteProfile(name: name)
                    }
                }
            }
        }
    }

    private func beginEdit() {
        nameDraft = name
        isEditing = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitName() {
        guard isEditing else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != name {
            store.renameSpeakerGlobally(from: name, to: trimmed)
            profileStore.renameProfile(from: name, to: trimmed)
        }
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
        nameDraft = name
    }

    /// Scan all recordings that have this speaker and collect their
    /// stored embeddings to build/update the voice profile.
    private func updateVoiceProfile() {
        isUpdatingProfile = true
        profileUpdateStatus = nil
        let recs = store.recordings(forSpeaker: name)
        var collectedEmbeddings: [([Float], Int)] = []

        for rec in recs {
            for (rawID, speakerName) in rec.speakerNames where speakerName == name {
                if let emb = rec.speakerEmbeddings[rawID], !emb.isEmpty {
                    collectedEmbeddings.append((emb, 1))
                }
            }
        }

        if collectedEmbeddings.isEmpty {
            isUpdatingProfile = false
            profileUpdateStatus = "No voice data found. Re-transcribe recordings to extract embeddings."
            return
        }

        // Compute weighted average centroid from all collected embeddings.
        let dim = collectedEmbeddings[0].0.count
        var centroid = [Float](repeating: 0, count: dim)
        var totalCount = 0
        for (emb, count) in collectedEmbeddings {
            guard emb.count == dim else { continue }
            for i in 0..<dim {
                centroid[i] += emb[i] * Float(count)
            }
            totalCount += count
        }
        if totalCount > 0 {
            for i in 0..<dim {
                centroid[i] /= Float(totalCount)
            }
        }

        // Delete existing profile and create fresh from all data.
        profileStore.deleteProfile(name: name)
        profileStore.updateProfile(name: name, embedding: centroid, sampleCount: totalCount)
        isUpdatingProfile = false
        profileUpdateStatus = "Voice profile updated from \(collectedEmbeddings.count) recording\(collectedEmbeddings.count == 1 ? "" : "s")"
    }
}
