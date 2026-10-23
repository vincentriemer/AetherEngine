import AVFoundation
import Foundation

/// Session intent. An automatically resolved track must never become an explicit override on reload.
public enum NativeSubtitlePolicy: Sendable, Equatable {
    case automatic, off, track(Int)

    static func characteristic(_ source: Int) -> String {
        "com.aetherengine.subtitle.source.\(source)"
    }
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
        installAVKitSubtitleSelection()
    }

    /// Shares the item-owned observation lifetime with the legacy deselection pin, never its behavior.
    func installAVKitSubtitleSelection() {
        cancelNativeLegibleDeselectPin()
        guard let item = currentAVPlayer?.currentItem else { return }
        nativeLegibleDeselectPinTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !Task.isCancelled, self.currentAVPlayer?.currentItem === item else { return }
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
            case .automatic: item.selectMediaOptionAutomatically(in: group)
            case .off: item.select(nil, in: group)
            case let .track(source):
                let option = group.options.first { $0.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(source))) }
                if option == nil {
                    self.recordNativeSubtitlePolicy(.off)
                    self.avKitSubtitlePendingPolicy = .off
                }
                item.select(option, in: group)
            }
            self.nativeLegibleDeselectPinItem = item
            self.nativeLegibleDeselectPinGroup = group
            self.nativeLegibleDeselectPinObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
            ) { [weak self, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self, let item, item === self.currentAVPlayer?.currentItem,
                          let group = self.nativeLegibleDeselectPinGroup else { return }
                    self.consumeAVKitSubtitleSelection(item: item, group: group)
                }
            }
            self.consumeAVKitSubtitleSelection(item: item, group: group)
        }
    }

    func consumeAVKitSubtitleSelection(item: AVPlayerItem, group: AVMediaSelectionGroup) {
        guard loadedOptions.nativeSubtitleSelectionByAVKit, currentAVPlayer?.currentItem === item else { return }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        let ordinal = nativeSubtitleTrackTable.indices.first { index in
            let entry = nativeSubtitleTrackTable[index]
            guard let source = entry.sourceStreamIndex ?? entry.externalID else { return false }
            return selected?.hasMediaCharacteristic(.init(rawValue: NativeSubtitlePolicy.characteristic(source))) == true
        }
        let source = ordinal.flatMap { nativeSubtitleTrackTable[$0].sourceStreamIndex ?? nativeSubtitleTrackTable[$0].externalID }
        if let pending = avKitSubtitlePendingPolicy {
            let automatic = item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group)
            switch pending {
            case .automatic: guard automatic else { return }
            case .off: guard !automatic, selected == nil else { return }
            case let .track(expected): guard !automatic, source == expected else { return }
            }
            avKitSubtitlePendingPolicy = nil
        }
        recordNativeSubtitlePolicy(item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group)
            ? .automatic : source.map { .track($0) } ?? .off)
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
