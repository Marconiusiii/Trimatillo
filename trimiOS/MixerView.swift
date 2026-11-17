import SwiftUI

nonisolated struct MixerChannel: Identifiable {
	let id: String
	let title: String
}

struct MixerView: View {
	let project: EditingProject
	@Binding var selection: String
	@Binding var solo: Set<String>
	@ObservedObject var playback: ProjectPlayback
	let apply: (EditingProject, String, Bool) -> Void
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private var channel: MixerChannel {
		project.mixerChannels.first { $0.id == selection } ?? MixerChannel(id: TimelineTrack.primaryAudio.id, title: TimelineTrack.primaryAudio.title)
	}

	var body: some View {
		Toggle("Loop", isOn: Binding(get: { playback.mixerLoop != nil }, set: { playback.setMixerLoop($0 ? project.captionRange : nil) }))
			.disabled(project.captionRange == nil)
		TimelineChooser(selection: Binding(get: { selection }, set: { id in
			withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = id }
		}), options: project.mixerChannels, title: \.title)
		Section {
			MixerLevelSlider(title: "Volume", level: project.trackVolumes?[channel.id] ?? 1) { level, commit in
				var next = project
				var levels = next.trackVolumes ?? [:]
				levels[channel.id] = level
				next.trackVolumes = levels
				apply(next, "Track Volume", commit)
			}
			.id(channel.id)
			HStack(spacing: 0) {
				mixToggle("Mute", enabled: project.mutedTracks?.contains(channel.id) == true) { muted in
					var next = project
					var tracks = next.mutedTracks ?? []
					if muted { tracks.insert(channel.id) } else { tracks.remove(channel.id) }
					next.mutedTracks = tracks
					apply(next, "Track Mute", true)
				}
				mixToggle("Solo", enabled: solo.contains(channel.id)) { enabled in
					let id = channel.id
					solo = enabled ? solo.union([id]) : solo.subtracting([id])
				}
			}
			Button("Reset Track Mix") {
				var next = project
				next.trackVolumes?.removeValue(forKey: channel.id)
				next.mutedTracks?.remove(channel.id)
				solo.remove(channel.id)
				apply(next, "Reset Track Mix", true)
			}
			.buttonStyle(EditorButtonStyle())
		} header: {
			Text(channel.title).font(.headline).accessibilityAddTraits(.isHeader)
				.contentTransition(.opacity)
		}
		.listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
		Section {
			MixerLevelSlider(title: "Master Volume", level: project.masterVolume ?? 1) { level, commit in
				var next = project
				next.masterVolume = level
				apply(next, "Master Volume", commit)
			}
			.padding(.horizontal, 12)
		}
	}
	private func mixToggle(_ title: String, enabled: Bool, change: @escaping (Bool) -> Void) -> some View {
		Toggle(isOn: Binding(get: { enabled }, set: change)) {
			HStack {
				Image(systemName: enabled ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
				Text(title)
			}
			.editorTouchRow()
		}
		.toggleStyle(.button)
	}

}

private struct MixerLevelSlider: View {
	let title: String
	let level: Float
	let change: (Float, Bool) -> Void
	@State private var dragging = false
	@State private var draft: Double?

	private var decibels: Double {
		draft ?? (level > 0 ? max(-60, 20 * log10(Double(level))) : -60.5)
	}

	private func linear(_ db: Double) -> Float {
		db < -60 ? 0 : Float(pow(10, db / 20))
	}

	private func finish() {
		dragging = false
		if let draft {
			change(linear(draft), true)
			self.draft = nil
		}
	}

	var body: some View {
		let value = decibels < -60 ? "Silent" : String(format: "%.1f dB", decibels)
		VStack(spacing: 0) {
			LabeledContent(title, value: value).accessibilityHidden(true)
			Slider(value: Binding(get: { decibels }, set: { db in
				if dragging { draft = db }
				change(linear(db), !dragging)
			}), in: -60.5...12, step: 0.5, onEditingChanged: { editing in
				if editing { dragging = true } else { finish() }
			}) { Text(title) }
			.frame(minHeight: 48)
			.accessibilityValue(value)
		}
		.onDisappear { finish() }
	}
}
