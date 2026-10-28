import AVFoundation
import Foundation

/// Session intent. An automatically resolved track must never become an explicit override on reload.
public enum NativeSubtitlePolicy: Sendable, Equatable {
    case automatic, off, track(Int)

    static func characteristic(_ source: Int) -> String {
        "com.aetherengine.subtitle.source.\(source)"
    }
}

/// Selection notifications include audio acknowledgements and can arrive after a newer command.
/// Compare legible state, rather than treating every notification as a new subtitle choice.
struct AVKitSubtitleSelectionState: Equatable {
    let option: AVMediaSelectionOption?
    let automatic: Bool

    init(item: AVPlayerItem, group: AVMediaSelectionGroup) {
        option = item.currentMediaSelection.selectedMediaOption(in: group)
        automatic = item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group)
    }
}

enum AVKitSubtitleSelectionPhase {
    case preparing(AVKitSubtitleSelectionState)
    case applying(AVKitSubtitleSelectionState)
}

extension AetherEngine {
    public var nativeSubtitleResolvedOrdinal: Int? {
        nativeSubtitleReapplyOrdinal
    }

    public var nativeSubtitleSelectionPolicy: NativeSubtitlePolicy {
        loadedOptions.nativeSubtitlePolicy
    }

    public func setNativeSubtitlePolicy(_ policy: NativeSubtitlePolicy) {
        guard loadedOptions.nativeSubtitleSelectionByAVKit else { return }
        recordNativeSubtitlePolicy(policy)
        if policy == .off { activateAVKitSubtitleSource(nil) }
        installAVKitSubtitleSelection()
    }

