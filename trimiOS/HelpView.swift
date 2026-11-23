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
	case describer = "Describer"
	case voicer = "Voicer"
	case mixer = "Mixer"
	case generators = "Generators and compositing"
	case projectTouch = "Project Direct Touch Editor"

	var introduction: String {
		switch self {
		case .generators: "Create text, backgrounds, and silence, then arrange visual layers over your video."
		case .mixer: "Adjust the volume and stereo position of each track while listening to the project."
		case .voicer: "Record a voice-over take and place it at a chosen time in your project."
		case .describer: "Describe what happens in a passage with a timed transcript, a spoken recording, or both."
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
			"To make captions part of the picture, turn on Burn In Open Captions. The movie uses the captions and timing in the Caption Timeline.",
			"For video, choose Photos to save a new video to the library, or Files to choose a folder. For an audio project, choose Files to save an M4A.",
			"In Files, keep the project name or enter a filename, then choose Save. A chime confirms the project was exported to Photos or Files. VoiceOver announces Export complete."
		])
	}

	var sections: [HelpSection] {
		switch self {
		case .generators:
			[HelpSection("Create a clip", numbered: true, [
				"In Editor, choose the destination track with Timeline Chooser. Choose Add Generator, use the track's Add Generator action, or press G.",
				"On a video track, choose Text, Black, Solid Color, or Gradient. On an audio track, create Silence. Set Duration in Seconds; a marked In and Out range supplies the initial duration.",
				"For text, choose a preset and enter Text. Title and Subheading adds a second line; Name and Role adds a role below the name. Subtitle creates a text clip that appears over the video.",
				"Open Typography to change font, bold, text size, or line spacing. Appearance controls text and background colors, transparency, outline, shadow, and the text panel. Layout controls text position, safe margin, and width.",
				"Choose Append, Insert at Playhead, Overwrite at Playhead, or New Track at Playhead. Enter a track name when creating a new track. Choose Preview to play the result in the project, then Close to return and Add to create the clip."
			]), HelpSection("Edit a generated clip", numbered: true, [
				"Open a generated timeline clip's menu or accessibility actions and choose Edit Generator. Change its text or appearance, then Save. Other copies retain their own settings.",
				"Edit Generator in Project Media changes the source settings for copies that have not received their own generator edits. Use the Cutting Board to trim a generated clip and Save Changes to update it on the timeline."
			]), HelpSection("Layer clips", numbered: true, [
				"Place the title or other visual clip on a video track above the footage. Open the timeline clip in the Cutting Board, then choose Edit Actions and Compositing.",
				"Opacity controls how much of the clip is visible. Blend Mode combines its colors with the tracks below. Scale changes the clip size; Position and the horizontal and vertical offsets place it within the project frame.",
				"Choose Preview to play the project with these settings. Close returns to the controls. Save applies the settings to this timeline clip. Reset Compositing restores full opacity, normal blending, original size, and centered position.",
				"For transparent titles, enable Transparent Background in Edit Generator. Background colors and text panels remain editable there. Project export includes the generated clips and their compositing settings."
			])]
		case .mixer:
			[HelpSection("Mix voice and project audio", numbered: true, [
				"Open Mixer or press Command-Shift-M. Set In and Out around a passage with voice and background sound. Turn on Loop and press Play to repeat it.",
				"Choose a track in Timeline Chooser. Command-Option-Up Arrow and Command-Option-Down Arrow cycle through the tracks.",
				"Turn on Mute to silence the selected track in the project and its export. Turn on Solo to listen to the selected track alone, or solo several tracks to hear them together. Leaving Mixer clears Solo.",
				"To match clips recorded at different levels, open Track Effects from the audio track heading in Editor. Choose Effects, then Match Loudness. Use Mixer Volume to adjust the matched track as a whole.",
				"Adjust Volume while listening. Zero dB plays the track at its original level. Raise Volume up to 12 dB to bring up quieter sound.",
				"Adjust Pan to move the track left or right. Stereo Balance lowers the opposite channel. Center gives both channels their original position and balance.",
				"Adjust Stereo Width to narrow or widen the sound. Choose Mono to bring both sides together or Original for the recorded width.",
				"Use Channel Routing to keep both channels, send the left or right input to both sides, or swap left and right.",
				"Adjust Master Volume to change the level of the whole mix. Reset Track Mix restores the original volume, stereo position, width, and routing, and clears Mute and Solo. Choose Undo to reverse a saved mix adjustment.",
				"Choose Export in Project Actions to render the saved levels, stereo settings, mute settings, and description ducking. Solo applies only while listening in Mixer."
			])]
		case .voicer:
			[HelpSection("Record a take", numbered: true, [
				"Open Voicer and move the project playhead to the start of the narration.",
				"Choose Record Voice Over, or press Command-Shift-V from the project. To use a different insertion time, change Insert at Time or Insert at Frame.",
				"Enter a Clip Name. Leave Source Audio Playback on to hear the project during the take, or turn it off to record with the project audio muted. Choose Record and speak after the rising cue. Choose Stop Recording when you finish.",
				"Choose Play Take to hear your recording alone, or Play with Primary Audio to hear it at the insertion time. Choose Record again to make another take. Recover Take opens a saved draft.",
				"Choose Add to Project. The take appears on a Voice Over audio track. Takes that overlap use separate tracks. Project export includes the recording.",
				"Open the take in the Voice Over timeline. Choose Open Cutting Board, trim the take, then choose Save Changes. Choose Move to Time to change its start.",
				"Remove from Track removes this placement. Delete from Project removes the recording and all timeline clips that use it. Choose Undo to restore the edit."
			]), HelpSection("One finger in Voicer Direct Touch", [
				"Swipe right to step forward one project frame.",
				"Swipe left to step back one project frame.",
				"Double-tap and hold, then drag to scrub through the project.",
				"Swipe down to mark In. Repeat at the marker to remove it.",
				"Swipe up to mark Out. Repeat at the marker to remove it.",
				"Triple-tap to close Direct Touch."
			]), HelpSection("Two fingers in Voicer Direct Touch", [
				"Double-tap to play or pause. With VoiceOver, use Magic Tap.",
				"Swipe right to play forward. Repeat to increase speed.",
				"Swipe left to rewind. Repeat to increase speed.",
				"Swipe down to open Record Voice Over at the playhead. After Add to Project or Cancel, VoiceOver announces In Direct Touch Editor when the surface is ready."
			]), HelpSection("Three fingers in Voicer Direct Touch", [
				"Tap once to hear the current playhead position.",
				"Swipe right to go to the next voice-over edit point or project marker.",
				"Swipe left to go to the previous voice-over edit point or project marker.",
				"Swipe down to undo a project edit.",
				"Swipe up to redo it."
			])]
		case .describer:
			[HelpSection("Describe a passage", numbered: true, [
				"Open Describer in a project. Mark In at the beginning of the passage and Out at its end.",
				"For a written entry, select Descriptive Transcript in Timeline Chooser. Choose New Description or press Command-Shift-D. In Written Description, enter Description Text and choose Save.",
				"Choose Play In to Out to repeat the passage. Choose Stop Preview when you are finished.",
				"For narration, select Audio Description in Timeline Chooser and choose New Description. In Audio Description, you can change Recording Name. Turn off Source Audio Playback to mute the passage during recording. Voicer and Audio Description share this setting. Choose Record. Allow microphone access when prompted. Speak after the rising cue. The project plays to Out. Choose Stop Recording when you finish speaking.",
				"Choose Play Take to hear the original recording. Speed Up to Fit trims silence from the end of the take. Your voice plays at its recorded speed if it fits before Out. Longer narration speeds up and keeps its pitch. Choose Trim at Out to play the original take up to Out. Play with Primary Audio previews the result against the passage.",
				"Choose Save to add the recording to Audio Description. When a description sheet closes back to Direct Touch, VoiceOver announces In Direct Touch Editor. To resume a recorded draft, mark the passage, open Audio Description, and choose Recover Take."
			]), HelpSection("Review and export", numbered: true, [
				"Adjust the Timeline Chooser wheel to Descriptive Transcript or Audio Description. The entries under the timeline heading change as you turn the wheel. The playhead and markers stay in place.",
				"Open an entry's menu or accessibility actions to go to its start, edit, or delete it. Return edits a focused entry with a keyboard. Mark a new range and choose Use Marked Range while editing to change its timing. Undo restores a deleted entry.",
				"A transcript spans the marked range. A shorter recording ends when the take ends. Entries on the two timelines can be changed independently.",
				"On the Audio Description timeline, choose Audio Ducking to lower project audio during descriptions. Set the amount and fade, then choose Save. Project playback and movie export use the same mix.",
				"On the Descriptive Transcript timeline, choose Export Description Transcript to share the timed text as a WebVTT file. To export the movie with narration, choose Project Actions, then Export.",
				"Open Audio in the main Settings sheet to select a microphone or audio output. Same as System follows the current microphone route."
			]), HelpSection("One finger in Describer Direct Touch", [
				"Swipe right to advance one frame.",
				"Swipe left to go back one frame.",
				"Double-tap and hold, then drag to scrub.",
				"Swipe down to mark In. Repeat at the same time to remove In.",
				"Swipe up to mark Out. Repeat at the same time to remove Out.",
				"Double-tap on an entry boundary to edit it. Double-tap elsewhere to create a description for the marked passage.",
				"Triple-tap to return to Describer."
			]), HelpSection("Two fingers in Describer Direct Touch", [
				"Double-tap to play or pause.",
				"Swipe right to play forward. Repeat to increase speed.",
				"Swipe left to rewind. Repeat to increase speed.",
				"Swipe up to open Written Description for the marked passage. Description Text is ready to type.",
				"Swipe down to open Audio Description for the marked passage. Choose Record to start a take."
			]), HelpSection("Three fingers in Describer Direct Touch", [
				"Tap once to hear the current playhead position.",
				"Swipe right to reach the next entry boundary or project End.",
				"Swipe left to reach the previous entry boundary or project Start.",
				"Swipe down to undo.",
				"Swipe up to redo."
			])]
		case .captioner:
			[HelpSection("Create a caption", numbered: true, [
				"Open a project and choose the Captioner tab. The playhead stays at the same position when you switch tabs.",
				"Move to the beginning of the passage and choose Mark In. Move to its end and choose Mark Out.",
				"Choose New Caption and start typing. Choose Dismiss Keyboard to finish typing and keep the caption open. Play Selection repeats the marked passage while you write. Pause Selection stops playback.",
				"Use Insert Caption Description to add a music description, sound description, or lyrics. Replace the sample words with your own.",
				"Choose Save. The caption appears in the Caption Timeline and over the picture during its marked range. When you create a caption from Direct Touch, VoiceOver announces Caption Created, then In Direct Touch Editor. Cancel returns to the surface and announces In Direct Touch Editor."
			]), HelpSection("Review and export", numbered: true, [
				"Open a caption's menu or accessibility actions to go to its start, edit it, or delete it. To change its timing, mark a new range, edit the caption, and choose Use Marked Range.",
				"Choose Finalize Captions to divide draft passages into captions of up to two lines. Timing uses a reading speed of 160 words per minute, the project frame rate, and the space before the next caption or project end.",
				"If all passages finalize, VoiceOver announces the result. If any need review, the review heading gives the count. Move to each passage to read the reason. Shorten the text or adjust the marked range and finalize again. Undo restores the previous captions.",
				"Choose Export Captions, then SRT or WebVTT for timed captions, or Plain Text Transcript for the words in timeline order. Choose an app in the share sheet or choose Save to Files."
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
				"Tap once to hear the current playhead position.",
				"Swipe right to move to the next caption start, marker, or project boundary.",
				"Swipe left to move to the previous caption start, marker, or project boundary.",
				"Swipe down to undo the last project change.",
				"Swipe up to redo it."
			]), HelpSection("Captioner keyboard commands", [
				"Press I and O to mark In and Out without stopping playback. Option-I and Option-O clear the markers.",
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
				"Tap once to hear the current playhead position.",
				"Swipe right to snap to the next edit point on the selected track.",
				"Swipe left to snap to the previous edit point on the selected track.",
				"Swipe down to undo the last project edit.",
				"Swipe up to redo the last project edit you undid."
			]), HelpSection("Four fingers", [
				"Swipe down at an edit point to apply Cross Dissolve on a video track or Cross Fade on an audio track. The first duration is one second. Later uses follow the duration last saved for Cross Dissolve or Cross Fade.",
				"Swipe up to open Quick Fade. Set Fade In and Fade Out and their durations, preview the result, then choose Save.",
				"Tap once to open Transitions for the clip or edit point on the selected track. Choose a transition, set its duration, preview it, then choose Save. Cancel returns without applying the changes."
			]), HelpSection("Track navigation", [
				"Switching tracks keeps the playhead in place. Playback and scrubbing include the full project mix.",
				"At a shared cut, the edit point uses the name of the clip beginning there in either direction. Start, End, In, and Out are also stops.",
				"In the main Editor, adjust Timeline Chooser to select the active track. The Editor shows the selected track and its edit points on the playhead slider. Use the Next Edit Point and Previous Edit Point actions on the step buttons to reach the same stops."
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
			]), HelpSection("Preview and apply track effects", numbered: true, [
				"Open the track heading in Editor and choose Track Effects. Move the playhead to the passage you want to hear and choose Play. Magic Tap also plays or pauses the preview.",
				"On an audio track, open Effects and choose Match Loudness to bring clips recorded at different volumes to a common level. On Primary Audio Track, this includes sound from video clips.",
				"Set Playback Level to choose how loud the clips should sound. Higher values are louder. Peak Limit sets the highest peak allowed by Match Loudness. A clip with a strong peak may stay quieter.",
				"Choose Even Out Volume from Effects to soften louder passages within clips. Start Smoothing Above sets the level where smoothing begins. A higher Smoothing Strength reduces louder passages more.",
				"During playback, turn Bypass Effects on to hear the original levels and off to hear the effects. Adjust Volume to change the level of the whole track.",
				"Use the Remove button under an effect to take it off the track. Save applies your changes to existing clips and clips added later. Cancel discards your changes. In Editor, choose Undo to reverse a save."
			]), HelpSection("Add and preview transitions", numbered: true, [
				"Select a timeline clip, or move the playhead to the cut where two clips meet. Open Transitions from the clip menu or its accessibility actions. The track heading also offers Transitions, Quick Fade, and Cross Dissolve or Cross Fade.",
				"At a cut, choose a transition and its Duration in Seconds. Video choices include Cross Dissolve, Fade Out/Fade In through black, Fade Through White, directional wipes, slides, covers and reveals, circles, and Pixel Dissolve. Audio offers Cross Fade and Fade Out/Fade In.",
				"Use Easing with a wipe, slide, cover, reveal, or circle to change its movement over time. Linear keeps a steady pace. Ease In slows toward the incoming picture, Ease Out accelerates away from the outgoing picture, and Easy Ease smooths both ends.",
				"Turn on Crossfade Audio to include linked video sound. Choose Linear or Equal Power for the audio curve. Equal Power maintains more volume around the middle of a crossfade.",
				"Choose Play or use Magic Tap to preview. Playback loops around the transition. Adjust the settings to prepare an updated preview. Use the playhead to choose another position.",
				"Choose Save to apply the transition, or Cancel to discard the changes. Reopen Transitions at the same cut to adjust it or choose Remove Transition and Save. Undo and Redo restore saved transition changes.",
				"Choose Quick Fade to apply Fade In, Fade Out, or both, with separate durations. At a shared cut, Fade Out affects the outgoing clip and Fade In affects the incoming clip. From a selected clip's menu, both apply to that clip.",
				"Cross transitions use extra source material on both sides of the cut. If there is too little available, shorten the transition or adjust the cut in the Cutting Board. The project duration stays the same.",
				"Transitions follow their clips. Removing a clip, separating a joined pair, or shortening a clip beyond its transition removes the affected transition. Undo restores it.",
				"In Editor, press X for a quick crossfade, F for Quick Fade, or Command-Shift-T for Transitions. Commands use the focused clip when one is selected, otherwise the playhead on the selected track."
			]), HelpSection("Project playback and navigation", [
				"Choose Direct Touch Editor to use gestures on the project. The Project Direct Touch Editor Help topic lists each gesture.",
				"Choose Play to preview the timeline. Choose Pause to stop at the current position.",
				"Choose Rewind or Fast Forward to play in that direction. Repeat to select 1x, 1.5x, 2x, 4x, or 8x. Changing direction starts at 1x.",
				"Use the Go to Start accessibility action on Rewind or Go to End on Fast Forward to move to that boundary of the project.",
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
				"Choose a track with Timeline Chooser. Open its heading for Track Actions, including Track Effects and the Magnetic setting.",
				"The primary tracks start with Magnetic on. Removing or trimming a clip shifts later clips on its track. New tracks use absolute placement. Turn Magnetic off to keep neighboring clips at their project times. Turning it on asks for confirmation when clips need to move together.",
				"Choose Move to Playhead on a clip to place its start at the playhead. On a magnetic track, a move into another clip splits it and preserves the rest. A move beyond the last clip appends it.",
				"Choose Remove from Track to remove one placement and keep its source in Project Media. To remove the source and every placement made from it, choose Delete from Project in the clip menu or accessibility actions, then confirm. Undo restores the source and its timeline clips together.",
				"Choose Move to Time, enter Start Time or Start Frame, then choose Move. Absolute placement needs open time for the clip. To leave a gap on a populated magnetic track, turn Magnetic off first.",
				"Choose Move to New Track, enter Track Name, and choose Move to keep the clip at its current time on a new track. Moving linked audio moves its video with it.",
				"On a clip, choose Mark for Editing to include it in a group. Choose Start Drag on a marked clip to pick up the group. Choose Add to Drag on another compatible clip to include it. The drag announcement gives the clip name for one clip and the count for a group.",
				"Choose the destination track with Timeline Chooser. On the destination clip, choose Drop Before or Drop After followed by the destination clip name. The confirmation identifies where the clip or group landed. On an empty compatible track, choose Drop on Track. Cancel Drag abandons the move. After a drop, choose Undo or shake the device to restore the previous order. A group move takes one undo.",
				"You can also drag a clip onto the leading or trailing half of another clip to place it before or after that clip."
			]), Self.projectExport, HelpSection("Project keyboard commands", [
				"On a project Cutting Board, E appends, Option-W opens Add at Playhead, W inserts and splits, and D overwrites. Command-U saves changes to an existing placement.",
				"In Editor, X applies a quick crossfade, F opens Quick Fade, and Command-T or Command-Shift-T opens Transitions.",
				"On the project timeline, Space or K plays or pauses, including when a clip is focused. K also stops rewind or fast forward. J rewinds and L plays forward. Left and Right Arrow step one frame, or ten with Shift. T reads the playhead. Home and End jump to the project boundaries.",
				"I and O mark In and Out at the current playhead without stopping playback. Hold Option to clear a marker. Semicolon and Apostrophe move to the previous and next boundary or marker. Command-Left and Command-Right do the same.",
				"Command-Option-Up and Command-Option-Down select a track. C opens its clip at or after the playhead. Return opens the focused clip. Command-B splits at the playhead. Command-[ and Command-] trim the start and end.",
				"S marks or unmarks a clip. With a clip focused, Shift-S starts a drag or adds the clip to the current drag. Use Left or Right Arrow to choose a destination and Command-Option-V to drop. Escape cancels. Without a selected destination, Command-Option-V drops after the focused clip.",
				"Command-Option-Left and Command-Option-Right move a clip or marked group earlier or later. Delete removes the selected clips. Command-Z undoes and Command-Shift-Z redoes."
			]), HelpSection("Reopen and reconnect", numbered: true, [
				"Choose Close, then My Projects and the project name. Choose Cancel during timeline preparation to return to the main screen. Trimatillo saves each project change as you work.",
				"If a saved project cannot be read, restore its project file from backup. Choose another project in My Projects to keep editing.",
				"If a source is unavailable, open Project Media, choose the source, and reconnect it from Files or Photos. Choose the original to restore access for every placement.",
				"When moving to a new device, restore Trimatillo's project data from your device backup and make the original media available through Files or Photos."
			]), HelpSection("Manage storage", numbered: true, [
				"From the main screen, open Settings, then Storage to check the space used by projects and temporary files.",
				"Choose Clear Temporary Files to remove unused working copies. Files in use are released when their import, edit, share, or export finishes.",
				"Choose Manage Projects to review each project's name and size, open it, or delete it.",
				"In the system Settings app, open Apps, then Trimatillo. Turn on Clear Temporary Files on Next Launch to request cleanup the next time Trimatillo is active."
			]), HelpSection("Delete a project", numbered: true, [
				"Open My Projects. On the project you want to remove, choose Delete Project from its context menu or accessibility actions.",
				"Check the project name and size in the alert, then choose Delete Project. This removes the edits and files saved inside that project. Original clips referenced from Photos or Files and exports saved elsewhere stay in their chosen locations."
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
				"The clip preview is followed by the Playhead slider and playback controls. With VoiceOver, focus Clip preview to use image description tools.",
				"Drag the Playhead slider to scrub through the edited clip. Lift your finger to leave the playhead at that position.",
				"With VoiceOver, swipe up or down on Playhead to move five seconds forward or back. For clips shorter than 50 seconds, each swipe moves one tenth of the clip. Double-tap and hold, then drag to scrub. Magic Tap plays or pauses while Playhead is focused.",
				"Play starts at the playhead. Pause holds the current position.",
				"Fast Forward plays forward. Rewind plays backward. Repeat either control to advance through 1x, 1.5x, 2x, 4x, and 8x. Switching direction starts at 1x.",
				"Use the Go to Start accessibility action on Rewind or Go to End on Fast Forward to move to that boundary of the edited clip.",
				"Step Back and Step Forward move to the previous or next frame in a video. In a clip with a variable frame rate, the time between steps can change as you move through it.",
				"At 24 frames per second, one frame lasts about 41.7 milliseconds. At 60 it lasts about 16.7 milliseconds, and at 120 it lasts about 8.3 milliseconds.",
				"In an audio-only clip, one step moves one thirtieth of a second. Ten steps move one third of a second.",
				"Choose Jump to Time, enter seconds or a time separated by colons, then choose Jump.",
				"For frame entry, choose Frames under Timecode in Settings before opening the clip. On the Cutting Board, choose Jump to Time, enter a frame number, and choose Jump. Counting starts at zero."
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
				"Double-tap at a join to open its boundaries. Choose Save or Cancel to return. VoiceOver announces In Direct Touch Editor.",
				"Triple-tap to close the editor and return to the Cutting Board."
			]), HelpSection("Two fingers", [
				"Double-tap to play or pause.",
				"Swipe right to play forward. Repeat to increase the speed through 1x, 1.5x, 2x, 4x, and 8x.",
				"Swipe left to rewind. Repeat to increase the rewind speed through the same five speeds.",
				"Swipe down to delete the marked range. When material remains on both sides, the two sections meet at a join."
			]), HelpSection("Three fingers", [
				"Tap once to hear the current playhead position.",
				"Swipe right to move to the next join, marker, or end of the clip.",
				"Swipe left to move to the previous join, marker, or start of the clip.",
				"Swipe down to undo the last edit. Repeat to undo earlier edits. VoiceOver announces the action after each Undo.",
				"Swipe up to redo the last edit you undid. Repeat to reapply edits in order."
			]), HelpSection("Four fingers", [
				"Swipe right to trim the head of the clip to the playhead.",
				"Swipe left to trim the tail of the clip to the playhead.",
				"Swipe down in a project Cutting Board to append the marked portion to the timeline.",
				"Swipe up in a project Cutting Board to choose Append to Track, Add to New Track, Overwrite at Playhead, or Insert and Split at Playhead. After you add the clip or choose Cancel, VoiceOver announces In Direct Touch Editor."
			]), HelpSection("Direct Touch Scrubbing", [
				"In Settings, choose Direct Touch Scrubbing under Editing.",
				"Absolute is the default. The left edge is the start of the edited clip, the center is halfway through, and the right edge is the end. The playhead jumps to your finger as soon as the hold begins.",
				"Relative starts each drag at the current playhead. On clips ten seconds or longer, dragging from the center to either edge moves five seconds. On shorter clips, the full width spans the clip's duration.",
				"To continue in Relative mode, lift and start another double-tap and hold. You can start anywhere on the surface, including back at the center."
			])]
		case .keys:
			[HelpSection("On the primary Cutting Board", [
				"Space or K plays or pauses. Press K during rewind or fast forward to stop at the current playhead.",
				"Use these commands anywhere on the primary Cutting Board. When a text field is active, type into the field; dismiss the keyboard to resume editing commands.",
				"Press J to rewind. Press it again to increase the speed.",
				"Press L to play forward. Press it again to increase the speed.",
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
				"Command-Z undoes the last edit. Command-Shift-Z redoes it."
			])]
		case .save:
			[Self.projectExport, HelpSection("Export from the Cutting Board", [
				"Save Changes to Original updates the selected Photos video or replaces a writable MOV, MP4, or M4A original in Files.",
				"Save as New Clip creates a separate clip. For video, choose Photos or Files. For audio, use the Files picker.",
				"In Files, select the folder, change the suggested filename if desired, and choose Save.",
				"When editing from the Photos Share sheet, choose Export, then Photos or Files under Save as New Clip.",
				"In Trim a Clip, choose Close, then Close Clip to finish. Choose Cancel to continue editing. Export edits you want to keep before closing."
			])]
		}
	}
}
