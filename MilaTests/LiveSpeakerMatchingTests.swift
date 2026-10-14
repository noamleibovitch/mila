import XCTest
@testable import Mila

/// Pins the two online-matching improvements added on top of the merged
/// cross-recording voice recognition work (#204 / #206):
///
///   1. **Session normalization** — `assign` compares mean-subtracted
///      embeddings, so a shared channel offset that dominates the raw
///      embedding space no longer compresses same- and cross-speaker
///      similarity into the same threshold band.
///   2. **Temporal stickiness** — a borderline utterance stays with the
///      previous utterance's speaker when that speaker is nearly as similar,
///      without ever lowering a confident match into a mere attach.
///
/// ## Fixture style
///
/// Small meaningful vectors (`e0` = shared channel axis, `e1` = voice A's
/// axis, `e2` = voice B's axis) padded to the 256 dims the daemon actually
/// emits, mirroring the tiny-vector geometry `SeedAnchorWeightTests` uses so
/// every margin below is checkable by hand. The pad is zeros, so mean
/// subtraction only ever touches the axes that carry signal.
@MainActor
final class LiveSpeakerMatchingTests: XCTestCase {

    /// Pad a short, hand-built vector into the 256-dim shape the online
    /// diarizer is written for. The extra coordinates are zero, so the
    /// session mean is zero there and normalization leaves them untouched.
    private func e(_ values: [Float]) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        for (i, x) in values.enumerated() { v[i] = x }
        return v
    }

    private func observedCount(_ d: LiveSpeakerDiarizer, _ id: String) -> Int? {
        d.currentProfiles().first { $0.id == id }?.observedCount
    }

    /// Two seeded anchors at known, orthogonal axes. Used by the stickiness
    /// tests so "previous speaker" can be set to `SPEAKER_00` without the
    /// mint ordering getting in the way.
    private func twoAnchorDiarizer(threshold: Double = 0.55) -> LiveSpeakerDiarizer {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = threshold
        d.seedPool(with: [
            (id: "A", name: "A", centroid: e([1, 0, 0]), sampleCount: 40),
            (id: "B", name: "B", centroid: e([0, 1, 0]), sampleCount: 40),
        ])
        return d
    }

    // MARK: - 1. Channel dominance

    /// A shared channel axis (`e0`) is present in every utterance of both
    /// voices, so it dominates the raw embedding space: two different voices
    /// score cos 0.5 raw, inside the attach band (`createThreshold` 0.40 ..
    /// match 0.55). A raw matcher therefore attaches the first voice-B
    /// utterance to voice A's entry and the two voices fuse. Subtracting the
    /// session mean removes the shared channel axis: the same-speaker
    /// residual stays near 1 while cross-speaker goes to −1, so the sequence
    /// resolves into two ids and each voice keeps one. This is a behavioural
    /// contract — the raw band is described here, not asserted.
    ///
    /// Fixture (hand-checked): A = e0 + A-axis = `[1,1,0]`,
    /// B = e0 + B-axis = `[1,0,1]`; interleaved A,B,A,B,A,B,A,B.
    func test_channel_offset_collapses_without_normalization_but_assign_keeps_one_speaker() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55

        let a = e([1, 1.0, 0])
        let b = e([1, 0.0, 1.0])
        let order: [(v: [Float], isA: Bool)] = [
            (a, true), (b, false), (a, true), (b, false),
            (a, true), (b, false), (a, true), (b, false),
        ]

        var ids: [String] = []
        var aIDs: [String] = []
        for item in order {
            let id = d.ingest(embedding: item.v, startSeconds: 0, endSeconds: 2)
            ids.append(id)
            if item.isA { aIDs.append(id) }
        }

        XCTAssertEqual(Set(ids).count, 2,
                       "channel dominance must not fuse the two voices into one id "
                       + "— got \(Set(ids))")
        XCTAssertEqual(Set(aIDs).count, 1,
                       "all four utterances of voice A must land on one id, got \(aIDs)")
    }

    // MARK: - 2. Stickiness: borderline stays with the previous speaker

    /// `u2` is closer to `SPEAKER_01` (0.53) than to the previous speaker
    /// `SPEAKER_00` (0.50), but the gap is inside the 0.05 margin and both
    /// land in the attach tier. The utterance must stay with `SPEAKER_00`.
    func test_borderline_utterance_stays_with_previous_speaker() {
        let d = twoAnchorDiarizer()
        XCTAssertEqual(d.assign(embedding: e([1, 0, 0])), "SPEAKER_00")
        XCTAssertEqual(d.assign(embedding: e([1, 0.05, 0])), "SPEAKER_00")

        // cos to 00 ≈ 0.50, cos to 01 ≈ 0.53 — both attach-tier, gap 0.03.
        let borderline = e([0.50, 0.53, 0.685])
        XCTAssertEqual(d.assign(embedding: borderline), "SPEAKER_00",
                       "a borderline utterance within the margin must not switch "
                       + "away from the previous speaker")
    }

    // MARK: - 3. Margin negative control

    /// The same shape with a wider gap (0.42 vs 0.53, i.e. > 0.05): the
    /// margin must not apply and the best entry wins as before.
    func test_margin_does_not_follow_previous_when_gap_exceeds_0_05() {
        let d = twoAnchorDiarizer()
        XCTAssertEqual(d.assign(embedding: e([1, 0, 0])), "SPEAKER_00")
        XCTAssertEqual(d.assign(embedding: e([1, 0.05, 0])), "SPEAKER_00")

        // cos to 00 ≈ 0.42, cos to 01 ≈ 0.53 — gap 0.11 > 0.05.
        let clear = e([0.42, 0.53, 0.737])
        XCTAssertEqual(d.assign(embedding: clear), "SPEAKER_01",
                       "outside the margin the closest entry must win")
    }

    // MARK: - 4. Confidence is never downgraded

    /// The previous speaker (00) is within the margin, but the best entry
    /// (01) clears `similarityThreshold` while 00 only clears
    /// `createThreshold`. The tiers differ, so stickiness is not allowed to
    /// turn a confident match into a bare attach: 01 wins and folds.
    func test_confident_winner_beats_sticky_previous() {
        let d = twoAnchorDiarizer()
        XCTAssertEqual(d.assign(embedding: e([1, 0, 0])), "SPEAKER_00")

        // cos to 00 ≈ 0.54 (attach), cos to 01 ≈ 0.585 (confident and clear
        // of the observation gate), gap 0.045 < 0.05.
        let probe = e([0.54, 0.585, 0.60512])
        XCTAssertEqual(d.assign(embedding: probe), "SPEAKER_01",
                       "a confident winner must not be overridden by a merely "
                       + "attachable previous speaker")
        XCTAssertEqual(observedCount(d, "SPEAKER_01"), 1,
                       "the confident winner folds — confidence was not downgraded")
    }

    // MARK: - 4b. Stickiness respects the attach/mint boundary

    /// The previous speaker (00) sits *below* `createThreshold` (0.40) while
    /// the best entry (01) sits in the attach band `[0.40, 0.55)` — both below
    /// the confidence boundary, so the old same-tier gate treated them as one
    /// tier. Pulling 00 forward would then fail the attach branch and mint a
    /// brand-new speaker where raw comparison attached. The margin must not
    /// apply across the attach/mint boundary: 01 is the winner and attaches,
    /// no previous-speaker switch and no mint.
    func test_stickiness_does_not_pull_a_mint_tier_previous_over_an_attach_band_winner() {
        let d = twoAnchorDiarizer()
        XCTAssertEqual(d.assign(embedding: e([1, 0, 0])), "SPEAKER_00")
        XCTAssertEqual(d.assign(embedding: e([1, 0.05, 0])), "SPEAKER_00")

        // cos to 00 ≈ 0.38 (below createThreshold 0.40, mint tier),
        // cos to 01 ≈ 0.42 (attach band), gap 0.04 < 0.05, duration >= 1.0.
        let probe = e([0.38, 0.42, -0.823])
        XCTAssertEqual(d.assign(embedding: probe, utteranceDuration: 2.0), "SPEAKER_01",
                       "a mint-tier previous speaker must not pull an attach-band "
                       + "winner over the boundary and force a new speaker")
        XCTAssertEqual(d.currentProfiles().count, 2,
                       "the attach-band winner attaches — no third speaker is minted")
    }

    /// Companion negative control for the boundary check: when the previous
    /// speaker (00) is *also* in the attach band and within the margin, the
    /// two are genuinely same-tier and stickiness must still select 00. This
    /// proves the new boundary condition does not disable stickiness within a
    /// tier.
    func test_stickiness_still_selects_previous_when_both_are_in_the_attach_band() {
        let d = twoAnchorDiarizer()
        XCTAssertEqual(d.assign(embedding: e([1, 0, 0])), "SPEAKER_00")
        XCTAssertEqual(d.assign(embedding: e([1, 0.05, 0])), "SPEAKER_00")

        // cos to 00 ≈ 0.43 (attach band), cos to 01 ≈ 0.47 (attach band),
        // gap 0.04 < 0.05, both on the same side of both boundaries.
        let probe = e([0.43, 0.47, -0.770])
        XCTAssertEqual(d.assign(embedding: probe, utteranceDuration: 2.0), "SPEAKER_00",
                       "same-tier stickiness must still select the previous speaker "
                       + "within the attach band")
    }

    // MARK: - 5. Sub-3-utterance sessions still use raw cosine

    /// Until three usable embeddings are in, no mean exists and the
    /// comparison must be exactly today's raw cosine. A probe at raw cosine
    /// ≈ 0.486 to the sole entry sits below the match threshold and above the
    /// create floor, so it attaches without folding — the raw arithmetic.
    func test_fewer_than_3_usable_utterances_use_raw_cosine() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55
        _ = d.ingest(embedding: e([1, 0, 0]), startSeconds: 0, endSeconds: 2)
        XCTAssertEqual(observedCount(d, "SPEAKER_00"), 1)

        // cos([0.5,0.9,0],[1,0,0]) = 0.5 / sqrt(0.25+0.81) ≈ 0.486.
        let probe = e([0.5, 0.9, 0])
        XCTAssertLessThan(cosineSimilarity(probe, e([1, 0, 0])), d.similarityThreshold)
        XCTAssertEqual(d.assign(embedding: probe), "SPEAKER_00",
                       "with fewer than 3 usable utterances the raw cosine decides")
        XCTAssertEqual(observedCount(d, "SPEAKER_00"), 1,
                       "0.486 is below the match threshold, so it attaches without folding")
    }

    // MARK: - 6. Zero norm after mean subtraction falls back to raw

    /// Once a mean exists, an embedding equal to that mean subtracts to the
    /// zero vector. The comparison must fall back to raw cosine instead of
    /// dividing by a zero norm — a real id comes back, no NaN.
    func test_zero_norm_after_mean_subtraction_falls_back_to_raw() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55
        _ = d.ingest(embedding: e([1, 0, 0]), startSeconds: 0, endSeconds: 2)
        _ = d.ingest(embedding: e([0, 1, 0]), startSeconds: 2, endSeconds: 4)
        _ = d.ingest(embedding: e([1, 1, 0]), startSeconds: 4, endSeconds: 6)

        // Session sum is [2,2,0], so the mean is [2/3,2/3,0]; feeding it back
        // makes the mean-subtracted embedding ~zero.
        let sessionMean = e([2.0 / 3.0, 2.0 / 3.0, 0])
        let id = d.assign(embedding: sessionMean)
        XCTAssertFalse(id.isEmpty, "the raw-cosine fallback must return a real id")
        XCTAssertTrue(d.currentProfiles().contains { $0.id == id },
                      "the returned id must be a live pool entry")
    }

    // MARK: - 7. reset clears the session state

    /// `reset()` must drop the accumulator and the previous-speaker tracker so
    /// a new recording starts fresh: the first utterance mints `SPEAKER_00`
    /// with no stickiness, exactly like a brand-new diarizer.
    func test_reset_clears_session_state() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55
        _ = d.ingest(embedding: e([1, 1, 0]), startSeconds: 0, endSeconds: 2)
        _ = d.ingest(embedding: e([1, 0.8, 0]), startSeconds: 2, endSeconds: 4)
        _ = d.ingest(embedding: e([1, 0, 1]), startSeconds: 4, endSeconds: 6)

        d.reset()

        let fresh = LiveSpeakerDiarizer()
        fresh.similarityThreshold = 0.55
        for v in [e([1, 0, 0]), e([1, 0, 1]), e([1, 0.8, 0])] {
            XCTAssertEqual(
                d.ingest(embedding: v, startSeconds: 0, endSeconds: 2),
                fresh.ingest(embedding: v, startSeconds: 0, endSeconds: 2),
                "after reset the diarizer must behave like a fresh one")
        }
    }

    // MARK: - 8. Observation quality gate (learning vs matching)

    /// A long, clearly-confident utterance folds the persisted observation
    /// pair; a short-but-confident one still folds the matching pair (that is
    /// how the entry tracks today's acoustics) but must not reach the profile.
    func test_short_confident_match_adapts_matching_but_does_not_observe() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55
        d.seedPool(with: [(id: "A", name: "A", centroid: e([1, 0, 0]), sampleCount: 40)])

        // 3 s, cos 0.8 — clears threshold + 0.03, so it observes.
        let long = e([0.8, 0.6, 0])
        XCTAssertEqual(d.assign(embedding: long, utteranceDuration: 3.0), "SPEAKER_00")
        XCTAssertEqual(observedCount(d, "SPEAKER_00"), 1, "a long confident match observes")
        let afterLong = d.matchingSampleCount(forSpeaker: "SPEAKER_00")

        // 1 s, still a confident match — matching adapts, observation does not.
        XCTAssertEqual(d.assign(embedding: long, utteranceDuration: 1.0), "SPEAKER_00")
        XCTAssertEqual(observedCount(d, "SPEAKER_00"), 1,
                       "a sub-2 s utterance must not reach the persisted profile")
        XCTAssertEqual(d.matchingSampleCount(forSpeaker: "SPEAKER_00"), (afterLong ?? 0) + 1,
                       "the confident match still folds the matching representation")
    }

    /// A match that only just clears `similarityThreshold` is the false-
    /// positive-prone band: it matches (matching folds) but is not worth
    /// learning from, so the observation pair stays empty.
    func test_marginal_confident_match_does_not_observe() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55
        d.seedPool(with: [(id: "A", name: "A", centroid: e([1, 0, 0]), sampleCount: 40)])

        // cos ≈ 0.56 — above 0.55 (confident) but below 0.55 + 0.03.
        let marginal = e([0.56, 0.8285, 0])
        XCTAssertGreaterThanOrEqual(cosineSimilarity(marginal, e([1, 0, 0])), d.similarityThreshold)
        XCTAssertLessThan(cosineSimilarity(marginal, e([1, 0, 0])),
                          d.similarityThreshold + LiveSpeakerDiarizer.observationConfidenceMargin)

        XCTAssertEqual(d.assign(embedding: marginal, utteranceDuration: 3.0), "SPEAKER_00")
        XCTAssertEqual(observedCount(d, "SPEAKER_00"), 0,
                       "a just-cleared match must not teach the profile")
        XCTAssertEqual(d.matchingSampleCount(forSpeaker: "SPEAKER_00"), 4,
                       "but it still folds the matching representation")
    }

    /// Enrollment observes on duration alone — there is no winner to be
    /// confident about. A short mint labels but starts with an empty observed
    /// pair; a later quality match can still fill it.
    func test_enrollment_observes_only_when_long() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55

        XCTAssertEqual(d.assign(embedding: e([1, 0, 0]), utteranceDuration: 1.0), "SPEAKER_00")
        XCTAssertEqual(observedCount(d, "SPEAKER_00"), 0,
                       "a short enrollment utterance labels but does not observe")

        XCTAssertEqual(d.assign(embedding: e([0, 1, 0]), utteranceDuration: 3.0), "SPEAKER_01")
        XCTAssertEqual(observedCount(d, "SPEAKER_01"), 1, "a long enrollment utterance observes")

        // Repair: a later long, clear match fills the first entry's empty pair.
        let repair = e([1, 0, 0])
        XCTAssertEqual(d.assign(embedding: repair, utteranceDuration: 3.0), "SPEAKER_00")
        XCTAssertEqual(observedCount(d, "SPEAKER_00"), 1,
                       "a quality utterance can fill a pair the short enrollment left empty")
        XCTAssertEqual(d.currentProfiles().first { $0.id == "SPEAKER_00" }?.observedCentroid, repair,
                       "the repaired pair is built from the observing member only")
    }

    /// The deferred recluster pass re-derives observed pairs from cluster
    /// membership and must apply the same quality gate: a narrator the online
    /// pass fragmented across ids collapses to one id, but nothing is learned
    /// from the sub-2 s noise.
    ///
    /// Online fragmentation here is the session-normalization effect: all
    /// utterances carry a large shared channel axis, so once three are in the
    /// session mean, a fourth same-voice fragment whose residual points away
    /// from the centroid gets a strongly negative normalized similarity and
    /// mints a second id. Offline the raw cosine sees one voice.
    func test_recluster_quality_gate_matches_online() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55

        var ids: [String] = []
        ids.append(d.ingest(embedding: e([10, 1, 0]), startSeconds: 0, endSeconds: 1))
        ids.append(d.ingest(embedding: e([10, 1, 0]), startSeconds: 1, endSeconds: 2))
        ids.append(d.ingest(embedding: e([10, 1, 0]), startSeconds: 2, endSeconds: 3))
        ids.append(d.ingest(embedding: e([10, 0, 1]), startSeconds: 3, endSeconds: 4))
        XCTAssertEqual(Set(ids).count, 2,
                       "fixture must start fragmented for the correction to be meaningful")

        XCTAssertNotNil(d.applyReclusteredLabels())
        XCTAssertEqual(Set(d.intervals.map { $0.speaker }).count, 1,
                       "all fragments must relabel to one cluster id")
        let clusterID = d.intervals[0].speaker
        XCTAssertEqual(observedCount(d, clusterID), 0,
                       "nothing is learned from sub-2 s noise")
        XCTAssertEqual(d.matchingSampleCount(forSpeaker: clusterID), 4,
                       "matching stats still fold every fragment")
    }

    /// Companion to the gate test: when the fragments are long enough, the
    /// recluster pass re-derives the full observation count for the cluster
    /// (enrollment plus confident folds all pass the duration gate).
    func test_recluster_enrollment_observations_survive() {
        let d = LiveSpeakerDiarizer()
        d.similarityThreshold = 0.55

        _ = d.ingest(embedding: e([10, 1, 0]), startSeconds: 0, endSeconds: 3)
        _ = d.ingest(embedding: e([10, 1, 0]), startSeconds: 3, endSeconds: 6)
        _ = d.ingest(embedding: e([10, 1, 0]), startSeconds: 6, endSeconds: 9)
        _ = d.ingest(embedding: e([10, 0, 1]), startSeconds: 9, endSeconds: 12)

        XCTAssertNotNil(d.applyReclusteredLabels())
        let clusterID = d.intervals[0].speaker
        XCTAssertEqual(Set(d.intervals.map { $0.speaker }).count, 1)
        XCTAssertEqual(observedCount(d, clusterID), 4,
                       "enrollment plus confident folds all pass the duration gate")
        XCTAssertEqual(d.matchingSampleCount(forSpeaker: clusterID), 4)
    }
}
