import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

@MainActor
@Suite("Native bitmap subtitle selection")
struct NativeBitmapSubtitleSelectionTests {
    private func prepared() throws -> AetherEngine {
        let engine = try AetherEngine()
        // No reader/session is installed: selection identity and worker ownership need no I/O.
        engine.loadedURL = URL(fileURLWithPath: "/synthetic-subtitles.mkv")
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: 3, language: "eng"),
            .init(sourceStreamIndex: 41, language: "eng", needsOCR: true),
            .init(sourceStreamIndex: 77, language: "eng", needsOCR: true),
            .init(sourceStreamIndex: 91, language: "deu", needsOCR: true),
        ]
        engine.testHookNativeStores = (0..<4).map { _ in NativeSubtitleCueStore() }
        return engine
    }

    @Test("same-language native ordinals activate the actual bitmap source and one OCR worker")
    func bitmapSources() throws {
        let engine = try prepared()
        defer { engine.stop() }
        for (ordinal, source) in [(1, 41), (2, 77), (3, 91)] {
            let previous = engine.subtitleOCRWorkerTask
            engine.selectNativeSubtitle(track: ordinal)
            #expect(engine.activeSubtitleTrackIndex == source)
            #expect(engine.nativeSubtitleReapplyOrdinal == ordinal)
            #expect(engine.subtitleOCRArmedOrdinal == ordinal)
            #expect(engine.subtitleOCRWorkerTask != nil)
            #expect(engine.subtitleDrainerTask == nil)
            #expect(engine.subtitleDrainTargets.isEmpty)
            #expect(engine.subtitleCues.isEmpty)
            #expect(engine.subtitlePacketStreamIndices == [Int32(source)])
            if let previous { #expect(previous.isCancelled) }
        }
    }

    @Test("text selection retires OCR; Off releases workers and active subtitle state")
    func textAndOff() throws {
        let engine = try prepared()
        defer { engine.stop() }
        engine.selectNativeSubtitle(track: 1)
        let worker = try #require(engine.subtitleOCRWorkerTask)
        engine.selectNativeSubtitle(track: 0)
        #expect(worker.isCancelled)
        #expect(engine.activeSubtitleTrackIndex == 3)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
        engine.selectNativeSubtitle(track: 2)
        engine.selectNativeSubtitle(track: nil)
        #expect(engine.subtitleOCRWorkerTask == nil)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.nativeSubtitleReapplyOrdinal == nil)
        #expect(!engine.isSubtitleActive)
    }

    @Test("native text reads only its selected source and bitmap changes cancel text work")
    func selectedTextReader() async throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try prepared()
        defer { engine.stop() }
        engine.loadedURL = url
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: 1, language: "eng"),
            .init(sourceStreamIndex: 2, language: "spa"),
            .init(sourceStreamIndex: 41, language: "eng", needsOCR: true),
        ]
        let stores = (0..<3).map { _ in NativeSubtitleCueStore() }
        engine.testHookNativeStores = stores
        engine.nativeSubtitleReaderParams = (url, stores)
        engine.selectNativeSubtitle(track: 0)
        let textReader = try #require(engine.nativeSubtitleReadersTask)
        for _ in 0..<100 where stores[0].cueCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(stores[0].cueCount == 2)
        #expect(stores[1].cueCount == 0, "unselected text must not be decoded")
        #expect(engine.subtitleDrainerTask == nil)
        engine.selectNativeSubtitle(track: 2)
        #expect(textReader.isCancelled)
        #expect(engine.nativeSubtitleReadersTask == nil)
        #expect(engine.nativeSubtitleReaderDeferralTask == nil)
        #expect(engine.subtitleOCRArmedOrdinal == 2)
        engine.selectNativeSubtitle(track: 1)
        for _ in 0..<100 where stores[1].cueCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(stores[1].cueCount == 2)
        #expect(engine.subtitleOCRWorkerTask == nil)
        engine.selectNativeSubtitle(track: nil)
        #expect(engine.nativeSubtitleReadersTask == nil)
        #expect(engine.subtitlePacketStreamIndices.isEmpty)
    }

    @Test("native OCR owns lookahead across secondary cleanup, seeks, and stop")
    func independentPacketLookahead() async throws {
        let engine = try prepared()
        defer { engine.stop() }
        engine.selectNativeSubtitle(track: 1)
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.subtitleOCRCursors[1] = SubtitleDrainCursor(lastDecodedPts: 240, lastPlayhead: 0)
        engine.clock.sourceTime = 500
        let reanchor = SubtitleForwardPrefetcher.SideReaderReanchor(anchorStreamIndex: 41, fallbackDuration: 0, seekTimeout: 5)
        engine.subtitleForwardPrefetchReanchor = reanchor
        engine.subtitleForwardPrefetchActiveLead = AetherEngine.subtitleOCRPrefetchLeadSeconds
        let prefetch = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        engine.subtitleForwardPrefetchTask = prefetch
        engine.clearSecondarySubtitle()
        #expect(!prefetch.isCancelled, "secondary overlay cleanup cannot stop native OCR lookahead")
        for _ in 0..<100 where !reanchor.hasPending {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reanchor.take()?.seconds == 500)
        #expect(engine.subtitlePacketStreamIndices == [41])
        #expect(engine.subtitleDrainerTask == nil)
        engine.stop()
        #expect(prefetch.isCancelled)
        #expect(engine.subtitleForwardPrefetchTask == nil)
        #expect(engine.subtitleOCRWorkerTask == nil)
        #expect(engine.subtitlePacketStreamIndices.isEmpty)
        #expect(!engine.nativeSubtitleOnly)
    }

    @Test("native-only selection survives session carryover without an overlay")
    func nativeCarryover() throws {
        let engine = try prepared()
        defer { engine.stop() }
        engine.selectNativeSubtitle(track: 1)
        let carryover = engine.captureSubtitleSessionCarryover()
        #expect(carryover.nativeOnly)
        engine.stop()
        engine.loadedURL = URL(fileURLWithPath: "/synthetic-subtitles.mkv")
        engine.nativeSubtitleTrackTable = [.init(sourceStreamIndex: 41, language: "eng", needsOCR: true)]
        engine.testHookNativeStores = [NativeSubtitleCueStore()]
        engine.restoreSubtitleSelection(from: carryover, resumeAnchor: 500)
        #expect(engine.activeSubtitleTrackIndex == 41)
        #expect(engine.nativeSubtitleOnly)
        #expect(engine.subtitleOCRArmedOrdinal == 0)
        #expect(engine.nativeSubtitleReapplyOrdinal == 0)
        #expect(engine.subtitleDrainerTask == nil)
    }

    @Test("changing to OCR cancels a deferred text reader before it can open")
    func retiredTextDeferral() throws {
        let engine = try prepared()
        defer { engine.stop() }
        engine.nativeSubtitleReaderParams = (try #require(engine.loadedURL), try #require(engine.testHookNativeStores))
        engine.testHookRestartInFlightOverride = true
        engine.selectNativeSubtitle(track: 0)
        let deferred = try #require(engine.nativeSubtitleReaderDeferralTask)
        engine.selectNativeSubtitle(track: 1)
        #expect(deferred.isCancelled)
        #expect(engine.nativeSubtitleReaderDeferralTask == nil)
        #expect(engine.nativeSubtitleReadersTask == nil)
    }

    @Test("invalid choices leave the active rendition and source untouched")
    func invalidChoices() throws {
        let engine = try prepared()
        defer { engine.stop() }
        engine.selectNativeSubtitle(track: 1)
        for ordinal in [-1, 4, 41] { engine.selectNativeSubtitle(track: ordinal) }
        #expect(engine.activeSubtitleTrackIndex == 41)
        #expect(engine.nativeSubtitleReapplyOrdinal == 1)
        #expect(engine.subtitleOCRArmedOrdinal == 1)
    }

    @Test("Off and stop cancel a pending item selection rather than resurrecting it")
    func pendingSelectionCleanup() throws {
        let engine = try prepared()
        defer { engine.stop() }
        // The asynchronous legible-group load has not run yet on this actor.
        let player = AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/synthetic.mp4")))
        engine.currentAVPlayer = player
        engine.selectNativeSubtitle(track: 1)
        let first = try #require(engine.nativeSubtitleSelectionTask)
        let worker = try #require(engine.subtitleOCRWorkerTask)
        engine.selectNativeSubtitle(track: nil)
        #expect(first.isCancelled)
        #expect(worker.isCancelled)
        let off = try #require(engine.nativeSubtitleSelectionTask)
        engine.selectNativeSubtitle(track: 2)
        #expect(off.isCancelled)
        let last = try #require(engine.nativeSubtitleSelectionTask)
        engine.stop()
        #expect(last.isCancelled)
        #expect(engine.nativeSubtitleSelectionTask == nil)
        #expect(engine.subtitleOCRWorkerTask == nil)
    }

    @Test("real OCR cue arrival retries a cold selection, but never a retired choice")
    func coldRecognitionCompletes() throws {
        let engine = try prepared()
        defer { engine.stop() }
        engine.currentAVPlayer = AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/synthetic.mp4")))
        engine.selectNativeSubtitle(track: 1)
        engine.pendingNativeSubtitleOCROrdinal = 1
        let pending = try #require(engine.nativeSubtitleSelectionTask)
        engine.nativeSubtitleOCRDidFill(ordinal: 1)
        #expect(engine.pendingNativeSubtitleOCROrdinal == 1)
        #expect(!pending.isCancelled, "an empty OCR store cannot trigger a retry")
        let store = try #require(engine.testHookNativeStores?[1])
        store.appendCues([SubtitleCue(id: 1, startTime: 0, endTime: 2, body: .text("Recognized"))])
        engine.nativeSubtitleOCRDidFill(ordinal: 1)
        #expect(pending.isCancelled)
        #expect(engine.pendingNativeSubtitleOCROrdinal == nil)
        #expect(engine.nativeSubtitleReapplyOrdinal == 1)
        engine.pendingNativeSubtitleOCROrdinal = 1
        engine.selectNativeSubtitle(track: nil)
        let off = try #require(engine.nativeSubtitleSelectionTask)
        engine.nativeSubtitleOCRDidFill(ordinal: 1)
        #expect(engine.nativeSubtitleReapplyOrdinal == nil)
        #expect(!off.isCancelled)
    }
}
