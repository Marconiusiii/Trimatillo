import AVFoundation
import AudioToolbox
import Photos
import Combine
import CoreTransferable
import UniformTypeIdentifiers
import UIKit

// Photos lends the transfer a file URL. Keep a private copy for the lifetime of the edit.
nonisolated final class ImportedMovie: Transferable, Sendable {
	let url: URL
	private let directory: URL

	init(copying source: URL) throws {
		let manager = FileManager.default
		directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		url = directory.appendingPathComponent(source.lastPathComponent)
		try manager.createDirectory(at: directory, withIntermediateDirectories: false)
		do {
			try manager.copyItem(at: source, to: url)
		} catch {
			try? manager.removeItem(at: directory)
			throw error
		}
	}

	static func snapshot(of url: URL) async throws -> ImportedMovie {
		try await Task.detached {
			var error: NSError?
			var copy: Result<ImportedMovie, Error>?
			NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
				copy = Result { try ImportedMovie(copying: readable) }
			}
			if let error { throw error }
			guard let copy else { throw CocoaError(.fileReadUnknown) }
			return try copy.get()
		}.value
	}

	static var transferRepresentation: some TransferRepresentation {
		FileRepresentation(importedContentType: .movie) { received in
			try ImportedMovie(copying: received.file)
		}
	}

	deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class CuttingBoardSession: ObservableObject {
	struct Snapshot {
		var timeline: ClipEditTimeline
		var position: CMTime = .zero
		var markIn: CMTime?
		var markOut: CMTime?
	}

	let player = AVPlayer()
	let title: String
	let hasVideo: Bool
	let hasAudio: Bool
	private let source: AVURLAsset
	private let scopedURL: URL?
	private let importedMovie: ImportedMovie
	private let originalFile: URL?
	private let photoIdentifier: String?
	private var originalModification: Date?
	private let tracks: [(AVAssetTrack, CMTimeRange)]
	private let transform: CGAffineTransform
	private let originalDuration: CMTime
	private let sourceFrames: [CMTime]
	private var frames: [CMTime] = []
	private var history: [Snapshot] = []
	private var playbackObservation: Any?
	private var endObservation: NSObjectProtocol?
	private var itemObservation: NSKeyValueObservation?
	private var editAsset: AVAsset
	private var reverseTask: Task<Void, Never>?
	private var previewTask: Task<Void, Never>?
	private var pendingScrubTime: CMTime?
	private let engine = AVAudioEngine()
	private let node = AVAudioPlayerNode()
	private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
	private var audioActive = false
	private var seekGeneration = 0
	private var returnAfterAudition: CMTime?
	@Published private(set) var state: Snapshot
	@Published private(set) var rate = 0.0
	var speedLabel: String { abs(rate).formatted() + "x" }
	var shuttleLabel: String { (rate < 0 ? "Rewind " : "Forward ") + speedLabel }
	@Published var sheet: BoardSheet?
	@Published var message: String?
	var duration: CMTime { state.timeline.duration }
	var canUndo: Bool { !history.isEmpty }
	var currentJoin: ClipEditTimeline.EditPoint? {
		state.timeline.editPoints.first { CMTimeCompare($0.time, position) == 0 }
	}
	var position: CMTime { state.position }
	var selection: CMTimeRange? {
		guard let start = state.markIn, let end = state.markOut, start < end else { return nil }
		return CMTimeRange(start: start, end: end)
	}

	static func open(_ url: URL, importedMovie: ImportedMovie? = nil, photoIdentifier: String? = nil) async throws -> CuttingBoardSession {
		let scoped = url.startAccessingSecurityScopedResource()
		do {
			let modification = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
			let copy: ImportedMovie
			if let importedMovie { copy = importedMovie } else { copy = try await ImportedMovie.snapshot(of: url) }
			let asset = AVURLAsset(url: copy.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
			let duration = try await asset.load(.duration)
			guard duration.isNumeric, duration > .zero else { throw CocoaError(.fileReadCorruptFile) }
			let video = try await asset.loadTracks(withMediaType: .video).first
			let audio = try await asset.loadTracks(withMediaType: .audio).first
			var tracks: [(AVAssetTrack, CMTimeRange)] = []
			for track in [video, audio].compactMap({ $0 }) {
				tracks.append((track, try await track.load(.timeRange)))
			}
			guard !tracks.isEmpty else { throw CocoaError(.fileReadUnsupportedScheme) }
			let transform = try await video?.load(.preferredTransform) ?? .identity
			let frames = try await MediaTimelineReader.shared.frameTimes(asset: asset, track: video)
			try Task.checkCancellation()
			return CuttingBoardSession(asset: asset, importedMovie: copy, originalFile: importedMovie == nil ? url : nil,
				photoIdentifier: photoIdentifier, modification: importedMovie == nil ? modification : Date(), scopedURL: scoped ? url : nil, duration: duration,
				tracks: tracks, transform: transform, frames: frames, hasVideo: video != nil, hasAudio: audio != nil)
		} catch {
			if scoped { url.stopAccessingSecurityScopedResource() }
			throw error
		}
	}

	private init(asset: AVURLAsset, importedMovie: ImportedMovie, originalFile: URL?, photoIdentifier: String?, modification: Date?, scopedURL: URL?, duration: CMTime, tracks: [(AVAssetTrack, CMTimeRange)],
		transform: CGAffineTransform, frames: [CMTime], hasVideo: Bool, hasAudio: Bool) {
		source = asset
		editAsset = asset
		self.scopedURL = scopedURL
		self.importedMovie = importedMovie
		self.originalFile = originalFile
		self.photoIdentifier = photoIdentifier
		originalModification = modification
		title = asset.url.lastPathComponent
		self.tracks = tracks
		self.transform = transform
		self.hasVideo = hasVideo
		self.hasAudio = hasAudio
		originalDuration = duration
		sourceFrames = frames
		self.frames = frames
		state = Snapshot(timeline: ClipEditTimeline(sourceDuration: duration))
		engine.attach(node)
		engine.connect(node, to: engine.mainMixerNode, format: audioFormat)
		player.actionAtItemEnd = .pause
		installItem(asset)
		playbackObservation = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.rate > 0, let item = self.player.currentItem else { return }
				let now = self.player.currentTime()
				guard now.isNumeric else { return }
				let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : self.duration
				if self.player.rate == 0 && now >= end {
					self.rate = 0
					if let point = self.returnAfterAudition {
						self.seek(point)
						return
					}
				}
				self.state.position = min(now, end)
			}
		}
	}

	private func installItem(_ asset: AVAsset) {
		if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
		let item = AVPlayerItem(asset: asset)
		player.replaceCurrentItem(with: item)
		endObservation = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
			object: item, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.player.currentItem === item, self.rate > 0 else { return }
				let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : self.duration
				guard self.player.currentTime() >= end else { return }
				self.seek(self.returnAfterAudition ?? end)
			}
		}
		itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
			guard item.status == .failed else { return }
			Task { @MainActor [weak self] in
				guard let self, self.player.currentItem === item else { return }
				self.stop()
				self.message = "Playback failed. Open the clip again or choose another file."
			}
		}
	}

	deinit {
		if let playbackObservation { player.removeTimeObserver(playbackObservation) }
		if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
		scopedURL?.stopAccessingSecurityScopedResource()
	}

	func stop() {
		seekGeneration += 1
		returnAfterAudition = nil
		if rate > 0, player.rate > 0, player.currentTime().isNumeric {
			state.position = min(duration, max(.zero, player.currentTime()))
		}
		rate = 0
		player.pause()
		player.currentItem?.forwardPlaybackEndTime = .invalid
		reverseTask?.cancel()
		reverseTask = nil
		previewTask?.cancel()
		previewTask = nil
		pendingScrubTime = nil
		node.stop()
	}

	func releaseAudio() {
		stop()
		engine.stop()
		if audioActive {
			try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
			audioActive = false
		}
	}

	private func activateAudio() throws {
		if !audioActive {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, mode: .default)
			try session.setActive(true)
			audioActive = true
		}
	}

	func seek(_ time: CMTime, audible: Bool = false) {
		stop()
		state.position = min(duration, max(.zero, time))
		player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
		if audible && hasAudio {
			let start = min(position, max(.zero, duration - audioStep))
			previewTask = Task { [weak self] in
				guard let self else { return }
				await self.preview(at: start)
			}
		}
	}

	func beginScrub() -> Int {
		stop()
		return seekGeneration
	}

	func scrub(to time: CMTime, generation: Int) {
		guard generation == seekGeneration else { return }
		let next = min(duration, max(.zero, time))
		guard next != position else { return }
		state.position = next
		if hasVideo { player.seek(to: next, toleranceBefore: .zero, toleranceAfter: .zero) }
		guard hasAudio else { return }
		pendingScrubTime = min(next, max(.zero, duration - audioStep))
		guard previewTask == nil else { return }
		// Finish the current decode while newer touches replace the pending position.
		previewTask = Task { [weak self] in
			guard let self else { return }
			defer { if generation == self.seekGeneration { self.previewTask = nil } }
			while !Task.isCancelled, let point = self.pendingScrubTime {
				self.pendingScrubTime = nil
				await self.preview(at: point)
				do { try await Task.sleep(for: .milliseconds(65)) } catch { return }
			}
		}
	}

	func endScrub(at time: CMTime, generation: Int) {
		guard generation == seekGeneration else { return }
		seek(time)
	}

	var audioStep: CMTime { CMTime(value: 1, timescale: 30) }

	func stepped(from time: CMTime, by count: Int, sourceTime: Bool = false) -> CMTime {
		let times = sourceTime ? sourceFrames : frames
		guard !times.isEmpty else { return time + CMTimeMultiply(audioStep, multiplier: Int32(count)) }
		let index = times.lowerBound(time)
		let base = count > 0 && (index == times.count || times[index] != time) ? index - 1 : index
		let next = base + count
		if next >= times.count { return sourceTime ? tracks.map { $0.1.end }.max() ?? duration : duration }
		return times[max(0, next)]
	}

	func step(_ count: Int) {
		stop()
		let previous = position
		let next = min(duration, max(.zero, stepped(from: previous, by: count)))
		guard previous != next else { return }
		seek(next)
		guard hasAudio else { return }
		let start = next == duration ? max(.zero, stepped(from: next, by: -1)) : next
		let end = min(duration, stepped(from: start, by: 1))
		previewTask = Task { [weak self] in await self?.preview(at: start, length: (end - start).seconds) }
	}

	private func announce(_ text: String) {
		if UIAccessibility.isVoiceOverRunning {
			UIAccessibility.post(notification: .announcement, argument: text)
		}
	}

	func navigate(_ forward: Bool, spoken: Bool = false) {
		let stops = state.timeline.editPoints.map(\.time) + [state.markIn, state.markOut, .zero, duration].compactMap { $0 }
		let next = forward ? stops.filter { $0 > position }.min() : stops.filter { $0 < position }.max()
		guard let next else { return }
		seek(next)
		if spoken {
			var names: [String] = []
			if next == .zero { names.append("Start") }
			if let join = currentJoin { names.append(join.name) }
			if next == state.markIn { names.append("In point") }
			if next == state.markOut { names.append("Out point") }
			if next == duration { names.append("End") }
			announce(names.joined(separator: ", "))
		}
	}

	func mark(_ isIn: Bool, toggleAtPlayhead: Bool = false) {
		let now = rate > 0 && player.rate > 0 ? player.currentTime() : position
		let time = min(duration, max(.zero, now))
		if toggleAtPlayhead, (isIn ? state.markIn : state.markOut) == time {
			clear(isIn)
			announce(isIn ? "In Removed" : "Out Removed")
			return
		}
		if isIn { state.markIn = time } else { state.markOut = time }
		if toggleAtPlayhead { announce(isIn ? "Marked In" : "Marked Out") }
	}

	func clear(_ isIn: Bool) {
		if isIn { state.markIn = nil } else { state.markOut = nil }
	}

	func delete(_ range: CMTimeRange?, spoken: Bool = false) {
		guard removeRange(range), spoken else { return }
		announce(["Content deleted", currentJoin?.name].compactMap { $0 }.joined(separator: ", "))
	}

	private func removeRange(_ range: CMTimeRange?) -> Bool {
		guard let range else { message = "Set In before Out to delete a marked range."; return false }
		do {
			var timeline = state.timeline
			try timeline.delete(editedRange: range)
			try apply(Snapshot(timeline: timeline, position: range.start), record: true)
			return true
		} catch {
			message = error.localizedDescription
			return false
		}
	}

	func trim(head: Bool, spoken: Bool = false) {
		let point = rate > 0 && player.rate > 0 ? player.currentTime() : position
		let range = CMTimeRange(start: head ? .zero : point, end: head ? point : duration)
		if removeRange(range), spoken {
			announce(head ? "Head trimmed to playhead" : "Tail trimmed to playhead")
		}
	}

	func adjust(_ index: Int, preceding: Bool, to time: CMTime, audible: Bool) {
		guard let join = state.timeline.editPoints.first(where: { $0.index == index }) else { return }
		do {
			let timeline = try state.timeline.adjustingEditPoint(index,
				inTime: preceding ? time : join.inTime, outTime: preceding ? join.outTime : time)
			let position = timeline.editPoints[index].time
			try apply(Snapshot(timeline: timeline, position: position), record: true)
			if audible { previewBoundary(preceding: preceding, at: position) }
		} catch { message = "Choose a boundary inside the adjacent section that keeps In before Out." }
	}

	private func previewBoundary(preceding: Bool, at point: CMTime) {
		guard hasAudio else { return }
		let start = preceding ? max(.zero, point - CMTime(seconds: 0.15, preferredTimescale: 48000)) : point
		previewTask = Task { [weak self] in await self?.preview(at: start) }
	}

	func undo() {
		guard let previous = history.last else { return }
		do {
			try apply(previous, record: false)
			history.removeLast()
		} catch { message = error.localizedDescription }
	}

	private func apply(_ snapshot: Snapshot, record: Bool) throws {
		let composition = AVMutableComposition()
		for (track, available) in tracks {
			guard let output = composition.addMutableTrack(withMediaType: track.mediaType,
				preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.featureUnsupported) }
			if track.mediaType == .video { output.preferredTransform = transform }
			var cursor = CMTime.zero
			for range in snapshot.timeline.sourceRanges {
				let overlap = CMTimeRangeGetIntersection(range, otherRange: available)
				if overlap.isValid && !overlap.isEmpty {
					try output.insertTimeRange(overlap, of: track, at: cursor + (overlap.start - range.start))
				}
				cursor = cursor + range.duration
			}
		}
		if composition.duration < snapshot.timeline.duration {
			composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: snapshot.timeline.duration))
		}
		stop()
		if record { history.append(state) }
		state = snapshot
		editAsset = composition
		var cursor = CMTime.zero
		frames = snapshot.timeline.sourceRanges.flatMap { range -> [CMTime] in
			defer { cursor = cursor + range.duration }
			let first = sourceFrames.lowerBound(range.start)
			let slice = sourceFrames[first..<sourceFrames.lowerBound(range.end)]
			var starts = slice.map { cursor + ($0 - range.start) }
			if first > 0, slice.first != range.start,
				tracks.contains(where: { $0.0.mediaType == .video && $0.1.containsTime(range.start) }) {
				starts.insert(cursor, at: 0)
			}
			return starts
		}
		installItem(composition)
		seek(snapshot.position)
	}

	func toggle() {
		if rate != 0 { stop() } else { play(from: position >= duration ? .zero : position, to: duration, speed: 1) }
	}

	func shuttle(_ direction: Int) {
		let current = rate * Double(direction)
		guard let speed = [1.0, 1.5, 2, 4, 8].first(where: { $0 > current }) else { return }
		stop()
		let start = direction > 0 && position >= duration ? CMTime.zero : (direction < 0 && position <= .zero ? duration : position)
		if direction > 0 {
			play(from: start, to: duration, speed: speed)
			if rate == speed { announce(shuttleLabel) }
			return
		}
		do { try activateAudio() } catch { message = "Could not start audio. Check the audio output and try Play again."; return }
		rate = -speed
		announce(shuttleLabel)
		state.position = start
		reverseTask = Task { [weak self] in
			guard let self else { return }
			do {
				try await self.playReverse(from: start, speed: speed)
				try Task.checkCancellation()
				self.seek(.zero)
			} catch {
				if !Task.isCancelled {
					self.stop()
					self.message = "Reverse playback failed. Check the audio output and try Rewind again."
				}
			}
		}
	}

	private func playReverse(from start: CMTime, speed: Double) async throws {
		let scale: CMTimeScale = 48000
		let startFrame = CMTimeConvertScale(start, timescale: scale, method: .roundHalfAwayFromZero).value
		var unread = startFrame
		var scheduled: Int64 = 0
		var played: Int64 = 0
		let clock = ContinuousClock()
		let began = clock.now
		var remaining = startFrame
		while remaining > 0 {
			try Task.checkCancellation()
			// Queue contiguous blocks ahead of the render clock. Only the last block can be partial.
			if hasAudio, unread > 0, scheduled - played < 16000 {
				let count = min(unread, Int64(8192 * speed))
				let first = unread - count
				let samples = try await FrameAudioSamples.read(asset: editAsset, mix: nil,
					at: CMTime(value: first, timescale: scale), length: Double(count) / Double(scale))
				try Task.checkCancellation()
				guard let buffer = pcmBuffer(samples, reverseSpeed: speed) else { throw CocoaError(.fileReadCorruptFile) }
				if !engine.isRunning { try engine.start() }
				enqueue(buffer)
				scheduled += Int64(buffer.frameLength)
				unread = first
				if !node.isPlaying && (scheduled >= 16000 || unread == 0) { node.play() }
				continue
			}
			if hasAudio {
				if let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) {
					played = max(0, min(scheduled, time.sampleTime))
				}
			} else {
				let elapsed = began.duration(to: clock.now).components
				played = elapsed.seconds * Int64(scale) + Int64(Double(elapsed.attoseconds) * 48_000e-18)
			}
			remaining = max(0, startFrame - Int64(Double(played) * speed))
			if hasAudio && unread == 0 && played == scheduled { remaining = 0 }
			let next = CMTime(value: remaining, timescale: scale)
			if next != position {
				state.position = next
				if hasVideo { player.seek(to: next, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in }) }
			}
			try await Task.sleep(for: .milliseconds(16))
		}
	}

	func playAcross(_ point: CMTime) {
		let second = CMTime(value: 1, timescale: 1)
		play(from: max(.zero, point - second), to: min(duration, point + second), speed: 1)
		returnAfterAudition = point
	}

	func playMarked() {
		guard let selection else { return }
		play(from: selection.start, to: selection.end, speed: 1)
	}

	private func play(from start: CMTime, to end: CMTime, speed: Double) {
		seek(start)
		do { try activateAudio() } catch { message = "Could not start audio. Check the audio output and try Play again."; return }
		player.currentItem?.forwardPlaybackEndTime = end
		let generation = seekGeneration
		rate = speed
		player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
			Task { @MainActor [weak self] in
				guard finished, let self, generation == self.seekGeneration else { return }
				self.player.playImmediately(atRate: Float(speed))
			}
		}
	}

	private func preview(at time: CMTime, length: Double = 0.2) async {
		do {
			let samples = try await FrameAudioSamples.read(asset: editAsset, mix: nil, at: time, length: length)
			try Task.checkCancellation()
			guard !samples.isEmpty else { return }
			try activateAudio()
			guard let buffer = pcmBuffer(samples) else { return }
			node.stop()
			if !engine.isRunning { try engine.start() }
			playBuffer(buffer)
		} catch {
			if !Task.isCancelled { stop(); message = "Audio preview failed. Check the audio output and reopen the clip." }
		}
	}

	private func pcmBuffer(_ samples: [Float], reverseSpeed: Double? = nil) -> AVAudioPCMBuffer? {
		let frames = samples.count / 2
		let stride = reverseSpeed ?? 1
		let length = Int(ceil(Double(frames) / stride))
		guard length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(length)),
			let channels = buffer.floatChannelData else { return nil }
		buffer.frameLength = buffer.frameCapacity
		for i in 0..<length {
			if reverseSpeed != nil {
				let end = frames - Int(Double(i) * stride)
				let first = max(0, frames - Int(Double(i + 1) * stride))
				for channel in 0..<2 {
					var sum: Float = 0
					for frame in first..<end { sum += samples[frame * 2 + channel] }
					channels[channel][i] = sum / Float(end - first)
				}
			} else {
				channels[0][i] = samples[i * 2]
				channels[1][i] = samples[i * 2 + 1]
			}
		}
		return buffer
	}

	private func enqueue(_ buffer: AVAudioPCMBuffer) {
		node.scheduleBuffer(buffer)
	}

	private func playBuffer(_ buffer: AVAudioPCMBuffer) {
		enqueue(buffer)
		node.play()
	}

	func frameNumber(at time: CMTime, sourceTime: Bool = false) -> Int64 {
		let timestamps = sourceTime ? sourceFrames : frames
		let atEnd = time >= (sourceTime ? originalDuration : duration)
		if timestamps.isEmpty {
			return CMTimeConvertScale(time, timescale: 30, method: atEnd ? .roundTowardPositiveInfinity : .roundTowardZero).value
		}
		if atEnd { return Int64(timestamps.count) }
		let index = timestamps.lowerBound(time)
		if index < timestamps.count && timestamps[index] == time { return Int64(index) }
		return Int64(max(0, index - 1))
	}

	func time(atFrame index: Int64, sourceTime: Bool) -> CMTime? {
		let end = sourceTime ? originalDuration : duration
		let count = frameNumber(at: end, sourceTime: sourceTime)
		guard index >= 0, index <= count else { return nil }
		if index == count { return end }
		let timestamps = sourceTime ? sourceFrames : frames
		return timestamps.isEmpty ? CMTime(value: index, timescale: 30) : timestamps[Int(index)]
	}

	func timecode(_ time: CMTime, format: TimecodeFormat, sourceTime: Bool = false) -> String {
		if format == .frames { return "Frame \(frameNumber(at: time, sourceTime: sourceTime))" }
		let milliseconds = format == .milliseconds
		let ticks = CMTimeConvertScale(time, timescale: milliseconds ? 1000 : 1,
			method: milliseconds ? .roundHalfAwayFromZero : .roundTowardZero).value
		let seconds = milliseconds ? ticks / 1000 : ticks
		let clock = String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
		return milliseconds ? clock + String(format: ".%03lld", ticks % 1000) : clock
	}

	static func parse(_ text: String) -> CMTime? {
		let parts = text.split(separator: ":", omittingEmptySubsequences: false)
		guard (1...3).contains(parts.count) else { return nil }
		var total = 0.0
		for (index, part) in parts.enumerated() {
			guard let value = Double(part), value.isFinite, value >= 0,
				index == 0 || value < 60, index == parts.count - 1 || value == value.rounded() else { return nil }
			total = total * 60 + value
		}
		let result = CMTime(seconds: total, preferredTimescale: 600000)
		return result.isNumeric ? result : nil
	}
}

