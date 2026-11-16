import AVFoundation
import Foundation
import Darwin

nonisolated struct ProjectTime: Codable, Equatable {
	let value: Int64
	let scale: Int32

	init(_ time: CMTime) {
		value = time.value
		scale = time.timescale
	}

	init(seconds: Double) { self.init(CMTime(seconds: seconds, preferredTimescale: 600000)) }
	var seconds: Double { time.seconds }
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
	var linkedVideoID: String?

	var videoPartnerID: String? { self == .primaryAudio ? TimelineTrack.primaryVideo.id : linkedVideoID }

	static let primaryVideo = TimelineTrack(id: "Video", kind: .video, name: "Primary Video")
	static let primaryAudio = TimelineTrack(id: "Audio", kind: .audio, name: "Primary Audio Track")
	var title: String { id == kind.rawValue ? name : name + " " + kind.rawValue + " Track" }
}

nonisolated enum PlacementMode { case append, split, overwrite, update }

nonisolated struct ProjectPlacement: Identifiable, Codable, Equatable {
	var id = UUID()
	let sourceID: UUID
	var labelIndex: Int?
	var track: ProjectTrack
	var additionalTrack: String?
	var omitAudio: Bool?
	var trackID: String { additionalTrack ?? track.rawValue }
	var start: ProjectTime
	var ranges: [ProjectRange]
	func displayName(for source: ProjectMediaSource) -> String {
		guard var index = labelIndex, index >= 0 else { return source.displayName }
		var letters = ""
		repeat {
			letters = String(UnicodeScalar(65 + index % 26)!) + letters
			index = index / 26 - 1
		} while index >= 0
		return source.displayName + " " + letters
	}

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
	var matchesMedia: Bool?
	var targetSeconds: Double?
	var sources: [ProjectMediaSource] = []
	var placements: [ProjectPlacement] = []
	var additionalTracks: [TimelineTrack]?
	var trackVolumes: [String: Float]?
	var tracks: [TimelineTrack] {
		let extra = additionalTracks ?? []
		return extra.filter { $0.kind == .video }.reversed() + [.primaryVideo, .primaryAudio] + extra.filter { $0.kind == .audio }
	}
	var captions: [CaptionCue]?
	var markIn: ProjectTime?
	var markOut: ProjectTime?

	var duration: CMTime { placements.map(\.end).max() ?? .zero }
	var frame: CMTime { picture?.frame.time ?? CMTime(value: 1, timescale: 30) }

	func clips(on track: TimelineTrack) -> [ProjectPlacement] {
		placements.filter { $0.trackID == track.id }.sorted { $0.start.time < $1.start.time }
	}

	func displayedClips(on track: TimelineTrack) -> [ProjectPlacement] {
		guard let videoID = track.videoPartnerID else { return clips(on: track) }
		let sourcesWithAudio = Set(sources.filter(\.hasAudio).map(\.id))
		return placements.filter { clip in
			clip.trackID == track.id || (clip.trackID == videoID &&
				clip.omitAudio != true && sourcesWithAudio.contains(clip.sourceID))
		}.sorted { $0.start.time < $1.start.time }
	}

	func navigationPoint(from position: CMTime, forward: Bool, on track: TimelineTrack) -> (time: CMTime, name: String) {
		let clips = displayedClips(on: track)
		let end = duration
		let boundaries = [.zero, end] + [markIn?.time, markOut?.time].compactMap { $0 } +
			clips.flatMap { [$0.start.time, $0.end] }
		let time = forward ? boundaries.filter { $0 > position }.min() ?? end :
			boundaries.filter { $0 < position }.max() ?? .zero
		if time == .zero { return (time, "Start") }
		if time == end { return (time, "End") }
		if time == markIn?.time { return (time, "In") }
		if time == markOut?.time { return (time, "Out") }
		let kind = track.kind.rawValue + " edit point"
		// At a shared cut the incoming clip supplies the name in both directions.
		guard let clip = clips.first(where: { $0.start.time == time }) ?? clips.first(where: { $0.end == time }),
			let source = sources.first(where: { $0.id == clip.sourceID }) else { return (time, kind) }
		return (time, kind + ": " + clip.displayName(for: source))
	}

	mutating func assignPlacementLabels() {
		let groups = Dictionary(grouping: placements.indices, by: { placements[$0].sourceID })
		for indices in groups.values where indices.count > 1 {
			var used = Set(indices.compactMap { placements[$0].labelIndex })
			var next = 0
			for index in indices where placements[index].labelIndex == nil {
				while used.contains(next) { next += 1 }
				placements[index].labelIndex = next
				used.insert(next)
			}
		}
	}

	func audioPartner(for videoID: String) -> TimelineTrack? {
		tracks.first { $0.videoPartnerID == videoID }
	}

	private mutating func ensureAudioPartner(for track: TimelineTrack) {
		guard track.kind == .video, audioPartner(for: track.id) == nil else { return }
		let existing = tracks
		var name = track.name
		var number = 2
		while existing.contains(where: { $0.kind == .audio && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
			name = track.name + " " + String(number)
			number += 1
		}
		let partner = TimelineTrack(id: "audio-" + track.id, kind: .audio, name: name, linkedVideoID: track.id)
		additionalTracks = (additionalTracks ?? []) + [partner]
	}

	fileprivate mutating func restoreAudioPartners() {
		let audibleSources = Set(sources.filter(\.hasAudio).map(\.id))
		let videoIDs = Set(placements.filter { $0.track == .video && $0.omitAudio != true && audibleSources.contains($0.sourceID) }.map(\.trackID))
		for track in tracks where videoIDs.contains(track.id) { ensureAudioPartner(for: track) }
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
		let clip = ProjectPlacement(id: id ?? UUID(), sourceID: source.id,
			labelIndex: id.flatMap { id in placements.first(where: { $0.id == id })?.labelIndex }, track: track.kind,
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
				if left != nil {
					right?.id = UUID()
					right?.labelIndex = nil
				}
				if mode == .split { right?.start = ProjectTime(clip.end) }
				return [left, right].compactMap { $0 }
			}
		}
		placements.append(clip)
		if source.hasAudio && !omitAudio { ensureAudioPartner(for: track) }
		assignPlacementLabels()
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
		if track.kind == .video, moving.contains(where: { clip in
			clip.omitAudio != true && sources.contains { $0.id == clip.sourceID && $0.hasAudio }
		}) { ensureAudioPartner(for: track) }
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

nonisolated enum ProjectLibrary {
	static let directory = URL.documentsDirectory.appendingPathComponent("Projects", isDirectory: true)

	// Projects store edit decisions and references, never the media payload.
	private static let maximumBytes = 32 * 1024 * 1024

	private static func data(at url: URL) throws -> Data {
		let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
		guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
		let handle = try FileHandle(forReadingFrom: url)
		defer { try? handle.close() }
		let size = try handle.seekToEnd()
		guard size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
		try handle.seek(toOffset: 0)
		let data = try handle.read(upToCount: Int(size) + 1) ?? Data()
		guard data.count == size else { throw CocoaError(.fileReadCorruptFile) }
		return data
	}

	static func name(at url: URL) throws -> String {
		struct Header: Decodable { let name: String }
		return try JSONDecoder().decode(Header.self, from: data(at: url)).name
	}

	static func load(_ url: URL) throws -> EditingProject {
		var project = try JSONDecoder().decode(EditingProject.self, from: data(at: url))
		guard (1...4).contains(project.version) else { throw ProjectFailure("Update Trimatillo to open this project.") }
		try validate(project)
		if project.version < 3 { project.restoreAudioPartners() }
		project.assignPlacementLabels()
		return project
	}

	private static func validate(_ project: EditingProject) throws {
		let corrupt = CocoaError(.fileReadCorruptFile)
		func validTime(_ time: ProjectTime) -> Bool {
			time.scale > 0 && time.value >= 0 && time.time.seconds * 48000 < Double(Int64.max)
		}
		func validPicture(_ picture: ProjectPicture) -> Bool {
			(1...16384).contains(picture.width) && (1...16384).contains(picture.height)
				&& validTime(picture.frame) && picture.frame.value > 0
		}
		if let picture = project.picture, !validPicture(picture) { throw corrupt }
		if let target = project.targetSeconds, !target.isFinite || target <= 0 { throw corrupt }
		var sources = [UUID: ProjectMediaSource]()
		for source in project.sources {
			guard sources.updateValue(source, forKey: source.id) == nil, validTime(source.duration),
				source.duration.value > 0, source.picture.map(validPicture) ?? source.hasAudio else { throw corrupt }
		}
		var tracks = [String: ProjectTrack]()
		for track in project.tracks {
			guard tracks.updateValue(track.kind, forKey: track.id) == nil else { throw corrupt }
		}
		var pairedVideos: Set<String> = [TimelineTrack.primaryVideo.id]
		for track in project.additionalTracks ?? [] {
			if let videoID = track.linkedVideoID {
				guard track.kind == .audio, tracks[videoID] == .video, pairedVideos.insert(videoID).inserted else { throw corrupt }
			}
		}
		for (id, volume) in project.trackVolumes ?? [:] {
			guard tracks[id] != nil, (0...1).contains(volume) else { throw corrupt }
		}
		var ids = Set<UUID>()
		for clip in project.placements {
			guard ids.insert(clip.id).inserted, let source = sources[clip.sourceID],
				tracks[clip.trackID] == clip.track, clip.track == (source.picture == nil ? .audio : .video),
				validTime(clip.start), !clip.ranges.isEmpty else { throw corrupt }
			for range in clip.ranges {
				guard validTime(range.start), validTime(range.length), range.length.value > 0,
					range.range.end.isNumeric, range.range.end <= source.duration.time else { throw corrupt }
			}
			let end = clip.end
			guard end.isNumeric, end.seconds * 48000 < Double(Int64.max),
				end.seconds / project.frame.seconds < Double(Int64.max) else { throw corrupt }
		}
		let duration = project.duration
		var cueIDs = Set<UUID>()
		for cue in project.captions ?? [] {
			guard cueIDs.insert(cue.id).inserted, validTime(cue.start), validTime(cue.end),
				cue.end.time > cue.start.time, !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw corrupt }
		}
		for marker in [project.markIn, project.markOut].compactMap({ $0 }) {
			guard validTime(marker), marker.time <= duration else { throw corrupt }
		}
	}

	static func savedFiles() throws -> [URL] {
		guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
		return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "json" }
	}

	@MainActor static func delete(_ url: URL) throws {
		guard url.isFileURL, url.pathExtension == "json",
			url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
			throw CocoaError(.fileWriteNoPermission)
		}
		// Unlink only this directory entry, even if it was replaced since the list loaded.
		try url.withUnsafeFileSystemRepresentation { path in
			guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
			guard unlink(path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
		}
	}

	@MainActor static func save(_ project: EditingProject, replacing previous: EditingProject? = nil) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appending(component: project.id.uuidString + ".json")
		if let previous, try load(url) != previous {
			throw ProjectFailure("This project changed in another window. Close and reopen it before editing.")
		}
		let data = try JSONEncoder().encode(project)
		guard data.count <= maximumBytes else { throw ProjectFailure("This project is too large to save. Continue in a new project.") }
		try data.write(to: url, options: .atomic)
	}
}
