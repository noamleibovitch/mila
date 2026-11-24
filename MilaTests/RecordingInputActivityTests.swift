import XCTest
import AVFoundation
import SwiftUI
import AppKit
import Combine
@testable import Mila

@MainActor
final class RecordingInputActivityTests: XCTestCase {
    private func recording(_ source: RecordingSource = .meeting) async -> RecordingSession {
        let session = RecordingSession()
        await session.startFakeForTesting(outputURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("input-visuals-\(UUID()).wav"), source: source)
        addTeardownBlock { await session.cancelAll() }
        return session
    }

    private func buffer(_ amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        pcm.frameLength = 512
        let samples = try XCTUnwrap(pcm.floatChannelData?[0])
        for i in 0..<512 { samples[i] = amplitude * sinf(Float(i) * 2 * .pi * 440 / 16_000) }
        return pcm
    }

    func test_separate_real_PCM_levels_expire_only_for_display_and_do_not_publish_session() async throws {
        let session = await recording()
        var sessionChanges = 0
        let token = session.objectWillChange.sink { sessionChanges += 1 }
        defer { token.cancel() }
        await session.consumeMic(try buffer(0.25))
        await session.consumeSystem(try buffer(0.01))
        let current = session.meters.displayLevels()
        XCTAssertGreaterThan(current.microphone, current.appAudio)
        XCTAssertGreaterThan(current.appAudio, 0)
        let rawMicrophone = session.micLevel
        let rawAppAudio = session.systemLevel
        var meterChanges = 0
        let meterToken = session.meters.objectWillChange.sink { meterChanges += 1 }
        defer { meterToken.cancel() }
        let expired = session.meters.displayLevels(now: ContinuousClock.now.advanced(by: .seconds(1)))
        XCTAssertEqual(expired, RecordingInputLevels())
        XCTAssertEqual(session.micLevel, rawMicrophone, "Display expiry must not change diagnostics")
        XCTAssertEqual(session.systemLevel, rawAppAudio)
        XCTAssertEqual(meterChanges, 0, "Read-side freshness must not publish")
        XCTAssertEqual(sessionChanges, 0, "Meter buffers must not re-evaluate the App scene")
    }

    func test_new_capture_and_pause_clear_both_inputs_without_changing_source_preferences() async throws {
        let session = await recording()
        await session.consumeMic(try buffer(0.25))
        await session.consumeSystem(try buffer(0.25))
        await session.pause()
        XCTAssertEqual(session.meters.displayLevels(), RecordingInputLevels())
        XCTAssertEqual(RecordingInputChannel.microphone.status(source: session.source, isPaused: true,
                                                               levels: .init()), "Paused")
        session.resume()
        await session.consumeMic(try buffer(0.25))
        XCTAssertGreaterThan(session.meters.displayLevels().microphone, 0)
        let epoch = session.captureEpoch
        _ = await session.stop()
        XCTAssertEqual(session.meters.displayLevels(), RecordingInputLevels())
        await session.startFakeForTesting(outputURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("input-next-\(UUID()).wav"), source: .systemAudio)
        XCTAssertGreaterThan(session.captureEpoch, epoch)
        XCTAssertEqual(session.meters.displayLevels(), RecordingInputLevels())
        XCTAssertEqual(RecordingInputChannel.microphone.status(source: session.source, isPaused: false,
                                                               levels: .init(microphone: 1)), "Off")
        XCTAssertEqual(RecordingInputChannel.appAudio.status(source: session.source, isPaused: true,
                                                            levels: .init()), "Paused")
    }

    func test_actual_capture_sources_and_off_precedence_are_exhaustive() {
        for source in RecordingSource.allCases {
            let microphone = RecordingInputChannel.microphone.isEnabled(for: source)
            let appAudio = RecordingInputChannel.appAudio.isEnabled(for: source)
            XCTAssertEqual(microphone, source != .systemAudio)
            XCTAssertEqual(appAudio, source == .systemAudio || source == .meeting)
        }
        XCTAssertEqual(RecordingInputChannel.appAudio.status(source: .microphone, isPaused: true,
                                                            levels: .init(appAudio: 1)), "Off")
        XCTAssertEqual(RecordingInputChannel.microphone.status(source: .meeting, isPaused: false,
                                                               levels: .init()), "Quiet")
        XCTAssertEqual(RecordingInputChannel.appAudio.status(source: .meeting, isPaused: false,
                                                            levels: .init(appAudio: 0.5)), "Receiving audio")
    }

    func test_history_is_bounded_and_nonfinite_levels_cannot_reach_drawing() {
        var history = RecordingInputHistory()
        for _ in 0..<1_000 { history.append(.init(microphone: -1, appAudio: 2)) }
        XCTAssertEqual(history.microphone.count, 40)
        XCTAssertEqual(history.appAudio.count, 40)
        XCTAssertTrue(history.microphone.allSatisfy { $0 == 0 })
        XCTAssertTrue(history.appAudio.allSatisfy { $0 == 1 })
        history.append(.init(microphone: .nan, appAudio: .infinity))
        XCTAssertEqual(history.latest, RecordingInputLevels())
    }

    /// Real SwiftUI/AppKit component captures, seeded to avoid scheduling-
    /// dependent screenshot contents. This is not physical audio or a full
    /// Home/live-transcript end-to-end test, nor VoiceOver listening proof.
    func test_native_component_renders_compact_sources_pause_and_reduced_motion() async throws {
        for (name, source, paused, reduced) in [
            ("Meeting", RecordingSource.meeting, false, false),
            ("App audio only", .systemAudio, false, false),
            ("Microphone only", .microphone, false, false),
            ("Paused meeting", .meeting, true, false),
            ("Reduced motion", .meeting, false, true)
        ] {
            let session = await recording(source)
            var history = RecordingInputHistory()
            for i in 0..<40 {
                await session.consumeMic(try buffer(i % 8 < 4 ? 0.1 : 0.005))
                await session.consumeSystem(try buffer(i % 10 < 5 ? 0.002 : 0.2))
                history.append(session.meters.displayLevels())
            }
            if paused { await session.pause() }
            let content = RecordingInputActivityView(seededHistory: history, reduceMotion: reduced)
                .environmentObject(session)
                .padding(12)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 190),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Recording input fixture"
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let view = NSHostingView(rootView: content)
            window.contentView = view
            window.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            XCTAssertGreaterThanOrEqual(image.pixelsWide, 300)
            XCTAssertGreaterThanOrEqual(image.pixelsHigh, 170)
            let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Recording inputs - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            await session.cancelAll()
        }
    }
}
