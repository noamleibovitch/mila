import XCTest
@testable import Mila

@MainActor
final class RecordingUITestRootTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func makeRoot(name: String = "Mila-UITest-" + UUID().uuidString) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        roots.append(url)
        return url
    }

    func test_owned_private_shared_uuid_root_is_accepted() throws {
        XCTAssertTrue(RecordingStore.isValidUITestRoot(try makeRoot()))
    }

    func test_only_the_named_runner_container_private_uuid_root_is_accepted() throws {
        let home = try makeRoot()
        let parent = home.appendingPathComponent(
            "Library/Containers/io.island.whisper.IslandWhisperUITests.xctrunner/Data/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let candidate = parent.appendingPathComponent("Mila-UITest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(RecordingStore.isValidUITestRoot(candidate, runnerHome: home))
        let other = home.appendingPathComponent("Library/Containers/Other.xctrunner/Data/tmp")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let foreign = other.appendingPathComponent("Mila-UITest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertFalse(RecordingStore.isValidUITestRoot(foreign, runnerHome: home))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        XCTAssertFalse(RecordingStore.isValidUITestRoot(candidate, runnerHome: home))
    }

    func test_public_or_non_uuid_root_is_refused() throws {
        let publicRoot = try makeRoot()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: publicRoot.path)
        XCTAssertFalse(RecordingStore.isValidUITestRoot(publicRoot))
        XCTAssertFalse(RecordingStore.isValidUITestRoot(try makeRoot(name: "Mila-UITest-not-a-uuid-" + UUID().uuidString)))
    }

    func test_symlink_and_nested_root_are_refused() throws {
        let real = try makeRoot()
        let link = real.deletingLastPathComponent().appendingPathComponent("Mila-UITest-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        roots.append(link)
        XCTAssertFalse(RecordingStore.isValidUITestRoot(link))
        let nested = real.appendingPathComponent("Mila-UITest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertFalse(RecordingStore.isValidUITestRoot(nested))
    }
}
