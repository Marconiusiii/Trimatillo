# Apple Feedback draft: identical FOA plus center layouts return a non-identity mix matrix

## Submission status

Prepared locally; not submitted. Attach `ChannelLayoutCheck.swift`. The minimal reproduction requires no user recordings, project files, UI, audio playback, or APAC encoding.

## Summary

AudioFormatGetProperty with kAudioFormatProperty_MatrixMixMap returns a non-identity matrix when both input and output point to the same five-channel layout: ACN channels 0 through 3 followed by Center. kAudioFormatProperty_AreChannelLayoutsEquivalent returns 1. The layout also matches the spatial writer layout returned by CNAssetSpatialAudioInfo for a four-channel camera recording.

Please confirm whether this mapping is intentional for this mixed ambisonic/discrete layout and how clients should preserve independent channel signals when requesting PCM from AVAssetReader.

## Environments reproduced

- macOS 27.2.1, build 26B131.
- iOS 26.0 Simulator, build 23A343.
- iOS 27.2 Simulator, build 24B8117.
- Xcode 27.2, build 27B52; Apple silicon host.

Physical iPhone behavior has not been checked.

## Reproduce on macOS

From the repository root:

```sh
xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 -module-cache-path /tmp/trimatillo-quality-module-cache Prototypes/MediaQuality/ChannelLayoutCheck.swift -o /tmp/trimatillo-channel-layout-check
/tmp/trimatillo-channel-layout-check
```

The program exits 1 when the identity check fails, 2 for an API error, and 0 when all matrix checks pass. An optional movie path compares the layout returned by Cinematic's spatial writer helper on supported platforms.

## Expected result

An identity matrix for identical channel layouts: each input channel maps only to the corresponding output channel with unity gain.

## Actual result

Core Audio reports equivalent layouts, returns noErr, and supplies this matrix. Rows are input channels; columns are output channels, in W, Y, Z, X, Center order.

```text
1.5 0.5 0.5 0.5 0.5
0   1   0   0   0
0   0   1   0   0
0   0   0   1   0
0   0   0   0   1
```

Stereo and four-channel ACN/SN3D control layouts return identity matrices. Same-format AVAudioConverter PCM-to-PCM conversions preserve isolated input signals, with and without an explicit channel map. Those passing controls may bypass layout conversion and do not establish a workaround for AVAssetReader.

## Related observation

In a separate macOS trace, an uncompressed five-channel LPCM file containing only a W-channel tone retains RMS 0.070710678 in W and zero elsewhere when read without conversion. Reading it through AVAssetReaderAudioMixOutput with the same requested five-channel PCM layout yields RMS 0.106066018 in W and 0.035355339 in each other channel, consistent with the matrix above. The initial problem was discovered during an APAC round trip, but APAC is not required for this observation. The attached minimal reproduction isolates the matrix query rather than the file-writing path.

## Apple configuration comparison

CNAssetSpatialAudioInfo.assetWriterInputSettings(for: .spatial) returns an equivalent five-channel layout for the tested four-channel iPhone camera recording. Querying the matrix with that returned layout produces the same result. The complete Apple sample has not been run end to end.

References: [Editing spatial audio with an audio mix](https://developer.apple.com/documentation/cinematic/editing-spatial-audio-with-an-audio-mix), [AVAudioConverter channelMap](https://developer.apple.com/documentation/avfaudio/avaudioconverter/channelmap), and [Apple Positional Audio Codec](https://developer.apple.com/av-foundation/Apple-Positional-Audio-Codec.pdf).