private extension Array where Element == CMTime {
	func lowerBound(_ value: CMTime) -> Int {
		var low = 0
		var high = count
		while low < high {
			let mid = low + (high - low) / 2
			if self[mid] < value { low = mid + 1 } else { high = mid }
		}
		return low
	}
}

private actor MediaTimelineReader {
	static let shared = MediaTimelineReader()
	func frameTimes(asset: AVAsset, track: AVAssetTrack?) async throws -> [CMTime] {
		guard let track else { return [] }
		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
		reader.add(output)
		guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		defer { reader.cancelReading() }
		var times: [CMTime] = []
		while let sample = output.copyNextSampleBuffer() {
			try Task.checkCancellation()
			guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
			let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
			if time.isNumeric, time >= .zero { times.append(time) }
		}
		guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		var previous = CMTime.invalid
		return times.sorted().filter { time in
			defer { previous = time }
			return time != previous
		}
	}
}

/// A bounded	PCM preview. The reader works away from the main actor; video stays paused.
nonisolated enum FrameAudioSamples {
	static let sampleRate = 48_000.0
	static let channels = 2

	private static let decoder = FrameAudioDecoder()

	static func read(asset: AVAsset, mix: AVAudioMix?, at time: CMTime, length: Double = 0.2) async throws -> [Float] {
		try await decoder.read(asset: asset, mix: mix, at: time, length: length)
	}
}

