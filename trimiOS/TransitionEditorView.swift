import SwiftUI
import AVFoundation

struct ProjectTransitionRequest: Identifiable {
	let id = UUID()
	let track: TimelineTrack
	let clip: UUID
	let outgoing: UUID?
	let incoming: UUID?
	let quickFade: Bool
	let returnTime: CMTime
	var clips: Set<UUID>? = nil
	var existingID: UUID? = nil
	var between: Bool { outgoing != nil && incoming != nil }
}

struct TransitionEditorView: View {
	let project: EditingProject
	let request: ProjectTransitionRequest
	let format: TimecodeFormat
	let formatTime: (CMTime) -> String
	let save: (EditingProject, String) throws -> Void
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var phase
	@StateObject private var preview = ProjectPlayback()
	@State private var style: TransitionStyle
	@State private var edge: ProjectTransition.Edge
	@State private var seconds: Double
	@State private var fadeIn: Bool
	@State private var fadeOut: Bool
	@State private var inSeconds: Double
	@State private var outSeconds: Double
	@State private var includeAudio: Bool
	@State private var equalPower: Bool
	@State private var ease: TransitionEase
	@State private var error: String?
	@State private var preparing = true
	@State private var removing = false
	@State private var loaded = false
	@State private var resume = false
	@State private var preparation: Task<Void, Never>?
	@State private var deadline: Task<Void, Never>?
	@State private var preparationID = UUID()
	@FocusState private var typing: Bool

	init(project: EditingProject, request: ProjectTransitionRequest, format: TimecodeFormat,
		formatTime: @escaping (CMTime) -> String, save: @escaping (EditingProject, String) throws -> Void) {
		self.project = project
		self.request = request
		self.format = format
		self.formatTime = formatTime
		self.save = save
		let effects = project.transitions ?? []
		let selected = effects.first { $0.id == request.existingID }
		let existing = effects.first { $0.trackID == request.track.id && $0.edge == .between && $0.outgoing == request.outgoing && $0.incoming == request.incoming }
		let intro = effects.first { $0.trackID == request.track.id && $0.edge == .intro && $0.incoming == (request.incoming ?? request.clip) }
		let outro = effects.first { $0.trackID == request.track.id && $0.edge == .outro && $0.outgoing == (request.outgoing ?? request.clip) }
		_style = State(initialValue: selected?.style ?? existing?.style ?? .crossDissolve)
		_edge = State(initialValue: selected?.edge ?? (request.between ? .between : .intro))
		_seconds = State(initialValue: selected?.seconds ?? existing?.seconds ?? Self.lastDuration(audio: request.track.kind == .audio))
		_fadeIn = State(initialValue: intro != nil || outro == nil)
		_fadeOut = State(initialValue: outro != nil || intro == nil)
		_inSeconds = State(initialValue: intro?.seconds ?? 1)
		_outSeconds = State(initialValue: outro?.seconds ?? 1)
		_includeAudio = State(initialValue: selected?.includeAudio ?? existing?.includeAudio ?? true)
		_equalPower = State(initialValue: selected?.equalPower ?? existing?.equalPower ?? false)
		_ease = State(initialValue: selected?.ease ?? existing?.ease ?? .linear)
	}
	static func lastDuration(audio: Bool, style: TransitionStyle = .crossDissolve) -> Double {
		let value = EditorPreferences.shared.double(forKey: (audio ? "audioTransitionDuration." : "videoTransitionDuration.") + style.rawValue)
		return value.isFinite && value > 0 ? value : 1
	}
	private var title: String { request.quickFade ? "Quick Fade" : "Transitions" }
	private var loadingTitle: LocalizedStringKey { request.quickFade ? "Preparing Quick Fade Preview" : "Preparing Transition Preview" }
	private var edits: [ProjectTransition] {
		if removing { return [] }
		func effect(_ edge: ProjectTransition.Edge, seconds: Double) -> ProjectTransition {
			ProjectTransition(trackID: request.track.id,
				outgoing: edge == .intro ? nil : (request.outgoing ?? request.clip),
				incoming: edge == .outro ? nil : (request.incoming ?? request.clip),
				edge: edge, style: edge == .between ? style : .fade, seconds: seconds,
				includeAudio: includeAudio, equalPower: equalPower, ease: ease)
		}
		if request.quickFade {
			if let clips = request.clips {
				return clips.flatMap { id in
					(fadeIn ? [ProjectTransition(trackID: request.track.id, incoming: id, edge: .intro, style: .fade, seconds: inSeconds, includeAudio: includeAudio, equalPower: equalPower, ease: ease)] : []) +
					(fadeOut ? [ProjectTransition(trackID: request.track.id, outgoing: id, edge: .outro, style: .fade, seconds: outSeconds, includeAudio: includeAudio, equalPower: equalPower, ease: ease)] : [])
				}
			}
			return (fadeIn ? [effect(.intro, seconds: inSeconds)] : []) + (fadeOut ? [effect(.outro, seconds: outSeconds)] : [])
		}
		return [effect(edge, seconds: seconds)]
	}
	private func manages(_ effect: ProjectTransition) -> Bool {
		if let id = request.existingID { return effect.id == id }
		guard effect.trackID == request.track.id else { return false }
		if request.quickFade {
			if let clips = request.clips {
				return effect.edge == .intro && effect.incoming.map(clips.contains) == true || effect.edge == .outro && effect.outgoing.map(clips.contains) == true
			}
			return effect.edge == .intro && effect.incoming == (request.incoming ?? request.clip) ||
				effect.edge == .outro && effect.outgoing == (request.outgoing ?? request.clip)
		}
		switch edge {
		case .between: return effect.edge == .between && effect.outgoing == request.outgoing && effect.incoming == request.incoming
		case .intro: return effect.edge == .intro && effect.incoming == request.clip
		case .outro: return effect.edge == .outro && effect.outgoing == request.clip
		}
	}
	private var draft: EditingProject {
		var next = project
		let old = project.transitions ?? []
		let additions = edits.map { edit in
			var copy = edit
			copy.id = request.existingID ?? old.first { $0.trackID == edit.trackID && $0.edge == edit.edge && $0.outgoing == edit.outgoing && $0.incoming == edit.incoming }?.id ?? UUID()
			return copy
		}
		next.transitions = old.filter { !manages($0) } + additions
		return next
	}
	// Use settings as the preparation key, independent of generated transition IDs.
	private var parameterKey: String {
		"\(style.rawValue)/\(edge.rawValue)/\(seconds)/\(fadeIn)/\(fadeOut)/\(inSeconds)/\(outSeconds)/\(includeAudio)/\(equalPower)/\(ease.rawValue)"
	}
	private var settingsKey: String { parameterKey + "/\(removing)" }

