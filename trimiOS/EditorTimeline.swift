import AVFoundation

nonisolated enum EditorTimeline: Identifiable, Equatable {
	case media(TimelineTrack)
	case captions
	case descriptions(DescriptionTimeline)

	var id: String {
		switch self {
		case .media(let track): track.id
		case .captions: "editor-captions"
		case .descriptions(let type): "editor-" + type.rawValue
		}
	}
	var title: String {
		switch self {
		case .media(let track): track.title
		case .captions: "Captions"
		case .descriptions(let type): type.rawValue
		}
	}
	var mediaTrack: TimelineTrack? {
		if case .media(let track) = self { return track }
		return nil
	}
}

extension EditingProject {
	var editorTimelines: [EditorTimeline] {
		tracks.map(EditorTimeline.media) + [.captions, .descriptions(.audio), .descriptions(.transcript)]
	}
	func editorRows(_ timeline: EditorTimeline) -> [DescriptionRow] {
		switch timeline {
		case .media: return []
		case .captions:
			return (captions ?? []).sorted { $0.start.time < $1.start.time }.map {
				DescriptionRow(id: $0.id, name: $0.text, start: $0.start.time, end: $0.end.time)
			}
		case .descriptions(let type): return descriptionRows(type)
		}
	}
	func editorPoints(_ timeline: EditorTimeline) -> [CMTime] {
		if let track = timeline.mediaTrack { return editPoints(on: track) }
		return (editorRows(timeline).flatMap { [$0.start, $0.end] } + [.zero, duration] + [markIn?.time, markOut?.time].compactMap { $0 })
			.filter { $0 >= .zero && $0 <= duration }
	}
	func editorPoint(_ timeline: EditorTimeline, from position: CMTime, forward: Bool) -> (time: CMTime, name: String) {
		if let track = timeline.mediaTrack { return navigationPoint(from: position, forward: forward, on: track) }
		let points = editorPoints(timeline)
		let target = forward ? points.filter { $0 > position }.min() ?? duration : points.filter { $0 < position }.max() ?? .zero
		let rows = editorRows(timeline)
		var names = rows.filter { $0.end == target }.map { "End of " + $0.name }
		names += rows.filter { $0.start == target }.map { "Start of " + $0.name }
		if target == .zero { names.insert("Start", at: 0) }
		if target == duration { names.append("End") }
		if target == markIn?.time { names.append("In") }
		if target == markOut?.time { names.append("Out") }
		return (target, names.joined(separator: ", "))
	}
}
