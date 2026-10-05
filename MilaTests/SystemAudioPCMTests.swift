import XCTest
import AVFoundation
import CoreMedia
@testable import Mila

final class SystemAudioPCMTests: XCTestCase {
    func test_copy_preserves_mono_and_both_stereo_layouts() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            for interleaved in [false, true] {
                let input = try makePCM(channels: channels, interleaved: interleaved)
                let sample = try makeSample(input)
                let output = try XCTUnwrap(SystemAudioPCM.buffer(from: sample))
                XCTAssertEqual(output.frameLength, input.frameLength)
                XCTAssertEqual(output.format, input.format)
                let expected = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
                let actual = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                XCTAssertEqual(actual.count, expected.count)
                for index in 0..<expected.count {
                    let bytes = Int(expected[index].mDataByteSize)
                    XCTAssertEqual(actual[index].mDataByteSize, expected[index].mDataByteSize)
                    XCTAssertEqual(Data(bytes: try XCTUnwrap(actual[index].mData), count: bytes),
                                   Data(bytes: try XCTUnwrap(expected[index].mData), count: bytes))
                }
                // Reusing the producer's memory must not change delivered audio.
                memset(try XCTUnwrap(expected[0].mData), 0, Int(expected[0].mDataByteSize))
                XCTAssertEqual(AudioConvert.samples(from: output), Array(repeating: 0.25, count: 32))
            }
        }
    }

    func test_not_ready_missing_and_empty_packets_are_rejected() throws {
        let input = try makePCM(channels: 1, interleaved: false)
        let missing = try makeSample(input, attachData: false)
        XCTAssertNil(SystemAudioPCM.buffer(from: missing))
        XCTAssertEqual(CMSampleBufferSetDataReady(missing), noErr)
        XCTAssertNil(SystemAudioPCM.buffer(from: missing))
        let empty = try makeSample(input, attachData: false, frames: 0)
        XCTAssertEqual(CMSampleBufferSetDataReady(empty), noErr)
        XCTAssertNil(SystemAudioPCM.buffer(from: empty))
    }

    func test_nil_and_truncated_float_storage_does_not_crash_or_meter_garbage() throws {
        let input = try makePCM(channels: 1, interleaved: false)
        let list = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let original = list[0]
        defer { list[0] = original }
        // Retain the buffer's allocation and restore before destruction.
        list[0].mData = nil
        XCTAssertTrue(AudioConvert.samples(from: input).isEmpty)
        XCTAssertEqual(AudioMeter.level(from: input), 0)
        list[0] = original
        list[0].mDataByteSize = 3
        XCTAssertTrue(AudioConvert.samples(from: input).isEmpty)
        XCTAssertEqual(AudioMeter.level(from: input), 0)
    }

    func test_channel_zero_meter_still_handles_planar_and_interleaved_stereo() throws {
        for interleaved in [false, true] {
            let input = try makePCM(channels: 2, interleaved: interleaved)
            XCTAssertEqual(AudioConvert.samples(from: input), Array(repeating: 0.25, count: 32))
            XCTAssertEqual(AudioMeter.level(from: input), (20 * log10(Float(0.25)) + 60) / 60, accuracy: 0.0001)
        }
        let empty = try makePCM(channels: 1, interleaved: false)
        empty.frameLength = 0
        XCTAssertTrue(AudioConvert.samples(from: empty).isEmpty)
        XCTAssertEqual(AudioMeter.level(from: empty), 0)
    }

    private func makePCM(channels: AVAudioChannelCount, interleaved: Bool) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000, channels: channels, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, entry) in list.enumerated() {
            let pointer = try XCTUnwrap(entry.mData).assumingMemoryBound(to: Float.self)
            for sample in 0..<(Int(entry.mDataByteSize) / MemoryLayout<Float>.size) {
                let channel = interleaved ? sample % Int(channels) : index
                pointer[sample] = channel == 0 ? 0.25 : -0.75
            }
        }
        return buffer
    }

    private func makeSample(_ pcm: AVAudioPCMBuffer, attachData: Bool = true,
                            frames: Int? = nil) throws -> CMSampleBuffer {
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
                                       presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: try XCTUnwrap(format), sampleCount: frames ?? Int(pcm.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        if attachData {
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result,
                blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: pcm.audioBufferList), noErr)
            XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        }
        return result
    }
}
