# Spatial project audio investigation

## Status

The project renderer is now integrated in `trimiOS/SpatialProjectAudio.swift`. The decoder requests `kAudioChannelLayoutTag_DiscreteInOrder` with the actual source channel count, retaining the source layout separately for explicit mixing and spatial encoding. This avoids the speaker-layout remix identified below. It uses neither compensating gains nor an inverse matrix.

Supported project exports on iOS 26 or later retain spatial audio plus the existing stereo mix. Project preview continues to use the existing stereo playback path. Spatial sources with non-neutral stereo controls or volume smoothing, unsupported layouts, and older systems retain the explicit stereo-export confirmation. Source files are not modified.

The intended behavior remains front narration with the same ducking gain applied to every program channel. Narration is excluded from that reduction.

## Renderer

`trimiOS/SpatialProjectAudio.swift` preserves four-channel ACN/SN3D soundfields in a five-channel working layout, retaining a fifth front-center channel when present. It places mono narration in the center and encodes stereo material at front-left and front-right positions. It reads bounded PCM blocks, aligns them by presentation timestamp, handles gaps, and applies linked spatial gain envelopes directly to PCM. Ordinary audio uses AVFoundation audio mixes before front placement.

Applying an AVFoundation processing tap to native spatial input caused an intermediate stereo conversion in the tested path. Spatial gain therefore uses explicit sample-aligned envelopes rather than that tap path.

The experimental writer attaches a stereo alternative to its APAC track and preserves a rendered video's compressed packets. The stereo alternative uses the corresponding source stereo mix. This is not proof of identical perceived loudness or spatial playback on a device.

## Run

Run from the repository root on an Apple silicon Mac with macOS 26 or later and the current Xcode SDK. Each output directory must be new. The checks use Apple's media services, which must be accessible to the process.

```sh
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 -module-cache-path /tmp/trimatillo-quality-module-cache trimiOS/SpatialProjectAudio.swift Prototypes/MediaQuality/ProjectAudioCheck.swift trimiOS/MediaExportSupport.swift -o /tmp/trimatillo-project-audio-check
/tmp/trimatillo-project-audio-check /tmp/project-audio-isolation --isolation
/tmp/trimatillo-project-audio-check /tmp/project-audio-4k appStore/testClips/Buddy_4KVideo.MOV
/tmp/trimatillo-project-audio-check /tmp/project-audio-cinematic appStore/testClips/Buddy_Cinematic.mov
```

A failed validation exits with status 1. The isolated-channel check now exercises each of the five channels independently. The camera fixture joins two separate source ranges, adds stereo and mono signals, applies source volume and ducking with fades, and exports a combined HDR video with spatial and stereo audio. Silent reference channels must remain silent rather than using a ratio with a zero denominator.

## Earlier observations before channel-order decoding

On both supplied recordings, every uncompressed mixed sample matched the independently constructed reference within 0.00001. The two-second fixture combines a source section, distinct left/right tones, centered narration, source gain, timed ducking, and fades. The narration remains unducked.

After APAC encoding and decoding, the first channel's RMS level was approximately 1.499 times the expected level for both recordings. This fails the 12 percent tolerance used by the native-media check.

The independent isolation case puts a 440 Hz signal only in the first channel. Expected RMS is 0.070711 in that channel and zero in all others. The observed decoded levels were 0.106041 in the first channel and 0.035347 in each of the other four channels. This check does not depend on a project, ducking, imported media, or narration.

The failure also reproduced with the previous prototype writer. Supplying an explicit source-format hint, using direct track decoding, and checking Apple's capture-helper settings did not establish a passing five-channel round trip. A separate direct Audio Converter encoder check also reproduced the discrepancy. The follow-up below reproduces a matching discrepancy without APAC encoding and narrows at least one failure to native channel-layout conversion. It does not prove the APAC codec itself is at fault.

The retained minimal reproduction uses ordinary documented APAC writer settings. It does not use reserved Apple content-source values, compensating gains, or an inverse channel matrix to conceal the problem.

## Validation boundaries

The app and Share extension compile with the integrated renderer. No Xcode scheme, selected device, or device installation was changed.

Physical iPhone playback, head tracking, perceived narration placement, and full-project performance have not been validated. This work does not establish general compatibility for arbitrary multichannel source layouts or stereo-specific effects applied to spatial source tracks.

