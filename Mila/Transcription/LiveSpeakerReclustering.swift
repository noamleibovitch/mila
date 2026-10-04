import Foundation

/// Offline correction of the live (online) speaker assignments.
///
/// `LiveSpeakerDiarizer.assign` labels each VAD utterance the moment its
/// embedding arrives: the first noisy 1–5 s embedding mints a pool entry,
/// borderline utterances attach to the nearest entry without folding, and a
/// sub-1 s utterance can never mint a new speaker. Those decisions are
/// irreversible online, so one narrator routinely ends up fragmented across
/// several `SPEAKER_NN` ids — and because the offline re-diarize pass is
/// skipped when the live pool stayed at ≤3 speakers, those greedy labels are
/// often the final transcript.
///
/// This is the deferred second look. At end of recording the whole utterance
/// set is re-clustered against the seeded voice profiles and rewritten before
/// `RecognisedSpeakerAssigner.finish` reads the diarizer's observations.
/// Speaker labels shown *during* recording are untouched; only the post-stop
/// rewrite moves.
///
/// The function is pure and deterministic (Foundation only). It is an
/// enum with static members rather than an instance because it holds no
/// state — the diarizer owns the records and the pool, and this transforms
/// one snapshot of them into a correction.
///
/// ## Why per-utterance destinations, not just an old-id map
///
/// The natural consumer wants `oldID -> newID`, and `Result.mapping` provides
/// exactly that for every old id whose records agree. But the algorithm is
/// per-utterance, so two records that shared an online id can legitimately
/// end at two different anchors, and a zero-norm record must keep its
/// original label while a valid record with the same online id moves. A
/// total id map cannot express either case without silently dropping a
/// requirement, so `Result.destinations` (one per record, index-aligned with
/// the diarizer's `intervals`) is the authoritative output and `mapping` is a
/// convenience for the uniform case.
@MainActor
enum LiveSpeakerReclustering {

    /// One VAD utterance this recording produced. Mirrors the diarizer's
    /// interval list one-to-one and in the same order, so `destinations[i]`
    /// rewrites `intervals[i]`.
    struct UtteranceRecord {
        let start: Double
        let end: Double
        let assignedID: String
        let embedding: [Float]

        var duration: Double { end - start }
    }

    /// The diarizer's pool entry as the recluster sees it. `seededCentroid` /
    /// `seededCount` are the *original* stored profile and its capped seed
    /// weight, kept separately from the online matching pair so corrected
    /// statistics can be rebuilt as `seed + corrected members` instead of
    /// re-folding members that the online pass already counted.
    struct PoolEntry {
        let id: String
        let centroid: [Float]
        let sampleCount: Int
        let observedCentroid: [Float]
        let observedCount: Int
        let profileName: String?
        let seededCentroid: [Float]
        let seededCount: Int
    }

    /// The two statistics pairs a pool entry carries after correction.
    struct CorrectedStats {
        /// Matching pair — seed weight plus *every* corrected member.
        let centroid: [Float]
        let sampleCount: Int
        /// Persistence pair — confidently observed members only; the seed
        /// weight never enters it.
        let observedCentroid: [Float]
        let observedCount: Int
        let profileName: String?
    }

    struct Result {
        /// Corrected speaker id per record, index-aligned with the records
        /// (and therefore with the diarizer's intervals).
        let destinations: [String]
        /// `oldID -> newID` for every old id whose records share one
        /// destination. Omitted for ids that split.
        let mapping: [String: String]
        /// Corrected statistics keyed by destination id.
        let entryStats: [String: CorrectedStats]
        /// Destination ids that do not yet exist in the pool, in creation
        /// order — the caller appends them.
        let mintedOrder: [String]
    }

    /// A cluster under construction. Seeded clusters carry their stored
    /// weight; freshly formed clusters start from their first member.
    private struct Cluster {
        let id: String
        let dim: Int
        let seedCentroid: [Float]
        let seedCount: Int
        var memberSum: [Float]
        var memberCount: Int
        var obsSum: [Float]
        var obsCount: Int
        let profileName: String?

