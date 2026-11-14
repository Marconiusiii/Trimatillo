import AVFoundation
import Foundation

nonisolated struct ProjectTime: Codable, Equatable {
	let value: Int64
	let scale: Int32

	init(_ time: CMTime) {
		value = time.value
		scale = time.timescale
	}

	var time: CMTime { CMTime(value: value, timescale: scale) }
}

nonisolated struct ProjectRange: Codable, Equatable {
	let start: ProjectTime
	let length: ProjectTime

	init(_ range: CMTimeRange) {
		start = ProjectTime(range.start)
		length = ProjectTime(range.duration)
	}

	var range: CMTimeRange { CMTimeRange(start: start.time, duration: length.time) }
}

nonisolated enum ProjectTrack: String, Codable, CaseIterable {
	case video = "Video"
	case audio = "Audio"
}

nonisolated struct TimelineTrack: Identifiable, Codable, Equatable {
	let id: String
	let kind: ProjectTrack
	let name: String

	static let primaryVideo = TimelineTrack(id: "Video", kind: .video, name: "Primary Video")
	static let primaryAudio = TimelineTrack(id: "Audio", kind: .audio, name: "Primary Audio Track")
	var title: String { id == kind.rawValue ? name : name + " " + kind.rawValue + " Track" }
}

nonisolated enum PlacementMode { case append, split, overwrite, update }

nonisolated struct ProjectPlacement: Identifiable, Codable, Equatable {
	var id = UUID()
	let sourceID: UUID
	var track: ProjectTrack
	var additionalTrack: String?
	var omitAudio: Bool?
	var trackID: String { additionalTrack ?? track.rawValue }
	var start: ProjectTime
	var ranges: [ProjectRange]
	var duration: CMTime { ranges.reduce(.zero) { $0 + $1.length.time } }
	var end: CMTime { start.time + duration }
}

nonisolated struct ProjectPicture: Codable, Equatable {
	var width: Int
	var height: Int
	var frame: ProjectTime
}

