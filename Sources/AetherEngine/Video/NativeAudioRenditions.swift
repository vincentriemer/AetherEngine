import Foundation

/// Real, container-indexed audio-only HLS renditions. Playlist and name requests are metadata-only.
/// The serial worker owns exactly one audio session; selection invalidates blocked source reads.
final class NativeAudioRenditions: @unchecked Sendable {
    struct Response { let data: Data; let type: String }
    struct Rendition {
        let id: Int
        let name: String
        let language: String?
        let codecs: [String]
        let channels: String?
    }

    static func characteristic(_ index: Int) -> String {
        "dev.atvplayer.source-audio.s\(index)"
    }

    private let tracks: [Rendition]
    private let plan: [HLSVideoEngine.Segment]
    private let initial: Int?
    private let makeSession: @Sendable (Int, Double) throws -> HLSVideoEngine
    private let failed: @Sendable (Int, Int) -> Void
    private let activated: @Sendable (Int, HLSVideoEngine) -> Void
    private let condition = NSCondition()
    private let worker = DispatchQueue(label: "AetherEngine.native-audio-rendition")
    private var selected: Int?
    private var seconds: Double = 0
    private var epoch = 0
    private var stopped = false
    private var child: HLSVideoEngine?
    private var childID: Int?
    private var childEpoch = -1

    init(tracks: [TrackInfo], names: [Int: String], initial: Int?, plan: [HLSVideoEngine.Segment],
         rendering: ObjectAudioRendering = .off, losslessTracks: Set<Int> = [],
         makeSession: @escaping @Sendable (Int, Double) throws -> HLSVideoEngine,
         activated: @escaping @Sendable (Int, HLSVideoEngine) -> Void,
         failed: @escaping @Sendable (Int, Int) -> Void = { _, _ in })
    {
        self.tracks = tracks.map { track in
            let base = names[track.id] ?? track.name
            // NAME must be unique even with absent/identical metadata. IDs always remain container IDs.
            let duplicate = tracks.filter { (names[$0.id] ?? $0.name) == base }.count > 1
            var codecs = [Self.codec(track.codec)]
            var channels = track.channels > 0 ? String(track.channels) : nil
            if track.codec == "eac3", track.isAtmos {
                channels = VideoSegmentProvider.atmosChannelsAttribute
            }
            if ["truehd", "dts"].contains(track.codec), !losslessTracks.contains(track.id),
               ObjectAudioRendering.isAvailable, let layout = rendering.layout
            {
                codecs.append(APACSampleEntry.codecsString(channelCount: layout.channelCount))
                // Decoder/encoder availability is resolved lazily; do not claim an output layout here.
                channels = nil
            }
            return Rendition(id: track.id, name: Self.quoted(duplicate ? "\(base) · Track \(track.id)" : base),
                             language: track.language.map(Self.quoted), codecs: codecs, channels: channels)
        }
        self.initial = initial
        selected = initial
        self.plan = plan
        self.makeSession = makeSession
        self.activated = activated
        self.failed = failed
    }

    var codecs: [String] {
        Array(Set(tracks.flatMap(\.codecs))).sorted()
    }

    var mediaTags: [String] {
        tracks.map { track in
            var attrs = ["TYPE=AUDIO", "GROUP-ID=\"aud\"", "NAME=\"\(track.name)\"",
                         "DEFAULT=\(track.id == initial ? "YES" : "NO")", "AUTOSELECT=\(track.id == initial ? "YES" : "NO")",
                         "CHARACTERISTICS=\"\(Self.characteristic(track.id))\"",
                         "URI=\"audio_\(track.id)/media.m3u8\""]
            if let channels = track.channels {
                attrs.append("CHANNELS=\"\(channels)\"")
            }
            if let language = track.language {
                attrs.append("LANGUAGE=\"\(language)\"")
            }
            return "#EXT-X-MEDIA:" + attrs.joined(separator: ",")
        }
    }

    func select(_ index: Int, at position: Double? = nil) {
        guard tracks.contains(where: { $0.id == index }) else { return }
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        if let position, position.isFinite {
            seconds = max(0, position)
        }
        guard selected != index else { condition.unlock(); return }
        selected = index
        epoch += 1
        let old = child
        condition.broadcast()
        condition.unlock()
        // Only cancellation here. Destruction is serialized with responses on the worker.
        old?.nativeAudioSourceReader?.reader.cancel()
        old?.demuxer?.markClosed()
    }

    var selectionEpoch: Int {
        condition.lock(); defer { condition.unlock() }
        return epoch
    }

    var selectedIndex: Int? {
        condition.lock(); defer { condition.unlock() }
        return stopped ? nil : selected
    }

    func stop(waitForCleanup: Bool = false) {
        condition.lock()
        if !stopped {
            epoch += 1
        }
        stopped = true
        let old = child
        condition.broadcast()
        condition.unlock()
        old?.nativeAudioSourceReader?.reader.cancel()
        old?.demuxer?.markClosed()
        if waitForCleanup {
            worker.sync { _ = retireChild() }
        } else {
            worker.async { [self] in retireChild() }
        }
    }