/// Only one blocking reader runs at a time, even during rapid replacement requests.
private actor FrameAudioDecoder {
	func read(asset: AVAsset, mix: AVAudioMix?, at time: CMTime, length: Double = 0.2) async throws -> [Float] {
		try Task.checkCancellation()
		let sampleRate = FrameAudioSamples.sampleRate
		let channels = FrameAudioSamples.channels
		guard time.isNumeric, time.seconds >= 0 else { return [] }
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		guard !tracks.isEmpty else { return [] }
		let duration = try await asset.load(.duration)
		guard duration.isNumeric else { return [] }
		let length = min(length, max(0, duration.seconds - time.seconds))
		guard length > 0 else { return [] }
		try Task.checkCancellation()
		let reader = try AVAssetReader(asset: asset)
		// Decode a little context around the requested interval. Some renderers
		// round the first or last packet at a non-packet-aligned reader boundary.
		// Copy only samples whose timestamps fall inside the requested buffer.
		let context = CMTime(value: 1024, timescale: 48_000)
		let end = time + CMTime(seconds: length, preferredTimescale: 48_000)
		reader.timeRange = CMTimeRange(start: max(.zero, time - context), end: min(duration, end + context))
		let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
			AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
			AVNumberOfChannelsKey: channels, AVLinearPCMIsFloatKey: true,
			AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
		])
		output.audioMix = mix
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw CocoaError(.fileReadUnknown) }
		reader.add(output)
		guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
		defer { reader.cancelReading() }
		let frameCount = Int((length * sampleRate).rounded())
		var samples = [Float](repeating: 0, count: frameCount * channels)
		while let buffer = output.copyNextSampleBuffer() {
			try Task.checkCancellation()
			guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
			let offset = Int(((CMSampleBufferGetPresentationTimeStamp(buffer).seconds - time.seconds) * sampleRate).rounded())
			let firstSourceFrame = max(0, -offset)
			let firstDestinationFrame = max(0, offset)
			let count = min(CMSampleBufferGetNumSamples(buffer) - firstSourceFrame, frameCount - firstDestinationFrame)
			guard count > 0 else { continue }
			let status = samples.withUnsafeMutableBytes { destination in
				CMBlockBufferCopyDataBytes(data, atOffset: firstSourceFrame * channels * 4,
					dataLength: count * channels * 4,
					destination: destination.baseAddress!.advanced(by: firstDestinationFrame * channels * 4))
			}
			guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
		}
		guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
		return samples
	}
}

