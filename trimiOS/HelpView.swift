import SwiftUI

struct HelpView: View {
	@Environment(\.dismiss) private var dismiss
	var body: some View {
		NavigationStack {
			List {
				Text("Start with Quick Start to edit your first clip, or choose a topic below.").editorTouchRow(alignment: .leading)
					.listRowBackground(EditorTheme.surface)
				ForEach(HelpTopic.allCases, id: \.self) { topic in
					NavigationLink(value: topic) { Text(topic.rawValue).editorTouchRow(alignment: .leading) }
						.listRowBackground(EditorTheme.surface)
				}
			}
			.editorListMargins()
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle("Trimatillo Help")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
			}
			.navigationDestination(for: HelpTopic.self) { topic in
				List {
					Text(topic.introduction).editorTouchRow(alignment: .leading).listRowBackground(EditorTheme.surface)
					ForEach(topic.sections, id: \.title) { section in
						Section {
							ForEach(section.rows.indices, id: \.self) { index in
								let step = section.numbered ? "\(index + 1). " : ""
								Text(step + section.rows[index]).editorTouchRow(alignment: .leading)
							}
						} header: { Text(section.title).editorTouchRow(alignment: .leading).accessibilityAddTraits(.isHeader) }
						.listRowBackground(EditorTheme.surface)
					}
				}
				.editorListMargins()
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
	case projects = "Multitrack projects"
	case captioner = "Captioner"
	case projectTouch = "Project Direct Touch Editor"

	var introduction: String {
		switch self {
		case .captioner: "Write timed text for dialogue, music, and sounds as you play through your project."
		case .projectTouch: "Explore the assembled project, choose a track, and find the clips that meet at each cut."
		case .projects: "Arrange video and audio clips on a shared timeline. Each placement has its own edits."
		case .first: "Trim the beginning and end of a clip, then cut a passage from the middle and save a copy."
		case .open: "Open an audio or video file in Trimatillo, or send a video from Photos to the Cutting Board."
		case .playback: "The playhead is your current position in the clip. Move it to find the moment you want to edit."
		case .cuts: "A trim shortens one end of a clip. Cutting a passage from the middle creates a join where the two remaining sections meet."
		case .actions: "Use the VoiceOver Actions rotor on Cutting Board controls to move the playhead, set markers, and make cuts."
		case .touch: "Use gestures on the Direct Touch editing surface to move through a clip and edit it."
		case .keys: "Use a connected keyboard on the primary Cutting Board to control playback, set markers, and edit."
		case .save: "Save an edited clip from the Cutting Board or export a project timeline from Project Actions."
		}
	}

	private static var projectExport: HelpSection {
		HelpSection("Export a project", numbered: true, [
			"Open Project Actions beside the project name and choose Export. Export includes the full timeline and its track volumes.",
			"For video, choose Photos to save a new video to the library, or Files to choose a folder. For an audio project, choose Files to save an M4A.",
			"In Files, keep the project name or enter a filename, then choose Save."
		])
	}

	var sections: [HelpSection] {
		switch self {
		case .captioner:
			[HelpSection("Create a caption", numbered: true, [
				"Open a project and choose the Captioner tab. The playhead stays at the same position when you switch tabs.",
				"Move to the beginning of the passage and choose Mark In. Move to its end and choose Mark Out.",
				"Choose New Caption. Enter the words in Caption Text. Play Selection repeats the marked passage while you write. Pause Selection stops playback.",
				"Use Insert Caption Description to add a music description, sound description, or lyrics. Replace the sample words with your own.",
				"Choose Save. The caption appears in the Caption Timeline and over the picture during its marked range. From Direct Touch, Save returns to the active surface and announces Caption Created."
			]), HelpSection("Review and export", numbered: true, [
				"Open a caption's menu or accessibility actions to go to its start, edit it, or delete it. To change its timing, mark a new range, edit the caption, and choose Use Marked Range.",
				"Choose Finalize Captions to divide draft passages into captions of up to two lines. Timing uses a reading speed of 160 words per minute, the project frame rate, and the space before the next caption or project end.",
				"Review any passages listed after finalizing. Shorten the text or adjust the marked range and finalize again. Undo restores the previous captions.",
				"Choose Export Captions, then SRT or WebVTT for timed captions, or Plain Text Transcript for the words in timeline order. Enter a filename and choose where to save it."
			]), HelpSection("One finger in Captioner Direct Touch", [
				"Swipe right to step forward one project frame.",
				"Swipe left to step back one project frame.",
				"Double-tap and hold the second tap, then drag to scrub using your Absolute or Relative setting.",
				"Swipe down to mark In. Repeat at the marker to remove it.",
				"Swipe up to mark Out. Repeat at the marker to remove it.",
				"Triple-tap to close Direct Touch."
			]), HelpSection("Two fingers in Captioner Direct Touch", [
				"Double-tap to play or pause.",
				"Swipe right to play forward. Repeat to increase speed.",
				"Swipe left to rewind. Repeat to increase rewind speed.",
				"Swipe down to open New Caption for the marked passage. Cancel returns to the surface without saving."
			]), HelpSection("Three fingers in Captioner Direct Touch", [
				"Swipe right to move to the next caption start, marker, or project boundary.",
				"Swipe left to move to the previous caption start, marker, or project boundary.",
				"Swipe down to undo the last project change.",
				"Swipe up to redo it."
			]), HelpSection("Captioner keyboard commands", [
				"Press I and O to mark In and Out. Option-I and Option-O clear the markers.",
				"Press Command-Shift-C to open New Caption. Return edits the focused caption or the caption at the playhead.",
				"Press Space or K to play or pause. J rewinds and L plays forward.",
				"Press Left or Right Arrow to step one frame. Hold Shift to step ten frames.",
				"Press semicolon or apostrophe for the previous or next caption point. Command-Left Arrow and Command-Right Arrow also navigate points.",
				"Home or Command-Up Arrow goes to Start. End or Command-Down Arrow goes to End. T reads the playhead.",
				"Command-Z undoes a project change. Command-Shift-Z redoes it."
			])]
		case .projectTouch:
			[HelpSection("Open Direct Touch", numbered: true, [
				"Open a project with clips on its timeline. In the Editor, choose Direct Touch Editor.",
				"The surface opens at the project playhead on the selected track. Primary Video is the initial track. With VoiceOver, the surface identifies the current track.",
				"Use Close to return to the Editor with the same playhead and track."
			]), HelpSection("One finger", [
				"Swipe right to step forward one project frame.",
				"Swipe left to step back one project frame.",
				"Double-tap and hold the second tap, then drag to scrub with project audio. Absolute scrubbing maps the full project across the surface. Relative scrubbing starts at the current playhead and spans up to ten seconds across the surface. Lift to leave the playhead there.",
				"Swipe down to mark In at the playhead. Repeat there to remove it.",
				"Swipe up to mark Out at the playhead. Repeat there to remove it.",
				"Triple-tap to close Direct Touch and return to the Editor."
			]), HelpSection("Two fingers", [
				"Double-tap to play or pause. With VoiceOver, use Magic Tap.",
				"Swipe right to play forward. Repeat to increase speed through 1x, 1.5x, 2x, 4x, and 8x.",
				"Swipe left to rewind. Repeat to increase rewind speed through the same five speeds.",
				"Swipe up to select the track above and load its edit points.",
				"Swipe down to select the track below and load its edit points. From Primary Video, one swipe down selects Primary Audio Track."
			]), HelpSection("Three fingers", [
				"Swipe right to snap to the next edit point on the selected track.",
				"Swipe left to snap to the previous edit point on the selected track.",
				"Swipe down to undo the last project edit.",
				"Swipe up to redo the last project edit you undid."
			]), HelpSection("Track navigation", [
				"Switching tracks keeps the playhead in place. Playback and scrubbing include the full project mix.",
				"At a shared cut, the edit point uses the name of the clip beginning there in either direction. Start, End, In, and Out are also stops.",
				"In the main Editor, choose Select Track from a track heading. Use the Next Edit Point and Previous Edit Point actions on the step buttons to reach the same stops."
			])]
		case .projects:
			[HelpSection("Create a project", numbered: true, [
				"Choose Create Project and enter a name.",
				"Choose Same as Media to use the size and frame rate of the first video you place on the timeline. To set your own, choose a resolution and enter a frame rate.",
				"Choose Custom to enter a width and height. With Lock Aspect Ratio on, changing one dimension adjusts the other.",
				"To set a length to aim for, turn on Use Set Project Duration and enter the Duration in Seconds. Clips can extend beyond that duration. Choose Create."
			]), HelpSection("Change project settings", numbered: true, [
				"Open Project Actions beside the project name and choose Project Settings.",
				"Edit the name, resolution, frame rate, or duration and choose Save. Resolution and frame rate apply to project playback and export."
			]), HelpSection("Arrange clips", numbered: true, [
				"Expand Project Media. Choose Import Clip, then Photo Library or Files, and select the original.",
				"In Photo Library, select a video to open Clip Preview. Play or scrub through it, then choose Use Clip to add it to Project Media. Back returns to the picker with the video selected.",
				"Choose Open Cutting Board from the source clip's menu or accessibility actions. Trim the clip or cut a marked range.",
				"Choose Append to add the marked portion after the last clip on the selected compatible track. With fewer than two markers, Append uses the entire current edit. Keep the Cutting Board open to append another passage.",
				"Primary Audio Track includes the linked sound from Primary Video. The linked clip follows the video through trims, splits, moves, and removal. Use Track Effects on Primary Audio Track to adjust its volume.",
				"Choose a timeline clip to jump to its start or end, remove it, or reopen its Cutting Board. Choose Save Changes to update that placement.",
				"Use the Undo menu to undo or redo a project change."
			]), HelpSection("Project playback and navigation", [
				"Choose Direct Touch Editor to use gestures on the project. The Project Direct Touch Editor Help topic lists each gesture.",
				"Choose Play to preview the timeline. Choose Pause to stop at the current position.",
				"Choose Rewind or Fast Forward to play in that direction. Repeat to select 1x, 1.5x, 2x, 4x, or 8x. Changing direction starts at 1x.",
				"Drag across Playhead to preview the project from start to end. Lift to leave the playhead there.",
				"With VoiceOver, focus Playhead, double-tap and hold until you hear three rising tones, then drag left or right. After lifting your finger, use Magic Tap to play or pause at the playhead. Swipe up or down to move five seconds forward or back. For projects shorter than 50 seconds, each swipe moves one tenth of the timeline.",
				"When scrub audio is unavailable, VoiceOver reads the timecode after a brief pause in your drag or when you lift.",
				"Choose Jump to Time to enter a time or frame in your selected timecode format.",
				"Choose Step Back or Step Forward to move one project frame. In the Actions rotor, choose the 10-frame action or the previous or next edit point. Double-tap to use that action again while the button stays focused.",
				"Edit points include clip boundaries on the active track, project markers, Start, and End.",
				"Choose Mark In or Mark Out to set a marker. Its actions let you go to it or clear it. Pressing the marker button at its marked position also clears it."
			]), HelpSection("Name a project clip", numbered: true, [
				"Expand Project Media. Open the imported clip's menu or actions and choose Rename Clip.",
				"Enter a Clip Name and choose Save. The project uses that name for the source and its timeline clips.",
				"Append a second passage from the same source. A clip named Interview becomes Interview A on the timeline, and the new passage is Interview B. Each clip keeps its letter when moved."
			]), HelpSection("Full Screen Preview", numbered: true, [
				"Pause or step to the picture you want to inspect. With VoiceOver, focus Video frame to explore the image.",
				"Choose Full Screen Preview beside the playback controls to open the project at the playhead.",
				"Use Play or Pause, or use Magic Tap. Drag the playback slider to move to another time.",
				"Choose Close to return to editing with the playhead at the preview position."
			]), HelpSection("Add at Playhead", numbered: true, [
				"Set the project playhead to the destination time before opening the Cutting Board. Mark the source passage and choose Add at Playhead.",
				"Choose New Track and enter a name, or choose an existing destination track for Overwrite or Split.",
				"Overwrite replaces the covered time. The original resumes after the added clip. Split inserts the selection and moves later material on that track forward.",
				"When a named video track first receives a clip with audio included, its linked audio track appears. The sound follows the video through edits. Adjust its volume in Track Effects.",
				"For a video cutaway, choose New Track. Turn off Include Clip Audio to keep the underlying sound. Choose Add."
			]), HelpSection("Track actions and clip movement", numbered: true, [
				"Use the track headings to navigate. Open a track menu to select the track or open Track Effects. Set Volume and choose Save.",
				"On a clip, choose Mark for Editing to include it in a group. Choose Start Drag on a marked clip to pick up the group. Choose Add to Drag on another compatible clip to include it. The drag announcement gives the clip name for one clip and the count for a group.",
				"On the destination clip, choose Drop Before or Drop After followed by the destination clip name. The confirmation identifies where the clip or group landed. On an empty compatible track, choose Drop on Track. Cancel Drag abandons the move. After a drop, choose Undo or shake the device to restore the previous order. A group move takes one undo.",
				"You can also drag a clip onto the leading or trailing half of another clip to place it before or after that clip."
			]), Self.projectExport, HelpSection("Project keyboard commands", [
				"On a project Cutting Board, E appends, Option-W opens Add at Playhead, W inserts and splits, and D overwrites. Command-U saves changes to an existing placement.",
				"On the project timeline, Space or K plays or pauses. J rewinds and L plays forward. Left and Right Arrow step one frame, or ten with Shift. T reads the playhead. Home and End jump to the project boundaries.",
				"I and O mark In and Out. Hold Option to clear a marker. Semicolon and Apostrophe move to the previous and next boundary or marker. Command-Left and Command-Right do the same.",
				"Command-Option-Up and Command-Option-Down select a track. C opens its clip at or after the playhead. Return opens the focused clip. Command-B splits at the playhead. Command-[ and Command-] trim the start and end.",
				"S marks or unmarks a clip. With a clip focused, Space picks it up. Shift-S adds another clip to the drag. Use Left or Right Arrow to choose a destination and press Space to drop. Escape cancels. Command-Option-V drops after the focused clip.",
				"Command-Option-Left and Command-Option-Right move a clip or marked group earlier or later. Delete removes the selected clips. Command-Z undoes and Command-Shift-Z redoes."
			]), HelpSection("Reopen and reconnect", numbered: true, [
				"Choose Close, then My Projects and the project name. Choose Cancel during timeline preparation to return to the main screen. Trimatillo saves each project change as you work.",
				"If a saved project cannot be read, restore its project file from backup. Choose another project in My Projects to keep editing.",
				"If a source is unavailable, open Project Media, choose the source, and reconnect it from Files or Photos. Choose the original to restore access for every placement.",
				"When moving to a new device, restore Trimatillo's project data from your device backup and make the original media available through Files or Photos."
			]), HelpSection("Delete a project", numbered: true, [
				"Open My Projects. On the project you want to remove, choose Delete Project from its context menu or accessibility actions.",
				"Check the project name in the alert, then choose Delete Project. Choose Cancel to keep the project."
			])]
		case .first:
			[HelpSection("Open a clip and trim its ends", numbered: true, [
				"Choose Trim a Clip. Choose Photo Library for a video or Files for an audio or video clip. Select your clip. For a Photo Library video, choose Use Clip in Clip Preview to open the Cutting Board.",
				"Choose Play. Pause where you want the clip to begin. Use Step Back or Step Forward to fine-tune the starting position.",
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
				"Use the picker's search field to find a clip. In Photo Library, select a video to open Clip Preview. When the preview is ready, use Play, Magic Tap, or the playback slider to check the video. VoiceOver announces \"Clip preview ready\" when playback becomes available.",
				"Choose Use Clip to open the Cutting Board, or Back to return to the picker with that video selected. Choose Cancel in the picker to return to Trim a Clip.",
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
				"Step Back and Step Forward move to the previous or next frame in a video. In a clip with a variable frame rate, the time between steps can change as you move through it.",
				"At 24 frames per second, one frame lasts about 41.7 milliseconds. At 60 it lasts about 16.7 milliseconds, and at 120 it lasts about 8.3 milliseconds.",
				"In an audio-only clip, one step moves one thirtieth of a second. Ten steps move one third of a second.",
				"Choose Playhead, enter seconds or a time separated by colons, then choose Jump.",
				"For frame entry, choose Frames under Timecode in Settings before opening the clip. On the Cutting Board, choose Playhead, enter a frame number, and choose Jump. Counting starts at zero."
			]), HelpSection("Full Screen Preview", numbered: true, [
				"Choose Full Screen Preview beside the playback controls to open the edited clip at the playhead.",
				"Use Play or Pause, or use Magic Tap. Drag the playback slider to move to another time.",
				"Choose Close to return to editing with the playhead at the preview position."
			])]
		case .cuts:
			[HelpSection("Select a range", [
				"Mark In sets the start of a selection at the playhead. Mark Out sets its end. Place Out after In. A bar along the bottom of the preview shows the range with a tick at each end.",
				"Move the playhead and set the same marker again to change its position.",
				"Edit Actions includes commands to clear each marker, play the marked range, and delete the selected passage."
			]), HelpSection("Trim and review", [
				"Trim Head to Playhead removes everything before the playhead. Trim Tail to Playhead removes everything after it.",
				"Previous Edit Point and Next Edit Point move among joins, markers, and the start and end of the clip.",
				"At a join, choose Adjust Edit Point in Edit Actions. Outgoing Out Point sets where the outgoing clip ends. Incoming In Point sets where the incoming clip begins.",
				"With VoiceOver focused on either point, swipe up to advance one source frame or down to go back one. In an audio clip, each swipe moves one thirtieth of a second. The Out Point previews sound before the cut and the In Point previews sound after it.",
				"Activate either point to type a source time or frame number. Choose Done to update the point or Cancel to keep its previous value. On the Edit Point sheet, choose Save to apply the join or Cancel to discard your adjustments.",
				"Choose Undo to reverse a marker change, trim, deletion, or saved join adjustment. Repeat to undo earlier edits. To reapply an edit, choose Redo in Edit Actions.",
				"To undo by shaking your device, turn on Shake to Undo in Trimatillo Settings and in the device's Accessibility settings under Touch."
			]), HelpSection("Trim silences", numbered: true, [
				"Open Edit Actions and choose Trim Silences. With In and Out set, leave Only Between In and Out on to search that passage.",
				"Adjust the Silence threshold slider. A higher value includes louder sounds. Minimum silence sets the shortest pause to find. Retained silence sets how much of each pause to keep, divided between its two ends.",
				"Choose Find Pauses. If No Pauses Found appears, choose OK to return to Find Pauses. Adjust the settings to search again.",
				"For each pause, choose its numbered preview button to play that pause with up to half a second of the original clip on either side. Close the preview to return to that button. Move the pause's Start or End slider to change the cut, or turn off Remove Pause to keep that passage.",
				"Time to remove shows the total duration of the selected cuts. Choose Preview Trimmed Clip to open Trimmed Silence Preview and play those cuts together. Choose Close to return to Preview Trimmed Clip.",
				"Choose Apply Cuts. Undo restores all the pauses from this operation in one step."
			])]
		case .actions:
			[HelpSection("Actions rotor", [
				"Focus Step Forward or Step Back. In the Actions rotor, swipe up or down to choose a ten-step move or the next or previous edit point. Double-tap to perform the selected action.",
				"Focus Undo, select Redo in the Actions rotor, and double-tap to reapply the last edit you undid. Making a new edit clears the remaining redo history.",
				"Focus Playhead and use its actions to mark, trim, delete a selection, or navigate to an edit point.",
				"Focus a set In or Out marker and use its actions to jump to that time or clear the marker.",
				"Use Magic Tap, a two-finger double-tap, to play or pause the clip."
			])]
		case .touch:
			[HelpSection("Open the editor", ["Choose Direct Touch Editor on the Cutting Board. Perform gestures on the editing surface below the heading and Close button."]),
			HelpSection("One finger", [
				"Swipe right to step forward.",
				"Swipe left to step back.",
				"Double-tap and hold the second tap to scrub. Drag left or right to preview the clip, then lift to leave the playhead there.",
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
				"Swipe down to undo the last edit. Repeat to undo earlier edits. VoiceOver announces the action after each Undo.",
				"Swipe up to redo the last edit you undid. Repeat to reapply edits in order."
			]), HelpSection("Four fingers", [
				"Swipe right to trim the head of the clip to the playhead.",
				"Swipe left to trim the tail of the clip to the playhead.",
				"Swipe down in a project Cutting Board to append the marked portion to the timeline.",
				"Swipe up in a project Cutting Board to choose Append to Track, Add to New Track, Overwrite at Playhead, or Insert and Split at Playhead. Choose Cancel to return to Direct Touch."
			]), HelpSection("Direct Touch Scrubbing", [
				"In Settings, choose Direct Touch Scrubbing under Editing.",
				"Absolute is the default. The left edge is the start of the edited clip, the center is halfway through, and the right edge is the end. The playhead jumps to your finger as soon as the hold begins.",
				"Relative starts each drag at the current playhead. On clips ten seconds or longer, dragging from the center to either edge moves five seconds. On shorter clips, the full width spans the clip's duration.",
				"To continue in Relative mode, lift and start another double-tap and hold. You can start anywhere on the surface, including back at the center."
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
			[Self.projectExport, HelpSection("Export from the Cutting Board", [
				"Save Changes to Original updates the selected Photos video or replaces a writable MOV, MP4, or M4A original in Files.",
				"Save as New Clip creates a separate clip. For video, choose Photos or Files. For audio, use the Files picker.",
				"In Files, select the folder, change the suggested filename if desired, and choose Save.",
				"When editing from the Photos Share sheet, choose Export, then Photos or Files under Save as New Clip."
			])]
		}
	}
}