    func response(path: String) -> Response? {
        if path == "/audio_names.json" {
            let names = Dictionary(uniqueKeysWithValues: tracks.map { ($0.name, ["en": $0.name]) })
            return (try? JSONSerialization.data(withJSONObject: names)).map { Response(data: $0, type: "application/json") }
        }
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0].hasPrefix("audio_"),
              let index = Int(parts[0].dropFirst(6)), tracks.contains(where: { $0.id == index }) else { return nil }
        if parts[1] == "media.m3u8" {
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD",
                         "#EXT-X-TARGETDURATION:\(Int(ceil(plan.map(\.durationSeconds).max() ?? 1)))",
                         "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-MAP:URI=\"init.mp4\""]
            for (n, segment) in plan.enumerated() {
                lines += [String(format: "#EXTINF:%.6f,", segment.durationSeconds), "seg\(n).m4s"]
            }
            lines += ["#EXT-X-ENDLIST", ""]
            return Response(data: Data(lines.joined(separator: "\n").utf8), type: "application/vnd.apple.mpegurl")
        }
        let segment: Int?
        if parts[1] == "init.mp4" {
            segment = nil
        } else if parts[1].hasPrefix("seg"), parts[1].hasSuffix(".m4s"),
                  let number = Int(parts[1].dropFirst(3).dropLast(4)), plan.indices.contains(number)
        {
            segment = number
        } else {
            return nil
        }
        // A rendition may be probed while its selection callback is queued. Never activate an
        // unselected pipeline, and never let an abandoned request retarget the active track.
        condition.lock()
        let deadline = Date(timeIntervalSinceNow: 2)
        while !stopped, selected != index {
            if !condition.wait(until: deadline) {
                break
            }
        }
        let generation = epoch
        let allowed = !stopped && selected == index
        condition.unlock()
        guard allowed else { return nil }
        return worker.sync {
            guard current(index, generation) else { return nil }
            do {
                if childID != index || childEpoch != generation {
                    guard retireChild() else { reportFailure(index, generation); return nil }
                    guard current(index, generation) else { return nil }
                    condition.lock(); let start = seconds; condition.unlock()
                    let session = try makeSession(index, segment.map { plan[$0].startSeconds } ?? start)
                    session.onVODSourceFailed = { [weak self] _, _, _ in
                        self?.reportFailure(index, generation)
                    }
                    condition.lock(); child = session; condition.unlock()
                    guard current(index, generation) else { retireChild(); return nil }
                    try session.prepare()
                    guard current(index, generation), let provider = session.provider,
                          session.segmentPlan.count == plan.count,
                          zip(session.segmentPlan, plan).allSatisfy({ abs($0.startSeconds - $1.startSeconds) < 0.001 })
                    else {
                        retireChild(); return nil
                    }
                    _ = provider
                    childID = index
                    childEpoch = generation
                    activated(index, session)
                }
                guard let provider = child?.provider else { return nil }
                if let segment, let child {
                    _ = provider.mediaSegmentURL(at: segment)
                    if child.cache?.peekURL(index: segment) == nil {
                        let base = child.currentProducerBaseIndex ?? segment
                        let passed = (child.cache?.highestStoredIndex ?? -1) > segment
                        if segment < base || segment > base + child.forwardWindowSegments || passed || child.currentProducerFinished {
                            child.requestRestart(at: segment, authoritative: true)
                        }
                    }
                }
                let deadline = Date(timeIntervalSinceNow: 15)
                while current(index, generation), Date() < deadline {
                    let data = segment.flatMap { child?.cache?.fetch(index: $0, timeout: 0.1) }
                        ?? (segment == nil ? child?.cache?.fetchInit(timeout: 0.1) : nil)
                    if let data {
                        return Response(data: data, type: "audio/mp4")
                    }
                }
                if current(index, generation) {
                    reportFailure(index, generation)
                }
                return nil
            } catch {
                retireChild()
                if current(index, generation) {
                    reportFailure(index, generation)
                }
                return nil
            }
        }
    }

    private func reportFailure(_ index: Int, _ generation: Int) {
        guard current(index, generation) else { return }
        failed(index, generation)
    }

    private func current(_ index: Int, _ generation: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !stopped && selected == index && epoch == generation
    }

    @discardableResult private func retireChild() -> Bool {
        condition.lock(); let old = child; condition.unlock()
        old?.producer?.stop()
        old?.nativeAudioSourceReader?.reader.cancel()
        old?.demuxer?.markClosed()
        // Never open a replacement decoder while the previous pump still owns its bridge.
        guard old?.producer?.waitForFinish(timeout: 3) != false else { return false }
        old?.stop(waitForCleanup: true)
        condition.lock(); child = nil; condition.unlock()
        childID = nil
        childEpoch = -1
        return true
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func codec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "aac": "mp4a.40.2"
        case "ac3": "ac-3"
        case "eac3": "ec-3"
        case "alac": "alac"
        default: "fLaC"
        }
    }
}

extension HLSVideoEngine {
    func makeNativeAudioSession(index: Int, seconds: Double) throws -> HLSVideoEngine {
        let source = nativeAudioReaderFactory?()
        guard source != nil || sourceReopenableByURL else { throw HLSVideoEngineError.notStarted }
        let child = HLSVideoEngine(url: sourceURL, sourceHTTPHeaders: sourceHTTPHeaders,
                                   audioSourceStreamIndexOverride: Int32(index),
                                   audioBridgeMode: audioBridgeMode,
                                   objectAudioRendering: nativeAudioLosslessStreamIndices.contains(index) ? .off : objectAudioRendering,
                                   sourceReopenableByURL: sourceReopenableByURL,
                                   forwardBufferSegments: forwardWindowSegments)
        child.nativeAudioSourceReader = source
        child.audioOnlyRendition = true
        child.initialStartSeconds = seconds
        child.nativeAudioSegmentPlan = segmentPlan
        child.audioDelaySeconds = audioDelaySeconds
        child.requestHeaders = requestHeaders
        return child
    }
}
