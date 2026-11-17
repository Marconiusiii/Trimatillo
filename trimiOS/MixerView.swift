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
	@Environment(\.dynamicTypeSize) private var textSize
	@ScaledMetric(relativeTo: .body) private var inlineChooserWidth: CGFloat = 190

	private var channel: MixerChannel {
		project.mixerChannels.first { $0.id == selection } ?? MixerChannel(id: TimelineTrack.primaryAudio.id, title: TimelineTrack.primaryAudio.title)
	}

	var body: some View {
		Toggle("Loop", isOn: Binding(get: { playback.mixerLoop != nil }, set: { playback.setMixerLoop($0 ? project.captionRange : nil) }))
			.disabled(project.captionRange == nil)
		Group {
			if textSize.isAccessibilitySize {
				stackedTrackControls
			} else {
				ViewThatFits(in: .horizontal) {
					HStack(spacing: 0) {
						trackChooser.frame(minWidth: inlineChooserWidth, idealWidth: inlineChooserWidth, maxWidth: .infinity)
						trackButtons.fixedSize(horizontal: true, vertical: false)
					}
					stackedTrackControls
				}
			}
		}
		.listRowInsets(EdgeInsets())
		Section {
			MixerSlider(title: "Volume", level: project.trackVolumes?[channel.id] ?? 1) { level, commit in
				var next = project
				var levels = next.trackVolumes ?? [:]
				levels[channel.id] = level
				next.trackVolumes = levels
				apply(next, "Track Volume", commit)
			}
			stereoSlider("Pan", key: \.pan, range: -1...1)
			stereoSlider("Stereo Balance", key: \.balance, range: -1...1)
			stereoSlider("Stereo Width", key: \.width, range: 0...2)
			Picker("Channel Routing", selection: Binding(get: { stereo.routing }, set: { routing in
				changeStereo(\.routing, to: routing, action: "Channel Routing", commit: true)
			})) {
				ForEach(TrackChannelRouting.allCases) { route in Text(route.title).tag(route) }
			}
			.pickerStyle(.menu)
			Button("Reset Track Mix") {
				var next = project
				next.trackStereo?.removeValue(forKey: channel.id)
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
		.id(channel.id)
		.listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
		Section {
			MixerSlider(title: "Master Volume", level: project.masterVolume ?? 1) { level, commit in
				var next = project
				next.masterVolume = level
				apply(next, "Master Volume", commit)
			}
			.padding(.horizontal, 12)
		}
	}

	private var stackedTrackControls: some View {
		VStack(spacing: 0) {
			trackChooser
			trackButtons
		}
	}

	private var trackChooser: some View {
		TimelineChooser(selection: Binding(get: { selection }, set: { id in
			withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = id }
		}), options: project.mixerChannels, title: \.title)
	}

	private var trackButtons: some View {
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
	}

	private var stereo: TrackStereoMix { project.trackStereo?[channel.id] ?? .neutral }

	private func changeStereo<Value>(_ key: WritableKeyPath<TrackStereoMix, Value>, to value: Value, action: String, commit: Bool) {
		var next = project
		var settings = stereo
		settings[keyPath: key] = value
		var tracks = next.trackStereo ?? [:]
		tracks[channel.id] = settings == .neutral ? nil : settings
		next.trackStereo = tracks.isEmpty ? nil : tracks
		apply(next, action, commit)
	}

	private func stereoSlider(_ title: String, key: WritableKeyPath<TrackStereoMix, Double>, range: ClosedRange<Double>) -> some View {
		MixerSlider(title: title, value: stereo[keyPath: key], range: range, step: 0.01, display: { value in
			let percent = Int((value * 100).rounded())
			if key == \.width {
				if percent == 0 { return "Mono" }
				if percent == 100 { return "Original" }
				return "\(percent)%"
			}
			if percent == 0 { return "Center" }
			return "\(abs(percent))% " + (percent < 0 ? "left" : "right")
		}) { value, commit in
			changeStereo(key, to: value, action: title, commit: commit)
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

private struct MixerSlider: View {
	let title: String
	let value: Double
	let range: ClosedRange<Double>
	let step: Double
	let display: (Double) -> String
	let change: (Double, Bool) -> Void
	@State private var dragging = false
	@State private var draft: Double?

	private func finish() {
		dragging = false
		if let draft {
			change(draft, true)
			self.draft = nil
		}
	}

	var body: some View {
		let label = display(draft ?? value)
		VStack(spacing: 0) {
			LabeledContent(title, value: label).accessibilityHidden(true)
			Slider(value: Binding(get: { draft ?? value }, set: { newValue in
				if dragging { draft = newValue }
				change(newValue, !dragging)
			}), in: range, step: step, onEditingChanged: { editing in
				if editing { dragging = true } else { finish() }
			}) { Text(title) }
			.frame(minHeight: 48)
			.accessibilityValue(label)
		}
		.onDisappear { finish() }
	}
}

private extension MixerSlider {
	init(title: String, level: Float, change: @escaping (Float, Bool) -> Void) {
		self.init(title: title, value: level > 0 ? max(-60, 20 * log10(Double(level))) : -60.5,
			range: -60.5...12, step: 0.5, display: { $0 < -60 ? "Silent" : String(format: "%.1f dB", $0) }) { db, commit in
			change(db < -60 ? 0 : Float(pow(10, db / 20)), commit)
		}
	}
}
