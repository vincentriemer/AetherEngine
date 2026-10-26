# ATVPlayer fork delta

Updated October 26, 2026, on upstream AetherEngine 7.48.0 and LibTrueHD 3.1.0.

## Supplied by upstream

The production TrueHD path directly renders the exact object presentation with full metadata. BedSplitter, the comparison-only path and the reference-render trait are removed. The library enables matrix interpolation by default. Upstream also owns producer-priority propagation and its new measured relaxation policy, native bitmap OCR arming, and the latest cache, subtitle and recovery fixes.

## Retained locally

- Check the result of requesting exact decoding during TrueHD decoder creation. The LibTrueHD fork rejects that request when interpolation was not compiled in, rather than silently decoding approximately. Its rebuilt slices, capability tests and provenance remain part of the fork.
- Native container-indexed audio renditions with source-format labels, one lazy active processing pipeline, stale-event rejection and retained lossless-recovery choices.
- Opt-in AVKit subtitle policy and stable source identities; preserve automatic versus explicit intent and audio selection. Demand can start the selected text/OCR source before player readiness. Native-only playback avoids an overlay decoder, protects OCR lookahead and scopes text readers to the selected source.
- Bound video-only intermediate muxer payloads at 8 MiB without changing complete samples, segment cuts, audio or disk-backed forward buffering. Preserve upstream stereo metadata and tail accounting for applicable stream types.
- Background Vision scheduling and one-time cue-availability publication without reducing OCR quality.

The upstream native OCR activation is reused by the legacy selection path; it does not replace source identity, native-only ownership, early demand or automatic-selection policy.

## Validation boundary

Run the retained native audio, native subtitle/automatic-policy, OCR, spatial rendering, fragment/sample-equivalence and cleanup tests with both object-audio traits enabled. App integration additionally requires its focused simulator suites and mandatory staged-tree validation. Hardware audio quality, HDMI format, long-session memory and high-bitrate buffering require separate owner acceptance. This merge does not establish that acceptance.
