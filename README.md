# Trimatillo

Trimatillo is a native audio and video editor for iPhone and iPad, built by Marco Salsiccia. It brings precise clip editing, multitrack projects, captions, audio description, and voice recording into a touch-friendly workspace.

Accessibility is central to the app. Edit with VoiceOver, dedicated Direct Touch gestures, an external keyboard, or the on-screen controls. Trimatillo is the iOS sister app to [Trimato](https://marconius.com/trimato/).

## Editing your way

- VoiceOver provides adjustable playheads, contextual accessibility actions, named edit points, and spoken editing confirmations.
- Full-screen Direct Touch editors provide playback, audible scrubbing, frame stepping, markers, and commands specific to the active workspace.
- External keyboard commands provide transport, marking, trimming, and navigation while the main editing workspace is open.
- On-screen controls provide preview playback, timelines, clip operations, and editing sheets in portrait and landscape.

The in-app Help covers editing concepts, task walkthroughs, keyboard commands, and individual Direct Touch gestures.

## Features

- Cutting Boards: trim heads and tails, mark In and Out, remove sections, adjust joins, and undo or redo edits. Trim Silences detects pauses for review and removal.
- Projects: arrange video and audio across tracks, choose magnetic or absolute placement, select and shift clips, and manage imported media.
- Captioner: write and time captions, finalize passages into cues, export caption files and text, or burn captions into video.
- Describer: create timed written descriptions and recorded audio descriptions, fit recordings to their marked ranges, and adjust program-audio ducking.
- Voicer: record narration while previewing the project, with optional source-audio playback.
- Mixer: adjust track and master levels, mute and solo tracks, control stereo positioning, and apply the available track audio effects.
- Generators and transitions: create text, colors, gradients, black, and silence; apply compositing, fades, and transitions.
- Import and export: choose media from Photos or Files, preview selected videos before importing, and export finished work to Photos or Files. The Share extension opens videos shared from other apps in a Cutting Board.

## Media quality

Trimatillo uses Apple's AVFoundation, Core Image, and audio frameworks. It does not depend on FFmpeg.

HDR video export preserves HDR where the device and media format support it. On iOS 26 or later, supported spatial-audio recordings can retain spatial audio in edited exports, with a stereo alternative included for playback. Project preview uses stereo. Unsupported spatial layouts or processing combinations offer an explicit stereo-export choice.

Trimatillo project documents are separate from Trimato's macOS project format.

## Build requirements

- A Mac with Xcode. The current project has been built with Xcode 27.2.
- iOS or iPadOS 18.6 or later to run the app.
- iOS or iPadOS 26 or later for the supported spatial-audio export path.
- Apple signing credentials and provisioned capabilities to run on a physical device.

The repository contains the app, Share extension, shared scheme, assets, and local StoreKit configuration. There are no third-party package dependencies to install.

## Build and run

1. Open `trimiOS.xcodeproj` in Xcode.
2. Select the `trimiOS` scheme.
3. Configure signing for both the `trimiOS` and `TrimatoShare` targets using your own development team.
4. For an independent build, use your own app and extension bundle identifiers. Replace `group.com.marconius.trimato-ios` consistently in both entitlement files and the source references, and enable that App Group for both targets.
5. Select an iPhone, iPad, or compatible simulator and build and run.

The checked-in bundle identifiers are `com.marconius.trimato-ios` and `com.marconius.trimato-ios.share`. The project directory and scheme retain the original `trimiOS` name; the displayed app name is Trimatillo.

For a command-line compilation check without signing:

```sh
xcodebuild -project trimiOS.xcodeproj -scheme trimiOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/trimatillo-build CODE_SIGNING_ALLOWED=NO build
```

An unsigned build is a compilation check, not an installable TestFlight build. Physical-device testing is needed for VoiceOver interaction, microphone routing, and media playback behavior.

## Local StoreKit testing

The shared scheme uses `StoreKit/SupportTrimatillo.storekit` for local Debug runs. It supplies the four Support Trimatillo consumable products for testing in Xcode. Distribution builds use the products configured in App Store Connect; the local catalog does not create those products.

## Project layout

- `trimiOS/`: application views, editing models, playback, rendering, recording, Help, and resources.
- `TrimatoShare/`: native Share extension.
- `trimiOS.xcodeproj/`: Xcode project and shared scheme.
- `StoreKit/`: local purchase-testing configuration.
- `Prototypes/MediaQuality/`: standalone media-quality investigations and reproduction tools. See their README for separate requirements and historical validation notes. Personal camera fixtures referenced by those notes are not included.

## Storage and privacy

Projects retain references to imported Photos and Files media. Project-owned recordings are stored with the project. Temporary working files are kept separately and can be cleared through the app's Storage settings.

Both targets include privacy manifests. Read the [privacy policy](https://marconius.com/trimato/privacy/) for the app's privacy information. Use Send App Feedback in Settings to contact the developer.

## License

Copyright (c) 2026 Marco Salsiccia. Distributed under the [MIT License](LICENSE).
