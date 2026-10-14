import XCTest
@testable import Mila

/// Tests for the deferred re-clustering pass that corrects the live
/// diarizer's greedy online speaker assignments at end of recording.
///
/// Fixtures are synthetic 256-dimensional embeddings, following the geometric
/// pattern of `SeedAnchorWeightTests` / `LiveSpeakerDiarizerPoolTests`: one
/// "voice" is a base direction plus deterministic noise, so same-voice cosine
/// sits high and cross-voice cosine sits near zero. No Python or pyannote.
@MainActor
final class LiveSpeakerReclusteringTests: XCTestCase {

    private let dim = 256
    private let threshold = 0.55

    // MARK: - Synthetic embeddings

    /// Voice A occupies the even coordinates, voice B the odd ones. Their
    /// cosine is ~0: two clearly distinct voices.
    private func baseA() -> [Float] { (0..<dim).map { $0 % 2 == 0 ? 1 : 0 } }
    private func baseB() -> [Float] { (0..<dim).map { $0 % 2 == 1 ? 1 : 0 } }

    /// Deterministic ±`amplitude` jitter on top of a base direction. Keeps
    /// same-voice cosine comfortably above the threshold without ever making
    /// two voices look alike.
    private func sample(_ base: [Float], seed: Int, amplitude: Float = 0.12) -> [Float] {
        var state = UInt64(truncatingIfNeeded: seed) &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return base.map { value in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(Double(state >> 33) / Double(1 << 31)) // 0..<1
            return value + (unit * 2 - 1) * amplitude
        }
    }

    private func record(_ embedding: [Float],
                        id: String,
                        start: Double,
                        duration: Double = 2.0) -> LiveSpeakerReclustering.UtteranceRecord {
        LiveSpeakerReclustering.UtteranceRecord(start: start,
                                                end: start + duration,
                                                assignedID: id,
                                                embedding: embedding)
    }

    private func poolEntry(_ id: String,
                           centroid: [Float],
                           observedCount: Int = 0,
                           profileName: String? = nil,
                           seededCentroid: [Float] = [],
                           seededCount: Int = 0) -> LiveSpeakerReclustering.PoolEntry {
        LiveSpeakerReclustering.PoolEntry(
            id: id,
            centroid: centroid,
            sampleCount: observedCount,
            observedCentroid: observedCount > 0 ? centroid : [],
            observedCount: observedCount,
            profileName: profileName,
            seededCentroid: seededCentroid,
            seededCount: seededCount)
    }

    // MARK: - (a) Fragmented narrator

    /// One narrator whose voice the online pass split across three ids must
    /// collapse back to a single cluster and a single label.
    func test_fragmented_narrator_collapses_to_one_cluster() {
        let a = baseA()
        let records = [
            record(sample(a, seed: 1), id: "SPEAKER_00", start: 0),
            record(sample(a, seed: 2), id: "SPEAKER_01", start: 2),
            record(sample(a, seed: 3), id: "SPEAKER_00", start: 4),
            record(sample(a, seed: 4), id: "SPEAKER_02", start: 6),
            record(sample(a, seed: 5), id: "SPEAKER_01", start: 8),
            record(sample(a, seed: 6), id: "SPEAKER_02", start: 10),
            record(sample(a, seed: 7), id: "SPEAKER_00", start: 12),
            record(sample(a, seed: 8), id: "SPEAKER_01", start: 14),
        ]
        let pool = [poolEntry("SPEAKER_00", centroid: a),
                    poolEntry("SPEAKER_01", centroid: a),
                    poolEntry("SPEAKER_02", centroid: a)]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        XCTAssertEqual(Set(result.destinations).count, 1,
                       "eight utterances of one voice must produce one label")
        XCTAssertEqual(result.entryStats.count, 1, "one cluster")
        XCTAssertEqual(Set(result.mapping.values), Set(["SPEAKER_00"]),
                       "all three online ids map onto the surviving label")
        XCTAssertEqual(Set(result.mapping.keys),
                       Set(["SPEAKER_00", "SPEAKER_01", "SPEAKER_02"]),
                       "every online id that appears is mapped")
    }

