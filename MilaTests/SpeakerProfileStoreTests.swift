import XCTest
@testable import Mila

@MainActor
final class SpeakerProfileStoreTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() async throws {
        // Every settings object below gets its own UserDefaults suite so the
        // opt-in flag never touches `.standard` (and never leaks between
        // tests). Tear them all down.
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    private func tempDir() -> URL {
        TestSupport.makeTempRoot(label: "SpeakerProfileStoreTests")
    }

    /// A `VoiceRecognitionSettings` on its own throwaway suite, never
    /// `.standard`. The setting itself is off out of the box — the point of
    /// the feature — so `enabled` is explicit here: these tests exercise the
    /// storage mechanics with the feature on, and
    /// `VoiceRecognitionGateTests` covers the off state.
    private func makeSettings(enabled: Bool, diarizationReady: Bool = true) -> VoiceRecognitionSettings {
        let name = "SpeakerProfileStoreTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { diarizationReady }
        settings.isEnabled = enabled
        return settings
    }

    /// An opted-in store rooted at `dir`. Keeps the settings object alive for
    /// the store's lifetime by handing it back to the caller via the store's
    /// own `settings` property.
    private func makeStore(in dir: URL, enabled: Bool = true, diarizationReady: Bool = true) -> SpeakerProfileStore {
        SpeakerProfileStore(directory: dir,
                            settings: makeSettings(enabled: enabled,
                                                   diarizationReady: diarizationReady))
    }

