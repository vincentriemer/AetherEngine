@testable import AetherEngine
import AVFoundation
import Foundation
import Synchronization
import Testing

@MainActor @Suite("AVKit subtitle ownership", .serialized)
struct AVKitSubtitleSelectionTests {
    @Test(.timeLimit(.minutes(1))) func OCRCoverageWaitHonorsCancellationAndItemOwnership() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let item = AVPlayerItem(asset: AVMutableComposition())
        engine.currentAVPlayer = AVPlayer(playerItem: item)
        engine.nativeSubtitleReapplyOrdinal = 0
        let store = NativeSubtitleCueStore()
        var began = false
        let wait = Task { @MainActor in
            began = true
            return await engine.awaitSubtitleOCRCoverage(ordinal: 0, store: store, item: item)
        }
        try await waitFor { began }
        wait.cancel()
        #expect(await wait.value == "superseded")
        engine.currentAVPlayer?.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        store.markFinished()
        #expect(await engine.awaitSubtitleOCRCoverage(ordinal: 0, store: store, item: item) == "superseded")
    }

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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func unfinishedOCRCoverageWaitsForHarvestDecodeAndRecognition(hasPacket: Bool) async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let item = AVPlayerItem(asset: AVMutableComposition())
        engine.currentAVPlayer = AVPlayer(playerItem: item)
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: 41, language: "en", needsOCR: true)]
        engine.nativeSubtitleReapplyOrdinal = 0
        engine.subtitleOCRArmedOrdinal = 0
        let store = NativeSubtitleCueStore()
        let packets = SubtitlePacketStore()
        engine.softwareSubtitlePacketStore = packets
        packets.noteHarvestAnchor(.pump, at: 0)
        packets.noteHarvestReach(.pump, through: 1)
        engine.subtitleOCRCursors[0] = SubtitleDrainCursor(lastDecodedPts: 0, lastPlayhead: 0)
        #expect(!engine.subtitleOCRCoversNativeWindow(ordinal: 0), "An unread empty window is not covered")
        if hasPacket {
            packets.append(streamIndex: 41, ptsSeconds: 1, durationSeconds: 1, payload: Data([0]))
        }
        packets.noteHarvestReach(.pump, through: AetherEngine.subtitleOCRLeadSeconds)
        if hasPacket {
            #expect(!engine.subtitleOCRCoversNativeWindow(ordinal: 0), "Read packets must also be decoded")
            engine.subtitleOCRCursors[0] = SubtitleDrainCursor(lastDecodedPts: 1, lastPlayhead: 0)
        }
        engine.subtitleOCRBatchInFlight = true
        var returned = false
        let pending = Task { @MainActor in
            let result = await engine.awaitSubtitleOCRCoverage(ordinal: 0, store: store, item: item)
            returned = true
            return result
        }
        #expect(try await !waitFor(upTo: .milliseconds(300)) { returned }, "Selection cannot open while the last recognition batch is in flight")
        engine.subtitleOCRBatchInFlight = false
        #expect(await pending.value == "covered")
        #expect(!store.isFinished)
        #expect(store.cueCount == 0, "Covered sparse or empty windows do not require fabricated text")
    }

    @Test func demandHonorsPolicyAndRejectsRetiredSessions() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.nativeSubtitleSelectionByAVKit = true
        engine.setLoadedOptionsForTesting(options)
        engine.loadedURL = URL(fileURLWithPath: "/synthetic.mkv")
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: 41, language: "en", needsOCR: true),
            .init(sourceStreamIndex: 77, language: "ja", needsOCR: true),
        ]
        engine.testHookNativeStores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/synthetic.mkv"), dvModeAvailable: false)
        engine.nativeVideoSession = session
        engine.currentAVPlayer = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        let demand = try #require(session.nativeSubtitleDemandHandler)
        demand(0)
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.activeSubtitleTrackIndex == 41)
        let worker = try #require(engine.subtitleOCRWorkerTask)
        demand(1) // An unresolved prefetch cannot open every source or undo a newer choice.
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.activeSubtitleTrackIndex == 41)
        #expect(!worker.isCancelled)
        engine.setNativeSubtitlePolicy(.off)
        #expect(worker.isCancelled)
        demand(0)
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.subtitleOCRWorkerTask == nil)
        engine.setNativeSubtitlePolicy(.track(77))
        demand(0)
        demand(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.activeSubtitleTrackIndex == 77)
        #expect(engine.nativeSubtitleSelectionPolicy == .track(77))
        engine.activateAVKitSubtitleSource(nil)
        let replacement = HLSVideoEngine(url: URL(fileURLWithPath: "/replacement.mkv"), dvModeAvailable: false)
        engine.nativeVideoSession = replacement
        demand(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.activeSubtitleTrackIndex == nil)
        let replacementDemand = try #require(replacement.nativeSubtitleDemandHandler)
        engine.stop()
        replacementDemand(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.subtitleOCRWorkerTask == nil)
        #expect(engine.nativeSubtitleReadersTask == nil)
    }

    #if os(macOS)
        @Test(.timeLimit(.minutes(1)), arguments: [false, true])
        func explicitOCRWaitsForCoverageAndRetiresPendingChoices(playing: Bool) async throws {
            let fixture = try await makePendingOCRFixture()
            let (engine, session, stores, player, item, group) = fixture
            defer { engine.stop(); session.stop() }
            let output = AVPlayerItemLegibleOutput()
            let sink = SubtitleOutputSink()
            output.setDelegate(sink, queue: .main)
            item.add(output)
            #expect(item.currentMediaSelection.selectedMediaOption(in: group) == nil)
            if playing { player.play() }

            engine.setNativeSubtitlePolicy(.track(41))
            try await waitFor { engine.subtitleOCRArmedOrdinal == 0 }
            // Recognition has not covered the selection burst. Selecting now lets AVPlayer
            // fetch and retain empty VTT segments, even though the worker is running.
            #expect(item.currentMediaSelection.selectedMediaOption(in: group) == nil)
            let abandoned = try #require(engine.nativeLegibleDeselectPinTask)
            let worker = try #require(engine.subtitleOCRWorkerTask)
            engine.setNativeSubtitlePolicy(.off)
            await abandoned.value
            #expect(worker.isCancelled)
            #expect(engine.subtitleOCRWorkerTask == nil)

            engine.setNativeSubtitlePolicy(.track(77))
            try await waitFor { engine.subtitleOCRArmedOrdinal == 1 }
            #expect(item.currentMediaSelection.selectedMediaOption(in: group) == nil)
            let superseded = try #require(engine.nativeLegibleDeselectPinTask)
            engine.setNativeSubtitlePolicy(.track(77))
            await superseded.value
            #expect(engine.subtitleOCRArmedOrdinal == 1, "Repeating a pending choice keeps its worker")
            stores[0].appendCues([.init(id: 0, startTime: 0, endTime: 20, body: .text("Retired OCR"))])
            stores[0].markFinished()
            stores[1].appendCues([.init(id: 1, startTime: 0, endTime: 20, body: .text("Ready OCR"))])
            stores[1].markFinished()
            try await waitFor { engine.avKitSubtitlePendingPolicy == nil && item.currentMediaSelection.selectedMediaOption(in: group) != nil }
            let selected = try #require(item.currentMediaSelection.selectedMediaOption(in: group))
            #expect(selected.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(77))))
            #expect(engine.nativeSubtitleSelectionPolicy == .track(77))
            #expect(engine.activeSubtitleTrackIndex == 77)
            #expect(player.rate == (playing ? 1 : 0), "Enabling subtitles must preserve transport intent")
            if playing {
                try await waitFor { sink.texts.withLock { $0.contains(where: { $0.contains("Ready OCR") }) } }
            }
        }

        @Test(.timeLimit(.minutes(1)), arguments: [false, true], [NativeSubtitlePolicy.track(77), .off, .automatic])
        func nativeChoiceRetiresPendingOCR(playing: Bool, choice: NativeSubtitlePolicy) async throws {
            let (engine, session, stores, player, item, group) = try await makePendingOCRFixture()
            defer { engine.stop(); session.stop() }
            player.setMediaSelectionCriteria(.init(preferredLanguages: ["ja"], preferredMediaCharacteristics: nil), forMediaCharacteristic: .legible)
            engine.setNativeSubtitlePolicy(.track(3))
            try await waitFor { engine.avKitSubtitlePendingPolicy == nil && engine.activeSubtitleTrackIndex == 3 }
            if playing { player.play() }
            engine.setNativeSubtitlePolicy(.track(41))
            try await waitFor { engine.subtitleOCRArmedOrdinal == 0 }
            let pending = try #require(engine.nativeLegibleDeselectPinTask)
            let worker = try #require(engine.subtitleOCRWorkerTask)
            var observed = false
            let observation = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    guard let group = engine.nativeLegibleDeselectPinGroup else { return }
                    let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                    let automatic = item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group)
                    switch choice {
                    case .automatic: observed = automatic
                    case .off: observed = !automatic && selected == nil
                    case let .track(source):
                        observed = !automatic && selected?.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(source))) == true
                    }
                }
            }
            defer { NotificationCenter.default.removeObserver(observation) }
            switch choice {
            case .automatic: item.selectMediaOptionAutomatically(in: group)
            case .off: item.select(nil, in: group)
            case let .track(source):
                let option = try #require(group.options.first { $0.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(source))) })
                item.select(option, in: group)
            }
            try await waitFor { observed }
            #expect(worker.isCancelled, "A native choice must retire OCR before its old store finishes")
            #expect(pending.isCancelled)
            #expect(engine.nativeSubtitleSelectionPolicy == choice)
            stores[0].appendCues([.init(id: 0, startTime: 0, endTime: 20, body: .text("Retired OCR"))])
            stores[0].markFinished()
            await pending.value
            #expect(engine.nativeSubtitleSelectionPolicy == choice)
            guard engine.nativeSubtitleSelectionPolicy == choice else { return }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            if choice == .off {
                #expect(selected == nil)
                #expect(engine.activeSubtitleTrackIndex == nil)
                #expect(engine.subtitleOCRWorkerTask == nil)
            } else {
                try await waitFor { engine.activeSubtitleTrackIndex == 77 }
                #expect(selected?.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(77))) == true)
                #expect(engine.subtitleOCRArmedOrdinal == 1)
            }
            #expect(player.rate == (playing ? 1 : 0))
        }

        @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
        func pendingOCRRetiresOnStopOrItemReplacement(playing: Bool, stopping: Bool) async throws {
            let (engine, session, stores, player, item, group) = try await makePendingOCRFixture()
            defer { engine.stop(); session.stop() }
            engine.setNativeSubtitlePolicy(.track(3))
            try await waitFor { engine.avKitSubtitlePendingPolicy == nil && engine.activeSubtitleTrackIndex == 3 }
            if playing { player.play() }
            engine.setNativeSubtitlePolicy(.track(41))
            try await waitFor { engine.subtitleOCRArmedOrdinal == 0 }
            let pending = try #require(engine.nativeLegibleDeselectPinTask)
            let worker = try #require(engine.subtitleOCRWorkerTask)
            if stopping {
                engine.stop()
            } else {
                let replacement = AVPlayerItem(asset: AVMutableComposition())
                player.replaceCurrentItem(with: replacement)
                try await waitFor { engine.currentAVPlayerItem === replacement }
                engine.setNativeSubtitlePolicy(.off)
            }
            await pending.value
            #expect(pending.isCancelled)
            #expect(worker.isCancelled)
            stores[0].markFinished()
            #expect(item.currentMediaSelection.selectedMediaOption(in: group)?.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(41))) != true)
            #expect(engine.subtitleOCRWorkerTask == nil)
            #expect(engine.nativeLegibleDeselectPinItem !== item)
        }

        private func makePendingOCRFixture() async throws -> (AetherEngine, HLSVideoEngine, [NativeSubtitleCueStore], AVPlayer, AVPlayerItem, AVMediaSelectionGroup) {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let engine = try AetherEngine()
            var options = LoadOptions()
            options.nativeSubtitleSelectionByAVKit = true
            options.nativeSubtitlePolicy = .off
            engine.setLoadedOptionsForTesting(options)
            engine.loadedURL = URL(fileURLWithPath: "/synthetic.mkv")
            engine.nativeSubtitleTrackTable = [
                .init(sourceStreamIndex: 41, language: "en", needsOCR: true),
                .init(sourceStreamIndex: 77, language: "ja", needsOCR: true),
                .init(sourceStreamIndex: 3, language: "en"),
            ]
            let stores = (0 ..< 3).map { _ in NativeSubtitleCueStore() }
            stores[2].appendCues([.init(id: 0, startTime: 0, endTime: 20, body: .text("Initial text"))])
            stores[2].markFinished()
            engine.testHookNativeStores = stores
            let session = HLSVideoEngine(url: root.appendingPathComponent("Fixtures/native-audio-tracks.mkv"), dvModeAvailable: false)
            session.enableNativeSubtitleTrackForSession = true
            session.nativeSubtitleRenditionInfosForSession = AetherEngine.nativeSubtitleRenditionInfos(for: engine.nativeSubtitleTrackTable, avKitOwned: true)
            session.nativeSubtitleLanguagesForSession = ["en", "ja", "en"]
            session.nativeSubtitleCueStoresForSession = stores
            engine.nativeVideoSession = session
            let url = try await BlockingWork.detached { try session.start() }.value
            let item = AVPlayerItem(url: url)
            let player = AVPlayer()
            player.isMuted = true
            engine.currentAVPlayer = player
            player.replaceCurrentItem(with: item)
            let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
            try await waitFor { engine.nativeLegibleDeselectPinObserver != nil && engine.avKitSubtitlePendingPolicy == nil }
            return (engine, session, stores, player, item, group)
        }

        @Test(.timeLimit(.minutes(1))) func automaticEmptyRenditionStartsItsSourceBeforeReadiness() async throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let engine = try AetherEngine()
            defer { engine.stop() }
            var options = LoadOptions()
            options.nativeSubtitleSelectionByAVKit = true
            engine.setLoadedOptionsForTesting(options)
            engine.loadedURL = URL(fileURLWithPath: "/synthetic.mkv")
            engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: 41, language: "en", needsOCR: true)]
            let store = NativeSubtitleCueStore()
            engine.testHookNativeStores = [store]
            let session = HLSVideoEngine(url: root.appendingPathComponent("Fixtures/native-audio-tracks.mkv"), dvModeAvailable: false)
            session.enableNativeSubtitleTrackForSession = true
            session.nativeSubtitleRenditionInfosForSession = AetherEngine.nativeSubtitleRenditionInfos(for: engine.nativeSubtitleTrackTable, avKitOwned: true)
            session.nativeSubtitleLanguagesForSession = ["en"]
            session.nativeSubtitleCueStoresForSession = [store]
            engine.nativeVideoSession = session
            let url = try await BlockingWork.detached { try session.start() }.value
            defer { session.stop() }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer()
            player.isMuted = true
            player.setMediaSelectionCriteria(.init(preferredLanguages: ["en"], preferredMediaCharacteristics: nil), forMediaCharacteristic: .legible)
            engine.currentAVPlayer = player
            player.replaceCurrentItem(with: item)
            player.play()
            // Simulate a cold OCR source: it can only publish after the selected worker is armed.
            let output = AVPlayerItemLegibleOutput()
            let sink = SubtitleOutputSink()
            output.setDelegate(sink, queue: .main)
            item.add(output)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while engine.subtitleOCRArmedOrdinal == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(engine.subtitleOCRArmedOrdinal == 0, "The selected source must start before AVPlayer waits for its empty rendition")
            guard engine.subtitleOCRArmedOrdinal == 0 else { return }
            store.appendCues([.init(id: 0, startTime: 0, endTime: 20, body: .text("Cold automatic OCR cue"))])
            store.markFinished()
            let rendered = ContinuousClock.now.advanced(by: .seconds(5))
            while !sink.texts.withLock({ $0.contains(where: { $0.contains("Cold automatic OCR cue") }) }), ContinuousClock.now < rendered {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(item.status == .readyToPlay)
            #expect(sink.texts.withLock { $0.contains(where: { $0.contains("Cold automatic OCR cue") }) })
            #expect(engine.nativeSubtitleSelectionPolicy == .automatic)
        }

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
            player.isMuted = true
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
