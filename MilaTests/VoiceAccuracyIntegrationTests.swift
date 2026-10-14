import XCTest
@testable import Mila

@MainActor
final class VoiceAccuracyIntegrationTests: XCTestCase {
    private func profile() -> VoiceProfile {
        VoiceProfile(id: UUID(), name: "Speaker", embedding: [1, 0], sampleCount: 4,
                     createdAt: Date(timeIntervalSince1970: 0), lastSeenAt: Date(timeIntervalSince1970: 1),
                     embeddingModel: SpeakerEmbeddingModel.current.id,
                     importedShares: [.init(bundleKey: "bundle", sharedName: "Speaker")],
                     recentCentroid: [0, 1], recentCount: 2)
    }

    func test_model_import_tokens_and_recent_pair_survive_one_round_trip() throws {
        let original = profile()
        let restored = try JSONDecoder().decode(VoiceProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.embeddingModel, original.embeddingModel)
        XCTAssertEqual(restored.importedShares, original.importedShares)
        XCTAssertEqual(restored.recentCentroid, original.recentCentroid)
        XCTAssertEqual(restored.recentCount, original.recentCount)
        XCTAssertEqual(restored.embedding, original.embedding)
        XCTAssertNil(restored.unusableReason)
        XCTAssertNil(restored.recentUnusableReason)
    }

    func test_recent_repair_keeps_valid_centroid_model_and_import_history() throws {
        let root = TestSupport.makeTempRoot(label: "VoiceAccuracyIntegrationTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "VoiceAccuracyIntegrationTests.\(UUID())"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        var damaged = profile()
        damaged.recentCentroid = [VoiceProfile.maxEmbeddingMagnitude * 2, 0]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([damaged]).write(to: root.appendingPathComponent("speaker-profiles.json"))
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.diarizationReady = { true }
        settings.isEnabled = true
        let store = SpeakerProfileStore(directory: root, settings: settings)
        let restored = try XCTUnwrap(store.profiles.first)
        XCTAssertEqual(restored.embedding, damaged.embedding)
        XCTAssertEqual(restored.embeddingModel, damaged.embeddingModel)
        XCTAssertEqual(restored.importedShares, damaged.importedShares)
        XCTAssertNil(restored.recentCentroid)
        XCTAssertEqual(restored.recentCount, 0)
        XCTAssertTrue(store.importedShareTokens.contains(damaged.importedShares[0]))
    }

    func test_wrong_model_cannot_refresh_recent_pair_or_change_import_history() throws {
        let root = TestSupport.makeTempRoot(label: "VoiceAccuracyIntegrationTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "VoiceAccuracyIntegrationTests.\(UUID())"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.diarizationReady = { true }
        settings.isEnabled = true
        let store = SpeakerProfileStore(directory: root, settings: settings)
        store.updateProfile(name: "Speaker", embedding: [1, 0], sampleCount: 2)
        let token = ImportedShareToken(bundleKey: "bundle", sharedName: "Speaker")
        store.recordImport(token: token, onProfileNamed: "Speaker")
        store.updateProfile(name: "Speaker", embedding: [0, 1], sampleCount: 2, embeddingModel: "incompatible-model")
        let unchanged = try XCTUnwrap(store.profiles.first)
        XCTAssertEqual(unchanged.recentCentroid, [1, 0])
        XCTAssertEqual(unchanged.recentCount, 2)
        XCTAssertEqual(unchanged.importedShares, [token])
        XCTAssertEqual(unchanged.sampleCount, 2)
    }
}
