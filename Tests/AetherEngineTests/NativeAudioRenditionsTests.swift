@testable import AetherEngine
import Foundation
import Testing

@Suite("Native container audio renditions", .serialized)
struct NativeAudioRenditionsTests {
    private let tracks = [
        TrackInfo(id: 2, name: "Main", codec: "aac", language: "eng", channels: 2, isDefault: true),
        TrackInfo(id: 7, name: "Commentary", codec: "ac3", language: "eng", channels: 6, isDefault: false),
        TrackInfo(id: 11, name: "German", codec: "aac", language: "deu", channels: 2, isDefault: false),
    ]
    @Test("Manifest names and language alternatives retain container identities without opening readers")
    func lazyManifest() {
        let rendition = NativeAudioRenditions(tracks: tracks,
                                              names: [2: "English · AAC 2.0", 7: "English · AC-3 5.1 · Commentary", 99: "Invalid"],
                                              initial: 7, plan: [], makeSession: { _, _ in Issue.record("metadata opened a pipeline"); throw CancellationError() },
                                              activated: { _, _ in Issue.record("metadata activated a pipeline") })
        defer { rendition.stop() }
        #expect(rendition.mediaTags.count == 3)
        #expect(rendition.mediaTags[0].contains("audio_2/media.m3u8"))
        #expect(rendition.mediaTags[1].contains("DEFAULT=YES"))
        #expect(rendition.mediaTags[1].contains("English · AC-3 5.1 · Commentary"))
        #expect(rendition.mediaTags[1].contains(NativeAudioRenditions.characteristic(7)))
        #expect(rendition.response(path: "/audio_names.json") != nil)
        #expect(rendition.response(path: "/audio_11/media.m3u8") != nil)
        #expect(rendition.response(path: "/audio_99/media.m3u8") == nil)
    }

    @Test("Recovered tracks retain lossless policy independently of other renditions")
    func fallbackPolicy() throws {
        let parent = HLSVideoEngine(url: URL(fileURLWithPath: "/unused"), audioBridgeMode: .lossless, objectAudioRendering: .apac(.l714))
        parent.nativeAudioLosslessStreamIndices = [7]
        let main = try parent.makeNativeAudioSession(index: 2, seconds: 17)
        let recovered = try parent.makeNativeAudioSession(index: 7, seconds: 17)
        defer { parent.stop(); main.stop(); recovered.stop() }
        #expect(main.objectAudioRendering == .apac(.l714))
        #expect(recovered.objectAudioRendering == .off)
        #expect(recovered.audioBridgeMode == .lossless)
        #expect(recovered.initialStartSeconds == 17)
        #expect(recovered.audioOnlyRendition)
        #expect(main.producer == nil && recovered.producer == nil)
    }

    @Test("Identical source names remain distinct")
    func duplicateNames() {
        let rendition = NativeAudioRenditions(tracks: tracks, names: [2: "English", 7: "English"], initial: 2,
                                              plan: [], makeSession: { _, _ in throw CancellationError() }, activated: { _, _ in })
        defer { rendition.stop() }
        #expect(rendition.mediaTags[0].contains("English · Track 2"))
        #expect(rendition.mediaTags[1].contains("English · Track 7"))
    }

    @Test("Real rendition bytes contain audio only, switch codec, align seeks, and reject stale requests",
          .enabled(if: FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/native-audio-tracks.mkv").path), "Run Scripts/fetch-fixtures.sh"), .timeLimit(.minutes(2)))
    func realRenditions() async throws {
        try await BlockingWork.detached {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let session = HLSVideoEngine(url: root.appendingPathComponent("Fixtures/native-audio-tracks.mkv"), dvModeAvailable: false)
            session.nativeAudioTrackNames = [1: "English · AAC 2.0", 2: "English · AC-3 5.1 · Commentary", 3: "German · AAC 2.0"]
            session.initialStartSeconds = 0
            try session.prepare()
            defer { session.stop(waitForCleanup: true) }
            let renditions = try #require(session.nativeAudioRenditions)
            #expect(session.audioBridge == nil) // Primary video never owns an audio decoder.
            let firstInit = try #require(renditions.response(path: "/audio_1/init.mp4"))
            #expect(firstInit.data.range(of: Data("soun".utf8)) != nil)
            #expect(firstInit.data.range(of: Data("vide".utf8)) == nil)
            #expect(firstInit.data.range(of: Data("mp4a".utf8)) != nil)
            let first = try #require(renditions.response(path: "/audio_1/seg0.m4s"))
            #expect(!first.data.isEmpty)
            renditions.select(2, at: 8)
            let nextInit = try #require(renditions.response(path: "/audio_2/init.mp4"))
            #expect(nextInit.data.range(of: Data("ac-3".utf8)) != nil)
            #expect(nextInit.data.range(of: Data("vide".utf8)) == nil)
            #expect(renditions.response(path: "/audio_1/seg1.m4s") == nil)
            #expect(renditions.response(path: "/audio_2/seg1.m4s") != nil)
            renditions.select(3)
            renditions.select(1)
            #expect(renditions.response(path: "/audio_1/seg0.m4s") != nil)
            renditions.stop()
            #expect(renditions.response(path: "/audio_1/init.mp4") == nil)
        }.value
    }
}

#if os(macOS)
    import AVFoundation

    @Suite("Native rendition AVFoundation integration", .serialized)
    struct NativeAudioAVFoundationTests {
        @MainActor @Test("Real native selections preserve the item, paused scene, and container identity",
                         .enabled(if: FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/native-audio-tracks.mkv").path), "Run Scripts/fetch-fixtures.sh"), .timeLimit(.minutes(2)))
        func nativeSelection() async throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let session = HLSVideoEngine(url: root.appendingPathComponent("Fixtures/native-audio-tracks.mkv"), dvModeAvailable: false)
            session.nativeAudioTrackNames = [1: "English · AAC 2.0", 2: "English · AC-3 5.1 · Commentary", 3: "German · AAC 2.0"]
            let url = try await BlockingWork.detached { try session.start() }.value
            defer { session.stop() }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.appliesMediaSelectionCriteriaAutomatically = false
            defer { player.pause(); player.replaceCurrentItem(with: nil) }
            let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
            #expect(group.options.map(\.displayName) == ["English · AAC 2.0", "English · AC-3 5.1 · Commentary", "German · AAC 2.0"])
            try await waitFor { item.status != .unknown }
            #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
            #expect(await player.seek(to: CMTime(seconds: 6, preferredTimescale: 600)))
            for index in [2, 3, 1] {
                let option = try #require(group.options.first { $0.hasMediaCharacteristic(AVMediaCharacteristic(rawValue: NativeAudioRenditions.characteristic(index))) })
                session.nativeAudioRenditions?.select(index, at: player.currentTime().seconds)
                item.select(option, in: group)
                try await waitFor { item.currentMediaSelection.selectedMediaOption(in: group) == option }
                #expect(player.currentItem === item)
                #expect(player.rate == 0)
                #expect(abs(player.currentTime().seconds - 6) < 0.2)
                #expect(item.status == .readyToPlay)
                player.play()
                try await waitFor { session.activeAudioSourceStreamIndex == Int32(index) && player.currentTime().seconds > 6.15 }
                player.pause()
                #expect(await player.seek(to: CMTime(seconds: 6, preferredTimescale: 600)))
            }
        }
    }
#endif
