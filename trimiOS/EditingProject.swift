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
	var isVoiceOver: Bool?

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
	var loudnessGain: Float?
	var generatorOverride: GeneratorDefinition?
	var compositing: ClipCompositing?
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
	var version = 12
	var name: String
	var picture: ProjectPicture?
	var matchesMedia: Bool?
	var targetSeconds: Double?
	var sources: [ProjectMediaSource] = []
	var placements: [ProjectPlacement] = []
	var additionalTracks: [TimelineTrack]?
	var magneticTracks: [String: Bool]?
	var trackStereo: [String: TrackStereoMix]?
	var transitions: [ProjectTransition]?
	var trackEffects: [String: TrackAudioEffects]?
	var trackVolumes: [String: Float]?
	var masterVolume: Float?
	var mutedTracks: Set<String>?
	static let maximumMixerLevel = Float(pow(10.0, 12.0 / 20.0))
	static let descriptionMixID = "audio-description"

	var mixerChannels: [MixerChannel] {
		var channels = tracks.filter { $0.kind == .audio }.map { MixerChannel(id: $0.id, title: $0.title) }
		if audioDescriptions?.isEmpty == false { channels.append(MixerChannel(id: Self.descriptionMixID, title: "Audio Description")) }
		return channels
	}
	var tracks: [TimelineTrack] {
		let extra = additionalTracks ?? []
		return extra.filter { $0.kind == .video }.reversed() + [.primaryVideo, .primaryAudio] + extra.filter { $0.kind == .audio }
	}
	var descriptiveTranscript: [TranscriptEntry]?
	var audioDescriptions: [DescriptionTake]?
	var descriptionDucking: DescriptionDucking?
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

	var voiceClips: [ProjectPlacement] {
		tracks.filter { $0.isVoiceOver == true }.flatMap { clips(on: $0) }
	}

	func editPoints(on track: TimelineTrack) -> [CMTime] { editPoints(for: displayedClips(on: track)) }

	func editPoints(for clips: [ProjectPlacement]) -> [CMTime] {
		[.zero, duration] + [markIn?.time, markOut?.time].compactMap { $0 } +
			clips.flatMap { [$0.start.time, $0.end] }
	}

	func navigationPoint(from position: CMTime, forward: Bool, on track: TimelineTrack, voiceOver: Bool = false) -> (time: CMTime, name: String) {
		let clips = voiceOver ? voiceClips : displayedClips(on: track)
		let end = duration
		let boundaries = editPoints(for: clips)
		let time = forward ? boundaries.filter { $0 > position }.min() ?? end :
			boundaries.filter { $0 < position }.max() ?? .zero
		if time == .zero { return (time, "Start") }
		if time == end { return (time, "End") }
		if time == markIn?.time { return (time, "In") }
		if time == markOut?.time { return (time, "Out") }
		let kind = (voiceOver ? "Voice Over" : track.kind.rawValue) + " edit point"
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

	func isMagnetic(_ track: TimelineTrack) -> Bool {
		magneticTracks?[track.id] ?? (track == .primaryVideo || track == .primaryAudio)
	}

	func needsPacking(_ track: TimelineTrack) -> Bool {
		var cursor = CMTime.zero
		for clip in clips(on: track) {
			if clip.start.time != cursor { return true }
			cursor = clip.end
		}
		return false
	}

	mutating func setMagnetic(_ enabled: Bool, on track: TimelineTrack) {
		var modes = magneticTracks ?? [:]
		modes[track.id] = enabled
		magneticTracks = modes
		if enabled {
			var cursor = CMTime.zero
			for index in placements.indices.filter({ placements[$0].trackID == track.id }).sorted(by: { placements[$0].start.time < placements[$1].start.time }) {
				placements[index].start = ProjectTime(cursor)
				cursor = placements[index].end
			}
		}
	}

	private mutating func shiftClips(on track: TimelineTrack, from time: CMTime, by amount: CMTime) {
		for index in placements.indices where placements[index].trackID == track.id && placements[index].start.time >= time {
			placements[index].start = ProjectTime(placements[index].start.time + amount)
		}
	}

	mutating func deleteSource(_ id: UUID) {
		removeClips(Set(placements.filter { $0.sourceID == id }.map(\.id)))
		sources.removeAll { $0.id == id }
	}

	mutating func removeClips(_ ids: Set<UUID>) {
		let removed = placements.filter { ids.contains($0.id) }.sorted { $0.start.time > $1.start.time }
		placements.removeAll { ids.contains($0.id) }
		for clip in removed {
			if let track = tracks.first(where: { $0.id == clip.trackID }), isMagnetic(track) {
				shiftClips(on: track, from: clip.end, by: .zero - clip.duration)
			}
		}
	}

	mutating func createTrack(_ name: String, kind: ProjectTrack, voiceOver: Bool? = nil) throws -> TimelineTrack {
		let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { throw ProjectFailure("Enter a track name.") }
		let track = TimelineTrack(id: UUID().uuidString, kind: kind, name: name, isVoiceOver: voiceOver)
		guard !tracks.contains(where: { $0.title.localizedCaseInsensitiveCompare(track.title) == .orderedSame }) else {
			throw ProjectFailure("Choose another name for this track.")
		}
		additionalTracks = (additionalTracks ?? []) + [track]
		return track
	}

	mutating func addVoiceOver(_ source: ProjectMediaSource, at start: CMTime) throws {
		let range = CMTimeRange(start: start, duration: source.duration.time)
		let track: TimelineTrack
		if let available = tracks.first(where: { track in
			track.isVoiceOver == true && !isMagnetic(track) && !clips(on: track).contains {
				$0.start.time < range.end && $0.end > start
			}
		}) {
			track = available
		} else {
			var number = 1
			var name = "Voice Over"
			while tracks.contains(where: { $0.kind == .audio && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
				number += 1
				name = "Voice Over " + String(number)
			}
			track = try createTrack(name, kind: .audio, voiceOver: true)
		}
		try place(source, ranges: [CMTimeRange(start: .zero, duration: source.duration.time)], at: start, on: track, mode: .append)
		sources.append(source)
	}

	mutating func place(_ source: ProjectMediaSource, ranges: [CMTimeRange], at start: CMTime,
		on track: TimelineTrack, mode: PlacementMode, replacing id: UUID? = nil, omitAudio: Bool = false) throws {
		guard tracks.contains(track), track.kind == (source.picture == nil ? .audio : .video), start >= .zero,
			!ranges.isEmpty, ranges.allSatisfy({ $0.isValid && $0.start >= .zero && $0.duration > .zero && $0.end <= source.duration.time }) else {
			throw ProjectFailure("Choose a compatible track and a valid clip range.")
		}
		var start = start
		if isMagnetic(track), mode == .split || mode == .overwrite {
			let existing = clips(on: track)
			if let first = existing.first, let last = existing.last {
				start = min(max(start, first.start.time), last.end)
			}
		}
		let previous = id.flatMap { placementID in placements.first { $0.id == placementID } }
		let clip = ProjectPlacement(id: id ?? UUID(), sourceID: source.id,
			labelIndex: previous?.labelIndex, track: track.kind,
			additionalTrack: track.id == track.kind.rawValue ? nil : track.id, omitAudio: omitAudio,
			loudnessGain: previous?.sourceID == source.id ? previous?.loudnessGain : nil,
			generatorOverride: previous?.generatorOverride, compositing: previous?.compositing,
			start: ProjectTime(start), ranges: ranges.map(ProjectRange.init))
		if mode == .update || mode == .append {
			let existing = clips(on: track)
			if mode == .update && isMagnetic(track) {
				guard let previous = existing.first(where: { $0.id == id }), previous.start.time == start else {
					throw ProjectFailure("Reopen the timeline clip before saving its edits.")
				}
				shiftClips(on: track, from: previous.end, by: clip.duration - previous.duration)
			} else {
				guard mode != .update || existing.contains(where: { $0.id == id }) else { throw ProjectFailure("Reopen the timeline clip to save its edits.") }
				guard !existing.contains(where: { $0.id != id && $0.end > start && $0.start.time < clip.end }) else {
					throw ProjectFailure("The edit overlaps another clip. Use Add at Playhead to split or overwrite.")
				}
			}
			placements.removeAll { $0.id == id }
		} else {
			makeRoom(for: clip, mode: mode)
		}
		placements.append(clip)
		if source.hasAudio && !omitAudio { ensureAudioPartner(for: track) }
		assignPlacementLabels()
		if picture == nil { picture = source.picture }
	}

	private mutating func makeRoom(for clip: ProjectPlacement, mode: PlacementMode) {
		let start = clip.start.time
		placements = placements.flatMap { existing -> [ProjectPlacement] in
			guard existing.trackID == clip.trackID, existing.end > start else { return [existing] }
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

	mutating func moveClip(_ id: UUID, to requested: CMTime, on track: TimelineTrack, exact: Bool) throws {
		guard var clip = placements.first(where: { $0.id == id }), track.kind == clip.track,
			requested.isNumeric, requested >= .zero, requested.seconds * 48000 < Double(Int64.max) else {
			throw ProjectFailure("Enter a valid clip start.")
		}
		if clip.trackID == track.id && requested == clip.start.time { return }
		var next = self
		next.removeClips([id])
		let others = next.clips(on: track)
		var start = requested
		if next.isMagnetic(track), !others.isEmpty || clip.trackID == track.id {
			let earliest = others.first?.start.time ?? clip.start.time
			let latest = others.last?.end ?? earliest
			if exact && (start < earliest || start > latest) {
				throw ProjectFailure("This time would leave a gap. Choose a time within the track or turn Magnetic off in Track Actions.")
			}
			start = min(max(earliest, start), latest)
		}
		clip.additionalTrack = track.id == track.kind.rawValue ? nil : track.id
		clip.start = ProjectTime(start)
		if next.isMagnetic(track) {
			next.makeRoom(for: clip, mode: .split)
		} else if others.contains(where: { $0.end > start && $0.start.time < clip.end }) {
			throw ProjectFailure("The clip overlaps another clip. Choose an open time on this track.")
		}
		next.placements.append(clip)
		if clip.omitAudio != true && sources.contains(where: { $0.id == clip.sourceID && $0.hasAudio }) { next.ensureAudioPartner(for: track) }
		next.assignPlacementLabels()
		self = next
	}

	mutating func move(_ ids: Set<UUID>, to track: TimelineTrack, beside anchor: UUID?, after: Bool) throws {
		let moving = placements.filter { ids.contains($0.id) }.sorted {
			if $0.start.time != $1.start.time { return $0.start.time < $1.start.time }
			return $0.trackID < $1.trackID
		}
		guard let first = moving.first, moving.count == ids.count, moving.allSatisfy({ $0.track == track.kind }) else {
			throw ProjectFailure("Choose clips from a compatible track.")
		}
		var next = self
		next.removeClips(ids)
		let destination = next.clips(on: track)
		let magnetic = next.isMagnetic(track)
		let preserveSpacing = !magnetic && moving.allSatisfy { $0.trackID == first.trackID }
		let span = preserveSpacing ? moving.last!.end - first.start.time : moving.reduce(.zero) { $0 + $1.duration }
		let start: CMTime
		if let anchor {
			guard let clip = destination.first(where: { $0.id == anchor }) else { throw ProjectFailure("Choose a different destination clip.") }
			start = after ? clip.end : magnetic ? clip.start.time : clip.start.time - span
		} else { start = destination.last?.end ?? first.start.time }
		if magnetic { next.shiftClips(on: track, from: start, by: span) }
		var cursor = start
		for var clip in moving {
			if preserveSpacing { cursor = start + (clip.start.time - first.start.time) }
			clip.start = ProjectTime(cursor)
			clip.additionalTrack = track.id == track.kind.rawValue ? nil : track.id
			guard cursor >= .zero, !next.clips(on: track).contains(where: { $0.end > cursor && $0.start.time < clip.end }) else {
				throw ProjectFailure("There is not enough open time for this drop. Choose another position.")
			}
			next.placements.append(clip)
			if clip.omitAudio != true && sources.contains(where: { $0.id == clip.sourceID && $0.hasAudio }) { next.ensureAudioPartner(for: track) }
			cursor = clip.end
		}
		self = next
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
	private static let writeLock = NSLock()
	static let directory = URL.documentsDirectory.appendingPathComponent("Projects", isDirectory: true)

	// Only the manifest is decoded into memory. Project-owned media lives alongside it.
	private static let maximumBytes = 32 * 1024 * 1024

	private static func data(at url: URL) throws -> Data {
		let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
		guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		defer { try? handle.close() }
		var info = stat()
		guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadCorruptFile) }
		let size = try handle.seekToEnd()
		guard size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
		try handle.seek(toOffset: 0)
		let data = try handle.read(upToCount: Int(size) + 1) ?? Data()
		guard data.count == size else { throw CocoaError(.fileReadCorruptFile) }
		return data
	}

	private static func manifest(_ entry: URL) throws -> URL {
		guard entry.isFileURL, entry.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
			try ProjectStorage.directoryExists(directory) else { throw CocoaError(.fileReadNoPermission) }
		if entry.pathExtension == "json" { return entry }
		guard UUID(uuidString: entry.lastPathComponent) != nil, try ProjectStorage.directoryExists(entry) else {
			throw CocoaError(.fileReadCorruptFile)
		}
		return entry.appendingPathComponent("Project.json")
	}

	static func name(at url: URL) throws -> String {
		struct Header: Decodable { let name: String }
		return try JSONDecoder().decode(Header.self, from: data(at: manifest(url))).name
	}

	static func load(_ url: URL) throws -> EditingProject {
		var project = try JSONDecoder().decode(EditingProject.self, from: data(at: manifest(url)))
		if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), id != project.id { throw CocoaError(.fileReadCorruptFile) }
		guard (1...12).contains(project.version) else { throw ProjectFailure("Update Trimatillo to open this project.") }
		try validate(project)
		try project.validateTransitions()
		if project.version < 3 { project.restoreAudioPartners() }
		project.assignPlacementLabels()
		if project.version < 6 {
			for track in [TimelineTrack.primaryVideo, .primaryAudio] where project.needsPacking(track) {
				project.setMagnetic(false, on: track)
			}
			project.version = 6
		}
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
			if case .recording(let owner, _) = source.reference, owner != project.id { throw corrupt }
			if let generator = source.generator {
				guard generator.isValid, source.duration == generator.source.duration, source.picture == generator.source.picture, source.hasAudio == generator.source.hasAudio else { throw corrupt }
			}
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
		let mixIDs = Set(tracks.keys).union([EditingProject.descriptionMixID])
		guard tracks[EditingProject.descriptionMixID] == nil,
			(0...EditingProject.maximumMixerLevel).contains(project.masterVolume ?? 1),
			(project.mutedTracks ?? []).isSubset(of: mixIDs) else { throw corrupt }
		for (id, stereo) in project.trackStereo ?? [:] {
			guard mixIDs.contains(id), stereo == stereo.normalized else { throw corrupt }
		}
		for (id, effects) in project.trackEffects ?? [:] {
			guard tracks[id] == .audio, effects.isValid else { throw corrupt }
		}
		for (id, volume) in project.trackVolumes ?? [:] {
			guard mixIDs.contains(id), (0...EditingProject.maximumMixerLevel).contains(volume) else { throw corrupt }
		}
		var ids = Set<UUID>()
		for clip in project.placements {
			guard ids.insert(clip.id).inserted, let source = sources[clip.sourceID],
				tracks[clip.trackID] == clip.track, clip.track == (source.picture == nil ? .audio : .video),
				(0...1001).contains(clip.loudnessGain ?? 1), validTime(clip.start), !clip.ranges.isEmpty else { throw corrupt }
			if let settings = clip.compositing, !settings.isValid || clip.track != .video { throw corrupt }
			if let generator = clip.generatorOverride {
				guard let original = source.generator, generator.isValid, generator.kind == original.kind, generator.seconds == original.seconds, generator.picture == original.picture else { throw corrupt }
			}
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
		var descriptionIDs = Set<UUID>()
		for entry in project.descriptiveTranscript ?? [] {
			guard descriptionIDs.insert(entry.id).inserted, validTime(entry.start), validTime(entry.end),
				entry.start.time < entry.end.time, !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw corrupt }
		}
		for take in project.audioDescriptions ?? [] {
			if let end = take.narrationLength {
				guard validTime(end), end.value > 0, end.time <= take.length.time else { throw corrupt }
			}
			guard descriptionIDs.insert(take.id).inserted, validTime(take.start), validTime(take.limit), validTime(take.length),
				take.limit.time > take.start.time, take.length.value > 0, !take.name.isEmpty else { throw corrupt }
		}
		if let duck = project.descriptionDucking {
			guard (-30...0).contains(duck.decibels), (0...3).contains(duck.fade) else { throw corrupt }
		}
		for marker in [project.markIn, project.markOut].compactMap({ $0 }) {
			guard validTime(marker), marker.time <= duration else { throw corrupt }
		}
	}

	static func savedFiles() throws -> [URL] {
		guard try ProjectStorage.directoryExists(directory) else { return [] }
		let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
		let legacyNames = Set(entries.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
		return try entries.filter { entry in
			if entry.pathExtension == "json" { return true }
			guard UUID(uuidString: entry.lastPathComponent) != nil else { return false }
			// A crash between mkdir and moving a legacy manifest can leave an empty sibling.
			if legacyNames.contains(entry.lastPathComponent), (try? ProjectStorage.directoryExists(entry)) == true {
				return try !FileManager.default.contentsOfDirectory(atPath: entry.path).isEmpty
			}
			return true
		}
	}

	private static let discardedProjects = URL.cachesDirectory.appendingPathComponent("DiscardedProjects", isDirectory: true)

	static func pendingDeletions() throws -> [URL] {
		guard try ProjectStorage.directoryExists(discardedProjects) else { return [] }
		return try FileManager.default.contentsOfDirectory(at: discardedProjects, includingPropertiesForKeys: nil)
			.filter { UUID(uuidString: $0.lastPathComponent) != nil }
	}

	@concurrent static func finishDeletions() async throws {
		for entry in try pendingDeletions() {
			do { try FileManager.default.removeItem(at: entry) }
			catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { continue }
		}
	}

	@MainActor static func delete(_ entry: URL) throws {
		writeLock.lock()
		defer { writeLock.unlock() }
		guard entry.isFileURL, entry.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
			try ProjectStorage.directoryExists(directory), entry.pathExtension == "json" || UUID(uuidString: entry.lastPathComponent) != nil else {
			throw CocoaError(.fileWriteNoPermission)
		}
		if let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent), ProjectPlayback.isOpen(id) {
			throw ProjectFailure("Close the project in its other window before deleting it.")
		}
		// Move the entire project out of the library in one rename. A later cleanup
		// can finish reclaiming its bytes if the process exits during removal.
		try ProjectStorage.prepareDirectory(discardedProjects)
		let discarded = discardedProjects.appendingPathComponent(UUID().uuidString)
		guard rename(entry.path, discarded.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
	}

	static func save(_ project: EditingProject, replacing previous: EditingProject? = nil) throws {
		writeLock.lock()
		defer { writeLock.unlock() }
		try ProjectStorage.prepareDirectory(directory)
		let folder = directory.appendingPathComponent(project.id.uuidString, isDirectory: true)
		let legacy = directory.appendingPathComponent(project.id.uuidString + ".json")
		let manager = FileManager.default
		let hasLegacy = manager.fileExists(atPath: legacy.path)
		if let previous, try load(hasLegacy ? legacy : folder) != previous {
			throw ProjectFailure("This project changed in another window. Close and reopen it before editing.")
		}
		let data = try JSONEncoder().encode(project)
		guard data.count <= maximumBytes else { throw ProjectFailure("This project is too large to save. Continue in a new project.") }
		let existed = try ProjectStorage.directoryExists(folder)
		if !existed && !hasLegacy {
			// Publish a new folder only after its complete manifest is on the same volume.
			let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
			defer { try? manager.removeItem(at: staging) }
			let package = staging.appendingPathComponent(project.id.uuidString, isDirectory: true)
			try ProjectStorage.prepareDirectory(package)
			try data.write(to: package.appendingPathComponent("Project.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
			try manager.moveItem(at: package, to: folder)
			return
		}
		try ProjectStorage.prepareDirectory(folder)
		let url = folder.appendingPathComponent("Project.json")
		do {
			if hasLegacy {
				// An interrupted migration has either the original manifest or the moved one.
				_ = try self.data(at: legacy)
				try manager.moveItem(at: legacy, to: url)
			}
			try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
		} catch {
			if !existed { _ = rmdir(folder.path) }
			throw error
		}
	}
}

nonisolated enum TrackChannelRouting: String, Codable, CaseIterable, Identifiable, Sendable {
	case both, left, right, swap
	var id: Self { self }
	var title: String {
		switch self {
		case .both: "Both Channels"
		case .left: "Left Channel Only"
		case .right: "Right Channel Only"
		case .swap: "Swap Left and Right"
		}
	}
}

nonisolated struct TrackStereoMix: Codable, Hashable, Sendable {
	var pan: Double = 0
	var balance: Double = 0
	var width: Double = 1
	var routing: TrackChannelRouting = .both
	static let neutral = Self()

	var normalized: Self {
		var value = self
		value.pan = Self.bounded(pan, -1...1, fallback: 0)
		value.balance = Self.bounded(balance, -1...1, fallback: 0)
		value.width = Self.bounded(width, 0...2, fallback: 1)
		return value
	}

	static func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
		value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
	}

	func matrix(gain: Double) -> StereoMixMatrix {
		let value = normalized
		func transform(_ left: Double, _ right: Double) -> (Double, Double) {
			var l = left, r = right
			switch value.routing {
			case .both: break
			case .left: r = l
			case .right: l = r
			case .swap: swap(&l, &r)
			}
			let mid = (l + r) / 2, side = (l - r) / 2 * value.width
			l = mid + side
			r = mid - side
			// Move stereo material toward either side while preserving both input channels.
			let angle = (value.pan + 1) * Double.pi / 4
			if value.pan < 0 {
				l = (l - r * value.pan) / (1 - value.pan) * sqrt(2) * cos(angle)
				r *= sqrt(2) * sin(angle)
			} else if value.pan > 0 {
				r = (r + l * value.pan) / (1 + value.pan) * sqrt(2) * sin(angle)
				l *= sqrt(2) * cos(angle)
			}
			l *= 1 - max(value.balance, 0)
			r *= 1 + min(value.balance, 0)
			return (l * gain, r * gain)
		}
		let a = transform(1, 0), b = transform(0, 1)
		return StereoMixMatrix(ll: a.0, lr: b.0, rl: a.1, rr: b.1)
	}
}

nonisolated struct StereoMixMatrix: Equatable, Sendable {
	var ll: Double = 1, lr: Double = 0, rl: Double = 0, rr: Double = 1
	static let silent = Self(ll: 0, lr: 0, rl: 0, rr: 0)
}
