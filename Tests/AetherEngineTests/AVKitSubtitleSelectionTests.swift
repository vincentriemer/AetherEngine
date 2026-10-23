@testable import AetherEngine
import AVFoundation
import Foundation
import Synchronization
import Testing

@MainActor @Suite("AVKit subtitle ownership", .serialized)
struct AVKitSubtitleSelectionTests {
    @Test func sourceOwnershipAndCleanup() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.loadedURL = URL(fileURLWithPath: "/synthetic.mkv")
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: 3, language: "en"),
            .init(sourceStreamIndex: 41, language: "en", needsOCR: true),
            .init(sourceStreamIndex: 77, language: "ja", needsOCR: true),
        ]
        engine.testHookNativeStores = (0 ..< 3).map { _ in NativeSubtitleCueStore() }
        engine.activateAVKitSubtitleSource(1)
        #expect(engine.activeSubtitleTrackIndex == 41)
        let worker = try #require(engine.subtitleOCRWorkerTask)
        engine.activateAVKitSubtitleSource(2)
        #expect(worker.isCancelled)
        #expect(engine.activeSubtitleTrackIndex == 77)
        engine.activateAVKitSubtitleSource(0)
        #expect(engine.subtitleOCRWorkerTask == nil)
        #expect(engine.activeSubtitleTrackIndex == 3)
        engine.activateAVKitSubtitleSource(nil)
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.nativeSubtitleReadersTask == nil)
        #expect(engine.subtitleDrainTargets.isEmpty)
    }

    #if os(macOS)
        @Test(.timeLimit(.minutes(2))) func engineSelectionReloadAndStaleItem() async throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let subtitles = FileManager.default.temporaryDirectory.appendingPathComponent("native-policy-\(UUID()).srt")
            try "1\n00:00:00,000 --> 00:00:20,000\nNative selection cue\n".write(to: subtitles, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: subtitles) }
            let engine = try AetherEngine()
            defer { engine.stop() }
            var options = LoadOptions()
            options.autoplay = false
            options.suppressDisplayCriteria = true
            options.prepareNativeSubtitles = true
            options.nativeSubtitleSelectionByAVKit = true
            options.nativeAudioTrackNames = [1: "English AAC", 2: "English AC-3", 3: "German AAC"]
            options.externalSubtitles = [.init(url: subtitles, language: "en"), .init(url: subtitles, language: "ja")]
            _ = try await engine.load(url: root.appendingPathComponent("Fixtures/native-audio-tracks.mkv"), options: options, audioSourceStreamIndex: 3)
            for _ in 0 ..< 200 {
                if engine.currentAVPlayerItem != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let item = try #require(engine.currentAVPlayerItem)
            let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
            #expect(engine.nativeSubtitleTracks.count == 2)
            #expect(Set(engine.nativeSubtitleTracks.compactMap(\.sourceID)).count == 2)
            for _ in 0 ..< 200 {
                if engine.nativeLegibleDeselectPinObserver != nil, engine.avKitSubtitlePendingPolicy == nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(engine.nativeLegibleDeselectPinObserver != nil)
            let option = try #require(group.options.first)
            item.select(option, in: group)
            for _ in 0 ..< 200 {
                if case .track = engine.nativeSubtitleSelectionPolicy {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let policy = engine.nativeSubtitleSelectionPolicy
            guard case let .track(source) = policy else { Issue.record("Native selection failed to activate the engine source"); return }
            #expect(engine.activeSubtitleTrackIndex == source)
            #expect(engine.nativeSubtitleTracks.first { $0.sourceID == source }?.ordinal == engine.nativeSubtitleResolvedOrdinal)
            let audio = engine.nativeVideoSession?.nativeAudioRenditions?.selectedIndex
            #expect(audio == 3)
            let audioGroup = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
            #expect(!item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: audioGroup))
            _ = try await engine.reloadAtCurrentPosition()
            for _ in 0 ..< 200 {
                if engine.activeSubtitleTrackIndex == source {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(engine.nativeSubtitleSelectionPolicy == policy)
            #expect(engine.activeSubtitleTrackIndex == source)
            #expect(engine.nativeVideoSession?.nativeAudioRenditions?.selectedIndex == audio)
            item.select(nil, in: group) // Retired item cannot change the new session.
            try await Task.sleep(for: .milliseconds(50))
            #expect(engine.nativeSubtitleSelectionPolicy == policy)
            engine.setNativeSubtitlePolicy(.off)
            for _ in 0 ..< 100 {
                if engine.activeSubtitleTrackIndex == nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(engine.activeSubtitleTrackIndex == nil)
            let player = try #require(engine.currentAVPlayer)
            player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(preferredLanguages: ["ja"], preferredMediaCharacteristics: nil), forMediaCharacteristic: .legible)
            engine.setNativeSubtitlePolicy(.automatic)
            for _ in 0 ..< 200 {
                if engine.nativeSubtitleResolvedOrdinal == 1 {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(engine.nativeSubtitleSelectionPolicy == .automatic)
            #expect(engine.nativeSubtitleResolvedOrdinal == 1)
            #expect(engine.nativeVideoSession?.nativeAudioRenditions?.selectedIndex == audio)
            // Rapid explicit changes coalesce, including Off, without restarting an obsolete source.
            engine.setNativeSubtitlePolicy(.track(source))
            engine.setNativeSubtitlePolicy(.off)
            engine.setNativeSubtitlePolicy(.automatic)
            for _ in 0 ..< 200 {
                if engine.nativeSubtitleResolvedOrdinal == 1 {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(engine.nativeSubtitleSelectionPolicy == .automatic)
            #expect(engine.nativeSubtitleResolvedOrdinal == 1)
            try await engine.reloadAtCurrentPosition()
            for _ in 0 ..< 200 {
                if engine.nativeLegibleDeselectPinObserver != nil, engine.avKitSubtitlePendingPolicy == nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(engine.nativeSubtitleSelectionPolicy == .automatic)
            let replacement = try #require(engine.currentAVPlayerItem)
            let replacementGroup = try #require(try await replacement.asset.loadMediaSelectionGroup(for: .legible))
            #expect(replacement.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: replacementGroup))
            #expect(engine.nativeVideoSession?.nativeAudioRenditions?.selectedIndex == audio)
            engine.stop()
            #expect(engine.nativeLegibleDeselectPinTask == nil)
            #expect(engine.nativeLegibleDeselectPinObserver == nil)
            #expect(engine.subtitleOCRWorkerTask == nil)
            #expect(engine.nativeSubtitleReadersTask == nil)
        }

        @Test(.timeLimit(.minutes(2))) func realMediaSelectionIdentityAndIntent() async throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let session = HLSVideoEngine(url: root.appendingPathComponent("Fixtures/native-audio-tracks.mkv"), dvModeAvailable: false)
            session.enableNativeSubtitleTrackForSession = true
            let entries: [AetherEngine.NativeSubtitleTrackEntry] = [
                .init(sourceStreamIndex: 11, language: "en"),
                .init(sourceStreamIndex: 29, language: "en"),
                .init(sourceStreamIndex: 43, language: "en", isHearingImpaired: true),
                .init(sourceStreamIndex: 61, language: "en", isForced: true),
                .init(sourceStreamIndex: 83, language: "ja"),
                .init(sourceStreamIndex: 97, language: "en", needsOCR: true),
            ]
            session.nativeSubtitleRenditionInfosForSession = AetherEngine.nativeSubtitleRenditionInfos(for: entries, avKitOwned: true)
            session.nativeSubtitleLanguagesForSession = entries.map(\.language)
            session.nativeSubtitleCueStoresForSession = entries.indices.map { index in
                let store = NativeSubtitleCueStore()
                if index != 5 {
                    store.appendCues([SubtitleCue(id: index, startTime: 0, endTime: 20, body: .text("Rendition \(index)"))])
                }
                return store
            }
            let url = try await BlockingWork.detached { try session.start() }.value
            defer { session.stop() }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            defer { player.pause(); player.replaceCurrentItem(with: nil) }
            let output = AVPlayerItemLegibleOutput()
            let sink = SubtitleOutputSink()
            output.setDelegate(sink, queue: .main)
            item.add(output)
            let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
            #expect(group.options.count == entries.count)
            #expect(Set(session.nativeSubtitleRenditionInfosForSession.map(\.name)).count == entries.count)
            for entry in entries {
                let id = try NativeSubtitlePolicy.characteristic(#require(entry.sourceStreamIndex))
                let matches = group.options.filter { $0.hasMediaCharacteristic(.init(rawValue: id)) }
                #expect(matches.count == 1)
            }
            let sdh = try #require(group.options.first { $0.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) })
            item.select(sdh, in: group)
            #expect(!item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group))
            #expect(item.currentMediaSelection.selectedMediaOption(in: group) == sdh)
            item.select(nil, in: group)
            #expect(!item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group))
            #expect(item.currentMediaSelection.selectedMediaOption(in: group) == nil)
            let first = try #require(group.options.first { $0.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(11))) })
            item.select(first, in: group)
            player.play()
            for _ in 0 ..< 200 {
                if sink.texts.withLock({ $0.contains(where: { $0.contains("Rendition 0") }) }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(sink.texts.withLock { $0.contains(where: { $0.contains("Rendition 0") }) })
            let delayed = try #require(group.options.first { $0.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(97))) })
            item.select(delayed, in: group)
            let fill = Task { @MainActor in
                try await Task.sleep(for: .seconds(5))
                session.nativeSubtitleCueStoresForSession[5].appendCues([SubtitleCue(id: 5, startTime: 0, endTime: 20, body: .text("Delayed OCR"))])
            }
            defer { fill.cancel() }
            for _ in 0 ..< 240 {
                if sink.texts.withLock({ $0.contains(where: { $0.contains("Delayed OCR") }) }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(sink.texts.withLock { $0.contains(where: { $0.contains("Delayed OCR") }) })
            #expect(player.currentTime().seconds > 4)
            item.selectMediaOptionAutomatically(in: group)
            for _ in 0 ..< 100 {
                if item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group) {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group))
        }
    #endif
}

private final class SubtitleOutputSink: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    let texts = Mutex<[String]>([])
    func legibleOutput(_: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers _: [Any], forItemTime _: CMTime)
    {
        texts.withLock { $0.append(contentsOf: strings.map(\.string)) }
    }
}
