import Foundation

/// Persistent voice profile for cross-recording speaker recognition.
/// Stores the speaker's name alongside a centroid embedding (256-dim
/// vector from wespeaker ECAPA-TDNN via pyannote). The centroid is a
/// running mean of all embeddings observed for this speaker — the more
/// recordings, the tighter the distribution.
struct SpeakerProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 256-dimensional centroid embedding (running mean).
    var embedding: [Float]
    /// Number of utterances folded into the centroid.
    var sampleCount: Int
    var createdAt: Date
    var lastSeenAt: Date

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SpeakerProfile, rhs: SpeakerProfile) -> Bool { lhs.id == rhs.id }
}

/// Manages persistent speaker voice profiles for cross-recording
/// recognition. Profiles are created when a user names a speaker
/// that has an embedding in the live diarizer pool.
@MainActor
final class SpeakerProfileStore: ObservableObject {
    @Published private(set) var profiles: [SpeakerProfile] = []

    private let fileManager = FileManager.default
    private var storeURL: URL {
        let appSupport = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("Mila", isDirectory: true)
            .appendingPathComponent("speaker-profiles.json")
    }

    init() {
        load()
    }

    // MARK: - CRUD

    /// Upsert a speaker profile by name. If a profile with the same name
    /// exists, merge the new embedding into its centroid via weighted
    /// average. Otherwise create a new profile.
    func updateProfile(name: String, embedding: [Float], sampleCount: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !embedding.isEmpty else { return }

        if let idx = profiles.firstIndex(where: { $0.name == trimmed }) {
            // Weighted merge of centroids.
            let existing = profiles[idx]
            let totalCount = existing.sampleCount + sampleCount
            var merged = [Float](repeating: 0, count: embedding.count)
            for i in 0..<merged.count {
                merged[i] = (existing.embedding[i] * Float(existing.sampleCount)
                           + embedding[i] * Float(sampleCount)) / Float(totalCount)
            }
            profiles[idx].embedding = merged
            profiles[idx].sampleCount = totalCount
            profiles[idx].lastSeenAt = Date()
            save()
        } else {
            let profile = SpeakerProfile(
                id: UUID(),
                name: trimmed,
                embedding: embedding,
                sampleCount: sampleCount,
                createdAt: Date(),
                lastSeenAt: Date()
            )
            profiles.append(profile)
            save()
        }
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
    }

    func deleteProfile(name: String) {
        profiles.removeAll { $0.name == name }
        save()
    }

    /// Check if a profile with the given name exists.
    func profileExists(name: String) -> Bool {
        profiles.contains { $0.name == name }
    }

    /// Find the profile for a given name.
    func profile(named: String) -> SpeakerProfile? {
        profiles.first { $0.name == named }
    }

    /// Rename a profile, propagating across all stored profiles.
    func renameProfile(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        if let idx = profiles.firstIndex(where: { $0.name == oldName }) {
            profiles[idx].name = trimmed
            save()
        }
    }

    /// Merge two profiles: keep the `keep` profile, absorb the `absorb`
    /// profile's centroid via weighted average, then delete `absorb`.
    /// Returns the merged profile.
    @discardableResult
    func mergeProfiles(keep keepName: String, absorb absorbName: String) -> SpeakerProfile? {
        guard let keepIdx = profiles.firstIndex(where: { $0.name == keepName }),
              let absorbIdx = profiles.firstIndex(where: { $0.name == absorbName }),
              keepIdx != absorbIdx else { return nil }

        let keep = profiles[keepIdx]
        let absorb = profiles[absorbIdx]
        let totalCount = keep.sampleCount + absorb.sampleCount
        let dim = min(keep.embedding.count, absorb.embedding.count)
        var merged = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            merged[i] = (keep.embedding[i] * Float(keep.sampleCount)
                       + absorb.embedding[i] * Float(absorb.sampleCount)) / Float(totalCount)
        }
        profiles[keepIdx].embedding = merged
        profiles[keepIdx].sampleCount = totalCount
        profiles[keepIdx].lastSeenAt = max(keep.lastSeenAt, absorb.lastSeenAt)

        // Remove absorb (index may have shifted if keepIdx < absorbIdx).
        profiles.removeAll { $0.id == absorb.id }
        save()
        return profiles.first { $0.id == keep.id }
    }

    /// Match an embedding against all stored profiles. Returns the best
    /// match above the threshold, or nil.
    func match(embedding: [Float], threshold: Double = 0.55) -> SpeakerProfile? {
        var best: (profile: SpeakerProfile, sim: Double)?
        for profile in profiles {
            let sim = cosineSimilarity(embedding, profile.embedding)
            if sim >= threshold, best == nil || sim > best!.sim {
                best = (profile, sim)
            }
        }
        return best?.profile
    }

    /// Entries suitable for seeding the live diarizer pool.
    func seedEntries() -> [(id: String, name: String, centroid: [Float], sampleCount: Int)] {
        profiles.map { p in
            (id: p.name, name: p.name, centroid: p.embedding, sampleCount: p.sampleCount)
        }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(profiles)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            print("SpeakerProfileStore save error: \(error)")
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profiles = try decoder.decode([SpeakerProfile].self, from: data)
        } catch {
            print("SpeakerProfileStore load error: \(error)")
        }
    }
}