    // MARK: - (b) Two distinct voices stay distinct

    func test_two_interleaved_voices_stay_two_clusters() {
        let a = baseA()
        let b = baseB()
        var records: [LiveSpeakerReclustering.UtteranceRecord] = []
        for i in 0..<8 {
            let isA = i % 2 == 0
            let id = isA ? "SPEAKER_00" : "SPEAKER_01"
            let embedding = sample(isA ? a : b, seed: 100 + i)
            records.append(record(embedding, id: id, start: Double(i) * 2))
        }
        let pool = [poolEntry("SPEAKER_00", centroid: a),
                    poolEntry("SPEAKER_01", centroid: b)]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        XCTAssertEqual(result.entryStats.count, 2, "two voices stay two clusters")
        XCTAssertEqual(Set(result.destinations).count, 2)
        XCTAssertNotEqual(result.destinations[0], result.destinations[1],
                          "the two speakers must not merge")
    }

    // MARK: - (c) Seeded anchor pins a returning speaker

    func test_seeded_anchor_pins_returning_speaker_without_forking() {
        let a = baseA()
        // Alice's stored profile is on disk; the online pass fragmented her
        // across SPEAKER_00 and SPEAKER_01 before the deferred pass runs.
        let pool = [poolEntry("SPEAKER_00", centroid: a, profileName: "Alice",
                              seededCentroid: a, seededCount: 3)]
        let records = [
            record(sample(a, seed: 11), id: "SPEAKER_00", start: 0),
            record(sample(a, seed: 12), id: "SPEAKER_01", start: 2),
            record(sample(a, seed: 13), id: "SPEAKER_00", start: 4),
            record(sample(a, seed: 14), id: "SPEAKER_01", start: 6),
        ]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        XCTAssertEqual(result.destinations, Array(repeating: "SPEAKER_00", count: 4),
                       "every returning utterance must land on the seeded anchor")
        XCTAssertEqual(result.entryStats.count, 1, "the seed must not fork a duplicate")
        XCTAssertEqual(result.entryStats["SPEAKER_00"]?.profileName, "Alice",
                       "the seeded entry keeps its name")
        XCTAssertEqual(result.mapping["SPEAKER_01"], "SPEAKER_00",
                       "the fragment folds onto the anchor")
    }

    // MARK: - (d) Borderline and short utterances

    /// A borderline utterance (below the match bar, above the create floor)
    /// joins the nearest cluster without creating one; a sub-1 s utterance
    /// that is too dissimilar to match still attaches rather than minting.
    /// Neither is a confident observation.
    func test_borderline_and_short_utterances_attach_without_minting() {
        let a = baseA()
        let b = baseB()
        // cos 0.5 to voice A: below the 0.55 match bar, above the 0.40 floor.
        let borderline = zip(a, b).map { $0 * 0.5 + $1 * 0.866 }
        let records = [
            record(sample(a, seed: 21), id: "SPEAKER_00", start: 0, duration: 2.0),
            record(borderline, id: "SPEAKER_01", start: 2, duration: 2.0),
            // Nearly orthogonal, and too short to mint.
            record(b, id: "SPEAKER_02", start: 4, duration: 0.4),
        ]
        let pool = [poolEntry("SPEAKER_00", centroid: a)]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        XCTAssertEqual(result.entryStats.count, 1,
                       "the short dissimilar utterance must not mint a new cluster")
        XCTAssertEqual(Set(result.destinations), Set(["SPEAKER_00"]),
                       "both utterances attach to the only cluster")
        let stats = result.entryStats["SPEAKER_00"]
        XCTAssertEqual(stats?.sampleCount, 3,
                       "matching statistics include the borderline and short members")
        XCTAssertEqual(stats?.observedCount, 1,
                       "observation statistics include only the confident utterance")
    }

    // MARK: - (e) Idempotence