        /// Running mean of the seed (if any) plus every member folded so far.
        /// Cosine similarity is scale-invariant, but dividing here keeps the
        /// representation a true mean and the arithmetic easy to reason about.
        var representation: [Float] {
            guard dim > 0 else { return [] }
            let total = Float(seedCount + memberCount)
            guard total > 0 else { return [] }
            let seedWeight = Float(seedCount)
            let hasSeed = seedCount > 0 && seedCentroid.count == dim
            var out = [Float](repeating: 0, count: dim)
            for i in 0..<dim {
                let seeded = hasSeed ? seedCentroid[i] * seedWeight : 0
                out[i] = (seeded + memberSum[i]) / total
            }
            return out
        }
    }

    /// Re-cluster one recording's utterances against its pool snapshot.
    ///
    /// Seeded entries (`profileName != nil`) are pinned labeled anchors. Every
    /// usable utterance is folded chronologically into the anchor/cluster with
    /// the highest cosine similarity when that clears `similarityThreshold`;
    /// otherwise it joins the nearest cluster when it clears
    /// `max(0.40, similarityThreshold - 0.15)`; otherwise it forms a new
    /// cluster only if it is at least one second long, mirroring `assign`'s
    /// floors. A too-short utterance attaches to the nearest cluster if there
    /// is one; if there is not it keeps its original assignment *and* seeds a
    /// cluster for it, so the observation the online pass already recorded is
    /// not dropped by the correcting rewrite. Empty and zero-norm embeddings
    /// keep their original assignment and contribute nothing.
    static func recluster(records: [UtteranceRecord],
                          pool: [PoolEntry],
                          similarityThreshold: Double) -> Result {
        let createThreshold = max(0.40, similarityThreshold - 0.15)
        let poolIDs = Set(pool.map(\.id))
        let seededIDs = Set(pool.filter { $0.profileName != nil }.map(\.id))

        var clusters: [Cluster] = []
        for entry in pool {
            guard entry.profileName != nil,
                  entry.seededCount > 0,
                  !entry.seededCentroid.isEmpty else { continue }
            let dim = entry.seededCentroid.count
            clusters.append(Cluster(
                id: entry.id,
                dim: dim,
                seedCentroid: entry.seededCentroid,
                seedCount: entry.seededCount,
                memberSum: [Float](repeating: 0, count: dim),
                memberCount: 0,
                obsSum: [Float](repeating: 0, count: dim),
                obsCount: 0,
                profileName: entry.profileName))
        }

        var usedIDs = Set(clusters.map(\.id))
        var available = pool
            .filter { $0.profileName == nil && !usedIDs.contains($0.id) }
            .map(\.id)
        var mintCounter = pool.count

        var destinations = [String](repeating: "", count: records.count)

        // Chronological, ties broken by original order — a stable sort, so
        // two utterances with identical timestamps keep the order they
        // arrived in and the result is reproducible.
        let order = records.indices.sorted {
            if records[$0].start == records[$1].start { return $0 < $1 }
            return records[$0].start < records[$1].start
        }

        for idx in order {
            let record = records[idx]
            guard isUsable(record.embedding) else {
                destinations[idx] = record.assignedID
                continue
            }

            var bestIndex = -1
            var bestSim = -Double.greatestFiniteMagnitude
            for (clusterIndex, cluster) in clusters.enumerated() {
                let representation = cluster.representation
                guard representation.count == record.embedding.count,
                      !representation.isEmpty else { continue }
                let sim = cosine(record.embedding, representation)
                if bestIndex == -1 || sim > bestSim {
                    bestIndex = clusterIndex
                    bestSim = sim
                }
            }

            if bestIndex >= 0, bestSim >= similarityThreshold {
                // Mirrors the online quality gate: a confident match always
                // folds the matching stats, but only a long-enough,
                // clearly-confident utterance joins the persisted observed
                // pair. A seeded entry that never gets a quality utterance
                // still persists nothing.
                let observes = record.duration >= LiveSpeakerDiarizer.minObservationDuration
                    && bestSim >= similarityThreshold + LiveSpeakerDiarizer.observationConfidenceMargin
                fold(into: &clusters[bestIndex], record.embedding, observation: observes)
                destinations[idx] = clusters[bestIndex].id
            } else if bestIndex >= 0, bestSim >= createThreshold {
                fold(into: &clusters[bestIndex], record.embedding, observation: false)
                destinations[idx] = clusters[bestIndex].id
            } else if record.duration >= 1.0 {
                let newID = nextID(preferred: record.assignedID,
                                   seededIDs: seededIDs,
                                   usedIDs: &usedIDs,
                                   available: &available,
                                   mintCounter: &mintCounter)
                // ENROLLMENT RULE: the utterance that creates a fresh cluster
                // observes on duration alone — there is no winner to be
                // confident about. Mirrors the online quality gate, so a
                // sub-2 s fresh cluster starts with an empty observed pair.
                let observes = record.duration >= LiveSpeakerDiarizer.minObservationDuration
                let cluster = Cluster(
                    id: newID,
                    dim: record.embedding.count,
                    seedCentroid: [],
                    seedCount: 0,
                    memberSum: record.embedding,
                    memberCount: 1,
                    obsSum: observes ? record.embedding : [Float](repeating: 0, count: record.embedding.count),
                    obsCount: observes ? 1 : 0,
                    profileName: nil)
                clusters.append(cluster)
                destinations[idx] = newID
            } else if bestIndex >= 0 {
                // Too short to mint, but there is a cluster to attach to.
                fold(into: &clusters[bestIndex], record.embedding, observation: false)
                destinations[idx] = clusters[bestIndex].id
            } else if let existing = clusters.firstIndex(where: { $0.id == record.assignedID }) {
                // Too short to mint, nothing scorable to attach to, but a
                // cluster for this id already exists (a seeded entry of a
                // different dimension, or one kept by an earlier record).
                // Reuse it rather than minting a duplicate.
                fold(into: &clusters[existing],
                     record.embedding,
                     observation: onlineObservation(record, pool: pool, threshold: similarityThreshold))
                destinations[idx] = record.assignedID
            } else {
                // Too short to mint and nothing to attach to. The online
                // pass still recorded this utterance — an empty pool mints
                // even a sub-1 s one — so keep its id *and* materialise a
                // cluster for it. Dropping the id here would leave a record
                // claiming it while `applyReclusteredLabels` zeroed its
                // statistics as if absorbed, silently losing the observation.
                let entry = pool.first { $0.id == record.assignedID }
                let dim = record.embedding.count
                let seedCentroid = entry?.seededCentroid ?? []
                let seedCount = entry?.seededCount ?? 0
                let hasSeed = seedCount > 0 && seedCentroid.count == dim
                usedIDs.insert(record.assignedID)
                available.removeAll { $0 == record.assignedID }
                let observed = onlineObservation(record, pool: pool, threshold: similarityThreshold)
                clusters.append(Cluster(
                    id: record.assignedID,
                    dim: dim,
                    seedCentroid: hasSeed ? seedCentroid : [],
                    seedCount: hasSeed ? seedCount : 0,
                    memberSum: record.embedding,
                    memberCount: 1,
                    obsSum: observed ? record.embedding : [Float](repeating: 0, count: dim),
                    obsCount: observed ? 1 : 0,
                    profileName: entry?.profileName))
                destinations[idx] = record.assignedID
            }
        }

        var entryStats: [String: CorrectedStats] = [:]
        var mintedOrder: [String] = []
        for cluster in clusters {
            let observed: [Float]
            if cluster.obsCount > 0 {
                var mean = cluster.obsSum
                let count = Float(cluster.obsCount)
                for i in 0..<mean.count { mean[i] /= count }
                observed = mean
            } else {
                observed = []
            }
            entryStats[cluster.id] = CorrectedStats(
                centroid: cluster.representation,
                sampleCount: cluster.seedCount + cluster.memberCount,
                observedCentroid: observed,
                observedCount: cluster.obsCount,
                profileName: cluster.profileName)
            if !poolIDs.contains(cluster.id) { mintedOrder.append(cluster.id) }
        }

        // Uniform old-id mapping, derived from the per-record destinations.
        var grouped: [String: Set<String>] = [:]
        for i in records.indices {
            grouped[records[i].assignedID, default: []].insert(destinations[i])
        }
        var mapping: [String: String] = [:]
        for (old, dests) in grouped where dests.count == 1 {
            if let destination = dests.first { mapping[old] = destination }
        }

        return Result(destinations: destinations,
                      mapping: mapping,
                      entryStats: entryStats,
                      mintedOrder: mintedOrder)
    }

