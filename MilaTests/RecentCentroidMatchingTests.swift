import XCTest
@testable import Mila

/// Dual-centroid stored-profile matching (#206).
///
/// A `VoiceProfile` keeps a long-run centroid over every utterance ever
/// observed *and* the most recent recording's centroid. `SpeakerProfileStore.match`
/// accepts either, so a returning speaker whose acoustics moved (new headset,
/// different room) is still recognised where the stored-only match would have
/// missed. Because similarity is a `max`, it degrades safely: it can only ever
/// raise a profile's score, never lower it.
///
/// Real `SpeakerProfileStore` on a temp directory, real 4-dim synthetic
/// embeddings, isolated `VoiceRecognitionSettings`. Each claim that the recent
/// pair is doing the work is paired with the raw stored-only similarity, so a
/// passing test is provably discriminating rather than quiet. Geometry:
///   * `oldAcoustics`  = `[1, 0, 0, 0]` — Alice's headset history.
///   * `todayAcoustics`= `[0, 1, 0, 0]` — Alice in today's room.
///   * `otherSpeaker`  = `[0, 0, 1, 0]` — nobody Alice has ever been.
/// All are orthogonal, so every similarity below is either 0 or 1 exactly.
@MainActor
final class RecentCentroidMatchingTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteNames: [String] = []

    private let oldAcoustics: [Float] = [1, 0, 0, 0]
    private let todayAcoustics: [Float] = [0, 1, 0, 0]
    private let otherSpeaker: [Float] = [0, 0, 1, 0]
    /// Deliberately a test-local constant, so the "stored-only is below the
    /// bar" control is decoupled from the production default.
    private let threshold = 0.7

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "RecentCentroidMatchingTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func makeSettings() -> VoiceRecognitionSettings {
        let name = "RecentCentroidMatchingTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { true }
        settings.isEnabled = true
        return settings
    }

    private func openStore() -> SpeakerProfileStore {
        SpeakerProfileStore(directory: tempRoot, settings: makeSettings())
    }

    private var profilesFile: URL {
        tempRoot.appendingPathComponent("speaker-profiles.json")
    }

    /// A profile straight to disk with the exact geometry above — the stored
    /// centroid is *pure* headset acoustics, which no sequence of
    /// `updateProfile` calls can produce once a room recording has folded in.
    private func writeAliceWithRecent() throws {
        let id = UUID().uuidString
        let json = """
        [{"id":"\(id)","name":"Alice","embedding":[1,0,0,0],"sampleCount":40,\
        "createdAt":"2026-01-01T00:00:00Z","lastSeenAt":"2026-01-01T00:00:00Z",\
        "recentCentroid":[0,1,0,0],"recentCount":1}]
        """
        try Data(json.utf8).write(to: profilesFile)
    }

    // MARK: - (f) The recent centroid enables a match the stored one cannot

    func test_today_style_embedding_matches_via_recent_where_stored_alone_would_fail() throws {
        try writeAliceWithRecent()
        let store = openStore()

        guard let alice = store.profile(named: "Alice") else {
            return XCTFail("the dual-centroid profile must load")
        }
        XCTAssertEqual(alice.recentCentroid, todayAcoustics)
        XCTAssertEqual(alice.recentCount, 1)

        // The load-bearing negative control: the stored centroid alone misses
        // today's voice entirely, so the success below can only come from the
        // recent pair.
        let storedOnly = cosineSimilarity(todayAcoustics, alice.embedding)
        XCTAssertLessThan(storedOnly, threshold,
                          "raw stored-only similarity must be below the bar, or max() is not load-bearing")
        XCTAssertGreaterThanOrEqual(cosineSimilarity(todayAcoustics, alice.recentCentroid ?? []),
                                    threshold)

        XCTAssertEqual(store.match(embedding: todayAcoustics, threshold: threshold)?.name, "Alice",
                       "matching must accept the recent centroid")
    }

    /// The same outcome driven entirely through the public write path:
    /// `updateProfile` folds the room recording into the long-run centroid
    /// *and* stores it as recent, and a later room-style embedding matches
    /// well above the stored-only score.
    func test_updateProfile_recent_pair_enables_the_match() throws {
        let store = openStore()
        store.updateProfile(name: "Alice", embedding: oldAcoustics, sampleCount: 40)
        store.updateProfile(name: "Alice", embedding: todayAcoustics, sampleCount: 1)

        guard let alice = store.profile(named: "Alice") else {
            return XCTFail("Alice must exist")
        }
        XCTAssertEqual(alice.recentCentroid, todayAcoustics, "the latest recording is the recent pair")
        XCTAssertLessThan(cosineSimilarity(todayAcoustics, alice.embedding), threshold,
                          "the long-run centroid is still dominated by the headset history")
        XCTAssertEqual(store.match(embedding: todayAcoustics, threshold: threshold)?.name, "Alice")
    }

    // MARK: - (g) max() cannot conjure a match from nothing

    func test_both_centroids_below_threshold_still_returns_nil() throws {
        try writeAliceWithRecent()
        let store = openStore()

        guard let alice = store.profile(named: "Alice") else {
            return XCTFail("the dual-centroid profile must load")
        }
        XCTAssertLessThan(cosineSimilarity(otherSpeaker, alice.embedding), threshold)
        XCTAssertLessThan(cosineSimilarity(otherSpeaker, alice.recentCentroid ?? []), threshold)

        XCTAssertNil(store.match(embedding: otherSpeaker, threshold: threshold),
                     "the max of two sub-threshold scores is still sub-threshold")
    }

    // MARK: - (h) Stored-only matching is untouched

    func test_old_style_embedding_still_matches_via_stored() throws {
        try writeAliceWithRecent()
        let store = openStore()

        guard let alice = store.profile(named: "Alice") else {
            return XCTFail("the dual-centroid profile must load")
        }
        let storedSim = cosineSimilarity(oldAcoustics, alice.embedding)
        let recentSim = cosineSimilarity(oldAcoustics, alice.recentCentroid ?? [])
        XCTAssertGreaterThanOrEqual(storedSim, threshold)
        XCTAssertLessThan(recentSim, threshold, "the recent pair contributes nothing here")

        XCTAssertEqual(store.match(embedding: oldAcoustics, threshold: threshold)?.name, "Alice",
                       "adding a recent pair must not stop a stored-centroid match")
    }

    // MARK: - Seed forwarding

    /// All three call forms compile and seed: the six-field form (with recent
    /// metadata), the four-field compatibility form, and an untyped empty
    /// array. The recent pair is stored on the pool entry but never used for
    /// matching.
    func test_seedPool_accepts_four_six_and_empty_call_forms() {
        let six = LiveSpeakerDiarizer()
        six.seedPool(with: [
            (id: "Alice", name: "Alice", centroid: oldAcoustics, sampleCount: 40,
             recentCentroid: todayAcoustics, recentCount: 1),
        ])
        XCTAssertEqual(six.currentProfiles().first?.profileName, "Alice")

        let four = LiveSpeakerDiarizer()
        four.seedPool(with: [
            (id: "Alice", name: "Alice", centroid: oldAcoustics, sampleCount: 40),
        ])
        XCTAssertEqual(four.currentProfiles().first?.profileName, "Alice")

        let empty = LiveSpeakerDiarizer()
        empty.seedPool(with: [])
        XCTAssertTrue(empty.currentProfiles().isEmpty)
    }

    /// The six-field form must actually *store* the recent pair on the pool
    /// entry, not merely compile. `assign` deliberately never reads it (the
    /// #206 seam), so nothing behavioural would notice if the fields were
    /// silently dropped — this observes the stored values through the
    /// diarizer's test accessor. The four-field forwarding form is an old
    /// profile's state: nil centroid / zero count.
    func test_seedPool_copies_the_recent_pair_onto_the_pool_entry() {
        let six = LiveSpeakerDiarizer()
        six.seedPool(with: [
            (id: "Alice", name: "Alice", centroid: oldAcoustics, sampleCount: 40,
             recentCentroid: todayAcoustics, recentCount: 1),
        ])
        let seeded = six.recentPair(forSeeded: "SPEAKER_00")
        XCTAssertEqual(seeded?.centroid, todayAcoustics,
                       "the six-field seed must copy recentCentroid onto the pool entry")
        XCTAssertEqual(seeded?.count, 1,
                       "the six-field seed must copy recentCount onto the pool entry")

        let four = LiveSpeakerDiarizer()
        four.seedPool(with: [
            (id: "Alice", name: "Alice", centroid: oldAcoustics, sampleCount: 40),
        ])
        let forwarded = four.recentPair(forSeeded: "SPEAKER_00")
        XCTAssertNil(forwarded?.centroid,
                     "the four-field forwarding form must pass a nil recent centroid")
        XCTAssertEqual(forwarded?.count, 0,
                       "the four-field forwarding form must pass a zero recent count")

        XCTAssertNil(six.recentPair(forSeeded: "SPEAKER_99"),
                     "an unknown id has no pool entry to report")
    }

    // MARK: - The live pool does not match the recent pair (deliberate scope)

    /// The diarizer accepts and stores recent metadata but `assign` still
    /// compares only the stored centroid — carrying the recent pair into live
    /// matching is the separate change tracked by #206. An embedding that
    /// matches *only* the recent pair must therefore mint a new speaker.
    func test_live_pool_does_not_match_the_recent_pair() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = threshold
        d.reset()
        d.seedPool(with: [
            (id: "Alice", name: "Alice", centroid: oldAcoustics, sampleCount: 40,
             recentCentroid: todayAcoustics, recentCount: 1),
        ])

        // Today's voice matches the recent pair (sim 1) but the stored
        // centroid not at all (sim 0) — live matching must ignore the former.
        XCTAssertEqual(cosineSimilarity(todayAcoustics, oldAcoustics), 0, accuracy: 0.0001)
        XCTAssertEqual(d.assign(embedding: todayAcoustics, utteranceDuration: 2.0), "SPEAKER_01",
                       "live assignment still keys off the stored centroid only")
        XCTAssertNil(d.currentProfiles().first { $0.id == "SPEAKER_01" }?.profileName,
                     "the minted speaker is not the stored profile")
    }
}