nonisolated struct EditingProject: Identifiable, Codable, Equatable {
	var id = UUID()
	var version = 1
	var name: String
	var picture: ProjectPicture?
	var targetSeconds: Double?
	var sources: [ProjectMediaSource] = []
	var placements: [ProjectPlacement] = []
	var additionalTracks: [TimelineTrack]?
	var trackVolumes: [String: Float]?
	var tracks: [TimelineTrack] {
		let extra = additionalTracks ?? []
		return extra.filter { $0.kind == .video }.reversed() + [.primaryVideo, .primaryAudio] + extra.filter { $0.kind == .audio }
	}
	var markIn: ProjectTime?
	var markOut: ProjectTime?

	var duration: CMTime { placements.map(\.end).max() ?? .zero }
	var frame: CMTime { picture?.frame.time ?? CMTime(value: 1, timescale: 30) }

	func clips(on track: TimelineTrack) -> [ProjectPlacement] {
		placements.filter { $0.trackID == track.id }.sorted { $0.start.time < $1.start.time }
	}

	mutating func createTrack(_ name: String, kind: ProjectTrack) throws -> TimelineTrack {
		let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { throw ProjectFailure("Enter a track name.") }
		let track = TimelineTrack(id: UUID().uuidString, kind: kind, name: name)
		guard !tracks.contains(where: { $0.title.localizedCaseInsensitiveCompare(track.title) == .orderedSame }) else {
			throw ProjectFailure("Choose another name for this track.")
		}
		additionalTracks = (additionalTracks ?? []) + [track]
		return track
	}

	mutating func place(_ source: ProjectMediaSource, ranges: [CMTimeRange], at start: CMTime,
		on track: TimelineTrack, mode: PlacementMode, replacing id: UUID? = nil, omitAudio: Bool = false) throws {
		guard tracks.contains(track), track.kind == (source.picture == nil ? .audio : .video), start >= .zero,
			!ranges.isEmpty, ranges.allSatisfy({ $0.isValid && $0.start >= .zero && $0.duration > .zero && $0.end <= source.duration.time }) else {
			throw ProjectFailure("Choose a compatible track and a valid clip range.")
		}
		let clip = ProjectPlacement(id: id ?? UUID(), sourceID: source.id, track: track.kind,
			additionalTrack: track.id == track.kind.rawValue ? nil : track.id, omitAudio: omitAudio,
			start: ProjectTime(start), ranges: ranges.map(ProjectRange.init))
		if mode == .update {
			guard placements.contains(where: { $0.id == id }) else { throw ProjectFailure("Reopen the timeline clip to save its edits.") }
		}
		if mode == .update || mode == .append {
			guard !clips(on: track).contains(where: { $0.id != id && $0.end > start && $0.start.time < clip.end }) else {
				throw ProjectFailure("The edit overlaps another clip. Use Add at Playhead to split or overwrite.")
			}
			placements.removeAll { $0.id == id }
		} else {
			placements = placements.flatMap { existing -> [ProjectPlacement] in
				guard existing.trackID == track.id, existing.end > start else { return [existing] }
				if mode == .overwrite && existing.start.time >= clip.end { return [existing] }
				if mode == .split && existing.start.time >= start {
					var later = existing
					later.start = ProjectTime(existing.start.time + clip.duration)
					return [later]
				}
				let left = existing.slice(from: existing.start.time, to: start)
				let rightStart = mode == .split ? start : clip.end
				var right = existing.slice(from: rightStart, to: existing.end)
				if left != nil { right?.id = UUID() }
				if mode == .split { right?.start = ProjectTime(clip.end) }
				return [left, right].compactMap { $0 }
			}
		}
		placements.append(clip)
		if picture == nil { picture = source.picture }
	}

	mutating func move(_ ids: Set<UUID>, to track: TimelineTrack, beside anchor: UUID?, after: Bool) throws {
		let moving = placements.filter { ids.contains($0.id) }.sorted {
			if $0.start.time != $1.start.time { return $0.start.time < $1.start.time }
			return $0.trackID < $1.trackID
		}
		guard !moving.isEmpty, moving.count == ids.count, moving.allSatisfy({ $0.track == track.kind }),
			anchor.map({ !ids.contains($0) }) ?? true else { throw ProjectFailure("Choose a different clip on a compatible track.") }
		let original = clips(on: track)
		let lifted = moving.filter { $0.trackID == track.id }
		let destination = original.filter { !ids.contains($0.id) }.map { item in
			var clip = item
			let removed = lifted.filter { $0.end <= item.start.time }.reduce(CMTime.zero) { $0 + $1.duration }
			clip.start = ProjectTime(item.start.time - removed)
			return clip
		}
		let start: CMTime
		if let anchor {
			guard let clip = destination.first(where: { $0.id == anchor }) else { throw ProjectFailure("Choose a clip on the destination track.") }
			start = after ? clip.end : clip.start.time
		} else { start = destination.last?.end ?? .zero }
		placements.removeAll { ids.contains($0.id) || $0.trackID == track.id }
		placements.append(contentsOf: destination)
		var cursor = start
		for var clip in moving {
			clip.additionalTrack = track.id == track.kind.rawValue ? nil : track.id
			clip.start = ProjectTime(cursor)
			placements.append(clip)
			cursor = clip.end
		}
		for var clip in destination where clip.start.time >= start {
			if clip.start.time >= cursor { break }
			clip.start = ProjectTime(cursor)
			if let index = placements.firstIndex(where: { $0.id == clip.id }) { placements[index] = clip }
			cursor = clip.end
		}
	}
}

extension ProjectPlacement {
	nonisolated func slice(from start: CMTime, to end: CMTime) -> Self? {
		let from = max(start, self.start.time)
		let to = min(end, self.end)
		guard to > from else { return nil }
		var clip = self
		let timeline = ClipEditTimeline(sourceRanges: ranges.map(\.range))
		let portion = CMTimeRange(start: from - self.start.time, duration: to - from)
		clip.ranges = timeline.sourceRanges(in: portion).map(ProjectRange.init)
		clip.start = ProjectTime(from)
		return clip
	}
}

nonisolated struct ProjectFailure: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

enum ProjectLibrary {
	static let directory = URL.documentsDirectory.appendingPathComponent("Projects", isDirectory: true)

	static func load(_ url: URL) throws -> EditingProject {
		let project = try JSONDecoder().decode(EditingProject.self, from: Data(contentsOf: url))
		guard (1...2).contains(project.version) else { throw ProjectFailure("Update Trimatillo to open this project.") }
		return project
	}

	static func savedFiles() throws -> [URL] {
		guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
		return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "json" }
	}

	static func save(_ project: EditingProject, replacing previous: EditingProject? = nil) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appending(component: project.id.uuidString + ".json")
		if let previous, try load(url) != previous {
			throw ProjectFailure("This project changed in another window. Close and reopen it before editing.")
		}
		try JSONEncoder().encode(project).write(to: url, options: .atomic)
	}
}
