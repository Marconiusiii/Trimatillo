import CoreMedia
import Foundation

nonisolated struct CaptionCue: Identifiable, Codable, Equatable, Sendable {
	var id = UUID()
	var start: ProjectTime
	var end: ProjectTime
	var text: String
	var isDraft = true

	func validated() throws -> Self {
		guard start.time.isNumeric, start.time >= .zero, end.time.isNumeric, end.time > start.time else {
			throw ProjectFailure("Set In before Out and choose New Caption again.")
		}
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw ProjectFailure("Enter caption text.")
		}
		return self
	}
}

nonisolated enum CaptionFileFormat {
	case subRip, webVTT
}

extension EditingProject {
	var captionRange: CMTimeRange? {
		guard let start = markIn?.time, let end = markOut?.time, start < end, end <= duration else { return nil }
		return CMTimeRange(start: start, end: end)
	}

	func captionPoint(from position: CMTime, forward: Bool) -> (time: CMTime, name: String) {
		let cues = captions ?? []
		let times = [.zero, duration] + [markIn?.time, markOut?.time].compactMap { $0 } + cues.map { $0.start.time }
		let time = forward ? times.filter { $0 > position && $0 <= duration }.min() ?? duration : times.filter { $0 < position }.max() ?? .zero
		if time == .zero { return (time, "Start") }
		if time == duration { return (time, "End") }
		if time == markIn?.time { return (time, "In") }
		if time == markOut?.time { return (time, "Out") }
		return (time, "Caption: " + (cues.first { $0.start.time == time }?.text ?? ""))
	}
}
