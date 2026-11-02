# ATVPlayer fork delta

Updated November 2, 2026, on upstream AetherEngine 7.54.0 and LibTrueHD 3.1.0.

## Supplied by upstream

The production TrueHD path directly renders the exact object presentation with full metadata. BedSplitter, the comparison-only path and the reference-render trait are removed. The library enables matrix interpolation by default. Upstream also owns producer-priority propagation and its new measured relaxation policy, native bitmap OCR arming, and the latest cache, subtitle and recovery fixes.

## Retained locally

- Check the result of requesting exact decoding during TrueHD decoder creation. The LibTrueHD fork rejects that request when interpolation was not compiled in, rather than silently decoding approximately. Its rebuilt slices, capability tests and provenance remain part of the fork.
- Native container-indexed audio renditions with source-format labels, one lazy active processing pipeline, stale-event rejection and retained lossless-recovery choices.
- Opt-in AVKit subtitle policy and stable source identities; preserve automatic versus explicit intent and audio selection. Demand can start the selected text/OCR source before player readiness. Native-only playback avoids an overlay decoder, protects OCR lookahead and scopes text readers to the selected source.
- Bound video-only intermediate muxer payloads at 8 MiB without changing complete samples, segment cuts, audio or disk-backed forward buffering. Preserve upstream stereo metadata and tail accounting for applicable stream types.
- Background Vision scheduling and one-time cue-availability publication without reducing OCR quality.
- Explicit OCR selections arm the source and wait for existing forward-window coverage before AVPlayer can fetch empty segments. Pending coverage waits honor cancellation without changing transport or automatic-caption preference semantics.
- Native selection observation remains active through preparation. Actual legible changes supersede pending OCR work, while unchanged selection acknowledgements preserve the request.

The upstream native OCR activation is reused by the legacy selection path; it does not replace source identity, native-only ownership, early demand or automatic-selection policy.

## Validation boundary

Run the retained native audio, native subtitle/automatic-policy, OCR, spatial rendering, fragment/sample-equivalence and cleanup tests with both object-audio traits enabled. App integration additionally requires its focused simulator suites and mandatory staged-tree validation. Hardware audio quality, HDMI format, long-session memory and high-bitrate buffering require separate owner acceptance. This merge does not establish that acceptance.

## November 2 integration

Merged stable 7.54.0, including bitmap history byte limits, sidecar packet streaming, seek-gap coverage, frame-grid timing, and released read/recovery fixes. Retained native source selection and early OCR demand; packet protection excludes sidecar-only IDs while retaining the selected embedded OCR stream. Sidecar OCR uses upstream batches and publishes completion to the native owner.

Native audio children propagate upstream rendered-bed, Dolby-source and shaping state. Rendition codec declarations distinguish APAC from the new PCM option. ATVPlayer continues requesting APAC; no automatic output-policy change is implied. Upstream's TrueHD decoder and object renderer are unchanged from 7.48.0; the exact-decode guard and repaired LibTrueHD binary pin remain necessary. FFmpegBuild advances to 3.11.1. Three source-only compiler-warning cleanups retain identical decoding/filter behavior.

No retained repair was found wholly superseded by this release. Physical audio, HDMI and memory acceptance and the private sample-aligned reference comparison remain separate from automated tests.
