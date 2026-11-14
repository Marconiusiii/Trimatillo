import SwiftUI

struct HelpView: View {
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		NavigationStack {
			List(HelpTopic.allCases, id: \.self) { topic in
				NavigationLink(topic.rawValue, value: topic)
					.listRowBackground(EditorTheme.surface)
			}
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle("Trimatillo Help")
			.toolbar { Button("Done") { dismiss() } }
			.navigationDestination(for: HelpTopic.self) { topic in
				List {
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
	case first = "Make your first cut"
	case open = "Open a clip"
	case playback = "Playback and the playhead"
	case cuts = "Markers, trims, and joins"
	case actions = "VoiceOver actions"
	case touch = "Direct Touch Editing"
	case keys = "Keyboard commands"
	case save = "Save and export"
	case settings = "Settings and feedback"

	var sections: [HelpSection] {
		switch self {
		case .first:
			[HelpSection("Remove a passage from the middle", numbered: true, [
				"Choose Trim a Clip. Select a video from Photo Library or an audio or video file from Files.",
				"Choose Play. Pause at the beginning of the passage you want to remove. The playhead is your current position in the clip.",
				"Use Step Back or Step Forward to refine the position. Choose Mark In to set the start of the passage.",
				"Move to the end of the passage. Choose Mark Out to set its end.",
				"Open Edit Actions and choose Play Marked Range to review the selection.",
				"Choose Delete Marked Range in Edit Actions. The sections before and after the passage now meet at a join.",
				"At the join, choose Play Across Edit in Edit Actions to review the cut. If you want to restore the passage, choose Undo.",
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
				"At a join, choose Adjust Edit Point in Edit Actions. Select the end of the preceding section or the start of the following section.",
				"Use the Boundary stepper for a fine adjustment, or enter a source time or frame number and choose Set Boundary. Choose Play Across Edit to review the result.",
				"Choose Undo to reverse the last cut or boundary adjustment."
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
				"Triple-tap to close the editor and return to the Cutting Board."
			]), HelpSection("Two fingers", [
				"Double-tap to play or pause.",
				"Swipe right to play forward. Repeat to increase the speed through 1x, 1.5x, 2x, 4x, and 8x.",
				"Swipe left to rewind. Repeat to increase the rewind speed through the same five speeds.",
				"Swipe down to delete the marked range. When material remains on both sides, the two sections meet at a join."
			]), HelpSection("Three fingers", [
				"Swipe right to move to the next join, marker, or end of the clip.",
				"Swipe left to move to the previous join, marker, or start of the clip."
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
				"Turn on Shake to Undo under Editing to undo a cut by shaking your device. Shake to Undo must also be enabled in the device's Touch settings."
			]), HelpSection("About and support", [
				"Send App Feedback opens an email draft addressed to Marco Salsiccia. Privacy Policy opens the policy in your browser.",
				"Support Trimatillo lists available one-time tips with their App Store prices. Select an amount and confirm the purchase in the App Store sheet."
			])]
		}
	}
}