    private static func fold(_ cluster: inout Cluster,
                             _ embedding: [Float],
                             observation: Bool) {
        // A dimension mismatch cannot contribute to a mean — `cosine`
        // already scored such a pair as 0, so this is unreachable for the
        // confident branch, but an attach branch can still land here.
        guard embedding.count == cluster.dim else { return }
        for i in 0..<cluster.dim { cluster.memberSum[i] += embedding[i] }
        cluster.memberCount += 1
        if observation {
            for i in 0..<cluster.dim { cluster.obsSum[i] += embedding[i] }
            cluster.obsCount += 1
        }
    }

    /// Pick a destination id for a new cluster: keep the online id when it is
    /// free (which makes already-consistent records map to themselves), then
    /// reuse an absorbed non-seeded slot in pool order, then mint positionally.
    private static func nextID(preferred: String,
                               seededIDs: Set<String>,
                               usedIDs: inout Set<String>,
                               available: inout [String],
                               mintCounter: inout Int) -> String {
        if !seededIDs.contains(preferred), !usedIDs.contains(preferred) {
            usedIDs.insert(preferred)
            available.removeAll { $0 == preferred }
            return preferred
        }
        while let next = available.first {
            available.removeFirst()
            if !usedIDs.contains(next) {
                usedIDs.insert(next)
                return next
            }
        }
        var minted = String(format: "SPEAKER_%02d", mintCounter)
        while usedIDs.contains(minted) {
            mintCounter += 1
            minted = String(format: "SPEAKER_%02d", mintCounter)
        }
        mintCounter += 1
        usedIDs.insert(minted)
        return minted
    }