	var body: some View {
		NavigationStack {
			Group {
				if preparing && !loaded {
					LoadingStatusView(loadingTitle, cancel: { stopPreparation(); dismiss() })
				} else {
					Form {
						if let error {
							Section {
								Text(error)
								Button("Retry Preview", action: startPreparation)
							}
						}
						Section {
							if request.track.kind == .video {
								ProjectPreview(player: preview.player)
									.aspectRatio(CGFloat(project.picture?.width ?? 16) / CGFloat(project.picture?.height ?? 9), contentMode: .fit)
							}
							ProjectTimelineSlider(playhead: preview.playhead, playback: preview, duration: project.duration,
								points: project.editPoints(on: request.track), frame: project.frame, format: format, formatTime: formatTime)
								.disabled(!preview.ready || preparing)
							Button { preview.toggle() } label: {
								Label(preview.transport.playing ? "Pause" : "Play", systemImage: preview.transport.playing ? "pause.fill" : "play.fill")
									.labelStyle(.iconOnly).editorTouchRow()
							}.disabled(!preview.ready || preparing)
							if preparing { ProgressView(loadingTitle) }
						}
						if request.quickFade {
							Toggle("Fade In", isOn: $fadeIn)
							if fadeIn { duration("Fade In Duration in Seconds", value: $inSeconds) }
							Toggle("Fade Out", isOn: $fadeOut)
							if fadeOut { duration("Fade Out Duration in Seconds", value: $outSeconds) }
						} else {
							if !request.between {
								Picker("Position", selection: $edge) {
									Text("Fade In").tag(ProjectTransition.Edge.intro)
									Text("Fade Out").tag(ProjectTransition.Edge.outro)
								}
							} else {
								Picker("Transition", selection: $style) {
									ForEach(TransitionStyle.allCases.filter { $0 != .fade && (request.track.kind == .video || [.crossDissolve, .fadeOutIn].contains($0)) }) { style in
										Text(style == .crossDissolve && request.track.kind == .audio ? "Cross Fade" : style.title).tag(style)
									}
								}
								if style.supportsEase {
									Picker("Easing", selection: $ease) {
										ForEach(TransitionEase.allCases, id: \.self) { Text($0.rawValue).tag($0) }
									}
								}
							}
							duration("Duration in Seconds", value: $seconds)
						}
						if request.track.kind == .video { Toggle(request.quickFade ? "Fade Audio" : "Crossfade Audio", isOn: $includeAudio) }
						if request.track.kind == .audio || includeAudio {
							Picker("Audio Curve", selection: $equalPower) {
								Text("Linear").tag(false)
								Text("Equal Power").tag(true)
							}
						}
						if (project.transitions ?? []).contains(where: manages) {
							Button("Remove Transition", role: .destructive) { removing = true }
								.disabled(removing)
						}
					}
					.editorListMargins()
				}
			}
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				if !preparing || loaded {
					ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stopPreparation(); dismiss() } }
				}
				ToolbarItem(placement: .principal) { Text(title).accessibilityAddTraits(.isHeader) }
				if !preparing || loaded {
					ToolbarItem(placement: .confirmationAction) {
						Button("Save", action: commit).disabled(preparing || error != nil || !preview.ready)
					}
				}
			}
			.dismissKeyboardToolbar(while: typing) { typing = false }
		}
		.editorAppearance()
		.accessibilityAction(.magicTap) { if !preparing { preview.toggle() } }
		.task(id: settingsKey) { startPreparation() }
		.onChange(of: preview.ready) {
			if preview.ready {
				deadline?.cancel()
				deadline = nil
				loaded = true
				preparing = false
				if resume { preview.toggle(); resume = false }
			}
		}
		.onChange(of: parameterKey) { removing = false }
		.onChange(of: style) { _, style in
			removing = false
			let saved = (project.transitions ?? []).first { manages($0) && $0.style == style }
			seconds = saved?.seconds ?? Self.lastDuration(audio: request.track.kind == .audio, style: style)
		}
		.onChange(of: preview.failure) {
			if let failure = preview.failure {
				stopPreparation()
				error = failure
				preparing = false
			}
		}
		.onChange(of: phase) { if phase != .active { preview.pause(); resume = false } }
		.onDisappear { stopPreparation() }
	}
	private func duration(_ label: String, value: Binding<Double>) -> some View {
		TextField("", value: value, format: .number)
			.keyboardType(.decimalPad).focused($typing).editorFieldLabel(label)
	}
	private func stopPreparation() {
		preparationID = UUID()
		preparation?.cancel()
		preparation = nil
		deadline?.cancel()
		deadline = nil
		resume = false
		preview.cancelPreparation()
		preview.pause()
	}
	private func startPreparation() {
		let wasPlaying = preview.transport.playing
		stopPreparation()
		let id = preparationID
		preparing = true
		error = nil
		preparation = Task { await prepare(id: id, wasPlaying: wasPlaying) }
		deadline = Task { @MainActor in
			do { try await Task.sleep(for: .seconds(30)) }
			catch { return }
			guard preparationID == id, preparing else { return }
			stopPreparation()
			let failure = ProjectFailure("Could not prepare the preview in time. Choose Retry Preview, or close this screen and reopen the project.")
			preview.failPreparation(failure)
			error = failure.localizedDescription
			preparing = false
		}
	}
	private func prepare(id: UUID, wasPlaying: Bool) async {
		let ranges = edits.compactMap { $0.range(in: project) }
		let first = ranges.map(\.start).min() ?? request.returnTime
		let last = ranges.map(\.end).max() ?? request.returnTime
		let start = max(.zero, first - CMTime(seconds: 0.5, preferredTimescale: 600000))
		let end = min(project.duration, last + CMTime(seconds: 0.5, preferredTimescale: 600000))
		let position = preview.ready ? preview.position : start
		preview.pause()
		preparing = true
		do {
			try await Task.sleep(for: .milliseconds(250))
			let candidate = draft
			try candidate.validateTransitions()
			error = nil
			resume = wasPlaying
			preview.playhead.position = position
			await preview.prepare(candidate, audition: request.track)
			try Task.checkCancellation()
			guard preparationID == id else { return }
			if end > start { preview.setMixerLoop(CMTimeRange(start: start, end: end)) }
		} catch {
			guard !Task.isCancelled, preparationID == id else { return }
			deadline?.cancel()
			deadline = nil
			resume = false
			self.error = error.localizedDescription
			preparing = false
		}
	}
	private func commit() {
		do {
			let next = draft
			try next.validateTransitions()
			preview.pause()
			try save(next, removing ? "Remove Transition" : "Apply " + title)
			if !request.quickFade, edge == .between {
				EditorPreferences.shared.set(seconds, forKey: (request.track.kind == .audio ? "audioTransitionDuration." : "videoTransitionDuration.") + style.rawValue)
			}
			dismiss()
		} catch { self.self.error = error.localizedDescription }
	}
}
