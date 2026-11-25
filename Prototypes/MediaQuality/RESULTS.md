# Prototype results

## Subsequent channel-isolation finding

The project-audio investigation found a failing five-channel APAC round trip that the aggregate checks below did not establish. A signal in the first channel appeared in other channels after encoding and decoding. Do not treat the earlier five-channel camera result as proof of independent channel preservation. See [Spatial project audio investigation](PROJECT_AUDIO.md) for the retained reproduction, measurements, and validation boundaries.

Run on November 24, 2026, using macOS 27.2.1 and Apple Swift 6.4.2. The command-line target was macOS 26.0. Native encoder access was required outside the restricted execution sandbox.

## Passed

- macOS executable compilation with no diagnostics.
- iOS 26 SDK type checking with no diagnostics. This was not an iPhone build, installation, or runtime test.
- HDR source: 48 frames at 24 fps, lasting two seconds.
- Edited HDR: 36 frames at 24 fps, lasting 1.5 seconds after cuts and overlap.
- Exported video format: 10-bit HEVC, BT.2020 primaries, HLG transfer function.
- Minimum decoded highlight: 1.99995 in extended linear BT.2020, retaining values above SDR white.
- Dissolve sample: 3.32003 against an expected value of approximately 3.33333.
- Both title and caption regions contained visible white text. Peak decoded value was 1.20125, within the probe's compression-overshoot tolerance.
- Spatial output: four-channel APAC at 48 kHz, ACN/SN3D first-order ambisonic layout.
- Stereo output: two-channel AAC at 48 kHz, in the same alternate group with an explicit audio-fallback association.
- One-second cut and half-amplitude gain: decoded spatial RMS 0.0249888 against 0.0249986 expected.
- Added synthetic narration: decoded spatial RMS 0.0279622 against 0.0279497 expected.
- Per-channel spatial levels passed the configured tolerance, including the silent directional channels.
- Stereo fallback decoded with a nonzero signal.
- Combined HDR and spatial movie: 24 HDR frames over one second, preserving HLG highlights and both audio alternatives.
- Swift source indentation uses tabs.

## Supplied iPhone recordings

The camera validation used `appStore/testClips/Buddy_Cinematic.mov` and `appStore/testClips/Buddy_4KVideo.MOV`. Both originals were opened read-only. Both contain 3840 by 2160, 10-bit HEVC video with HLG/BT.2020 color information and alternate stereo/spatial audio tracks.

Each HDR probe rendered a 1.5-second cut/dissolve with generated title and caption at 3840 by 2160. The Cinematic test output contained 36 frames at the probe's 24 fps cadence; the other output contained 45 frames at 30 fps. These use the source minimum frame duration, not a promise of preserving every original variable-frame-rate timestamp. All output frames decoded. Central picture highlights reached approximately 3.75 and 3.82 in extended linear BT.2020. Both exports retained 10-bit HLG/BT.2020. Fresh HDR display metadata generation was requested from AVFoundation; original Dolby Vision metadata preservation was not asserted.

The Cinematic recording contains five-channel APAC: four ACN ambisonic channels and an explicit center channel. The 4K recording contains four-channel ACN/SN3D APAC. Both have a stereo AAC fallback associated with the spatial track. The prototype follows that association rather than choosing the first two-channel track arbitrarily.

The separate three-second audio probes cut from 0.25 seconds, halve the decoded source amplitude, and add a synthetic narration signal. All 144,000 requested audio frames were covered in each spatial and stereo decode. Exported audio retained the original four- or five-channel layout, APAC encoding, stereo alternative, and fallback relationship. Overall and per-channel levels passed the existing tolerances. The Cinematic output RMS was 0.00844515 against 0.00810083 expected; the 4K output RMS was 0.02251582 against 0.02252202 expected. These are lossy encodes, not bit-exact preservation.

The real camera video and audio checks produce separate outputs. A synchronized, combined real-camera multitrack export has not been validated. The combined HDR/spatial movie check above still refers to the synthetic fixture.

### Issues uncovered and implementation decisions

The initial audio reader concatenated samples rather than positioning them by timestamp. It now clips and positions samples into the requested interval and rejects uncovered frames instead of silently shortening or padding a result.

The initial assumption that spatial output always has four channels was wrong. Five-channel ambisonic-plus-center audio needs its own declared layout, and synthetic narration is added to its center channel. Four-channel input retains the established forward-facing ambisonic signal mapping.

Apple's Cinematic Audio Mix helper rejected the five-channel input with `CNCinematicErrorCodeIncomplete`. On the four-channel input, its rendered spatial output used five channels. That route also exposed a stereo processing tail and an audio-level mismatch after export. Those results are not passes. The final camera path uses direct source-layout processing for the requested cuts and gain, without invoking foreground/background remixing. Camera Audio Mix controls would require a separate investigation before integration.

## Not established

- End-to-end app playback or synchronized project export with the supplied camera clips.
- Original Dolby Vision metadata or editable Camera Audio Mix metadata preservation.
- Perceived spatial direction, spoken narration quality, or physical iPhone playback.
- Performance, memory, battery, or thermal behavior for production-sized projects.
- Integration with Trimatillo's project mixer, audio effects, ducking, transitions, source selection, or exports.

The working app source, Xcode project, schemes, and device selection were not changed. In-app Help was not changed because this prototype adds no app feature.

## Local artifacts

The final run log is `/tmp/trimatillo-quality-final.log`. Rendered fixtures are in `/tmp/trimatillo-quality-final/`. These temporary files may be removed by macOS; the source and run instructions remain in this directory.

The combined movie is `spatial-cut-gain-narration.mov`. It contains synthetic tones, not speech. `hdr-edited.mov` contains the full 1.5-second video demonstration.

The camera logs are `/tmp/trimatillo-camera-cinematic-preserved.log` and `/tmp/trimatillo-camera-4k-preserved.log`. Their corresponding output directories have the same names without `.log`. Each contains `camera-hdr-edited.mov` (silent video) and `camera-audio-cut-gain-narration.mov` (audio only).

## Follow-up: native channel conversion

The project-audio investigation reproduced a non-identity matrix for identical five-channel FOA plus center layouts on macOS and two iOS simulator runtimes. An uncompressed-file trace also reproduced the channel leakage without APAC. This narrows the investigation beyond the earlier encoded round-trip failure; it does not establish a codec defect or a production export workaround. See [PROJECT_AUDIO.md](PROJECT_AUDIO.md) and the unsubmitted [Apple Feedback draft](APPLE_FEEDBACK.md).

## Channel-preserving project export

The project renderer now requests discrete channel-order PCM decoding and keeps the original spatial metadata for encoding. Independent checks for all five channels pass, as do both supplied camera fixtures with narration and whole-program ducking. This replaces the earlier failing requested-layout conversion; it does not compensate for that conversion with gain changes. See [PROJECT_AUDIO.md](PROJECT_AUDIO.md) for the integrated path and remaining device-validation boundaries.
