# ATVPlayer fork delta

Updated November 9, 2026, on upstream AetherEngine 7.62.0 and published LibTrueHD 3.2.0.

## Supplied by upstream

TrueHD uses the lossless channel presentation for the output signal and the object presentation for spatial statistics. DTS:X uses the coded bed and presentation-specific height information from FFmpegBuild 3.14.0. The package manifest, resolved dependencies and Audio sources match upstream. This supersedes the fork’s direct object renderer and exact-interpolation requirement. ATVPlayer requests APAC 7.1.4 with lossless fallback. Audible equivalence requires listening on the owner's hardware.

## Retained locally

- Native container-indexed audio renditions with source-format labels, one lazy active processing pipeline, stale-event rejection and retained lossless-recovery choices.
- Opt-in AVKit subtitle policy and stable source identities; preserve automatic versus explicit intent and audio selection. Demand can start the selected text/OCR source before player readiness. Native-only playback avoids an overlay decoder, protects OCR lookahead and scopes text readers to the selected source.
- Bound video-only intermediate muxer payloads at 8 MiB without changing complete samples, segment cuts, audio or disk-backed forward buffering. Preserve upstream stereo metadata and tail accounting for applicable stream types.
- Background Vision scheduling and one-time cue-availability publication without reducing OCR quality.
- Explicit OCR selections arm the source and wait for existing forward-window coverage before AVPlayer can fetch empty segments. Pending coverage waits honor cancellation without changing transport or automatic-caption preference semantics.
- Native selection observation remains active through preparation. Actual legible changes supersede pending OCR work, while unchanged selection acknowledgements preserve the request.

The upstream native OCR activation is reused by the legacy selection path; it does not replace source identity, native-only ownership, early demand or automatic-selection policy.

## Validation boundary

Run the retained native audio, native subtitle/automatic-policy, OCR, spatial rendering, fragment/sample-equivalence and cleanup tests with both object-audio traits enabled. App integration additionally requires its focused simulator suites and mandatory staged-tree validation. Hardware audio quality, HDMI format, long-session memory and high-bitrate buffering require separate owner acceptance. This merge does not establish that acceptance.
