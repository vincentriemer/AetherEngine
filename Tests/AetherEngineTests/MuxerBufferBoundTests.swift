// Mid-segment fragment-flush bound for the fMP4 muxer (#64).
//
// The session muxer runs with movflags +frag_custom, so a moof+mdat is emitted only at an explicit
// segment cut. A degenerate segment plan (or any very long segment, or an audio stream that decodes to
// nothing) would otherwise leave the whole span buffered in libavformat's interleaver until the cut,
// growing RAM without bound. These pure helpers decide when an interim flush is due, computed in the
// muxer's rewritten output video time base.
import Foundation
import Testing
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

@Suite("MP4SegmentMuxer buffered-fragment bound (#64)")
struct MuxerBufferBoundTests {

    @Test("Tick span is computed from the output video time base")
    func ticksFromTimeBase() {
        // movenc's typical 24 fps rewrite is 1/16000; 8 s -> 128000 ticks.
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: 8, timeBase: AVRational(num: 1, den: 16_000)) == 128_000)
        // Source-axis 90 kHz would be 720000; proves the unit depends on the passed time base.
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: 8, timeBase: AVRational(num: 1, den: 90_000)) == 720_000)
    }

    @Test("Non-positive seconds or an invalid time base disables the bound (0 ticks)")
    func ticksDisabled() {
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: 0, timeBase: AVRational(num: 1, den: 16_000)) == 0)
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: -1, timeBase: AVRational(num: 1, den: 16_000)) == 0)
        #expect(MP4SegmentMuxer.bufferedFragmentTicks(
            seconds: 8, timeBase: AVRational(num: 0, den: 0)) == 0)
    }

    @Test("A flush is due once the buffered video span reaches the bound")
    func boundReached() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 0, currentDts: 127_999, boundTicks: 128_000) == false)
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 0, currentDts: 128_000, boundTicks: 128_000) == true)
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 0, currentDts: 200_000, boundTicks: 128_000) == true)
    }

    @Test("No window yet (sentinel first DTS) never triggers a flush")
    func sentinelFirstDts() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: Int64.min, currentDts: 999_999, boundTicks: 128_000) == false)
    }

    @Test("A backward DTS step never triggers a flush")
    func backwardStep() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 100_000, currentDts: 50_000, boundTicks: 128_000) == false)
    }

    @Test("A disabled bound (0 ticks) never triggers a flush")
    func disabledBound() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: 0, currentDts: 10_000_000, boundTicks: 0) == false)
    }

    @Test("A span wider than Int64 counts as past the bound instead of trapping (audit SEG-101)")
    func spanOverflow() {
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: Int64.min + 1, currentDts: Int64.max, boundTicks: 128_000))
        #expect(MP4SegmentMuxer.bufferedTicksExceedsBound(
            firstDts: -(Int64(1) << 62), currentDts: Int64(1) << 62, boundTicks: Int64.max))
    }
}

extension MuxerBufferBoundTests {
    @Test("byte-bounded video fragments preserve every encoded sample and timestamp across cuts")
    func byteBoundPreservesMedia() throws {
        let fixture = try #require(Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
                                       options: .ignoreUnknownCharacters))
        func remux(limit: Int) throws -> (Data, Int) {
            let source = Demuxer()
            defer { source.close() }
            try source.open(reader: DataIOReader(data: fixture), formatHint: "mp4")
            let stream = try #require(source.stream(at: source.videoStreamIndex))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var header = Data()
            let muxer = try MP4SegmentMuxer(initialSegmentIndex: 0, sessionDir: dir,
                video: .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                             timeBase: stream.pointee.time_base, codecTagOverride: nil),
                audio: nil, maxBufferedVideoBytes: limit, onInitCaptured: { header = $0 })
            var media = Data()
            var packetCount = 0
            var stagedBeforeCut = 0
            func cut(_ index: Int) throws {
                guard case .completed(let path, _) = muxer.cutFragmentForNextSegment(index) else {
                    throw MovencFragmentEndTests.ScenarioError.cutFailed
                }
                media.append(try Data(contentsOf: path))
            }
            while let packet = try source.readPacket() {
                defer { var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p) }
                guard packet.pointee.stream_index == source.videoStreamIndex else { continue }
                av_packet_rescale_ts(packet, stream.pointee.time_base, muxer.muxerVideoTimeBase)
                packet.pointee.stream_index = muxer.videoOutputStreamIndex
                #expect(muxer.writePacket(packet).rc >= 0)
                packetCount += 1
                stagedBeforeCut = max(stagedBeforeCut, muxer.stagedSegmentByteCount)
                if packetCount == 2 { try cut(1) }
            }
            #expect(packetCount > 2)
            try cut(2)
            _ = muxer.finalize()
            return (header + media, stagedBeforeCut)
        }
        func samples(_ data: Data) throws -> [(Data, Int64, Int64, Int64)] {
            let source = Demuxer()
            defer { source.close() }
            try source.open(reader: DataIOReader(data: data), formatHint: "mp4")
            var result: [(Data, Int64, Int64, Int64)] = []
            while let packet = try source.readPacket() {
                defer { var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p) }
                if packet.pointee.stream_index == source.videoStreamIndex {
                    result.append((Data(bytes: packet.pointee.data, count: Int(packet.pointee.size)),
                                   packet.pointee.pts, packet.pointee.dts, packet.pointee.duration))
                }
            }
            return result
        }
        // One byte forces an interim flush before each subsequent sample, including oversized
        // samples. No sample can be split or discarded to satisfy the budget.
        let bounded = try remux(limit: 1)
        let unbounded = try remux(limit: Int.max)
        #expect(bounded.1 > 0, "interim fragments must reach disk before a segment cut")
        #expect(unbounded.1 == 0, "control only writes at the segment cuts")
        let actual = try samples(bounded.0), expected = try samples(unbounded.0)
        #expect(actual.count == expected.count)
        for (a, b) in zip(actual, expected) {
            #expect(a.0 == b.0)
            #expect(a.1 == b.1 && a.2 == b.2 && a.3 == b.3)
        }
    }
}