struct ClipInfoSection {
	let title: String
	var rows: [(key: String, value: String)]
}

extension CuttingBoardSession {
	func clipInfo(format: TimecodeFormat = .milliseconds) async -> [ClipInfoSection] {
		let properties = try? source.url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
		var file = ClipInfoSection(title: "File", rows: [("Filename", title)])
		if let type = properties?.contentType?.localizedDescription { file.rows.append(("File type", type)) }
		if let bytes = properties?.fileSize {
			file.rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
		}
		func durationLabel(_ end: CMTime, sourceTime: Bool) -> String {
			guard format == .frames else { return timecode(end, format: format) }
			let count = frameNumber(at: end, sourceTime: sourceTime)
			return count == 1 ? "1 frame" : "\(count) frames"
		}
		file.rows.append(("Source duration", durationLabel(originalDuration, sourceTime: true)))
		file.rows.append(("Edited duration", durationLabel(duration, sourceTime: false)))
		var sections = [file]
		for (index, track) in ((try? await source.load(.tracks)) ?? []).enumerated() {
			var section = ClipInfoSection(title: "Track \(index + 1)", rows: [])
			let type = track.mediaType
			section.rows.append(("Type", type == .video ? "Video" : type == .audio ? "Audio" : type.rawValue))
			if let language = try? await track.load(.extendedLanguageTag) {
				section.rows.append(("Language", Locale.current.localizedString(forIdentifier: language) ?? language))
			}
			if type == .video {
				if let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
					let rect = CGRect(origin: .zero, size: size).applying(transform)
					section.rows.append(("Dimensions", "\(Int(rect.width)) by \(Int(rect.height)) pixels"))
				}
				if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
					section.rows.append(("Frame rate", "\(fps.formatted(.number.precision(.fractionLength(0...3)))) frames per second"))
				}
			}
			if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
				section.rows.append(("Estimated bit rate", "\(Int(rate).formatted()) bits per second"))
			}
			for format in (try? await track.load(.formatDescriptions)) ?? [] {
				let code = CMFormatDescriptionGetMediaSubType(format)
				let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
				section.rows.append(("Codec", String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? String(code)))
				if type == .audio, let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
					section.rows.append(("Sample rate", "\(audio.mSampleRate.formatted()) Hz"))
					section.rows.append(("Channels", "\(audio.mChannelsPerFrame)"))
				}
			}
			sections.append(section)
			for format in (try? await track.load(.availableMetadataFormats)) ?? [] {
				let items = (try? await track.loadMetadata(for: format)) ?? []
				if let tags = await metadataSection("Track \(index + 1) metadata", items) { sections.append(tags) }
			}
		}
		for format in (try? await source.load(.availableMetadataFormats)) ?? [] {
			let items = (try? await source.loadMetadata(for: format)) ?? []
			if let tags = await metadataSection(format.rawValue, items) { sections.append(tags) }
		}
		return sections
	}

	private func metadataSection(_ title: String, _ items: [AVMetadataItem]) async -> ClipInfoSection? {
		var section = ClipInfoSection(title: title, rows: [])
		for item in items {
			let name = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? item.key.map { String(describing: $0) } ?? "Metadata"
			if let text = try? await item.load(.stringValue) { section.rows.append((name, text)) }
			else if let date = try? await item.load(.dateValue) { section.rows.append((name, date.formatted())) }
			else if let value = try? await item.load(.numberValue) { section.rows.append((name, value.stringValue)) }
			else if let data = try? await item.load(.dataValue) { section.rows.append((name, "\(data.count.formatted()) bytes")) }
		}
		return section.rows.isEmpty ? nil : section
	}

	private var originalType: AVFileType? {
		switch originalFile?.pathExtension.lowercased() {
		case "mov" where hasVideo: .mov
		case "mp4" where hasVideo: .mp4
		case "m4a" where !hasVideo: .m4a
		default: nil
		}
	}

	var canSaveOriginal: Bool {
		if let originalFile { return originalType != nil && FileManager.default.isWritableFile(atPath: originalFile.path) }
		return photoIdentifier != nil
	}

	func saveOriginal() async throws {
		if let originalFile, let originalType {
			let file = try await exportClip(type: originalType)
			defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
			let expected = originalModification
			originalModification = try await Task.detached {
				let manager = FileManager.default
				var coordinationError: NSError?
				var result: Result<Date?, Error>?
				NSFileCoordinator().coordinate(writingItemAt: originalFile, options: .forReplacing, error: &coordinationError) { destination in
					result = Result {
						let current = try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
						guard expected == current else { throw SaveFailure.changed }
						let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
						defer { try? manager.removeItem(at: staging) }
						let replacement = staging.appendingPathComponent(destination.lastPathComponent)
						try manager.copyItem(at: file, to: replacement)
						_ = try manager.replaceItemAt(destination, withItemAt: replacement)
						return try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
					}
				}
				if let coordinationError { throw coordinationError }
				guard let result else { throw CocoaError(.fileWriteUnknown) }
				return try result.get()
			}.value
			return
		}

		try await authorizePhotos(.readWrite)
		guard let photoIdentifier, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoIdentifier], options: nil).firstObject,
			asset.canPerform(.content) else { throw SaveFailure.unavailable }
		if let modified = asset.modificationDate, let originalModification, modified > originalModification { throw SaveFailure.changed }
		let options = PHContentEditingInputRequestOptions()
		options.isNetworkAccessAllowed = true
		let input: PHContentEditingInput = try await withCheckedThrowingContinuation { continuation in
			asset.requestContentEditingInput(with: options) { input, _ in
				if let input { continuation.resume(returning: input) } else { continuation.resume(throwing: SaveFailure.unavailable) }
			}
		}
		let output = PHContentEditingOutput(contentEditingInput: input)
		let renderedURL = output.renderedContentURL
		let type: AVFileType
		switch renderedURL.pathExtension.lowercased() {
		case "mov": type = .mov
		case "mp4": type = .mp4
		default: throw SaveFailure.unavailable
		}
		let file = try await exportClip(type: type)
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		try await Task.detached { try FileManager.default.copyItem(at: file, to: renderedURL) }.value
		output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.marconius.trimato-ios.cut", formatVersion: "1", data: Data("Trimato cut".utf8))
		try Task.checkCancellation()
		try await PHPhotoLibrary.shared().performChanges {
			PHAssetChangeRequest(for: asset).contentEditingOutput = output
		}
		originalModification = Date()
	}

	func saveNewVideo() async throws {
		try await authorizePhotos(.addOnly)
		let file = try await exportClip()
		defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
		try await PHPhotoLibrary.shared().performChanges {
			let options = PHAssetResourceCreationOptions()
			options.originalFilename = file.lastPathComponent
			PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: options)
		}
	}

	private func authorizePhotos(_ level: PHAccessLevel) async throws {
		let status = await PHPhotoLibrary.requestAuthorization(for: level)
		guard status == .authorized || status == .limited else { throw SaveFailure.permission }
		try Task.checkCancellation()
	}

	enum SaveFailure: LocalizedError {
		case changed, unavailable, permission
		var errorDescription: String? {
			switch self {
			case .changed: "The original changed. Save as a new clip or reopen the original."
			case .unavailable: "This original cannot be edited. Save as a new clip."
			case .permission: "Allow Photos access in Settings or save the clip to Files."
			}
		}
	}

	func exportClip(type requested: AVFileType? = nil) async throws -> URL {
		let preset = hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
		guard let exporter = AVAssetExportSession(asset: editAsset, presetName: preset) else {
			throw CocoaError(.featureUnsupported)
		}
		exporter.timeRange = CMTimeRange(start: .zero, duration: duration)
		if hasAudio {
			let mix = AVMutableAudioMix()
			mix.inputParameters = try await editAsset.loadTracks(withMediaType: .audio).map { track in
				let input = AVMutableAudioMixInputParameters(track: track)
				input.setVolume(1, at: .zero)
				return input
			}
			exporter.audioMix = mix
		}
		let type: AVFileType = requested ?? (hasVideo ? (exporter.supportedFileTypes.contains(.mp4) ? .mp4 : .mov) : .m4a)
		guard exporter.supportedFileTypes.contains(type) else { throw CocoaError(.featureUnsupported) }
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		let name = source.url.deletingPathExtension().lastPathComponent + " Edited"
		let file = directory.appendingPathComponent(name).appendingPathExtension(type == .mp4 ? "mp4" : type == .mov ? "mov" : "m4a")
		do {
			try await exporter.export(to: file, as: type)
			try Task.checkCancellation()
			return file
		} catch {
			try? FileManager.default.removeItem(at: directory)
			throw error
		}
	}
}