    /// AVFoundation can fetch an automatically selected rendition before its media-selection
    /// group finishes loading. Bootstrap from actual segment demand, not a language guess or
    /// playlist enumeration. The item observer remains authoritative once selection resolves.
    func installAVKitSubtitleDemand(on session: HLSVideoEngine) {
        guard loadedOptions.nativeSubtitleSelectionByAVKit else { return }
        let generation = loadGeneration
        session.nativeSubtitleDemandHandler = { [weak self, weak session] ordinal in
            Task { @MainActor in
                guard let self, let session, self.loadGeneration == generation,
                      self.nativeVideoSession === session, self.currentAVPlayer?.currentItem != nil,
                      self.nativeSubtitleTrackTable.indices.contains(ordinal) else { return }
                let entry = self.nativeSubtitleTrackTable[ordinal]
                guard let source = entry.sourceStreamIndex ?? entry.externalID else { return }
                switch self.loadedOptions.nativeSubtitlePolicy {
                case .off: return
                case let .track(expected): guard source == expected else { return }
                case .automatic:
                    if let item = self.nativeLegibleDeselectPinItem, item === self.currentAVPlayer?.currentItem,
                       let group = self.nativeLegibleDeselectPinGroup, let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
                        guard selected.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(source))) else { return }
                    } else {
                        // Only one unresolved rendition may bootstrap. Old HTTP requests must not
                        // switch workers after a newer native selection has taken ownership.
                        guard self.nativeSubtitleReapplyOrdinal == nil || self.nativeSubtitleReapplyOrdinal == ordinal else { return }
                    }
                }
                self.activateAVKitSubtitleSource(ordinal)
            }
        }
    }

    /// Shares the item-owned observation lifetime with the legacy deselection pin, never its behavior.
    func installAVKitSubtitleSelection() {
        guard let item = currentAVPlayer?.currentItem else {
            cancelNativeLegibleDeselectPin()
            return
        }
        if nativeLegibleDeselectPinItem === item, let group = nativeLegibleDeselectPinGroup {
            nativeLegibleDeselectPinTask?.cancel()
            avKitSubtitleSelectionPhase = .preparing(.init(item: item, group: group))
        } else {
            cancelNativeLegibleDeselectPin()
        }
        avKitSubtitlePendingPolicy = loadedOptions.nativeSubtitlePolicy
        nativeLegibleDeselectPinTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !Task.isCancelled, self.currentAVPlayer?.currentItem === item else { return }
            if self.nativeLegibleDeselectPinObserver == nil {
                self.nativeLegibleDeselectPinItem = item
                self.nativeLegibleDeselectPinGroup = group
                self.avKitSubtitleSelectionPhase = .preparing(.init(item: item, group: group))
                self.nativeLegibleDeselectPinObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
                ) { [weak self, weak item] _ in
                    MainActor.assumeIsolated {
                        guard let self, let item, item === self.currentAVPlayer?.currentItem,
                              let group = self.nativeLegibleDeselectPinGroup else { return }
                        self.consumeAVKitSubtitleSelection(item: item, group: group)
                    }
                }
            }
            // Automatic legible selection must not release the user's source audio selection.
            if let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible),
               !Task.isCancelled, self.currentAVPlayer?.currentItem === item
            {
                let source = self.nativeVideoSession?.nativeAudioRenditions?.selectedIndex ?? self.activeAudioTrackIndex
                let selected = source.flatMap { index in
                    audio.options.first { $0.hasMediaCharacteristic(.init(rawValue: NativeAudioRenditions.characteristic(index))) }
                } ?? item.currentMediaSelection.selectedMediaOption(in: audio)
                if let selected {
                    item.select(selected, in: audio)
                }
            }
            guard !Task.isCancelled, self.currentAVPlayer?.currentItem === item else { return }
            self.currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = true
            self.avKitSubtitlePendingPolicy = self.loadedOptions.nativeSubtitlePolicy
            switch self.loadedOptions.nativeSubtitlePolicy {
            case .automatic:
                self.avKitSubtitleSelectionPhase = .applying(.init(item: item, group: group))
                item.selectMediaOptionAutomatically(in: group)
            case .off:
                self.avKitSubtitleSelectionPhase = .applying(.init(item: item, group: group))
                item.select(nil, in: group)
            case let .track(source):
                let option = group.options.first { $0.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(source))) }
                if option == nil {
                    self.recordNativeSubtitlePolicy(.off)
                    self.avKitSubtitlePendingPolicy = .off
                }
                // AVPlayer retains every subtitle segment fetched at selection. Arm OCR first
                // and cover that burst before exposing the rendition, including while paused.
                if option != nil, let ordinal = self.nativeSubtitleTrackTable.firstIndex(where: {
                    ($0.sourceStreamIndex ?? $0.externalID) == source
                }), self.nativeSubtitleTrackTable[ordinal].needsOCR,
                   let store = self.nativeStore(atOrdinal: ordinal) {
                    self.activateAVKitSubtitleSource(ordinal)
                    let exit = await self.awaitSubtitleOCRCoverage(ordinal: ordinal, store: store, item: item)
                    guard exit != "superseded", !Task.isCancelled,
                          self.currentAVPlayer?.currentItem === item,
                          self.loadedOptions.nativeSubtitlePolicy == .track(source) else { return }
                }
                self.avKitSubtitleSelectionPhase = .applying(.init(item: item, group: group))
                item.select(option, in: group)
            }
            self.consumeAVKitSubtitleSelection(item: item, group: group)
        }
    }

    func consumeAVKitSubtitleSelection(item: AVPlayerItem, group: AVMediaSelectionGroup) {
        guard loadedOptions.nativeSubtitleSelectionByAVKit, currentAVPlayer?.currentItem === item else { return }
        let state = AVKitSubtitleSelectionState(item: item, group: group)
        let selected = state.option
        let automatic = state.automatic
        let ordinal = nativeSubtitleTrackTable.indices.first { index in
            let entry = nativeSubtitleTrackTable[index]
            guard let source = entry.sourceStreamIndex ?? entry.externalID else { return false }
            return selected?.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(source))) == true
        }
        let source = ordinal.flatMap { nativeSubtitleTrackTable[$0].sourceStreamIndex ?? nativeSubtitleTrackTable[$0].externalID }
        if case let .preparing(baseline) = avKitSubtitleSelectionPhase {
            // Audio changes and late acknowledgements of the prior choice do not relinquish
            // preparation. An actual legible change does, even when it differs from our request.
            guard state != baseline else { return }
            nativeLegibleDeselectPinTask?.cancel()
            avKitSubtitlePendingPolicy = nil
        }
        if let pending = avKitSubtitlePendingPolicy {
            let acknowledged: Bool
            switch pending {
            case .automatic: acknowledged = automatic
            case .off: acknowledged = !automatic && selected == nil
            case let .track(expected): acknowledged = !automatic && source == expected
            }
            if !acknowledged {
                if case let .applying(baseline) = avKitSubtitleSelectionPhase, state == baseline { return }
                nativeLegibleDeselectPinTask?.cancel()
            }
            avKitSubtitlePendingPolicy = nil
        }
        avKitSubtitleSelectionPhase = nil
        recordNativeSubtitlePolicy(automatic ? .automatic : source.map { .track($0) } ?? .off)
        // Resolve the policy transaction even before readiness, so a subsequent manual choice
        // is accepted. An unresolved automatic group must not stop a demand-started source.
        if selected == nil, item.status == .unknown, automatic { return }
        activateAVKitSubtitleSource(ordinal)
    }

    /// Feeds only the resolved rendition. This never calls item.select or changes automatic criteria.
    func activateAVKitSubtitleSource(_ ordinal: Int?) {
        let expectedSource = ordinal.flatMap { nativeSubtitleTrackTable.indices.contains($0) ? nativeSubtitleTrackTable[$0].sourceStreamIndex ?? nativeSubtitleTrackTable[$0].externalID : nil }
        guard ordinal != nativeSubtitleReapplyOrdinal || activeSubtitleTrackIndex != expectedSource else { return }
        cancelNativeSubtitleReaders()
        cancelSubtitleOCRWorker()
        cancelSidecarTask()
        nativeSubtitleReapplyOrdinal = ordinal
        guard let ordinal, nativeSubtitleTrackTable.indices.contains(ordinal),
              let source = nativeSubtitleTrackTable[ordinal].sourceStreamIndex ?? nativeSubtitleTrackTable[ordinal].externalID
        else {
            clearSubtitleDrainTarget(channel: .primary, reason: .subtitlesCleared)
            activeSubtitleTrackIndex = nil
            activeEmbeddedSubtitleStreamIndex = -1
            isSubtitleActive = false
            nativeSubtitleOnly = false
            subtitleCues = []
            return
        }
        selectSubtitleTrack(index: source, startAt: sourceTime, nativeOnly: true)
        startLazyNativeSubtitleReadersWhenIdle()
    }
}
