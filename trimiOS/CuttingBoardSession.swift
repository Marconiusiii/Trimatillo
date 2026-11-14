import AVFoundation
import AudioToolbox
import Combine
import UIKit

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
	private let tracks: [(AVAssetTrack, CMTimeRange)]
	private let transform: CGAffineTransform
	private let sourceFrames: [CMTime]
	private var frames: [CMTime] = []
	private var history: [Snapshot] = []
	private var playbackObservation: Any?
	private var endObservation: NSObjectProtocol?
	private var itemObservation: NSKeyValueObservation?
	private var editAsset: AVAsset
	private var reverseTask: Task<Void, Never>?
	private var previewTask: Task<Void, Never>?
	private let engine = AVAudioEngine()
	private let node = AVAudioPlayerNode()
	private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
	private var audioActive = false
	private var seekGeneration = 0
	private var returnAfterAudition: CMTime?
	@Published private(set) var state: Snapshot
	@Published private(set) var rate = 0
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

	static func open(_ url: URL) async throws -> CuttingBoardSession {
		let scoped = url.startAccessingSecurityScopedResource()
		do {
			let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
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
			return CuttingBoardSession(asset: asset, scopedURL: scoped ? url : nil, duration: duration,
				tracks: tracks, transform: transform, frames: frames, hasVideo: video != nil, hasAudio: audio != nil)
		} catch {
			if scoped { url.stopAccessingSecurityScopedResource() }
			throw error
		}
	}

	private init(asset: AVURLAsset, scopedURL: URL?, duration: CMTime, tracks: [(AVAssetTrack, CMTimeRange)],
		transform: CGAffineTransform, frames: [CMTime], hasVideo: Bool, hasAudio: Bool) {
		source = asset
		editAsset = asset
		self.scopedURL = scopedURL
		title = asset.url.lastPathComponent
		self.tracks = tracks
		self.transform = transform
		self.hasVideo = hasVideo
		self.hasAudio = hasAudio
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

	func step(_ count: Int) { seek(stepped(from: position, by: count), audible: true) }

	func navigate(_ forward: Bool) {
		let stops = state.timeline.editPoints.map(\.time) + [state.markIn, state.markOut, .zero, duration].compactMap { $0 }
		let next = forward ? stops.filter { $0 > position }.min() : stops.filter { $0 < position }.max()
		seek(next ?? (forward ? duration : .zero))
	}

	func mark(_ isIn: Bool) {
		let now = rate > 0 && player.rate > 0 ? player.currentTime() : position
		if isIn { state.markIn = min(duration, max(.zero, now)) }
		else { state.markOut = min(duration, max(.zero, now)) }
	}

	func clear(_ isIn: Bool) {
		if isIn { state.markIn = nil } else { state.markOut = nil }
	}

	func delete(_ range: CMTimeRange?) {
		guard let range else { message = "Set In before Out to delete a marked range."; return }
		do {
			var timeline = state.timeline
			try timeline.delete(editedRange: range)
			try apply(Snapshot(timeline: timeline, position: range.start), record: true)
		} catch { message = error.localizedDescription }
	}

	func trim(head: Bool) {
		let point = rate > 0 && player.rate > 0 ? player.currentTime() : position
		delete(CMTimeRange(start: head ? .zero : point, end: head ? point : duration))
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
			let slice = sourceFrames[sourceFrames.lowerBound(range.start)..<sourceFrames.lowerBound(range.end)]
			return slice.map { cursor + ($0 - range.start) }
		}
		installItem(composition)
		seek(snapshot.position)
	}

	func toggle() {
		if rate != 0 { stop() } else { shuttle(1) }
	}

	func shuttle(_ direction: Int) {
		let speed = rate * direction > 0 ? min(8, abs(rate) * 2) : 1
		stop()
		let start = direction > 0 && position >= duration ? CMTime.zero : (direction < 0 && position <= .zero ? duration : position)
		if direction > 0 { play(from: start, to: duration, speed: speed); return }
		do { try activateAudio() } catch { message = "Could not start audio. Check the audio output and try Play again."; return }
		rate = -speed
		state.position = start
		reverseTask = Task { [weak self] in
			while !Task.isCancelled, let self, self.position > .zero {
				let interval = CMTime(value: 1, timescale: 5)
				let next = max(.zero, self.position - CMTimeMultiply(interval, multiplier: Int32(speed)))
				self.state.position = next
				self.player.seek(to: next, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
				if self.hasAudio { await self.preview(at: next, reversed: true) }
				do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
			}
			if !Task.isCancelled { self?.rate = 0 }
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

	private func play(from start: CMTime, to end: CMTime, speed: Int) {
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

	private func preview(at time: CMTime, reversed: Bool = false) async {
		do {
			let samples = try await FrameAudioSamples.read(asset: editAsset, mix: nil, at: time)
			try Task.checkCancellation()
			guard !samples.isEmpty else { return }
			try activateAudio()
			let count = samples.count / 2
			guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(count)),
				let channels = buffer.floatChannelData else { return }
			buffer.frameLength = buffer.frameCapacity
			for i in 0..<count {
				let source = reversed ? count - 1 - i : i
				channels[0][i] = samples[source * 2]
				channels[1][i] = samples[source * 2 + 1]
			}
			node.stop()
			if !engine.isRunning { try engine.start() }
			playBuffer(buffer)
		} catch {
			if !Task.isCancelled { stop(); message = "Audio preview failed. Check the audio output and reopen the clip." }
		}
	}

	private func playBuffer(_ buffer: AVAudioPCMBuffer) {
		node.scheduleBuffer(buffer)
		node.play()
	}

	static func timecode(_ time: CMTime) -> String {
		let ms = Int((time.seconds * 1000).rounded())
		return String(format: "%02d:%02d:%02d.%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
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

	static func read(asset: AVAsset, mix: AVAudioMix?, at time: CMTime) async throws -> [Float] {
		try await decoder.read(asset: asset, mix: mix, at: time)
	}
}

/// Only one blocking reader runs at a time, even during rapid replacement requests.
private actor FrameAudioDecoder {
	func read(asset: AVAsset, mix: AVAudioMix?, at time: CMTime) async throws -> [Float] {
		try Task.checkCancellation()
		let sampleRate = FrameAudioSamples.sampleRate
		let channels = FrameAudioSamples.channels
		guard time.isNumeric, time.seconds >= 0 else { return [] }
		let tracks = try await asset.loadTracks(withMediaType: .audio)
		guard !tracks.isEmpty else { return [] }
		let duration = try await asset.load(.duration)
		guard duration.isNumeric else { return [] }
		let length = min(0.2, max(0, duration.seconds - time.seconds))
		guard length > 0 else { return [] }
		try Task.checkCancellation()
		let reader = try AVAssetReader(asset: asset)
		reader.timeRange = CMTimeRange(start: time, duration: CMTime(seconds: length, preferredTimescale: 48_000))
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
