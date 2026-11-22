import XCTest
@testable import Mila

/// UI input fences for recording-folder migration.
///
/// These exercise the real store/admission API and the actual drag payload:
/// a context captured before a switch must not act on a same-UUID row in the
/// adopted library, including switch-away-and-back ABA. No view rendering is
/// involved; view call sites use the same `admitLibraryInput` / payload pair.
@MainActor
final class RecordingLibraryInputTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaLibraryInputTests-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        root = base.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: root)
    }

    override func tearDown() async throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        try await super.tearDown()
    }

    private func row(id: UUID,
                     title: String,
                     audio: String = "meeting.wav") -> Recording {
        Recording(id: id, title: title, duration: 1, source: .microphone,
                  audioFileName: audio, status: .completed)
    }

    /// Install a prepared library while rotating the activity epoch, exactly
    /// as the coordinator does on a successful switch.
    private func switchLibrary(to rows: [Recording], named name: String) throws {
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = try RecordingLibraryInspection.Layout(directory: directory, defaultRoot: root)
        try store.activatePrepared(.init(layout: layout, recordings: rows, folders: []),
                                   expectedActivity: store.libraryActivity.snapshot,
                                   commitSelection: {})
    }

    func test_retained_action_cannot_rename_same_uuid_row_after_switch() throws {
        let id = UUID()
        store.add(row(id: id, title: "Old library"))
        let retained = store.libraryActivity.context
        XCTAssertTrue(store.admitLibraryInput(retained))

        // A synthetic retained menu/sheet callback: capture the epoch when the
        // UI was presented, recheck immediately before the store call.
        let store = self.store!
        let retainedAction: () -> Void = {
            guard store.admitLibraryInput(retained) else { return }
            guard let live = store.recordings.first(where: { $0.id == id }) else { return }
            store.rename(live, to: "Leaked rename")
        }

        try switchLibrary(to: [row(id: id, title: "New library")], named: "Destination")

        XCTAssertFalse(store.admitLibraryInput(retained))
        retainedAction()
        XCTAssertEqual(store.recordings.first?.id, id)
        XCTAssertEqual(store.recordings.first?.title, "New library",
                       "A retained action must not rename the adopted library's same-UUID row")
    }

    func test_current_input_action_still_mutates_current_library() {
        let id = UUID()
        store.add(row(id: id, title: "Current"))
        let context = store.libraryActivity.context
        XCTAssertTrue(store.admitLibraryInput(context))

        let store = self.store!
        let action: () -> Void = {
            guard store.admitLibraryInput(context) else { return }
            guard let live = store.recordings.first(where: { $0.id == id }) else { return }
            store.rename(live, to: "Renamed")
        }
        action()

        XCTAssertEqual(store.recordings.first?.title, "Renamed")
    }

    func test_context_from_before_aba_switch_is_refused_on_the_way_back() throws {
        let id = UUID()
        store.add(row(id: id, title: "First", audio: "same.wav"))
        let retained = store.libraryActivity.context

        try switchLibrary(to: [row(id: id, title: "Second", audio: "same.wav")],
                          named: "Second")
        try switchLibrary(to: [row(id: id, title: "First again", audio: "same.wav")],
                          named: "FirstAgain")

        XCTAssertFalse(store.admitLibraryInput(retained),
                       "Switching away and back must not restore an earlier epoch")
        let store = self.store!
        let retainedAction: () -> Void = {
            guard store.admitLibraryInput(retained) else { return }
            guard let live = store.recordings.first(where: { $0.id == id }) else { return }
            store.rename(live, to: "Leaked rename")
        }
        retainedAction()
        XCTAssertEqual(store.recordings.first?.title, "First again")
    }

    func test_drag_payload_roundtrip_keeps_token_and_refuses_stale_or_legacy_payloads() throws {
        let id = UUID()
        store.add(row(id: id, title: "Draggable", audio: "same.wav"))
        let token = store.libraryActivity.contextToken
        let payload = RecordingDragPayload(id: id, contextToken: token)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RecordingDragPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.recording(in: store)?.id, id)

        try switchLibrary(to: [row(id: id, title: "Other", audio: "same.wav")],
                          named: "Other")

        XCTAssertNil(decoded.recording(in: store),
                     "A payload dragged from the old library must not resolve the same-UUID row")

        let current = RecordingDragPayload(id: id,
                                           contextToken: store.libraryActivity.contextToken)
        XCTAssertEqual(current.recording(in: store)?.id, id,
                       "A payload created in the current library still resolves normally")

        // A payload written before the token existed decodes with no token and
        // must be refused rather than resolved by UUID.
        struct LegacyPayload: Codable { let id: UUID }
        let legacyData = try JSONEncoder().encode(LegacyPayload(id: id))
        let legacy = try JSONDecoder().decode(RecordingDragPayload.self, from: legacyData)
        XCTAssertNil(legacy.contextToken)
        XCTAssertNil(legacy.recording(in: store))
    }
}
