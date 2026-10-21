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