    private static func isUsable(_ embedding: [Float]) -> Bool {
        guard !embedding.isEmpty else { return false }
        for value in embedding where value != 0 { return true }
        return false
    }

    /// Whether the online pass would have *confidently* folded this record
    /// into its own assigned id — the only case its embedding entered the
    /// persisted observation pair. Replays `assign`'s confident-match rule
    /// against the pool snapshot: the record lands on the same id it was
    /// assigned, that entry has a same-dimension centroid, and the cosine
    /// clears the match threshold *and* the observation quality gate (long
    /// enough, clear enough). A record that arrived via the borderline
    /// attach path (or a mint on an empty pool whose final centroid now
    /// drifts) is deliberately not counted. `assign`'s running centroid is
    /// only approximated here by the final snapshot, so an utterance whose
    /// similarity moved across the threshold later in the recording can be
    /// misclassified; the common kept-id cases are exact.
    private static func onlineObservation(_ record: UtteranceRecord,
                                          pool: [PoolEntry],
                                          threshold: Double) -> Bool {
        guard record.duration >= LiveSpeakerDiarizer.minObservationDuration else { return false }
        var bestIndex = -1
        var bestSim = -Double.greatestFiniteMagnitude
        for (idx, entry) in pool.enumerated() {
            guard !entry.centroid.isEmpty else { continue }
            let sim = cosine(record.embedding, entry.centroid)
            if bestIndex == -1 || sim > bestSim {
                bestIndex = idx
                bestSim = sim
            }
        }
        guard bestIndex >= 0 else { return false }
        return pool[bestIndex].id == record.assignedID
            && pool[bestIndex].centroid.count == record.embedding.count
            && bestSim >= threshold + LiveSpeakerDiarizer.observationConfidenceMargin
    }

    /// Float-accumulating cosine similarity. Returns 0 for mismatched or
    /// zero-length inputs so the caller never has to guard.
    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom == 0 ? 0 : Double(dot / denom)
    }
}