    func test_updateProfile_creates_new_profile() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Alice")
        XCTAssertEqual(store.profiles[0].embedding, [1, 0, 0])
        XCTAssertEqual(store.profiles[0].sampleCount, 1)
    }

    func test_updateProfile_merges_centroids() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 1)
        store.updateProfile(name: "Alice", embedding: [0, 1], sampleCount: 1)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].sampleCount, 2)
        // Weighted average: (1*1 + 0*1)/2 = 0.5, (0*1 + 1*1)/2 = 0.5
        XCTAssertEqual(store.profiles[0].embedding[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(store.profiles[0].embedding[1], 0.5, accuracy: 0.001)
    }

    /// The clamp that keeps `sampleCount` inside `maxSampleCount` must apply
    /// to the **stored count only**, never to the divisor of the weighted
    /// mean. Both folds weight their numerator by the true counts, so a
    /// clamped divisor stops producing a mean and starts scaling the whole
    /// centroid by `rawTotal / maxSampleCount`.
    ///
    /// Two ceiling-count profiles is the worst case — `rawTotal` is very
    /// nearly `Int.max`, i.e. twice the clamp — so the wrong shape yields
    /// `[1, 1]` where the mean is `[0.5, 0.5]`. The `accuracy: 0.001`
    /// assertions below are therefore discriminating rather than decorative:
    /// dividing by the clamped total fails them by 0.5.
    func test_updateProfile_divides_by_true_total_when_stored_count_saturates() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        let ceiling = VoiceProfile.maxSampleCount
        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: ceiling)
        store.updateProfile(name: "Alice", embedding: [0, 1], sampleCount: ceiling)

        XCTAssertEqual(store.profiles.count, 1)
        // (1*c + 0*c) / 2c = 0.5 — NOT (1*c + 0*c) / c = 1.0.
        XCTAssertEqual(store.profiles[0].embedding[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(store.profiles[0].embedding[1], 0.5, accuracy: 0.001)
        // The stored count saturates rather than overflowing…
        XCTAssertEqual(store.profiles[0].sampleCount, ceiling)
        // …and stays something `load` will hand back, which is the whole
        // point of having a ceiling.
        XCTAssertNil(store.profiles[0].unusableReason)
    }

    /// The control for the case above: a sum that lands exactly *on* the
    /// ceiling is not clamped at all, so the two divisors coincide and the
    /// mean is unaffected. Fixing the fold must not disturb this.
    func test_updateProfile_sum_exactly_at_ceiling_is_not_clamped() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        let ceiling = VoiceProfile.maxSampleCount
        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: ceiling - 1)
        store.updateProfile(name: "Alice", embedding: [0, 1], sampleCount: 1)

        XCTAssertEqual(store.profiles[0].sampleCount, ceiling)
        // The lone new sample is a ~10⁻¹⁹ share, so the centroid barely moves.
        XCTAssertEqual(store.profiles[0].embedding[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(store.profiles[0].embedding[1], 0.0, accuracy: 0.001)
        XCTAssertNil(store.profiles[0].unusableReason)
    }

    /// Same invariant on the other fold. `mergeProfiles` had the identical
    /// clamped-divisor shape, so it needs its own guard — a fix applied to
    /// one call site and not the other is exactly the failure mode here.
    func test_mergeProfiles_divides_by_true_total_when_stored_count_saturates() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        let ceiling = VoiceProfile.maxSampleCount
        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: ceiling)
        store.updateProfile(name: "Bob", embedding: [0, 1], sampleCount: ceiling)

        let merged = store.mergeProfiles(keep: "Alice", absorb: "Bob")

        XCTAssertEqual(store.profiles.count, 1)
        // Same discrimination as above: the clamped divisor gives [1, 1].
        XCTAssertEqual(merged?.embedding[0] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(merged?.embedding[1] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(merged?.sampleCount, ceiling)
        XCTAssertNil(merged?.unusableReason)
    }

    func test_updateProfile_rejects_dimension_mismatch() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 1)

        // Should not merge — dimension mismatch
        XCTAssertEqual(store.profiles[0].sampleCount, 1)
        XCTAssertEqual(store.profiles[0].embedding.count, 3)
    }

    func test_deleteProfile_by_name() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [2], sampleCount: 1)

        store.deleteProfile(name: "Alice")

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Bob")
    }

    func test_renameProfile() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
        store.renameProfile(from: "Alice", to: "Alicia")

        XCTAssertEqual(store.profiles[0].name, "Alicia")
        XCTAssertFalse(store.profileExists(name: "Alice"))
        XCTAssertTrue(store.profileExists(name: "Alicia"))
    }

    func test_match_returns_best_above_threshold() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [0, 1, 0], sampleCount: 1)

        // Exact match for Alice
        let match = store.match(embedding: [1, 0, 0], threshold: 0.9)
        XCTAssertEqual(match?.name, "Alice")

        // No match above threshold
        let noMatch = store.match(embedding: [0.5, 0.5, 0.5], threshold: 0.99)
        XCTAssertNil(noMatch)
    }

    func test_mergeProfiles() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 2)
        store.updateProfile(name: "Bob", embedding: [0, 1], sampleCount: 2)

        let merged = store.mergeProfiles(keep: "Alice", absorb: "Bob")

        XCTAssertNotNil(merged)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(merged?.name, "Alice")
        XCTAssertEqual(merged?.sampleCount, 4)
        // Weighted average: (1*2 + 0*2)/4 = 0.5, (0*2 + 1*2)/4 = 0.5
        XCTAssertEqual(merged?.embedding[0] ?? 0, 0.5, accuracy: 0.001)
    }

    func test_persistence_round_trip() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let store = makeStore(in: dir)
            store.updateProfile(name: "Alice", embedding: [1, 2, 3], sampleCount: 5)
        }

        let reloaded = makeStore(in: dir)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles[0].name, "Alice")
        XCTAssertEqual(reloaded.profiles[0].embedding, [1, 2, 3])
        XCTAssertEqual(reloaded.profiles[0].sampleCount, 5)
    }

    // MARK: - Deletion observers

    /// Deleting is a privacy action, and the store is not the only place the
    /// data lives: `LiveSpeakerDiarizer` was seeded with these centroids at
    /// record-start and keeps its own copy. The notification is what lets a
    /// recording already in flight drop them — without it the deletion is
    /// undone at stop. `RecognisedSpeakerAssignerTests` drives the whole
    /// chain; these pin the store's half of it.
    func test_deleteAllProfiles_notifies_observers() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        store.deleteAllProfiles()

        XCTAssertEqual(seen, [.all])
    }

    /// The case that most needs it. With the feature off the file is never
    /// parsed, so `profiles` is empty and the store cannot say *what* it
    /// deleted — `.all` is both the honest answer and the safe one. Firing
    /// only when something was in memory would skip exactly the user who
    /// switched the feature off and then deleted.
    func test_deleteAllProfiles_notifies_even_with_nothing_in_memory() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir, enabled: false)
        XCTAssertTrue(store.profiles.isEmpty, "precondition: nothing parsed while off")

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        store.deleteAllProfiles()

        XCTAssertEqual(seen, [.all])
    }

    func test_deleteProfile_notifies_with_the_deleted_name() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)
        store.updateProfile(name: "Bob", embedding: [2], sampleCount: 1)

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        store.deleteProfile(name: "Alice")
        let bobID = try XCTUnwrap(store.profile(named: "Bob")?.id)
        store.deleteProfile(id: bobID)

        XCTAssertEqual(seen, [.named(["Alice"]), .named(["Bob"])])
    }

    /// A delete that removed nothing must not disturb an in-flight
    /// recording's pool.
    func test_a_delete_that_matches_nothing_does_not_notify() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 1)

        var seen: [SpeakerProfileStore.Deletion] = []
        store.addDeletionObserver { seen.append($0) }
        store.deleteProfile(name: "Nobody")
        store.deleteProfile(id: UUID())

        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(store.profiles.count, 1)
    }

    /// Two registrants, both heard — the mistake `addEnabledObserver`'s
    /// single-slot version made.
    func test_every_deletion_observer_is_called() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        var first = 0, second = 0
        store.addDeletionObserver { _ in first += 1 }
        store.addDeletionObserver { _ in second += 1 }
        store.deleteAllProfiles()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
    }

    func test_seedEntries_returns_all_profiles() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1], sampleCount: 3)
        store.updateProfile(name: "Bob", embedding: [2], sampleCount: 5)

        let entries = store.seedEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Alice")
        XCTAssertEqual(entries[1].name, "Bob")
        // The recent pair rides along as the two new fields.
        XCTAssertEqual(entries[0].recentCentroid, [1])
        XCTAssertEqual(entries[0].recentCount, 3)
        XCTAssertEqual(entries[1].recentCentroid, [2])
        XCTAssertEqual(entries[1].recentCount, 5)
    }

    // MARK: - Recent pair (dual-centroid, #206)

    /// Write a profiles file as literal text, bypassing the store — the only
    /// way to produce an old-format document or values no encoder emits.
    private func writeRawProfilesFile(_ json: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("speaker-profiles.json"))
    }

    /// (a) An old-format file — no `recentCentroid`/`recentCount` keys at all
    /// — is exactly what every profile on every existing user's disk looks
    /// like. It must load unchanged, with the recent pair nil and the profile
    /// fully usable.
    func test_old_format_file_loads_with_nil_recent_pair() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        try writeRawProfilesFile("""
        [{"id":"\(id)","name":"Alice","embedding":[1,0,0],"sampleCount":4,\
        "createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z"}]
        """, in: dir)

        let store = makeStore(in: dir)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Alice")
        XCTAssertNil(store.profiles[0].recentCentroid)
        XCTAssertEqual(store.profiles[0].recentCount, 0)
        XCTAssertNil(store.profiles[0].unusableReason, "a missing recent pair is not a defect")
        XCTAssertEqual(store.match(embedding: [1, 0, 0], threshold: 0.9)?.name, "Alice")
    }

    /// (b) `updateProfile` writes this recording's centroid as the recent
    /// pair, and save/load brings it back.
    func test_recent_pair_survives_a_save_load_round_trip() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let store = makeStore(in: dir)
            store.updateProfile(name: "Alice", embedding: [1, 2, 3], sampleCount: 5)
        }

        let reloaded = makeStore(in: dir)
        XCTAssertEqual(reloaded.profiles[0].recentCentroid, [1, 2, 3])
        XCTAssertEqual(reloaded.profiles[0].recentCount, 5)
    }

    /// The recent pair tracks the *latest* recording, not an accumulation.
    func test_each_update_refreshes_the_recent_pair_to_the_latest() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 40)
        XCTAssertEqual(store.profiles[0].recentCentroid, [1, 0, 0])
        XCTAssertEqual(store.profiles[0].recentCount, 40)

        store.updateProfile(name: "Alice", embedding: [0, 1, 0], sampleCount: 1)

        XCTAssertEqual(store.profiles[0].sampleCount, 41, "the long-run count still accumulates")
        XCTAssertEqual(store.profiles[0].recentCentroid, [0, 1, 0],
                       "recent is the latest recording, not a running mean")
        XCTAssertEqual(store.profiles[0].recentCount, 1)
    }

    /// (c) A recent centroid carrying a value no `Float` can represent (here
    /// the JSON string `"NaN"`, since JSON has no NaN literal) is dropped by
    /// lenient decoding; the stored centroid still matches and the profile is
    /// kept. A bare `NaN` would make the whole document invalid JSON, which is
    /// a different — all-or-nothing — failure.
    func test_malformed_recent_centroid_drops_only_the_recent_pair() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        try writeRawProfilesFile("""
        [{"id":"\(id)","name":"Alice","embedding":[1,0,0],"sampleCount":4,\
        "createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z",\
        "recentCentroid":["NaN",0,0],"recentCount":9}]
        """, in: dir)

        let store = makeStore(in: dir)

        XCTAssertEqual(store.profiles.count, 1, "the sound stored profile survives")
        XCTAssertNil(store.profiles[0].recentCentroid, "the malformed recent centroid is dropped")
        XCTAssertEqual(store.profiles[0].recentCount, 0, "…and its count with it")
        XCTAssertEqual(store.match(embedding: [1, 0, 0], threshold: 0.9)?.name, "Alice",
                       "matching still runs on the stored centroid")
        XCTAssertEqual(store.profiles[0].sampleCount, 4, "the stored count is untouched")
    }

    /// A semantically-invalid recent pair that survives decoding — a negative
    /// count — is dropped by `recentUnusableReason`, and likewise costs only
    /// the recent pair.
    func test_invalid_recent_count_drops_only_the_recent_pair() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        try writeRawProfilesFile("""
        [{"id":"\(id)","name":"Alice","embedding":[1,0,0],"sampleCount":4,\
        "createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z",\
        "recentCentroid":[0,1,0],"recentCount":-1}]
        """, in: dir)

        let store = makeStore(in: dir)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertNil(store.profiles[0].recentCentroid)
        XCTAssertEqual(store.profiles[0].recentCount, 0)
        XCTAssertNil(store.profiles[0].unusableReason)
    }

    /// A recent count above `maxSampleCount` is out of range — the same bound
    /// the stored count carries — and likewise costs only the recent pair.
    func test_out_of_range_recent_count_drops_only_the_recent_pair() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        try writeRawProfilesFile("""
        [{"id":"\(id)","name":"Alice","embedding":[1,0,0],"sampleCount":4,\
        "createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z",\
        "recentCentroid":[0,1,0],"recentCount":\(VoiceProfile.maxSampleCount + 1)}]
        """, in: dir)

        let store = makeStore(in: dir)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertNil(store.profiles[0].recentCentroid)
        XCTAssertEqual(store.profiles[0].recentCount, 0)
        XCTAssertEqual(store.match(embedding: [1, 0, 0], threshold: 0.9)?.name, "Alice")
    }

    /// A recent centroid of a *different* width than the stored embedding is
    /// tolerated: it survives loading, and because `cosineSimilarity` returns
    /// 0 on a mismatch it simply never helps — the stored centroid still
    /// matches.
    func test_dimension_mismatched_recent_centroid_is_tolerated() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        try writeRawProfilesFile("""
        [{"id":"\(id)","name":"Alice","embedding":[1,0,0],"sampleCount":4,\
        "createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z",\
        "recentCentroid":[0,1],"recentCount":1}]
        """, in: dir)

        let store = makeStore(in: dir)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].recentCentroid, [0, 1], "the mismatched recent pair is kept")
        XCTAssertNil(store.profiles[0].recentUnusableReason)
        XCTAssertEqual(store.match(embedding: [1, 0, 0], threshold: 0.9)?.name, "Alice",
                       "a mismatched recent pair cannot help, but it must not hurt either")
    }

    /// An absent centroid with a positive count, and an empty present
    /// centroid, are both repaired away rather than rejecting the profile.
    func test_empty_or_unbacked_recent_pair_is_dropped() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        try writeRawProfilesFile("""
        [{"id":"\(id)","name":"Alice","embedding":[1,0,0],"sampleCount":4,\
        "createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z",\
        "recentCentroid":[],"recentCount":2},\
        {"id":"\(UUID().uuidString)","name":"Bob","embedding":[0,1,0],"sampleCount":4,\
        "createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z",\
        "recentCount":3}]
        """, in: dir)

        let store = makeStore(in: dir)

        XCTAssertEqual(store.profiles.map(\.name), ["Alice", "Bob"])
        XCTAssertTrue(store.profiles.allSatisfy { $0.recentCentroid == nil && $0.recentCount == 0 })
        XCTAssertTrue(store.profiles.allSatisfy { $0.unusableReason == nil })
    }

    /// (d) Un-naming the recording the recent pair came from clears it: the
    /// count and embedding both match, so there is nothing left to stand
    /// behind it. The stored centroid's subtraction is untouched.
    func test_subtractObservation_clears_the_recent_pair_when_it_is_the_latest() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 2)
        store.updateProfile(name: "Alice", embedding: [0, 1, 0], sampleCount: 1)
        XCTAssertEqual(store.profiles[0].recentCentroid, [0, 1, 0])
        XCTAssertEqual(store.profiles[0].recentCount, 1)

        store.subtractObservation(name: "Alice", embedding: [0, 1, 0], sampleCount: 1)

        XCTAssertEqual(store.profiles[0].sampleCount, 2, "the long-run math is untouched")
        XCTAssertNil(store.profiles[0].recentCentroid)
        XCTAssertEqual(store.profiles[0].recentCount, 0)
    }

    /// Subtracting a *different* observation leaves the recent pair alone.
    func test_subtractObservation_leaves_a_non_matching_recent_pair() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 2)
        store.updateProfile(name: "Alice", embedding: [0, 1, 0], sampleCount: 2)
        XCTAssertEqual(store.profiles[0].recentCentroid, [0, 1, 0])
        XCTAssertEqual(store.profiles[0].recentCount, 2)

        // Same count as the recent pair, but cosine 0.707 to it — a different
        // observation. Only the cosine clause saves the recent pair here.
        store.subtractObservation(name: "Alice", embedding: [1, 1, 0], sampleCount: 2)

        XCTAssertEqual(store.profiles[0].recentCentroid, [0, 1, 0],
                       "a same-count but different observation must not clear the recent pair")
        XCTAssertEqual(store.profiles[0].recentCount, 2)
    }

    /// (e) Merging discards the absorbed profile's recent pair and keeps the
    /// retained one's.
    func test_mergeProfiles_keeps_the_kept_recent_pair_and_discards_the_absorbed() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)

        store.updateProfile(name: "Alice", embedding: [1, 0], sampleCount: 2)
        store.updateProfile(name: "Bob", embedding: [0, 1], sampleCount: 2)

        let merged = store.mergeProfiles(keep: "Alice", absorb: "Bob")

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(merged?.recentCentroid, [1, 0], "the kept profile keeps its own recent pair")
        XCTAssertEqual(merged?.recentCount, 2)
    }
}
