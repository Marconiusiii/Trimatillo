# Media-quality prototype

This command-line prototype exercises native AVFoundation and Core Image APIs outside the Trimatillo app target. It does not change the app, its project documents, its deployment target, or the selected Xcode device.

## Run

Requires an Apple silicon Mac running macOS 26 or later and Xcode with the corresponding SDK. Run these commands from the repository root. The output directory must not already exist.

```sh
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 -module-cache-path /tmp/trimatillo-quality-module-cache Prototypes/MediaQuality/Main.swift Prototypes/MediaQuality/HDR.swift Prototypes/MediaQuality/Spatial.swift -o /tmp/trimatillo-media-quality
/tmp/trimatillo-media-quality /tmp/trimatillo-quality-results
```

The encoder requires access to native media services. A sandbox that blocks those services can report that the HEVC encoder is unavailable.

An optional second argument supplies a real iPhone Spatial Audio recording. The original is opened read-only. The camera probe renders a 1.5-second HDR cut/dissolve with title and caption at the source landscape resolution, then separately renders up to three seconds of audio with half volume and a synthetic narration signal. It preserves the source spatial layout and its associated stereo fallback in a new audio-only movie.

```sh
/tmp/trimatillo-media-quality /tmp/trimatillo-camera-results /absolute/path/to/recording.mov
```

The camera path has been exercised with the two supplied iPhone recordings. It accepts the observed four-channel ambisonic layout and five-channel ambisonic-plus-center layout, and rejects unrecognized layouts. The HDR probe currently requires unrotated landscape video. It does not preserve editable Camera Audio Mix analysis metadata. See RESULTS.md for the exact validation boundaries.

## What the synthetic checks establish

### HDR

The source is a two-second, 320 by 180, 24 fps, 10-bit HEVC fixture tagged BT.2020/HLG. Linear-light patches have levels 0.18, 2, and 4. A custom compositor cuts the source into two overlapping segments, dissolves between them, and overlays an SDR generated title and caption.

The output is decoded and checked for:

- Correct duration and frame count.
- HLG transfer function and BT.2020 primaries.
- Highlights remaining above SDR white throughout the output.
- An intermediate dissolve value consistent with linear-light blending.
- Visible title and caption pixels at approximately SDR white, allowing compression overshoot.

The native reader and writer use 10-bit YUV buffers; Core Image processes in extended linear BT.2020. This is a proof of the rendering approach, not a modification of the production compositor.

### Spatial audio

The fixture represents a stationary front-facing first-order ambisonic signal in ACN/SN3D order, W/Y/Z/X. It uses a 440 Hz tone at 48 kHz. The writer creates four-channel APAC and a stereo AAC fallback, with an alternate-track group and explicit fallback association.

The probe decodes a one-second section starting at half a second, reduces all channels to half amplitude, and exports it. A second variant adds an 880 Hz signal representing centered narration to both spatial and stereo representations. It also copies the first second of the rendered HDR video into that output without re-encoding it.

The outputs are checked for:

- Correct duration, APAC codec, channel count, and ambisonic layout.
- Spatial and stereo membership in the same alternate-track group.
- The spatial track's fallback association to the stereo track.
- Decoded overall and per-channel signal levels within lossy-encoding tolerances.
- A non-silent, decodable stereo fallback.
- Retained HDR properties, frame count, and highlights in the combined movie.

No listening test is performed, and no sound is played by this tool. The stereo fixture is explicitly authored for this simple signal; this is not a general ambisonic-to-stereo renderer. Camera audio processing preserves each source channel and its declared layout directly. It does not invoke Apple's foreground/background Audio Mix processing.

## Limits

These short fixtures are intentionally held in memory. Production processing must stream bounded buffers. They do not measure battery use, sustained performance, thermal behavior, 4K output, or long projects.

The prototype does not establish preservation of arbitrary Dolby Vision metadata, Camera Audio Mix analysis metadata, Dolby Atmos, all surround layouts, or spatial behavior on physical devices. The compositor requests generation of fresh HDR display metadata for edited frames; it does not claim to retain original Dolby Vision metadata. The narration probe verifies encoded signal handling, not spoken-voice quality or perceived position.

Production integration still needs channel-aware volume, panning, effects, ducking, transitions, and narration mixing, together with source-track selection and metadata handling. Its design must not reuse left/right stereo matrices for ambisonic channels. APAC encoding requires iOS 26 or later and must be accounted for alongside Trimatillo's existing iOS 18.6 minimum.

## References

- [Apple HDR editing guidance](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)
- [Editing Spatial Audio with an audio mix](https://developer.apple.com/documentation/cinematic/editing-spatial-audio-with-an-audio-mix)
- [Understanding alternate audio track groups](https://developer.apple.com/documentation/technotes/tn3177-understanding-alternate-audio-track-groups-in-movie-files)

Apple's spatial sample was inspected in temporary storage. Its source and bundled Git data were not extracted into this repository.