    /// Records that already agree with a single confident cluster produce an
    /// identity mapping and leave the observation delta unchanged.
    func test_consistent_records_produce_identity_mapping() {
        let a = baseA()
        let embeddings = (0..<4).map { sample(a, seed: 30 + $0) }
        let records = embeddings.enumerated().map {
            record($1, id: "SPEAKER_00", start: Double($0) * 2)
        }
        // The online pass already folded all four confidently, so the pool
        // holds their mean as SPEAKER_00's observation.
        var mean = [Float](repeating: 0, count: dim)
        for e in embeddings { for i in 0..<dim { mean[i] += e[i] / 4 } }
        let pool = [poolEntry("SPEAKER_00", centroid: mean, observedCount: 4)]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        XCTAssertEqual(result.mapping, ["SPEAKER_00": "SPEAKER_00"],
                       "an already-consistent id maps to itself")
        XCTAssertEqual(result.destinations, Array(repeating: "SPEAKER_00", count: 4))
        XCTAssertEqual(result.entryStats["SPEAKER_00"]?.observedCount, 4,
                       "the observation count is unchanged")
        XCTAssertGreaterThan(cosineSimilarity(result.entryStats["SPEAKER_00"]?.observedCentroid ?? [],
                                              mean), 0.999,
                             "and the observation centroid is unchanged")
    }

    // MARK: - (f) Unheard seed persists nothing

    func test_seeded_entry_that_never_spoke_persists_nothing() {
        let a = baseA()
        let b = baseB()
        let pool = [poolEntry("SPEAKER_00", centroid: a, profileName: "Alice",
                              seededCentroid: a, seededCount: 3)]
        let records = [
            record(sample(b, seed: 41), id: "SPEAKER_01", start: 0),
            record(sample(b, seed: 42), id: "SPEAKER_01", start: 2),
            record(sample(b, seed: 43), id: "SPEAKER_01", start: 4),
        ]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        let alice = result.entryStats["SPEAKER_00"]
        XCTAssertEqual(alice?.observedCount, 0,
                       "a seeded voice that never spoke observes nothing")
        XCTAssertEqual(alice?.observedCentroid, [],
                       "and carries no embedding into persistence")
        XCTAssertEqual(alice?.sampleCount, 3,
                       "but its seeded weight still anchors matching")
    }

    /// The other half of (f): a zero-norm record keeps its original label and
    /// contributes nothing to any cluster.
    func test_zero_norm_record_keeps_its_original_assignment() {
        let a = baseA()
        let records = [
            record(sample(a, seed: 51), id: "SPEAKER_00", start: 0),
            record([Float](repeating: 0, count: dim), id: "SPEAKER_07", start: 2),
        ]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: [],
                                                       similarityThreshold: threshold)

