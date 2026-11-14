import SwiftUI

struct HelpView: View {
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		NavigationStack {
			List {
				Text("Start with Quick Start to edit your first clip, or choose a topic below.")
					.listRowBackground(EditorTheme.surface)
				ForEach(HelpTopic.allCases, id: \.self) { topic in
					NavigationLink(topic.rawValue, value: topic)
						.listRowBackground(EditorTheme.surface)
				}
			}
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle("Trimatillo Help")
			.toolbar { Button("Done") { dismiss() } }
			.navigationDestination(for: HelpTopic.self) { topic in
				List {
					Text(topic.introduction).listRowBackground(EditorTheme.surface)
					ForEach(topic.sections, id: \.title) { section in
						Section {
							ForEach(section.rows.indices, id: \.self) { index in
								let step = section.numbered ? "\(index + 1). " : ""
								Text(step + section.rows[index])
							}
						} header: { Text(section.title).accessibilityAddTraits(.isHeader) }
						.listRowBackground(EditorTheme.surface)
					}
				}
				.scrollContentBackground(.hidden)
				.background(EditorTheme.workspace)
				.navigationTitle(topic.rawValue)
				.navigationBarTitleDisplayMode(.inline)
			}
		}
	}
}

private struct HelpSection {
	let title: String
	let numbered: Bool
	let rows: [String]

	init(_ title: String, numbered: Bool = false, _ rows: [String]) {
		self.title = title
		self.numbered = numbered
		self.rows = rows
	}
}

private enum HelpTopic: String, CaseIterable {
	case first = "Quick Start"
	case open = "Open a clip"
	case playback = "Playback and the playhead"
	case cuts = "Markers, trims, and joins"
	case actions = "VoiceOver actions"
	case touch = "Direct Touch Editing"
	case keys = "Keyboard commands"
	case save = "Save and export"
	case settings = "Settings and feedback"

	var introduction: String {
		switch self {
		case .first: "Trim the beginning and end of a clip, then cut a passage from the middle and save a copy."
		case .open: "Open an audio or video file in Trimatillo, or send a video from Photos to the Cutting Board."
		case .playback: "The playhead is your current position in the clip. Move it to find the moment you want to edit."
		case .cuts: "A trim shortens one end of a clip. Cutting a passage from the middle creates a join where the two remaining sections meet."
		case .actions: "Use the VoiceOver Actions rotor on Cutting Board controls to move the playhead, set markers, and make cuts."
		case .touch: "Use gestures on the Direct Touch editing surface to move through a clip and edit it."
		case .keys: "Use a connected keyboard on the primary Cutting Board to control playback, set markers, and edit."
		case .save: "Choose Export on the Cutting Board to update the original clip or save an edited copy."
		case .settings: "Open Settings from the welcome screen to change the appearance and editing preferences or send feedback."
		}
	}