The earlier aggregate five-channel camera checks in RESULTS.md are insufficient evidence of independent channel preservation. Their results need to be reconsidered alongside this isolated-channel failure. The existing standalone Cutting Board export path requires its own signal-level verification before attributing this exact failure to it.

## Recorded local evidence

- `/tmp/trimatillo-project-audio-4k-verified.log`
- `/tmp/trimatillo-project-audio-cinematic-verified.log`
- `/tmp/trimatillo-project-channel-isolation.log`

These temporary logs can be removed by macOS. The source and commands above retain the reproduction.

## Channel-layout follow-up

`ChannelLayoutCheck.swift` reproduces a non-identity conversion matrix for identical five-channel FOA plus center layouts without reading media, encoding APAC, or playing audio. Core Audio reports the layouts equivalent but returns 1.5 for W-to-W and 0.5 for W-to-each-other-channel. Stereo and four-channel FOA controls return identity matrices. Same-format PCM conversion preserves all five isolated channels with both the default mapping and an explicit identity mapping; that does not establish a complete export workaround.

The same matrix result occurred on macOS 27.2.1 (26B131), iOS 26.0 Simulator (23A343), and iOS 27.2 Simulator (24B8117), using Xcode 27.2 (27B52). On macOS, the layout returned by Apple's Cinematic spatial writer helper for the supplied four-channel camera recording equals the reproduction layout and produces the same matrix. The complete Apple sample was not run end to end.

A separate uncompressed-file trace retained isolated W at RMS 0.070710678 when read without conversion. Requesting five-channel PCM through AVAssetReaderAudioMixOutput changed it to 0.106066018 in W and 0.035355339 in each other channel. APAC is not required for this discrepancy. The retained minimal matrix reproduction and its run instructions are in [APPLE_FEEDBACK.md](APPLE_FEEDBACK.md).

The Apple Feedback report is a draft and has not been submitted. Neither simulator result establishes physical iPhone behavior. Both simulators were returned to their initial shutdown state. No phone installation or Xcode destination was changed. The prototype also now explicitly marks newly populated CMSampleBuffers ready; this did not resolve the channel discrepancy.

Additional temporary evidence: `/tmp/trimatillo-channel-layout-mac.log`, `/tmp/trimatillo-channel-layout-ios26.log`, `/tmp/trimatillo-channel-layout-ios272.log`, `/tmp/trimatillo-trace-pcm-stored.log`, and `/tmp/trimatillo-trace-pcm-remix.log`.

## Source timing and temporary audio

Seeking directly into compressed APAC produced a 2,944-sample (61.33 ms at 48 kHz) difference from continuously decoded source audio in the checks. The exporter therefore decodes each used spatial source continuously into managed temporary PCM audio before assembling its edit ranges. It reads only through the final required source time and retains each temporary asset until rendering completes. These files use the existing export work-directory cleanup and do not become project media. Memory remains bounded; temporary disk use grows with the required source duration. This preparation adds export work, especially for edits near the end of a long source.

The reference check continuously decodes past the chosen source ranges, then selects the exact source samples independently. All pre-encoding mixed samples now match within 0.00001 across the join. Source reference coverage is required for the selected ranges; native decoder buffering beyond those ranges is not treated as missing edited audio.

## Integrated path validation

All five isolated-channel APAC round trips passed with channel-order decoding, including a waveform check for signal timing. The four-channel and five-channel camera fixtures also passed the uncompressed mix and encoded channel-level checks. Combined exports retained 10-bit HDR video, spatial audio, and an associated stereo fallback. The current check compares fallback PCM with the stereo intermediate and decodes every video frame while checking video/audio duration alignment.

These checks exercise the production native-media renderer on macOS. The iOS app and Share extension are built separately. They do not establish physical iPhone listening quality, head tracking, VoiceOver behavior, or large-project thermal performance. No device installation or Xcode destination change is part of this implementation.

The prior matrix reproduction remains valid for the explicit mixed-layout conversion it queries. It does not describe the new discrete channel-order decoding path. The Apple Feedback draft records that distinction.

Final combined check: `/tmp/trimatillo-prepared-retained.log`. The standard 4K output decoded 60 video frames; the Cinematic output decoded 49 frames across the two selected ranges. Both retained HDR and matching two-second video/audio durations. Encoded channel RMS ratios were within 0.15 percent of their independent references, and the copied stereo alternative decoded to the same samples as its intermediate.