        XCTAssertEqual(result.destinations[1], "SPEAKER_07",
                       "a zero-norm embedding cannot be re-clustered, so it stays put")
        XCTAssertEqual(result.entryStats["SPEAKER_00"]?.observedCount, 1,
                       "and it contributes no observation")
    }

    // MARK: - Kept-id fallback preserves observations

    /// A sub-2.0 s utterance with an empty pool is minted online (the mint
    /// branch has no duration floor) and keeps its label after the correction.
    /// Its embedding never enters the persisted observation pair: under the
    /// quality-gated enrollment rule a sub-`minObservationDuration` utterance
    /// does not observe, so its noise is not learned. The mid-recording-name
    /// persistence path is protected by the duration-observing kept-id cases
    /// elsewhere; this test's job is label integrity and matching-stats
    /// continuity.
    func test_short_utterance_with_empty_pool_keeps_its_label_and_matching_stats() {
        let a = baseA()
        let e = sample(a, seed: 200)
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()

        diarizer.ingest(embedding: e, startSeconds: 0, endSeconds: 0.4)

        let result = diarizer.applyReclusteredLabels()

        XCTAssertEqual(result?.destinations, ["SPEAKER_00"],
                       "the only utterance keeps its online id")
        let entry = diarizer.currentProfiles().first { $0.id == "SPEAKER_00" }
        XCTAssertNotNil(entry, "the entry survives with its minted id")
        XCTAssertEqual(entry?.observedCount, 0,
                       "a sub-2.0 s enrollment utterance does not observe under the quality gate, so its noise is not learned")
        XCTAssertEqual(diarizer.matchingSampleCount(forSpeaker: "SPEAKER_00"), 1,
                       "but it still counts as a matching member")
    }

    /// A later usable utterance that shares the kept id folds into the same
    /// cluster rather than forking a duplicate. Only the 2.0 s member observes
    /// — the enrollment leg of e0 was gated off below `minObservationDuration`,
    /// while e1's confident member fold observes.
    func test_short_kept_id_and_later_utterance_share_one_cluster() {
        let a = baseA()
        let e0 = sample(a, seed: 201)
        let e1 = sample(a, seed: 202)
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()

        diarizer.ingest(embedding: e0, startSeconds: 0, endSeconds: 0.4)
        diarizer.ingest(embedding: e1, startSeconds: 0.4, endSeconds: 2.4)

        let result = diarizer.applyReclusteredLabels()

        XCTAssertEqual(result?.destinations, ["SPEAKER_00", "SPEAKER_00"],
                       "both utterances land on the one kept cluster")
        let entry = diarizer.currentProfiles().first { $0.id == "SPEAKER_00" }
        XCTAssertEqual(entry?.observedCount, 1,
                       "only the 2.0 s confident member observes; the sub-2.0 s enrollment leg is gated off")
        XCTAssertGreaterThan(cosineSimilarity(entry?.observedCentroid ?? [], e1), 0.999,
                             "the observed centroid is e1 alone, the only member that observed")
        // The component-wise mean of e0 and e1 is the wrong value now: e0 never
        // observed, so including it would attribute the short enrollment
        // embedding to the persisted pair.
        var mean = [Float](repeating: 0, count: dim)
        for i in 0..<dim { mean[i] = (e0[i] + e1[i]) / 2 }
        XCTAssertLessThan(cosineSimilarity(entry?.observedCentroid ?? [], mean), 0.999,
                          "the observed centroid must not be the mean of both members")
        XCTAssertEqual(diarizer.matchingSampleCount(forSpeaker: "SPEAKER_00"), 2,
                       "both members fold the matching stats")
    }

    /// A kept id that online reached by a borderline attach (not a confident
    /// fold, and no seeded profile) must keep its label but persist nothing.
    func test_kept_id_without_confident_online_match_persists_nothing() {
        let a = baseA()
        let b = baseB()
        // The pool entry is a different voice, so this id was never a
        // confident online fold.
        let pool = [poolEntry("SPEAKER_00", centroid: a, observedCount: 1)]
        let records = [record(b, id: "SPEAKER_01", start: 0, duration: 0.4)]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        XCTAssertEqual(result.destinations, ["SPEAKER_01"],
                       "the too-short utterance keeps its label")
        let stats = result.entryStats["SPEAKER_01"]
        XCTAssertEqual(stats?.observedCount, 0,
                       "a non-confident online attach is not persisted")
        XCTAssertEqual(stats?.observedCentroid, [])
        XCTAssertEqual(stats?.sampleCount, 1, "but it still counts as a member")
    }

    /// The fallback reserves the kept id: a later long utterance that has no
    /// cluster to join must not reuse it.
    func test_kept_id_is_reserved_from_later_minting() {
        let a = baseA()
        let b = baseB()
        let e0 = sample(a, seed: 203)
        // The pool snapshot still holds the online-minted kept id.
        let pool = [poolEntry("SPEAKER_01", centroid: e0)]
        let records = [
            record(e0, id: "SPEAKER_01", start: 0, duration: 0.4),
            record(sample(b, seed: 204), id: "SPEAKER_01", start: 1, duration: 2.0),
        ]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        XCTAssertEqual(result.destinations[0], "SPEAKER_01")
        XCTAssertNotEqual(result.destinations[1], "SPEAKER_01",
                          "the kept id is not handed to a second cluster")
        XCTAssertEqual(result.entryStats.count, 2)
    }

    /// A kept id whose retained pool entry carries seed weight anchors its
    /// fallback cluster from that seed, exactly like any other cluster.
    func test_kept_id_fallback_anchors_from_retained_seed() {
        let a = baseA()
        let e = sample(a, seed: 205)
        // A retired seeded entry: the profile name is gone but the retained
        // seed weight survives, as `forgetSeededProfiles` would leave it for
        // an in-recording id.
        let pool = [poolEntry("SPEAKER_03", centroid: a,
                              seededCentroid: a, seededCount: 3)]
        let records = [record(e, id: "SPEAKER_03", start: 0, duration: 0.4)]

        let result = LiveSpeakerReclustering.recluster(records: records,
                                                       pool: pool,
                                                       similarityThreshold: threshold)

        XCTAssertEqual(result.destinations, ["SPEAKER_03"])
        let stats = result.entryStats["SPEAKER_03"]
        XCTAssertEqual(stats?.sampleCount, 4, "3 seed samples + 1 member")
        XCTAssertEqual(stats?.observedCount, 0,
                       "the sub-2.0 s member does not observe under the quality gate")
        XCTAssertGreaterThan(cosineSimilarity(stats?.centroid ?? [], a),
                             cosineSimilarity(e, a),
                             "the retained seed pulls the representation toward it")
    }

    /// A genuinely absorbed id — every record moved to another destination —
    /// loses its observations on application.
    func test_absorbed_id_loses_all_observations_on_application() {
        let a = baseA()
        let b = baseB()
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: a, sampleCount: 40),
                                 (id: "Bob", name: "Bob",
                                  centroid: b, sampleCount: 40)])
        diarizer.ingest(embedding: sample(a, seed: 206), startSeconds: 0, endSeconds: 2)
        diarizer.ingest(embedding: sample(b, seed: 207), startSeconds: 2, endSeconds: 4)
        XCTAssertEqual(diarizer.currentProfiles()
            .first { $0.id == "SPEAKER_01" }?.observedCount, 1)

        let kept = LiveSpeakerReclustering.CorrectedStats(
            centroid: a, sampleCount: 44,
            observedCentroid: sample(a, seed: 206), observedCount: 1,
            profileName: "Alice")
        let injected = LiveSpeakerReclustering.Result(
            destinations: ["SPEAKER_00", "SPEAKER_00"],
            mapping: ["SPEAKER_00": "SPEAKER_00", "SPEAKER_01": "SPEAKER_00"],
            entryStats: ["SPEAKER_00": kept],
            mintedOrder: [])
        diarizer.applyReclusteredLabels(injected)

        XCTAssertEqual(diarizer.currentProfiles()
            .first { $0.id == "SPEAKER_01" }?.observedCount, 0,
                       "an id with no destination is absorbed and persists nothing")
        XCTAssertEqual(diarizer.currentProfiles()
            .first { $0.id == "SPEAKER_00" }?.observedCount, 1)
    }

    /// An id whose only record is a zero-norm embedding keeps its label after
    /// application and persists nothing.
    func test_zero_norm_only_record_keeps_label_and_persists_nothing() {
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()

        diarizer.ingest(embedding: [Float](repeating: 0, count: dim),
                        startSeconds: 0, endSeconds: 0.5)

        let result = diarizer.applyReclusteredLabels()

        XCTAssertEqual(result?.destinations, ["SPEAKER_00"],
                       "the unusable record keeps its label")
        XCTAssertEqual(diarizer.currentProfiles().first?.observedCount, 0,
                       "and generates no statistics to persist")
    }

    // MARK: - Integration shape: the diarizer applies the correction

    /// Exercise the real `LiveSpeakerDiarizer.applyReclusteredLabels`: the
    /// intervals are relabeled and the persisted observation pair is
    /// re-derived from corrected membership.
    func test_diarizer_relabels_intervals_and_rebuilds_observation_pair() {
        let a = baseA()
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: a, sampleCount: 40)])

        // Three near-identical utterances. Online they may fragment; the
        // deferred pass must reunite them on the seeded entry.
        let before = (0..<3).map { sample(a, seed: 60 + $0) }
        for (i, e) in before.enumerated() {
            diarizer.ingest(embedding: e,
                            startSeconds: Double(i) * 2,
                            endSeconds: Double(i) * 2 + 2)
        }
        XCTAssertEqual(diarizer.intervals.count, 3)

        let result = diarizer.applyReclusteredLabels()

        XCTAssertNotNil(result)
        XCTAssertTrue(diarizer.intervals.allSatisfy { $0.speaker == "SPEAKER_00" },
                      "all three intervals move onto the seeded anchor")
        let entry = diarizer.currentProfiles().first { $0.id == "SPEAKER_00" }
        XCTAssertEqual(entry?.observedCount, 3,
                       "the persisted observation re-derives from corrected membership")
        XCTAssertEqual(entry?.profileName, "Alice")
        XCTAssertEqual(entry?.observedCentroid.count, dim)
    }

    /// A second application of the same result must not change labels or
    /// counts — the pass replaces statistics, never accumulates.
    func test_reapplying_the_correction_is_idempotent() {
        let a = baseA()
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: a, sampleCount: 40)])
        for i in 0..<3 {
            diarizer.ingest(embedding: sample(a, seed: 70 + i),
                            startSeconds: Double(i) * 2,
                            endSeconds: Double(i) * 2 + 2)
        }

        let first = diarizer.applyReclusteredLabels()
        let labelsAfterFirst = diarizer.intervals.map(\.speaker)
        let countAfterFirst = diarizer.currentProfiles()
            .first { $0.id == "SPEAKER_00" }?.observedCount

        diarizer.applyReclusteredLabels()

        XCTAssertEqual(diarizer.intervals.map(\.speaker), labelsAfterFirst)
        XCTAssertEqual(diarizer.currentProfiles()
            .first { $0.id == "SPEAKER_00" }?.observedCount, countAfterFirst)
        XCTAssertNotNil(first)
    }

    /// The pass is a no-op when the recording produced no embeddings, so an
    /// opted-out or unconfigured recording is never touched.
    func test_no_records_is_a_no_op() {
        let a = baseA()
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: a, sampleCount: 40)])

        XCTAssertNil(diarizer.applyReclusteredLabels(),
                     "nothing to correct")
        XCTAssertEqual(diarizer.currentProfiles().first?.observedCount, 0)
    }

    /// Reset clears the transient records so they cannot leak into a later
    /// recording.
    func test_reset_clears_records_so_a_later_recording_is_untouched() {
        let a = baseA()
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: a, sampleCount: 40)])
        diarizer.ingest(embedding: sample(a, seed: 80), startSeconds: 0, endSeconds: 2)

        diarizer.reset()

        XCTAssertNil(diarizer.applyReclusteredLabels(),
                     "records were cleared with the pool and intervals")
        XCTAssertTrue(diarizer.intervals.isEmpty)
    }

    // MARK: - Seeded weight stays on the matching side

    /// The corrected matching pair includes borderline members, but the
    /// persisted observation pair excludes them and never absorbs the seed
    /// weight. Both halves of the #204 split survive reclustering.
    func test_seed_weight_and_borderline_members_stay_out_of_observations() {
        let a = baseA()
        let diarizer = LiveSpeakerDiarizer()
        diarizer.similarityThreshold = threshold
        diarizer.reset()
        // Two stored samples so the seed weight is observable as a non-zero
        // `sampleCount` that must not reach `observedCount`.
        diarizer.seedPool(with: [(id: "Alice", name: "Alice",
                                  centroid: a, sampleCount: 2)])

        diarizer.ingest(embedding: sample(a, seed: 90), startSeconds: 0, endSeconds: 2)
        // cos 0.5 to voice A: below the 0.55 match bar, above the 0.40
        // floor, so it attaches online and in the corrected pass without
        // ever entering the persisted observation set.
        let borderline = zip(a, baseB()).map { $0 * 0.5 + $1 * 0.866 }
        diarizer.ingest(embedding: borderline, startSeconds: 2, endSeconds: 4)

        let result = diarizer.applyReclusteredLabels()
        let entry = diarizer.currentProfiles().first { $0.id == "SPEAKER_00" }

        XCTAssertEqual(entry?.observedCount, 1,
                       "only the confident utterance is persisted")
        XCTAssertEqual(result?.entryStats["SPEAKER_00"]?.sampleCount, 4,
                       "matching: 2 seeded + confident + borderline")
    }
}