	var sections: [HelpSection] {
		switch self {
		case .first:
			[HelpSection("Open a clip and trim its ends", numbered: true, [
				"Choose Trim a Clip. Choose Photo Library for a video or Files for an audio or video clip. Select your clip.",
				"Choose Play. Pause where you want the clip to begin. Use Step Back or Step Forward to move the playhead one frame at a time.",
				"Open Edit Actions and choose Trim Head to Playhead. The clip now starts at the position you chose.",
				"Play or fast forward to where you want the clip to end. Pause and use the step buttons to refine the position.",
				"Open Edit Actions and choose Trim Tail to Playhead. The clip now ends at that position."
			]), HelpSection("Cut a passage from the middle", numbered: true, [
				"Rewind to the beginning of a passage you want to remove. Pause, refine the position with the step buttons, and choose Mark In.",
				"Play to the end of the passage. Pause and choose Mark Out.",
				"Open Edit Actions and choose Delete Marked Range. The playhead lands at the join where the remaining sections meet.",
				"Choose Export, then Save as New Clip. Choose a destination and save the edited copy."
			])]
		case .open:
			[HelpSection("From the welcome screen", [
				"Trim a Clip opens the source menu. Choose Photo Library for a video or Files for an audio or video clip.",
				"Use the picker's search field to find a clip. Select it to open its Cutting Board.",
				"Choose Clip Info at the top of the board to read the clip's filename, duration, and available media details."
			]), HelpSection("From Photos", numbered: true, [
				"Select one video in Photos and choose Share.",
				"Choose Trimatillo from the apps row. Choose More to see the full list.",
				"Edit the shared video on the Video Cutting Board. Choose Export to save a copy. Choose Close to return to Photos."
			])]
		case .playback:
			[HelpSection("Move through a clip", [
				"Play starts at the playhead. Pause holds the current position.",
				"Fast Forward plays forward. Rewind plays backward. Repeat either control to advance through 1x, 1.5x, 2x, 4x, and 8x. Switching direction starts at 1x.",
				"Step Back and Step Forward move one video frame at a time. For an audio clip, each step is one thirtieth of a second.",
				"Choose Playhead to jump to a time. Enter seconds or a time separated by colons. With Frames selected, enter a frame number. Choose Jump."
			])]
		case .cuts:
			[HelpSection("Select a range", [
				"Mark In sets the start of a selection at the playhead. Mark Out sets its end. Place Out after In.",
				"Move the playhead and set the same marker again to change its position.",
				"Edit Actions includes commands to clear each marker, play the marked range, and delete the selected passage."
			]), HelpSection("Trim and review", [
				"Trim Head to Playhead removes everything before the playhead. Trim Tail to Playhead removes everything after it.",
				"Previous Edit Point and Next Edit Point move among joins, markers, and the start and end of the clip.",
				"At a join, choose Adjust Edit Point in Edit Actions. The sheet shows the end of the preceding section and the start of the following section.",
				"Step either boundary one frame at a time or enter a source time or frame number. Choose Save to apply both boundaries or Cancel to discard the adjustments.",
				"Choose Undo to reverse a marker change, trim, deletion, or saved join adjustment. Repeat to undo earlier edits."
			])]
		case .actions:
			[HelpSection("Actions rotor", [
				"Focus Step Forward or Step Back. In the Actions rotor, swipe up or down to choose a ten-step move or the next or previous edit point. Double-tap to perform the selected action.",
				"Focus Playhead and use its actions to mark, trim, delete a selection, or navigate to an edit point.",
				"Focus a set In or Out marker and use its actions to jump to that time or clear the marker.",
				"Use Magic Tap, a two-finger double-tap, to play or pause the clip."
			])]
		case .touch:
			[HelpSection("Open the editor", ["Choose Direct Touch Editor on the Cutting Board. Perform gestures on the editing surface below the heading and Close button."]),
			HelpSection("One finger", [
				"Swipe right to step forward one video frame or one thirtieth of a second in an audio clip.",
				"Swipe left to step back one video frame or one thirtieth of a second in an audio clip.",
				"Touch and hold, then drag right or left to scrub forward or backward. Audio previews play as you move. Lift your finger to leave the playhead at that position.",
				"Swipe down to mark In. Repeat at the marker to remove it, or swipe down at a new position to move it.",
				"Swipe up to mark Out. Repeat at the marker to remove it, or swipe up at a new position to move it.",
				"Double-tap at a join to open its boundaries. Choose Save or Cancel to return to Direct Touch Editing.",
				"Triple-tap to close the editor and return to the Cutting Board."
			]), HelpSection("Two fingers", [
				"Double-tap to play or pause.",
				"Swipe right to play forward. Repeat to increase the speed through 1x, 1.5x, 2x, 4x, and 8x.",
				"Swipe left to rewind. Repeat to increase the rewind speed through the same five speeds.",
				"Swipe down to delete the marked range. When material remains on both sides, the two sections meet at a join."
			]), HelpSection("Three fingers", [
				"Swipe right to move to the next join, marker, or end of the clip.",
				"Swipe left to move to the previous join, marker, or start of the clip.",
				"Swipe down to undo the last edit. Repeat to undo earlier edits. VoiceOver announces the action after each Undo."
			]), HelpSection("Four fingers", [
				"Swipe right to trim the head of the clip to the playhead.",
				"Swipe left to trim the tail of the clip to the playhead."
			])]
		case .keys:
			[HelpSection("On the primary Cutting Board", [
				"Space or K plays or pauses.",
				"J rewinds. Repeat J to increase the speed.",
				"L plays forward. Repeat L to increase the speed.",
				"Left Arrow or Right Arrow steps back or forward. Hold Shift to move ten steps.",
				"T announces the current time."
			]), HelpSection("Navigate and edit", [
				"Home or Command-Up Arrow moves to the start.",
				"End or Command-Down Arrow moves to the end.",
				"Semicolon or Command-Left Arrow moves to the previous edit point.",
				"Apostrophe or Command-Right Arrow moves to the next edit point.",
				"I marks In. Option-I clears In.",
				"O marks Out. Option-O clears Out.",
				"Delete or Forward Delete removes the marked range.",
				"Command-Left Bracket trims the head to the playhead.",
				"Command-Right Bracket trims the tail to the playhead.",
				"Return at a join opens Adjust Edit Point.",
				"Command-Z undoes the last edit."
			])]
		case .save:
			[HelpSection("Export from the Cutting Board", [
				"Save Changes to Original updates the selected Photos video or replaces a writable MOV, MP4, or M4A original in Files.",
				"Save as New Clip creates a separate clip. For video, choose Photos or Files. For audio, use the Files picker.",
				"In Files, select the folder, change the suggested filename if desired, and choose Save.",
				"When editing from the Photos Share sheet, choose Export, then Photos or Files under Save as New Clip."
			])]
		case .settings:
			[HelpSection("Preferences", [
				"Open Settings on the welcome screen. Under Appearance, choose System to follow the device, or select Light or Dark.",
				"Choose Control Color to set the color of buttons and the selected range. The shade follows the current appearance.",
				"Under Editing, choose Timecode. Standard shows hours, minutes, and seconds. Milliseconds adds three decimal places.",
				"Frames counts from zero. End is one past the last frame. For audio clips, each frame is one thirtieth of a second.",
				"Turn on Shake to Undo under Editing to undo the last edit by shaking your device. Shake to Undo must also be enabled in the device's Touch settings."
			]), HelpSection("About and support", [
				"Send App Feedback opens an email draft addressed to Marco Salsiccia. Privacy Policy opens the policy in your browser.",
				"Support Trimatillo lists available one-time tips with their App Store prices. Select an amount and confirm the purchase in the App Store sheet."
			])]
		}
	}
}
