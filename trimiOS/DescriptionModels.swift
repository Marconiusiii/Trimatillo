import AVFoundation

nonisolated enum DescriptionTimeline: String, CaseIterable, Identifiable {
	case transcript = "Descriptive Transcript"
	case audio = "Audio Description"
	var id: Self { self }
}

nonisolated struct TranscriptEntry: Codable, Equatable, Identifiable {
	var id = UUID()
	var start: ProjectTime
	var end: ProjectTime
	var text: String
}

nonisolated enum DescriptionFit: String, Codable, CaseIterable {
	case speed = "Speed Up to Fit"
	case trim = "Trim at Out"
}

nonisolated struct DescriptionTake: Codable, Equatable, Identifiable {
	var id = UUID()
	var recording: UUID
	var name: String
	var start: ProjectTime
	var limit: ProjectTime
	var length: ProjectTime
	var fit: DescriptionFit

	var duration: CMTime { min(limit.time - start.time, length.time) }
	var end: CMTime { start.time + duration }

	func insert(in composition: AVMutableComposition, url: URL) async throws -> AVMutableAudioMixInputParameters {
		let asset = AVURLAsset(url: url)
		guard let source = try await asset.loadTracks(withMediaType: .audio).first,
			let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
			throw ProjectFailure("Could not read the recording for " + name + ".")
		}
		let available = try await source.load(.timeRange)
		let full = min(available.duration, length.time)
		let used = fit == .speed ? full : min(duration, full)
		guard used > .zero, duration > .zero else { throw ProjectFailure("Record a take before saving.") }
		try track.insertTimeRange(CMTimeRange(start: available.start, duration: used), of: source, at: start.time)
		if fit == .speed && used > duration {
			track.scaleTimeRange(CMTimeRange(start: start.time, duration: used), toDuration: duration)
		}
		let mix = AVMutableAudioMixInputParameters(track: track)
		mix.audioTimePitchAlgorithm = .timeDomain
		return mix
	}
}

nonisolated struct DescriptionDucking: Codable, Equatable {
	var enabled = false
	var decibels = -5.0
	var fade = 0.25

	func apply(to mix: AVMutableAudioMixInputParameters, volume: Float, takes: [DescriptionTake], duration: CMTime) {
		guard enabled, !takes.isEmpty else { return }
		let reduced = volume * Float(pow(10, decibels / 20))
		var end = -Double.infinity
		func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600000) }
		func release(_ start: Double, until: Double) {
			let stop = min(start + fade, until)
			if stop > start {
				mix.setVolumeRamp(fromStartVolume: reduced, toEndVolume: volume, timeRange: CMTimeRange(start: time(start), end: time(stop)))
			} else { mix.setVolume(volume, at: time(start)) }
		}
		for take in takes.sorted(by: { $0.start.time < $1.start.time }) {
			let start = take.start.seconds
			guard start < duration.seconds else { continue }
			if start > end {
				let transition = end.isFinite ? (start + end) / 2 : 0
				if end.isFinite { release(end, until: transition) }
				let begin = max(transition, start - fade)
				if begin < start {
					mix.setVolumeRamp(fromStartVolume: volume, toEndVolume: reduced, timeRange: CMTimeRange(start: time(begin), end: take.start.time))
				} else { mix.setVolume(reduced, at: take.start.time) }
			}
			end = max(end, take.end.seconds)
		}
		if end.isFinite && end < duration.seconds { release(end, until: duration.seconds) }
	}
}

nonisolated struct DescriptionRow: Identifiable {
	let id: UUID
	let name: String
	let start: CMTime
	let end: CMTime
}

extension EditingProject {
	func descriptionRows(_ timeline: DescriptionTimeline) -> [DescriptionRow] {
		let rows: [DescriptionRow]
		switch timeline {
		case .transcript:
			rows = (descriptiveTranscript ?? []).map { DescriptionRow(id: $0.id, name: $0.text, start: $0.start.time, end: $0.end.time) }
		case .audio:
			rows = (audioDescriptions ?? []).map { DescriptionRow(id: $0.id, name: $0.name, start: $0.start.time, end: $0.end) }
		}
		return rows.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
	}

	func descriptionPoint(_ timeline: DescriptionTimeline, from position: CMTime, forward: Bool) -> (time: CMTime, name: String) {
		let rows = descriptionRows(timeline)
		let points = (rows.flatMap { [$0.start, $0.end] } + [.zero, duration]).filter { $0 >= .zero && $0 <= duration }
		let target = forward ? points.filter { $0 > position }.min() ?? duration : points.filter { $0 < position }.max() ?? .zero
		var labels = rows.filter { $0.end == target }.map { "End of " + $0.name }
		labels += rows.filter { $0.start == target }.map { "Start of " + $0.name }
		if target == .zero { labels.insert("Start", at: 0) }
		if target == duration { labels.append("End") }
		return (target, labels.joined(separator: ", "))
	}
}
