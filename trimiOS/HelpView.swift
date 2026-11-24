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
	case touch = "Direct Touch Editing"
	case projectTouch = "Project Direct Touch Editor"
	case actions = "VoiceOver actions"
	case keys = "Keyboard commands"
	case open = "Open a clip"
	case playback = "Playback and the playhead"
	case cuts = "Markers, trims, and joins"
	case save = "Save and export"
	case projects = "Multitrack projects"
	case captioner = "Captioner"
	case describer = "Describer"
	case voicer = "Voicer"
	case mixer = "Mixer"
	case generators = "Generators and compositing"

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
		case .touch: "Use Direct Touch gestures in the Cutting Board to move through a clip and edit it. For project gestures, including generators and transitions, see Project Direct Touch Editor in Help."
		case .keys: "Use a connected keyboard to control playback, edit clips, and add generators and transitions in Editor."
		case .save: "Save an edited clip from the Cutting Board or export a project timeline from Project Actions."
		}
	}

	private static var projectExport: HelpSection {
		HelpSection("Export a project", numbered: true, [
			"Open Project Actions beside the project name and choose Export. Export includes the full timeline and its track volumes.",
			"To make captions part of the picture, turn on Burn In Open Captions. The movie uses the captions and timing in the Caption Timeline.",
			"For video, choose Photos to save a new video to the library, or Files to choose a folder. For an audio project, choose Files to save an M4A.",
			"In Files, choose a folder and filename for the export."
		])
	}

	var sections: [HelpSection] {
		switch self {
		case .generators:
			[HelpSection("Create a clip", numbered: true, [
				"Choose the destination track with Timeline Chooser. In Project Direct Touch, swipe right with four fingers to open Add Generator. In Editor, use the track's Add Generator accessibility action, press G, or choose Add Generator.",
				"On a video track, choose Text, Black, Solid Color, or Gradient. On an audio track, create Silence. Duration in Seconds starts at five seconds, or uses the marked range when valid In and Out points are set.",
				"For text, choose a preset and enter Text. Title and Subheading adds a second line; Name and Role adds a role below the name. Subtitle creates a text clip that appears over the video.",
				"Open Typography to change font, bold, Font Size in points, or line spacing. Layout controls text position, safe margin, and width.",
				"Choose Append, Insert at Playhead, Overwrite at Playhead, or New Track at Playhead. Enter a track name when creating a new track. Choose Preview to play the result in the project before adding it.",
				"Enable Shift Other Tracks to move later clips, captions, and descriptions on other tracks by the generator's duration. Entries beginning before the placement time stay where they are. Leave it off to change only the destination track and its linked audio."
			]), HelpSection("Set generator colors", numbered: true, [
				"Choose a preset color, or enable Custom Color and enter Red, Green, and Blue values from 0 to 255."
			]), HelpSection("Edit a generated clip", numbered: true, [
				"Open a generated timeline clip's accessibility actions or menu and choose Edit Generator. Change its text or appearance. Other copies retain their own settings.",
				"Edit Generator in Project Media changes the source settings for copies that have not received their own generator edits. Use the Cutting Board to trim a generated clip and Save Changes to update it on the timeline."
			]), HelpSection("Layer clips", numbered: true, [
				"Place the title or other visual clip on a video track above the footage. Open the timeline clip in the Cutting Board, then choose Edit Actions and Compositing.",
				"Opacity controls how much of the clip is visible. Blend Mode combines its colors with the tracks below. Scale changes the clip size; Position and the horizontal and vertical offsets place it within the project frame.",
				"Choose Preview to play the project with these settings. Compositing applies to this timeline clip. Reset Compositing restores full opacity, normal blending, original size, and centered position.",
				"For transparent titles, enable Transparent Background in Edit Generator. Background colors and text panels remain editable there. Project export includes the generated clips and their compositing settings."
			])]
		case .mixer:
			[HelpSection("Mix voice and project audio", numbered: true, [
				"Press Command-Shift-M or open Mixer. Set In and Out around a passage with voice and background sound. Turn on Loop and press Play to repeat it.",
				"Press Command-Option-Up Arrow or Command-Option-Down Arrow to switch tracks, or choose a track in Timeline Chooser.",
				"Turn on Mute to silence the selected track in the project and its export. Turn on Solo to listen to the selected track alone, or solo several tracks to hear them together. Leaving Mixer clears Solo.",
				"To match clips recorded at different levels, open Track Effects from the audio track heading in Editor. Choose Effects, then Match Loudness. Use Mixer Volume to adjust the matched track as a whole.",
				"Adjust Volume while listening to balance the selected track with the rest of the project.",
				"Adjust Pan to move the track left or right. Stereo Balance lowers the opposite channel. Center gives both channels their original position and balance.",
				"Adjust Stereo Width to narrow or widen the sound. Choose Mono to bring both sides together or Original for the recorded width.",
				"Use Channel Routing to keep both channels, send the left or right input to both sides, or swap left and right.",
				"Adjust Master Volume to change the level of the whole mix. Reset Track Mix restores the original volume, stereo position, width, and routing, and clears Mute and Solo. Choose Undo to reverse a saved mix adjustment.",
				"Choose Export in Project Actions to include your volume, stereo, mute, and audio ducking settings. Solo applies only while listening in Mixer."
			])]
		case .voicer:
			[HelpSection("Use Direct Touch", [
				"Open Voicer, then choose Direct Touch Editor to use these gestures."
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
				"Swipe down to open Record Voice Over at the playhead."
			]), HelpSection("Three fingers in Voicer Direct Touch", [
				"Tap once to hear the current playhead position.",
				"Swipe right to go to the next voice-over edit point or project marker.",
				"Swipe left to go to the previous voice-over edit point or project marker.",
				"Swipe down to undo a project edit.",
				"Swipe up to redo it."
			]), HelpSection("Record a take", numbered: true, [
				"Open Voicer and move the project playhead to the start of the narration.",
				"Press Command-Shift-V from the project, or choose Record Voice Over. To use a different insertion time, change Insert at Time or Insert at Frame.",
				"Enter a Clip Name. Leave Source Audio Playback on to hear the project during the take, or turn it off to record with the project audio muted. Choose Record and speak after the rising cue. Choose Stop Recording when you finish.",
				"Choose Play Take to hear your recording alone, or Play with Primary Audio to hear it at the insertion time. Choose Record again to make another take. Recover Take opens a saved draft.",
				"Choose Add to Project. The take appears on a Voice Over audio track. Takes that overlap use separate tracks. Project export includes the recording.",
				"Open the take in the Voice Over timeline. Choose Open Cutting Board, trim the take, then choose Save Changes. Choose Move to Time to change its start.",
				"Remove from Track removes this placement. Delete from Project removes the recording and all timeline clips that use it. Choose Undo to restore the edit."
			])]
		case .describer:
			[HelpSection("Use Direct Touch", [
				"Open Describer, then choose Direct Touch Editor to use these gestures."
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
			]), HelpSection("Describe a passage", numbered: true, [
				"Open Describer in a project. Mark In at the beginning of the passage and Out at its end.",
				"For a written entry, select Descriptive Transcript in Timeline Chooser. Press Command-Shift-D or choose New Description. Enter the passage in Description Text.",
				"Choose Play In to Out to repeat the passage while writing or preparing a recording.",
				"For narration, select Audio Description in Timeline Chooser and choose New Description. In Audio Description, you can change Recording Name. Turn off Source Audio Playback to mute the passage during recording. Voicer and Audio Description share this setting. Choose Record. Allow microphone access when prompted. Speak after the rising cue. The project plays to Out. Choose Stop Recording when you finish speaking.",
				"Choose Play Take to hear the original recording. Speed Up to Fit trims silence from the end of the take. Your voice plays at its recorded speed if it fits before Out. Longer narration speeds up and keeps its pitch. Choose Trim at Out to play the original take up to Out. Play with Primary Audio previews the result against the passage.",
				"To resume a recorded draft, mark the passage, open Audio Description, and choose Recover Take."
			]), HelpSection("Review and export", numbered: true, [
				"Use Timeline Chooser to switch between Descriptive Transcript and Audio Description at the current playhead. Projects open with Audio Description selected when recordings exist, or Descriptive Transcript when only written entries exist.",
				"For a group, use Select Clip in each entry's accessibility actions or menu, then choose Shift Clips on a selected entry. To shift the whole timeline, choose Shift Track from its heading. Choose Earlier or Later and enter Seconds. Recording lengths and spacing stay the same; Undo reverses the shift.",
				"Open an entry's accessibility actions or menu to go to its start, edit, or delete it. Return edits a focused entry with a keyboard. Mark a new range and choose Use Marked Range while editing to change its timing. Undo restores a deleted entry.",
				"A transcript spans the marked range. A shorter recording ends when the take ends. Entries on the two timelines can be changed independently.",
				"On the Audio Description timeline, choose Audio Ducking to lower project audio during descriptions. Set how much to lower the audio and how gradually it fades. Project playback and movie export use the same mix.",
				"On the Descriptive Transcript timeline, choose Export Description Transcript to share the timed text as a WebVTT file. To export the movie with narration, choose Project Actions, then Export.",
				"Open Audio in the main Settings sheet to select a microphone or audio output. Same as System uses the microphone selected by your device."
			])]
		case .captioner:
			[HelpSection("Use Direct Touch", [
				"Open Captioner, then choose Direct Touch Editor to use these gestures."
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
				"Swipe down to open New Caption for the marked passage."
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
			]), HelpSection("Create a caption", numbered: true, [
				"Open a project and choose the Captioner tab. The playhead stays at the same position when you switch tabs.",
				"Move to the beginning of the passage and choose Mark In. Move to its end and choose Mark Out.",
				"Choose New Caption and enter the caption text. Play Selection repeats the marked passage while you write.",
				"Use Insert Caption Description to add a music description, sound description, or lyrics. Replace the sample words with your own.",
				"The caption appears in the Caption Timeline and over the picture during its marked range."
			]), HelpSection("Review and export", numbered: true, [
				"Open a caption's accessibility actions or menu to go to its start, edit it, or delete it. To change its timing, mark a new range, edit the caption, and choose Use Marked Range.",
				"Choose Finalize Captions to divide draft passages into captions of up to two lines. Timing gives each caption time to be read within the available passage.",
				"If passages need review, read the reason for each one. Shorten the text or adjust the marked range and finalize again. Undo restores the previous captions.",
				"Choose Export Captions, then SRT or WebVTT for timed captions, or Plain Text Transcript for the words in timeline order. Choose an app in the share sheet or choose Save to Files."
			])]
		case .projectTouch:
			[HelpSection("Open Direct Touch", numbered: true, [
				"Open a project with clips on its timeline. In the Editor, choose Direct Touch Editor.",
				"The surface opens at the project playhead on the selected track. Primary Video is the initial track."
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
				"Swipe right to open Add Generator for the selected track. Choose the generator and where to add it.",
				"Swipe down at an edit point on the selected track to apply Cross Dissolve on a video track or Cross Fade on an audio track. The first duration is one second. Later uses follow the duration last saved for Cross Dissolve or Cross Fade.",
				"Swipe up to open Quick Fade at the playhead on the selected track. Set Fade In and Fade Out and their durations, then preview the result.",
				"Tap once to open Transitions for the clip or edit point on the selected track. Choose a transition, set its duration, and preview it."
			]), HelpSection("Track navigation", [
				"Switching tracks keeps the playhead in place. Playback and scrubbing include the full project mix.",
				"At a shared cut, the edit point uses the name of the clip beginning there in either direction. Start, End, In, and Out are also stops.",
				"In the main Editor, adjust Timeline Chooser to select the active track. The Editor shows the selected track and its edit points on the playhead slider. Use the Previous Edit Point and Next Edit Point buttons near the step controls to reach the same stops. The step buttons also retain these accessibility actions."
			])]
		case .projects:
			[HelpSection("Direct Touch and VoiceOver", [
				"In Editor, choose Direct Touch Editor for playback, markers, track navigation, generators, and transitions. Project Direct Touch Editor in Help lists each gesture.",
				"Use a clip's accessibility actions to open its Cutting Board, move it, or remove it. Use track headings to reach Track Actions."
			]), HelpSection("Project keyboard commands", [
				"On a project Cutting Board, E appends, Option-W opens Add at Playhead, W inserts and splits, and D overwrites. Command-U saves changes to an existing placement.",
				"In Editor, G opens Add Generator for the selected track.",
				"X applies Cross Dissolve on a video track or Cross Fade on an audio track at the edit point.",
				"F opens Quick Fade at the playhead on the selected track.",
				"Command-T or Command-Shift-T opens Transitions at the playhead on the selected track.",
				"On the project timeline, Space or K plays or pauses, including when a clip is focused. K also stops rewind or fast forward. J rewinds and L plays forward. Left and Right Arrow step one frame, or ten with Shift. T reads the playhead. Home and End jump to the project boundaries.",
				"I and O mark In and Out at the current playhead without stopping playback. Hold Option to clear a marker. Semicolon and Apostrophe move to the previous and next boundary or marker. Command-Left and Command-Right do the same.",
				"Command-Option-Up and Command-Option-Down select a track. C opens its clip at or after the playhead. Return opens the focused clip. Command-B splits at the playhead. Command-[ and Command-] trim the start and end.",
				"S selects or deselects a clip. With a clip focused, Shift-S starts a drag or adds the clip to the current drag. Use Left or Right Arrow to choose a destination and Command-Option-V to drop. Escape cancels. Without a selected destination, Command-Option-V drops after the focused clip.",
				"Command-Option-Left and Command-Option-Right move a clip or selected group earlier or later. Delete removes the selected clips. Command-Z undoes and Command-Shift-Z redoes."
			]), HelpSection("Create a project", numbered: true, [
				"Choose Create Project and enter a name.",
				"Choose Same as Media to use the size and frame rate of the first video you place on the timeline. To set your own, choose a resolution and enter a frame rate.",
				"Choose Custom to enter a width and height. With Lock Aspect Ratio on, changing one dimension adjusts the other.",
				"To set a length to aim for, turn on Use Set Project Duration and enter the Duration in Seconds. Clips can extend beyond that duration."
			]), HelpSection("Change project settings", numbered: true, [
				"Open Project Actions beside the project name and choose Project Settings.",
				"Edit the name, resolution, frame rate, or duration. Resolution and frame rate apply to project playback and export."
			]), HelpSection("Arrange clips", numbered: true, [
				"Expand Project Media. Choose Import Clip, then Photo Library or Files, and select the original.",
				"In Photo Library, select a video to open Clip Preview. Play or scrub through it, then choose Use Clip to add it to Project Media.",
				"Choose Open Cutting Board from the source clip's accessibility actions or menu. Trim the clip or cut a marked range.",
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
				"Track effects apply to existing clips and clips added later. In Editor, choose Undo to reverse a saved effect change."
			]), HelpSection("Add and preview transitions", numbered: true, [
				"Move the playhead onto a clip or to the cut where two clips meet. Open the Transitions menu beside Add Generator to choose Transitions, Quick Fade, or Cross Dissolve or Cross Fade for the selected track. To work on a specific clip, use its accessibility actions or menu. The track heading also offers these commands.",
				"At a cut, choose a transition and its Duration in Seconds. Video choices include Cross Dissolve, Fade Out/Fade In through black, Fade Through White, directional wipes, slides, covers and reveals, circles, and Pixel Dissolve. Audio offers Cross Fade and Fade Out/Fade In.",
				"Use Easing with a wipe, slide, cover, reveal, or circle to change its movement over time. Linear keeps a steady pace. Ease In slows toward the incoming picture, Ease Out accelerates away from the outgoing picture, and Easy Ease smooths both ends.",
				"Turn on Crossfade Audio to include linked video sound. Choose Linear or Equal Power for the audio curve. Equal Power maintains more volume around the middle of a crossfade.",
				"Use Magic Tap or Play to preview. Playback loops around the transition. Adjust the settings to prepare an updated preview. Use the playhead to choose another position.",
				"If preview preparation fails, choose Retry Preview. If it fails again, close the transition screen and reopen the project.",
				"Reopen Transitions at the same cut to adjust it or choose Remove Transition. Undo and Redo restore saved transition changes.",
				"Choose Quick Fade to apply Fade In, Fade Out, or both, with separate durations. At a shared cut, Fade Out affects the outgoing clip and Fade In affects the incoming clip. From a selected clip's menu, both apply to that clip.",
				"Cross transitions use extra source material on both sides of the cut. If there is too little available, shorten the transition or adjust the cut in the Cutting Board. The project duration stays the same.",
				"Transitions follow their clips. Removing a clip, separating a joined pair, or shortening a clip beyond its transition removes the affected transition. Undo restores it.",
				"In Editor, press X for a quick crossfade, F for Quick Fade, or Command-Shift-T for Transitions. These commands use the playhead on the selected track. Commands in a clip's own menu apply to that clip."
			]), HelpSection("Project playback and navigation", [
				"Choose Direct Touch Editor to use gestures on the project. The Project Direct Touch Editor Help topic lists each gesture.",
				"Choose Rewind or Fast Forward to play in that direction. Repeat to select 1x, 1.5x, 2x, 4x, or 8x. Changing direction starts at 1x.",
				"Use the Go to Start accessibility action on Rewind or Go to End on Fast Forward to move to that boundary of the project.",
				"Press Space or K to play or pause, J to rewind, and L to play forward. Left and Right Arrow step one project frame. Hold Shift to step ten frames.",
				"Drag across Playhead to preview the project from start to end. Lift to leave the playhead there.",
				"With VoiceOver, focus Playhead, double-tap and hold until you hear three rising tones, then drag left or right. After lifting your finger, use Magic Tap to play or pause at the playhead. Swipe up or down to move five seconds forward or back. Short projects use smaller steps.",
				"When scrub audio is unavailable, VoiceOver reads the timecode after a brief pause in your drag or when you lift.",
				"Choose Jump to Time to enter a time or frame in your selected timecode format.",
				"Choose Step Back or Step Forward to move one project frame. In the Actions rotor, choose the 10-frame action or the previous or next edit point. Double-tap to use that action again while the button stays focused.",
				"Previous Edit Point and Next Edit Point move between clip boundaries on the selected track, project markers, Start, and End. VoiceOver identifies the clip at a boundary and reads the position. Where two clips meet, it names the clip that begins there.",
				"Choose Mark In or Mark Out to set a marker. Its actions let you go to it or clear it. Pressing the marker button at its marked position also clears it. Opening a project clears its previous In and Out markers."
			]), HelpSection("Name a project clip", numbered: true, [
				"Expand Project Media. Open the imported clip's menu or actions and choose Rename Clip.",
				"Enter a Clip Name. The project uses that name for the source and its timeline clips.",
				"Append a second passage from the same source. A clip named Interview becomes Interview A on the timeline, and the new passage is Interview B. Each clip keeps its letter when moved."
			]), HelpSection("Full Screen Preview", numbered: true, [
				"Pause or step to the picture you want to inspect. With VoiceOver, focus Video frame to explore the image.",
				"Choose Full Screen Preview beneath the video preview to open the project at the playhead.",
				"Use Magic Tap or Play and Pause to control playback. Adjust the playback slider to move to another time."
			]), HelpSection("Add at Playhead", numbered: true, [
				"Set the project playhead to the destination time before opening the Cutting Board. Mark the source passage and choose Add at Playhead.",
				"Choose New Track and enter a name, or choose an existing destination track for Overwrite or Split.",
				"Overwrite replaces the covered time. The original resumes after the added clip. Split inserts the selection and moves later material on that track forward.",
				"When a named video track first receives a clip with audio included, its linked audio track appears. The sound follows the video through edits. Adjust its volume in Track Effects.",
				"For a video cutaway, choose New Track. Turn off Include Clip Audio to keep the underlying sound."
			]), HelpSection("Track actions and clip movement", numbered: true, [
				"Choose a track with Timeline Chooser. Open its heading for Track Actions, including Track Effects and the Magnetic setting.",
				"Choose Shift Track from the track heading's accessibility actions or menu to move all its clips by a set amount. For a group, select the clips and choose Shift Clips on a selected clip. Choose Earlier or Later and enter Seconds. Linked video and audio move together, spacing stays the same, and Undo reverses the whole shift.",
				"The primary tracks start with Magnetic on. Removing or trimming a clip shifts later clips on its track. New tracks use absolute placement. Turn Magnetic off to keep neighboring clips at their project times. Turning it on asks for confirmation when clips need to move together.",
				"Choose Move to Playhead on a clip to place its start at the playhead. On a magnetic track, a move into another clip splits it and preserves the rest. A move beyond the last clip appends it.",
				"Choose Remove from Track to remove one placement and keep its source in Project Media. To remove the source and every placement made from it, choose Delete from Project in the clip accessibility actions or menu, then confirm. Undo restores the source and its timeline clips together.",
				"Choose Move to Time, enter Start Time or Start Frame, then choose Move. Absolute placement needs open time for the clip. To leave a gap on a populated magnetic track, turn Magnetic off first.",
				"Choose Move to New Track, enter Track Name, and choose Move to keep the clip at its current time on a new track. Moving linked audio moves its video with it.",
				"On a clip, choose Select Clip to include it in a group. Choose Start Drag on a selected clip to pick up the group. Choose Add to Drag on another compatible clip to include it.",
				"Choose the destination track with Timeline Chooser. On the destination clip, choose Drop Before or Drop After followed by the destination clip name. On an empty compatible track, choose Drop on Track. After a drop, choose Undo or shake the device to restore the previous order. A group move takes one undo.",
				"You can also drag a clip onto the leading or trailing half of another clip to place it before or after that clip."
			]), HelpSection("Edit selected clips", numbered: true, [
				"Choose Select Clip in each clip's accessibility actions or menu. Selected clips form a group on that track. Choose Deselect Clip to remove a clip from the group.",
				"Choose Shift Clip to move one clip, or Shift Clips on a selected clip to move the group. Choose Earlier or Later, enter Seconds, then choose Shift.",
				"Choose Open Clips Cutting Board on a selected clip. The selected clips play consecutively for editing. Use the Cutting Board playback commands, markers, trimming, and Direct Touch gestures to edit the group. Command-U saves the changes.",
				"Choose Quick Fade or Compositing from Effects to apply settings to the selected clips. Save Changes applies your edits to the project. Linked audio follows the video, and a magnetic track moves later clips to close the removed time.",
				"Choose Remove Clips from Track on a selected clip to remove the group. Undo restores the group together."
			]), Self.projectExport, HelpSection("Reopen and reconnect", numbered: true, [
				"Choose My Projects on the main screen, then the project name. Trimatillo saves each project change as you work.",
				"If a saved project cannot be read, restore its project file from backup. Choose another project in My Projects to keep editing.",
				"If a source is unavailable, open Project Media, choose the source, and reconnect it from Files or Photos. Choose the original to restore access for every placement.",
				"When moving to a new device, restore Trimatillo's project data from your device backup and make the original media available through Files or Photos."
			]), HelpSection("Manage storage", numbered: true, [
				"From the main screen, open Settings, then Storage to check the space used by projects and temporary files.",
				"Choose Clear Temporary Files to remove unused working copies. Files in use are released when their import, edit, share, or export finishes.",
				"Choose Manage Projects to review each project's name and size, open it, or delete it.",
				"In the system Settings app, open Apps, then Trimatillo. Turn on Clear Temporary Files on Next Launch to request cleanup the next time Trimatillo is active."
			]), HelpSection("Delete a project", numbered: true, [
				"Open My Projects. On the project you want to remove, choose Delete Project from its accessibility actions or context menu.",
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
				"Use the picker's search field to find a clip. In Photo Library, select a video to open Clip Preview. When the preview is ready, use Magic Tap, Play, or the playback slider to check the video.",
				"Choose Use Clip to open the video in the Cutting Board.",
				"Choose Clip Info at the top of the board to read the clip's filename, duration, and available media details."
			]), HelpSection("From Photos", numbered: true, [
				"Select one video in Photos and choose Share.",
				"Choose Trimatillo from the apps row. Choose More to see the full list.",
				"Edit the shared video on the Video Cutting Board. Choose Export to save a copy."
			])]
		case .playback:
			[HelpSection("Move through a clip", [
				"With VoiceOver, focus Clip preview to use image description tools.",
				"With VoiceOver, swipe up or down on Playhead to move five seconds forward or back. Short clips use smaller steps. Double-tap and hold, then drag to scrub. Magic Tap plays or pauses while Playhead is focused.",
				"Fast Forward plays forward. Rewind plays backward. Repeat either control to advance through 1x, 1.5x, 2x, 4x, and 8x. Switching direction starts at 1x.",
				"Use the Go to Start accessibility action on Rewind or Go to End on Fast Forward to move to that boundary of the edited clip.",
				"Press Space or K to play or pause, J to rewind, and L to play forward. Left and Right Arrow step one frame. Keyboard commands in Help lists all Cutting Board shortcuts.",
				"Drag the Playhead slider to scrub through the edited clip. Lift your finger to leave the playhead at that position.",
				"Step Back and Step Forward move backward or forward one frame, using the clip's frame rate in the Cutting Board or the project's frame rate in Editor.",
				"Choose Jump to Time, enter seconds or a time separated by colons, then choose Jump.",
				"For frame entry, choose Frames under Timecode in Settings before opening the clip. On the Cutting Board, choose Jump to Time, enter a frame number, and choose Jump. Counting starts at zero."
			]), HelpSection("Full Screen Preview", numbered: true, [
				"Choose Full Screen Preview beside the playback controls to open the edited clip at the playhead.",
				"Use Magic Tap or Play and Pause to control playback. Adjust the playback slider to move to another time."
			])]
		case .cuts:
			[HelpSection("Select a range", [
				"Mark In sets the start of a selection at the playhead. Mark Out sets its end. Place Out after In.",
				"Move the playhead and set the same marker again to change its position.",
				"Edit Actions includes commands to clear each marker, play the marked range, and delete the selected passage."
			]), HelpSection("Trim and review", [
				"Trim Head to Playhead removes everything before the playhead. Trim Tail to Playhead removes everything after it.",
				"Previous Edit Point and Next Edit Point move among joins, markers, and the start and end of the clip.",
				"At a join, choose Adjust Edit Point in Edit Actions. Outgoing Out Point sets where the outgoing clip ends. Incoming In Point sets where the incoming clip begins.",
				"With VoiceOver focused on either point, swipe up to advance one source frame or down to go back one. The Out Point previews sound before the cut and the In Point previews sound after it.",
				"Activate either point to type a source time or frame number.",
				"Choose Undo to reverse a marker change, trim, deletion, or saved join adjustment. Repeat to undo earlier edits. To reapply an edit, choose Redo in Edit Actions.",
				"To undo by shaking your device, turn on Shake to Undo in Trimatillo Settings and in the device's Accessibility settings under Touch."
			]), HelpSection("Trim silences", numbered: true, [
				"Open Edit Actions and choose Trim Silences. With In and Out set, leave Only Between In and Out on to search that passage.",
				"Adjust the Silence threshold slider. A higher value includes louder sounds. Minimum silence sets the shortest pause to find. Retained silence sets how much of each pause to keep, divided between its two ends.",
				"Choose Find Pauses. If no pauses are found, adjust the detection settings and search again.",
				"For each pause, choose its numbered preview button to play that pause with up to half a second of the original clip on either side. Move the pause's Start or End slider to change the cut, or turn off Remove Pause to keep that passage.",
				"Time to remove shows the total duration of the selected cuts. Choose Preview Trimmed Clip to hear those cuts together.",
				"Choose Apply Cuts. Undo restores all the pauses from this operation in one step."
			])]
		case .actions:
			[HelpSection("Actions rotor", [
				"Focus Step Forward or Step Back. In the Actions rotor, swipe up or down to choose a ten-frame move or the next or previous edit point. Double-tap to perform the selected action.",
				"Focus Undo, select Redo in the Actions rotor, and double-tap to reapply the last edit you undid. Making a new edit clears the remaining redo history.",
				"Focus Playhead and use its actions to mark, trim, delete a selection, or navigate to an edit point.",
				"Focus a set In or Out marker and use its actions to jump to that time or clear the marker.",
				"Use Magic Tap, a two-finger double-tap, to play or pause the clip."
			])]
		case .touch:
			[HelpSection("Open the editor", ["Choose Direct Touch Editor on the Cutting Board to use the following gestures."]),
			HelpSection("One finger", [
				"Swipe right to step forward one frame.",
				"Swipe left to step back one frame.",
				"Double-tap and hold the second tap to scrub. Drag left or right to preview the clip, then lift to leave the playhead there.",
				"Swipe down to mark In. Repeat at the marker to remove it, or swipe down at a new position to move it.",
				"Swipe up to mark Out. Repeat at the marker to remove it, or swipe up at a new position to move it.",
				"Double-tap at a join to adjust its boundaries.",
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
				"Swipe up in a project Cutting Board to choose Append to Track, Add to New Track, Overwrite at Playhead, or Insert and Split at Playhead."
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
				"Left Arrow or Right Arrow steps back or forward one frame. Hold Shift to move ten frames.",
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
			]), HelpSection("Generators and transitions in Editor", [
				"Choose a track with Timeline Chooser and move the playhead to where you want to work. These commands use the selected track and playhead.",
				"G opens Add Generator.",
				"X applies Cross Dissolve on a video track or Cross Fade on an audio track at an edit point.",
				"F opens Quick Fade.",
				"Command-T or Command-Shift-T opens Transitions."
			])]
		case .save:
			[Self.projectExport, HelpSection("Export from the Cutting Board", [
				"Save Changes to Original updates the selected Photos video or replaces a writable MOV, MP4, or M4A original in Files.",
				"Save as New Clip creates a separate clip. For video, choose Photos or Files. For audio, use the Files picker.",
				"In Files, choose a folder and filename for the edited clip.",
				"When editing from the Photos Share sheet, choose Export, then Photos or Files under Save as New Clip.",
				"Export edits you want to keep before closing a clip in Trim a Clip."
			])]
		}
	}
}
