import AVFoundation

nonisolated enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
	case fade, crossDissolve, fadeOutIn, fadeThroughWhite
	case wipeLeft, wipeRight, wipeUp, wipeDown
	case slideLeft, slideRight, slideUp, slideDown
	case coverLeft, coverRight, coverUp, coverDown
	case revealLeft, revealRight, revealUp, revealDown
	case circleOpen, circleClose, pixelDissolve
	var id: String { rawValue }
	var title: String {
		switch self {
		case .fade: "Fade"
		case .crossDissolve: "Cross Dissolve"
		case .fadeOutIn: "Fade Out/Fade In"
		case .fadeThroughWhite: "Fade Through White"
		case .wipeLeft: "Wipe Left"
		case .wipeRight: "Wipe Right"
		case .wipeUp: "Wipe Up"
		case .wipeDown: "Wipe Down"
		case .slideLeft: "Slide Left"
		case .slideRight: "Slide Right"
		case .slideUp: "Slide Up"
		case .slideDown: "Slide Down"
		case .coverLeft: "Cover Left"
		case .coverRight: "Cover Right"
		case .coverUp: "Cover Up"
		case .coverDown: "Cover Down"
		case .revealLeft: "Reveal Left"
		case .revealRight: "Reveal Right"
		case .revealUp: "Reveal Up"
		case .revealDown: "Reveal Down"
		case .circleOpen: "Circle Open"
		case .circleClose: "Circle Close"
		case .pixelDissolve: "Pixel Dissolve"
		}
	}
	var extendsMedia: Bool { self != .fade && self != .fadeOutIn && self != .fadeThroughWhite }
	var supportsEase: Bool { extendsMedia && self != .crossDissolve && self != .pixelDissolve }
}

nonisolated enum TransitionEase: String, Codable, CaseIterable {
	case linear = "Linear", easeIn = "Ease In", easeOut = "Ease Out", easyEase = "Easy Ease"
	func progress(_ value: Double) -> Double {
		switch self {
		case .linear: value
		case .easeIn: 1 - pow(1 - value, 2)
		case .easeOut: value * value
		case .easyEase: value * value * (3 - 2 * value)
		}
	}
}

nonisolated struct ProjectTransition: Codable, Equatable, Identifiable {
	enum Edge: String, Codable, CaseIterable { case intro, outro, between }
	var id = UUID()
	var trackID: String
	var outgoing: UUID?
	var incoming: UUID?
	var edge: Edge
	var style: TransitionStyle = .crossDissolve
	var seconds = 1.0
	var includeAudio = true
	var equalPower = false
	var ease = TransitionEase.linear

	func title(audio: Bool) -> String {
		if edge == .intro { return "Fade In" }
		if edge == .outro { return "Fade Out" }
		return audio && style == .crossDissolve ? "Cross Fade" : style.title
	}
	func clips(in project: EditingProject) -> [ProjectPlacement] {
		guard let track = project.tracks.first(where: { $0.id == trackID }) else { return [] }
		return project.displayedClips(on: track)
	}
	func range(in project: EditingProject) -> CMTimeRange? {
		let clips = clips(in: project)
		let leading = clips.first { $0.id == outgoing }
		let trailing = clips.first { $0.id == incoming }
		let length = CMTime(seconds: seconds, preferredTimescale: 600000)
		switch edge {
		case .intro: return trailing.map { .init(start: $0.start.time, duration: length) }
		case .outro: return leading.map { .init(start: $0.end - length, duration: length) }
		case .between:
			guard let leading, let trailing, leading.end == trailing.start.time else { return nil }
			return .init(start: leading.end - CMTimeMultiplyByFloat64(length, multiplier: 0.5), duration: length)
		}
	}
	func validate(in project: EditingProject) throws {
		let correctClips: Bool
		switch edge {
		case .between: correctClips = outgoing != nil && incoming != nil && outgoing != incoming
		case .intro: correctClips = outgoing == nil && incoming != nil
		case .outro: correctClips = outgoing != nil && incoming == nil
		}
		guard correctClips, seconds.isFinite, seconds > 0, let track = project.tracks.first(where: { $0.id == trackID }),
			let range = range(in: project), range.start >= .zero, range.end <= project.duration,
			track.kind == .video || [.fade, .crossDissolve, .fadeOutIn].contains(style),
			(edge == .between) == (style != .fade) else {
			throw ProjectFailure("Choose compatible clips and a positive transition duration.")
		}
		let clips = clips(in: project)
		for id in [outgoing, incoming].compactMap({ $0 }) {
			guard let clip = clips.first(where: { $0.id == id }),
				let source = project.sources.first(where: { $0.id == clip.sourceID }),
				clip.duration.seconds >= (edge == .between ? seconds / 2 : seconds) else {
				throw ProjectFailure("Shorten the transition or extend the clip in the Cutting Board.")
			}
			if edge == .between && style.extendsMedia {
				let available = id == outgoing ? source.duration.seconds - (clip.ranges.last?.range.end.seconds ?? source.duration.seconds) :
					(clip.ranges.first?.range.start.seconds ?? 0)
				guard available + 0.000001 >= seconds / 2 else {
					throw ProjectFailure("The clip needs more source audio or video beyond this cut. Shorten the transition or adjust the cut in the Cutting Board.")
				}
			}
		}
	}
}

extension EditingProject {
	nonisolated func transitions(for clip: ProjectPlacement, channel: String) -> [ProjectTransition] {
		(transitions ?? []).filter {
			($0.outgoing == clip.id || $0.incoming == clip.id) &&
			($0.trackID == channel || ($0.includeAudio && audioPartner(for: $0.trackID)?.id == channel))
		}
	}
	nonisolated func transitionMedia(for clip: ProjectPlacement, channel: String) -> (start: CMTime, ranges: [CMTimeRange]) {
		var ranges = clip.ranges.map(\.range)
		var start = clip.start.time
		for effect in transitions(for: clip, channel: channel) where effect.edge == .between && effect.style.extendsMedia {
			let half = CMTime(seconds: effect.seconds / 2, preferredTimescale: 600000)
			if effect.incoming == clip.id, let first = ranges.first {
				ranges[0] = CMTimeRange(start: first.start - half, end: first.end)
				start = start - half
			}
			if effect.outgoing == clip.id, let last = ranges.last {
				ranges[ranges.count - 1] = CMTimeRange(start: last.start, end: last.end + half)
			}
		}
		return (start, ranges)
	}
	nonisolated mutating func cleanTransitions() {
		let valid = (transitions ?? []).filter { (try? $0.validate(in: self)) != nil }
		transitions = valid.isEmpty ? nil : valid
	}
	nonisolated func validateTransitions() throws {
		var ids = Set<UUID>()
		var occupied: [(String, CMTimeRange)] = []
		for effect in transitions ?? [] {
			try effect.validate(in: self)
			guard ids.insert(effect.id).inserted, let range = effect.range(in: self) else { throw ProjectFailure("The project contains an invalid transition.") }
			var channels = [effect.trackID]
			if effect.includeAudio, let audio = audioPartner(for: effect.trackID) { channels.append(audio.id) }
			for channel in channels {
				guard !occupied.contains(where: { $0.0 == channel && $0.1.intersection(range).duration > .zero }) else {
					throw ProjectFailure("Shorten or remove the other transition before applying overlapping transitions on this track.")
				}
				occupied.append((channel, range))
			}
		}
	}
}
