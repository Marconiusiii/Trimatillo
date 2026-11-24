import AVFoundation
import Accelerate
import MediaToolbox
import Combine
import UIKit
import Observation
import SwiftUI
import CoreImage

// Retain prepared stereo ranges for as long as a player, reader, or export uses its mix.
private final class StereoMedia {
	private struct RangeKey: Hashable {
		let url: URL?
		let assetID: ObjectIdentifier?
		let trackID: CMPersistentTrackID
		let start: CMTime
		let duration: CMTime
	}
	private var ranges: [RangeKey: (file: ExportFile, asset: AVURLAsset, track: AVAssetTrack)] = [:]

	func source(_ asset: AVAsset, track: AVAssetTrack, range: CMTimeRange) async throws -> (AVAssetTrack, CMTimeRange) {
		let formats = try await track.load(.formatDescriptions)
		if !formats.isEmpty && formats.allSatisfy({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame == 2 }) {
			return (track, range)
		}
		let url = (asset as? AVURLAsset)?.url
		let key = RangeKey(url: url, assetID: url == nil ? ObjectIdentifier(asset) : nil, trackID: track.trackID, start: range.start, duration: range.duration)
		let local = CMTimeRange(start: .zero, duration: range.duration)
		if let cached = ranges[key] { return (cached.track, local) }
		let file = try await Self.convert(asset, track: track, range: range, rate: formats.first.flatMap {
			CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate
		} ?? 48000)
		let stereoAsset = AVURLAsset(url: file.url)
		guard let converted = try await stereoAsset.loadTracks(withMediaType: .audio).first else {
			throw ProjectFailure("Could not prepare stereo audio. Reopen the project and try again.")
		}
		ranges[key] = (file, stereoAsset, converted)
		return (converted, local)
	}

	@concurrent private static func convert(_ asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, rate: Double) async throws -> ExportFile {
		let file = try ExportFile(name: "Stereo", suffix: "caf")
		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
			AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 2, AVSampleRateKey: rate,
			AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
		])
		reader.timeRange = range
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw CocoaError(.featureUnsupported) }
		reader.add(output)
		let audio = try AVAudioFile(forWriting: file.url, settings: [
			AVFormatIDKey: kAudioFormatAppleLossless, AVNumberOfChannelsKey: 2,
			AVSampleRateKey: rate, AVEncoderBitDepthHintKey: 24
		], commonFormat: .pcmFormatFloat32, interleaved: true)
		guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		defer { reader.cancelReading() }
		var buffer: AVAudioPCMBuffer?
		while let sample = output.copyNextSampleBuffer() {
			try Task.checkCancellation()
			let count = CMSampleBufferGetNumSamples(sample)
			guard count > 0 else { continue }
			if Int(buffer?.frameCapacity ?? 0) < count {
				buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(count))
			}
			guard let buffer else { throw CocoaError(.fileReadTooLarge) }
			buffer.frameLength = AVAudioFrameCount(count)
			let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList)
			guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
			try audio.write(from: buffer)
		}
		guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
		return file
	}
}

/// One state per composition audio track; no waits or model access on the render callback.
nonisolated private final class TrackMixProcessor: @unchecked Sendable {
	private let media: StereoMedia
	private let lock = NSLock()
	private struct Settings {
		var matrix: StereoMixMatrix
		var smoothing: TrackAudioEffects.Smoothing?
		var inputGain: Double
	}
	private var target: Settings
	private var active: Settings
	private var dynamics = TrackDynamics()
	private var current: StereoMixMatrix
	private var format = AudioStreamBasicDescription()
	private var step = StereoMixMatrix.silent
	private var remaining = 0
	private var destination: StereoMixMatrix

	init(matrix: StereoMixMatrix, media: StereoMedia, smoothing: TrackAudioEffects.Smoothing? = nil, inputGain: Double = 1) {
		self.media = media
		target = Settings(matrix: matrix, smoothing: smoothing, inputGain: inputGain)
		active = target
		current = matrix
		destination = matrix
	}
	func update(_ matrix: StereoMixMatrix, smoothing: TrackAudioEffects.Smoothing?, inputGain: Double) {
		lock.withLock { target = Settings(matrix: matrix, smoothing: smoothing, inputGain: inputGain) }
	}

	func copyProcessor() -> TrackMixProcessor {
		let matrix = lock.withLock { target }
		return TrackMixProcessor(matrix: matrix.matrix, media: media, smoothing: matrix.smoothing, inputGain: matrix.inputGain)
	}

	func makeTap() throws -> MTAudioProcessingTap {
		var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
			clientInfo: Unmanaged.passRetained(self).toOpaque(),
			init: { _, info, storage in storage.pointee = info },
			finalize: { tap in Unmanaged<TrackMixProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
			prepare: { tap, _, format in
				let state = Unmanaged<TrackMixProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
				state.prepare(format.pointee)
			}, unprepare: nil,
			process: { tap, requested, _, buffers, frames, flags in
				let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, nil, frames)
				guard status == noErr else { frames.pointee = 0; return }
				let state = Unmanaged<TrackMixProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
				state.process(buffers, frames: frames.pointee)
			})
		var tap: MTAudioProcessingTap?
		let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
			kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
		guard status == noErr, let tap else {
			Unmanaged<TrackMixProcessor>.fromOpaque(callbacks.clientInfo!).release()
			throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
		}
		return tap
	}

	func prepare(_ value: AudioStreamBasicDescription) {
		format = value
		dynamics = TrackDynamics()
		dynamics.configure(active.smoothing, rate: value.mSampleRate)
	}

	func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
		if lock.try() {
			let settings = target
			lock.unlock()
			if active.smoothing != settings.smoothing { dynamics.configure(settings.smoothing, rate: format.mSampleRate) }
			active = settings
			let next = settings.matrix
			if next != destination {
				destination = next
				remaining = max(Int(format.mSampleRate * 0.01), 1)
				let n = Double(remaining)
				step = StereoMixMatrix(ll: (next.ll - current.ll) / n, lr: (next.lr - current.lr) / n,
					rl: (next.rl - current.rl) / n, rr: (next.rr - current.rr) / n)
			}
		}
		let buffers = UnsafeMutableAudioBufferListPointer(list)
		let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
		guard format.mFormatID == kAudioFormatLinearPCM,
			(1...2).contains(format.mChannelsPerFrame),
			buffers.count >= (planar ? Int(format.mChannelsPerFrame) : 1) else { return }
		if !dynamics.enabled && remaining == 0 && current == StereoMixMatrix() { return }
		guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
			format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
			format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
			let leftData = buffers[0].mData,
			let rightData = buffers[planar ? 1 : 0].mData else {
			processOtherPCM(buffers, frames: frames, planar: planar)
			return
		}
		let left = leftData.assumingMemoryBound(to: Float.self)
		let right = rightData.assumingMemoryBound(to: Float.self)
		let stride = planar ? 1 : 2
		let offset = planar ? 0 : 1
		let capacity = min(Int(buffers[0].mDataByteSize), Int(buffers[planar ? 1 : 0].mDataByteSize)) / (4 * stride)
		let count = min(frames, capacity)
		if !dynamics.enabled, remaining == 0, current.lr == 0, current.rl == 0 {
			var leftGain = Float(current.ll)
			var rightGain = Float(current.rr)
			vDSP_vsmul(left, vDSP_Stride(stride), &leftGain, left, vDSP_Stride(stride), vDSP_Length(count))
			let rightStart = right.advanced(by: offset)
			vDSP_vsmul(rightStart, vDSP_Stride(stride), &rightGain, rightStart, vDSP_Stride(stride), vDSP_Length(count))
			return
		}
		for frame in 0..<count {
			advanceMatrix()
			let index = frame * stride
			let l = Double(left[index]), r = Double(right[index+offset])
			let gain = dynamics.enabled ? dynamics.gain(left: l * active.inputGain, right: r * active.inputGain) : 1
			left[index] = Float((l * current.ll + r * current.lr) * gain)
			right[index+offset] = Float((l * current.rl + r * current.rr) * gain)
		}
	}

	private func advanceMatrix() {
		if remaining > 0 {
			current.ll += step.ll
			current.lr += step.lr
			current.rl += step.rl
			current.rr += step.rr
			remaining -= 1
			if remaining == 0 { current = destination }
		}
	}

	private func processOtherPCM(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, planar: Bool) {
		let channels = Int(format.mChannelsPerFrame)
		let bytes = Int(format.mBytesPerFrame) / (planar ? 1 : channels)
		let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
		let bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
		let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
		let bits = Int(format.mBitsPerChannel)
		let shift = format.mFormatFlags & kAudioFormatFlagIsAlignedHigh == 0 ? 0 : bytes * 8 - bits
		guard (1...8).contains(bytes), bits <= bytes * 8,
			(isFloat && [32, 64].contains(bits) || !isFloat && bits > 0 && bits <= 32),
			let first = buffers[0].mData else { return }
		let stride = bytes * (planar ? 1 : channels)
		let rightBuffer = planar && channels == 2 ? 1 : 0
		guard let second = buffers[rightBuffer].mData else { return }
		let capacity = min(Int(buffers[0].mDataByteSize), Int(buffers[rightBuffer].mDataByteSize)) / stride
		let scale = pow(2, Double(bits - 1))
		func read(_ pointer: UnsafeMutableRawPointer) -> Double {
			var raw: UInt64 = 0
			let data = pointer.assumingMemoryBound(to: UInt8.self)
			for index in 0..<bytes { raw |= UInt64(data[index]) << (8 * (bigEndian ? bytes-1-index : index)) }
			if isFloat { return bits == 32 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) : Double(bitPattern: raw) }
			let mask = (UInt64(1) << bits) - 1
			raw = (raw >> shift) & mask
			if !signed { return (Double(raw) - scale) / scale }
			if raw & (UInt64(1) << (bits-1)) != 0 { raw |= ~mask }
			return Double(Int64(bitPattern: raw)) / scale
		}
		func write(_ value: Double, _ pointer: UnsafeMutableRawPointer) {
			let raw: UInt64
			if isFloat { raw = bits == 32 ? UInt64(Float(value).bitPattern) : value.bitPattern }
			else {
				let bounded = min(max(value.isFinite ? value : 0, -1), 1 - 1 / scale)
				let integer = Int64((bounded * scale).rounded()) + (signed ? 0 : Int64(scale))
				raw = (UInt64(bitPattern: integer) & ((UInt64(1) << bits) - 1)) << shift
			}
			let data = pointer.assumingMemoryBound(to: UInt8.self)
			for index in 0..<bytes { data[index] = UInt8(truncatingIfNeeded: raw >> (8 * (bigEndian ? bytes-1-index : index))) }
		}
		for frame in 0..<min(frames, capacity) {
			advanceMatrix()
			let leftPointer = first.advanced(by: frame * stride)
			let rightPointer = second.advanced(by: frame * stride + (planar || channels == 1 ? 0 : bytes))
			let left = read(leftPointer), right = read(rightPointer)
			let gain = dynamics.enabled ? dynamics.gain(left: left * active.inputGain, right: right * active.inputGain) : 1
			let l = (left * current.ll + right * current.lr) * gain
			let r = (left * current.rl + right * current.rr) * gain
			if channels == 1 { write((l+r)/2, leftPointer) }
			else { write(l, leftPointer); write(r, rightPointer) }
		}
	}

}

@MainActor final class ProjectPlayhead: ObservableObject {
	@Published var position: CMTime = .zero {
		didSet { if position != oldValue, navigationLabel != nil { navigationLabel = nil } }
	}
	@Published var navigationLabel: String?
}

@MainActor @Observable final class ProjectTransportState {
	var playing = false
	var shuttleRate: Double = 0
}

private struct ScrubAudioWindow {
	let startFrame: Int64
	let samples: [Float]

	static func frame(at time: CMTime) -> Int64 {
		CMTimeConvertScale(time, timescale: 48000, method: .roundHalfAwayFromZero).value
	}

	func contains(_ time: CMTime) -> Bool {
		let frame = Self.frame(at: time) - startFrame
		return frame >= 0 && frame < Int64(samples.count / 2)
	}

	func grain(at time: CMTime) -> [Float]? {
		let offset = Int(Self.frame(at: time) - startFrame) * 2
		guard offset >= 0, offset < samples.count else { return nil }
		let end = min(offset + 4800 * 2, samples.count)
		return Array(samples[offset..<end])
	}

	static func read(item: AVPlayerItem, mix: AVAudioMix?, at time: CMTime) async throws -> Self {
		let start = max(0, frame(at: time) - 9600)
		let samples = try await FrameAudioSamples.read(asset: item.asset, mix: mix,
			at: CMTime(value: start, timescale: 48000), length: 0.8)
		return Self(startFrame: start, samples: samples)
	}
}

@MainActor final class ProjectPlayback: ObservableObject {
	let player = AVPlayer()
	let playhead = ProjectPlayhead()
	var position: CMTime {
		if playing, reverse == nil {
			let time = player.currentTime()
			if time.isNumeric { return max(.zero, min(time, duration)) }
		}
		return playhead.position
	}
	private var playbackRange: CMTimeRange?
	@Published private(set) var mixerLoop: CMTimeRange?

	func setMixerLoop(_ range: CMTimeRange?) {
		guard mixerLoop != range else { return }
		mixerLoop = range
		if playing, speed > 0, let range {
			startLoop(range, at: range.containsTime(position) ? position : range.start, rate: speed)
		} else if playbackRange != nil {
			loopGeneration += 1
			playbackRange = nil
			player.currentItem?.forwardPlaybackEndTime = .invalid
			if playing && speed > 0 { playForward(speed) }
		}
	}
	private var loopRate = 1.0
	private var loopGeneration = 0
	private var ended: AnyCancellable?
	private var playbackFailed: AnyCancellable?
	let transport = ProjectTransportState()
	private var playing: Bool { transport.playing }
	@Published private(set) var ready = false
	@Published private(set) var preparing = false
	@Published var failure: String?
	private var media: [UUID: ProjectMediaAccess] = [:]
	private var observer: Any?
	private var status: AnyCancellable?
	private var startup: Task<Void, Never>?
	private let audioSession = EditorPlaybackAudioSession()
	private var generation = 0
	private var reverse: Task<Void, Never>?
	private(set) var scrubbing = false
	private(set) var audibleScrubPosition: CMTime?
	private var pictureSeek: Task<Void, Never>?
	private var scrubAudioFailed = false
	private var scrubDirection: Int32 = 0
	private var directionChanges = 0
	private var pendingScrub: CMTime?
	private var scrubTask: Task<Void, Never>?
	private var framePreview: Task<Void, Never>?
	private var warmup: Task<Void, Never>?
	private var window: ScrubAudioWindow?
	private let engine = AVAudioEngine()
	private let node = AVAudioPlayerNode()
	private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
	private var speed: Double = 0
	private var duration: CMTime = .zero

	let measurements: ClipLoudnessMeasurements

	init(measurements: ClipLoudnessMeasurements? = nil) {
		self.measurements = measurements ?? ClipLoudnessMeasurements()
		engine.attach(node)
		engine.connect(node, to: engine.mainMixerNode, format: format)
		observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.playing, self.reverse == nil else { return }
				let time = self.player.currentTime()
				guard time.isNumeric else { return }
				self.playhead.position = min(time, self.duration)
			}
		}
	}

	deinit { if let observer { player.removeTimeObserver(observer) } }

	#if DEBUG
	var keyboardPlaybackState: String {
		"playing=\(playing), speed=\(speed), player=\(player.rate), status=\(player.timeControlStatus.rawValue), loopGeneration=\(loopGeneration), reverse=\(reverse != nil), engine=\(engine.isRunning), node=\(node.isPlaying)"
	}
	#endif

	func exportTimeline(named name: String, captions: [CaptionCue], project: EditingProject) -> ProjectExport? {
		guard ready, let item = player.currentItem else { return nil }
		releaseAudio()
		let snapshot = AVPlayerItem(asset: item.asset)
		snapshot.videoComposition = item.videoComposition
		do { snapshot.audioMix = try audioMix(project, solo: []) }
		catch { failure = error.localizedDescription; return nil }
		return ProjectExport(name: name, captions: captions, item: snapshot, duration: duration, sources: Array(media.values), quality: mediaQuality)
	}

	func makePreview() -> PreviewPlayback? {
		guard let item = player.currentItem else { return nil }
		let forwardRate = max(0, speed)
		releaseAudio()
		let snapshot = AVPlayerItem(asset: item.asset)
		snapshot.videoComposition = item.videoComposition
		do { snapshot.audioMix = try independentMix(item) }
		catch { failure = error.localizedDescription; return nil }
		return PreviewPlayback(item: snapshot, start: position, rate: Float(forwardRate)) { [weak self, stereoMedia] time in
			withExtendedLifetime(stereoMedia) { self?.seek(time) }
		}
	}

	func playCaptionSelection(_ range: CMTimeRange) {
		guard ready, range.isValid, range.duration > .zero, range.start >= .zero, range.end <= duration else { return }
		startLoop(range, at: range.start, rate: 1)
	}

	private func startLoop(_ range: CMTimeRange, at start: CMTime, rate: Double) {
		stop(keepingAudio: true)
		loopRate = rate
		speed = rate
		transport.playing = true
		playbackRange = range
		player.currentItem?.forwardPlaybackEndTime = range.end
		restartLoop(at: start)
	}

	private func restartLoop(at start: CMTime) {
		do { try installPendingMix() }
		catch { stop(keepingAudio: false); failure = error.localizedDescription; return }
		let request = loopGeneration
		playhead.position = start
		player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
			Task { @MainActor [weak self] in
				guard let self, finished, request == loopGeneration, playbackRange != nil else { return }
				playForward(loopRate)
			}
		}
	}

	func pause() {
		stop(keepingAudio: true)
		do { try installPendingMix() }
		catch { failure = error.localizedDescription }
	}

	private func stop(keepingAudio: Bool) {
		if playing || playbackRange != nil { player.currentItem?.cancelPendingSeeks() }
		if playbackRange != nil {
			loopGeneration += 1
			playbackRange = nil
			player.currentItem?.forwardPlaybackEndTime = .invalid
		}
		warmup?.cancel()
		warmup = nil
		let wasRewinding = reverse != nil
		pictureSeek?.cancel()
		pictureSeek = nil
		scrubTask?.cancel()
		scrubTask = nil
		pendingScrub = nil
		reverse?.cancel()
		reverse = nil
		let wasStepping = framePreview != nil
		framePreview?.cancel()
		framePreview = nil
		if wasRewinding || scrubbing || wasStepping {
			scrubbing = false
			node.stop()
			engine.stop()
		}
		speed = 0
		if transport.shuttleRate != 0 { transport.shuttleRate = 0 }
		player.pause()
		if !wasRewinding, playing, player.currentTime().isNumeric { playhead.position = min(duration, player.currentTime()) }
		if playing { transport.playing = false }
		if !keepingAudio { audioSession.release() }
	}

	func releaseAudio() {
		pause()
		audioSession.release()
	}

	func toggle() {
		guard ready else { return }
		if playing { pause(); return }
		if let mixerLoop { startLoop(mixerLoop, at: mixerLoop.containsTime(position) ? position : mixerLoop.start, rate: 1); return }
		if scrubbing {
			stop(keepingAudio: true)
			seek(position)
		}
		if framePreview != nil { stop(keepingAudio: true) }
		if position >= duration { seek(.zero) }
		playForward(1)
	}

	private func configureAudioSession() throws {
		try audioSession.configure()
	}

	private func activateAudio() async throws {
		try await audioSession.activate()
	}

	private func playForward(_ rate: Double) {
		warmup?.cancel()
		warmup = nil
		do {
			// AVPlayer activates the configured session when forward playback starts.
			try configureAudioSession()
			try installPendingMix()
			speed = rate
			player.playImmediately(atRate: Float(rate))
			transport.playing = true
		} catch { failure = "Could not start project audio. Check the audio output and choose Play again." }
	}

	func shuttle(forward: Bool) {
		guard ready else { return }
		let current = forward ? transport.shuttleRate : -transport.shuttleRate
		guard let next = [1.0, 1.5, 2, 4, 8].first(where: { $0 > current }) else { return }
		stop(keepingAudio: true)
		if forward {
			if let mixerLoop {
				startLoop(mixerLoop, at: mixerLoop.containsTime(position) ? position : mixerLoop.start, rate: next)
				transport.shuttleRate = next
				UIAccessibility.post(notification: .announcement, argument: "Forward " + next.formatted() + "x")
				return
			}
			if position >= duration { seek(.zero) }
			playForward(next)
		} else if let item = player.currentItem {
			playReverse(next, item: item)
		}
		if playing {
			transport.shuttleRate = speed
			UIAccessibility.post(notification: .announcement, argument: (forward ? "Forward " : "Rewind ") + next.formatted() + "x")
		}
	}

	private func playReverse(_ rate: Double, item: AVPlayerItem) {
		if position <= .zero { seek(duration) }
		let start = position
		transport.playing = true
		speed = -rate
		reverse = Task {
			do {
				try await activateAudio()
				try Task.checkCancellation()
				let hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty
				try await ReverseAudioPlayback.run(from: start, speed: rate, asset: item.asset, mix: independentMix(item),
					hasAudio: hasAudio, engine: engine, node: node, format: format) { time in
					playhead.position = time
					player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
				}
				try Task.checkCancellation()
				seek(.zero)
			} catch {
				if !Task.isCancelled { pause(); failure = "Could not rewind the project. Check the audio output and try again." }
			}
		}
	}

	func stepWithAudio(forward: Bool, frame: CMTime, count: Int32 = 1) {
		guard ready, let item = player.currentItem else { return }
		stop(keepingAudio: true)
		let distance = CMTimeMultiply(frame, multiplier: count)
		let target = min(duration, max(.zero, position + (forward ? distance : .zero - distance)))
		let moved = target != position
		seek(target)
		guard moved, item.audioMix != nil else { pause(); return }
		let start = target == duration ? max(.zero, duration - frame) : target
		framePreview = Task {
			do {
				let samples = try await FrameAudioSamples.read(asset: item.asset, mix: independentMix(item),
					at: start, length: min(frame, duration - start).seconds)
				try Task.checkCancellation()
				if let buffer = ReverseAudioPlayback.pcmBuffer(samples, format: format) {
					try await activateAudio()
					if !engine.isRunning { try engine.start() }
					node.play()
					await node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack)
				}
			} catch {
				if !Task.isCancelled { failure = "Could not preview the frame. Check the audio output and try again." }
			}
			if !Task.isCancelled { pause() }
		}
	}

	func primeScrubAudio() {
		guard ready, !playing, !scrubbing, let item = player.currentItem, item.audioMix != nil else { return }
		let target = position
		guard window?.contains(target) != true else { return }
		warmup?.cancel()
		warmup = Task {
			guard let decoded = try? await ScrubAudioWindow.read(item: item, mix: independentMix(item), at: target),
				!Task.isCancelled, player.currentItem === item else { return }
			window = decoded
		}
	}

	func setScrubbing(_ active: Bool) {
		guard active != scrubbing else { return }
		if !active {
			pause()
			seek(position)
			return
		}
		guard ready else { return }
		stop(keepingAudio: true)
		scrubbing = true
		scrubDirection = 0
		audibleScrubPosition = nil
		scrubAudioFailed = false
	}

	func scrub(to time: CMTime) {
		guard scrubbing, let item = player.currentItem else { return }
		let target = min(duration, max(.zero, time))
		let direction = CMTimeCompare(target, playhead.position)
		if direction != 0 {
			audibleScrubPosition = nil
			if direction != scrubDirection { directionChanges += 1 }
			scrubDirection = direction
		}
		playhead.position = target
		if pictureSeek == nil {
			pictureSeek = Task {
				defer { if !Task.isCancelled { pictureSeek = nil } }
				while !Task.isCancelled {
					let requested = playhead.position
					await player.seek(to: requested, toleranceBefore: .zero, toleranceAfter: .zero)
					if requested == playhead.position { break }
				}
			}
		}
		guard item.audioMix != nil, !scrubAudioFailed else { return }
		pendingScrub = target
		guard scrubTask == nil else { return }
		scrubTask = Task {
			defer { if !Task.isCancelled { scrubTask = nil } }
			do {
				while var point = pendingScrub {
					try Task.checkCancellation()
					pendingScrub = nil
					if point >= duration {
						node.stop()
						continue
					}
					var samples = window?.grain(at: point)
					if samples == nil {
						let previousDirectionChanges = directionChanges
						let decoded = try await ScrubAudioWindow.read(item: item, mix: independentMix(item), at: point)
						try Task.checkCancellation()
						window = decoded
						if let latest = pendingScrub, decoded.contains(latest) {
							point = latest
							pendingScrub = nil
						} else if previousDirectionChanges != directionChanges || pendingScrub == duration {
							continue
						}
						samples = decoded.grain(at: point)
					}
					guard let samples, let buffer = ReverseAudioPlayback.pcmBuffer(samples, format: format) else { continue }
					try await activateAudio()
					if !engine.isRunning { try engine.start() }
					node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { _ in }
					if !node.isPlaying { node.play() }
					audibleScrubPosition = samples.contains { abs($0) > 0.0001 } ? point : nil
					// Limit replacements while dragging. The first grain is scheduled immediately.
					try await Task.sleep(for: .milliseconds(35))
				}
			} catch {
				if !Task.isCancelled {
					scrubAudioFailed = true
					audibleScrubPosition = nil
					node.stop()
				}
			}
		}
	}

	func seek(_ time: CMTime) {
		if playing || playbackRange != nil || scrubbing || framePreview != nil { pause() }
		playhead.position = min(duration, max(.zero, time))
		player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
	}

	func cancelPreparation() {
		releaseAudio()
		generation += 1
		status = nil
		startup?.cancel()
		startup = nil
		player.cancelPendingPrerolls()
		player.currentItem?.cancelPendingSeeks()
	}

	func failPreparation(_ error: Error) {
		cancelPreparation()
		pause()
		ready = false
		preparing = false
		player.replaceCurrentItem(with: nil)
		failure = error.localizedDescription
	}

	private static let openPlayers = NSHashTable<ProjectPlayback>.weakObjects()
	private var projectID: UUID?
	private var descriptionDucking: DescriptionDucking?
	private struct MixOutput {
		let id: CMPersistentTrackID
		let channel: String
		var video: String?
		var clipGain: Float = 1
		var envelopes: [TransitionAudioEnvelope] = []
		var auditionClip: UUID?
		var measurement: ClipLoudnessAnalyzer.Measurement?

		func gain(in project: EditingProject) -> Float {
			if let settings = project.trackEffects?[channel]?.loudness, let measurement {
				return measurement.gain(for: settings)
			}
			return clipGain
		}
	}
	private var stereoMedia = StereoMedia()
	private var mediaQuality = MediaQuality()
	private var mixOutputs: [MixOutput] = []
	private var liveProcessors: [CMPersistentTrackID: TrackMixProcessor] = [:]
	private var isPreviewMix = false
	private var mixProject: EditingProject?
	private var mixSolo: Set<String> = []
	private var mixNeedsInstall = false

	private func installPendingMix() throws {
		guard mixNeedsInstall, let project = mixProject, let item = player.currentItem else { return }
		item.audioMix = try audioMix(project, solo: mixSolo, live: true)
		mixNeedsInstall = false
	}

	private var narrationLevel: Float = 1
	private var primaryStereo = TrackStereoMix.neutral
	private var narrationStereo = TrackStereoMix.neutral
	private var masterLevel: Float = 1
	private var primaryLevels: [CMPersistentTrackID: Float] = [:]

	private func level(_ output: MixOutput, project: EditingProject, solo: Set<String>) -> Float {
		guard project.mutedTracks?.contains(output.channel) != true,
			solo.isEmpty || solo.contains(output.channel) else { return 0 }
		let videoLevel = output.video.flatMap { project.trackVolumes?[$0] } ?? 1
		return output.gain(in: project) * (project.trackVolumes?[output.channel] ?? 1) * videoLevel * (project.masterVolume ?? 1)
	}

	private func setLevel(_ level: Float, stereo: TrackStereoMix, on parameters: AVMutableAudioMixInputParameters,
		media: StereoMedia? = nil, output: MixOutput? = nil) throws {
		var smoothing: TrackAudioEffects.Smoothing?
		var inputGain = 1.0
		if let output, let mixProject {
			smoothing = mixProject.trackEffects?[output.channel]?.smoothing
			inputGain = Double(output.gain(in: mixProject))
		}
		let processor = TrackMixProcessor(matrix: stereo.matrix(gain: Double(level)), media: media ?? stereoMedia,
			smoothing: smoothing, inputGain: inputGain)
		parameters.audioTapProcessor = try processor.makeTap()
	}

	private func audioMix(_ project: EditingProject, solo: Set<String>, live: Bool = false, previewingChanges: Bool = false) throws -> AVAudioMix? {
		guard !mixOutputs.isEmpty else { return nil }
		let mix = AVMutableAudioMix()
		var processors: [CMPersistentTrackID: TrackMixProcessor] = [:]
		mix.inputParameters = try mixOutputs.map { output in
			let parameters = AVMutableAudioMixInputParameters()
			parameters.trackID = output.id
			let stereo = project.trackStereo?[output.channel] ?? .neutral
			let gain = level(output, project: project, solo: solo)
			let smoothing = project.trackEffects?[output.channel]?.smoothing
			let base: Float = smoothing == nil && live && !previewingChanges ? min(1, gain) : 1
			if !live || previewingChanges || gain > 1 || stereo != .neutral || smoothing != nil {
				let processor = TrackMixProcessor(matrix: stereo.matrix(gain: base > 0 ? Double(gain / base) : 1), media: stereoMedia, smoothing: smoothing, inputGain: Double(output.gain(in: project)))
				parameters.audioTapProcessor = try processor.makeTap()
				processors[output.id] = processor
			}
			if output.channel == EditingProject.descriptionMixID {
				parameters.setVolume(base, at: .zero)
				parameters.audioTimePitchAlgorithm = .timeDomain
			} else {
				let ducking = project.descriptionDucking?.volumeRamps(takes: project.audioDescriptions ?? [], duration: duration) ?? []
				parameters.applyTransitions(output.envelopes, base: base, ducking: ducking, duration: duration)
			}
			return parameters
		}
		if live {
			liveProcessors = processors
			isPreviewMix = previewingChanges
		}
		return mix
	}

	// Each AVFoundation consumer needs its own tap and render state.
	private func independentMix(_ item: AVPlayerItem) throws -> AVAudioMix? {
		guard let original = item.audioMix else { return nil }
		let mix = AVMutableAudioMix()
		mix.inputParameters = try original.inputParameters.map { parameters in
			guard let processor = liveProcessors[parameters.trackID] else { return parameters }
			guard let copy = parameters.mutableCopy() as? AVMutableAudioMixInputParameters else { throw CocoaError(.fileReadCorruptFile) }
			copy.audioTapProcessor = try processor.copyProcessor().makeTap()
			return copy
		}
		return mix
	}

	func updateMix(_ project: EditingProject, solo: Set<String>, preview: Bool = false) {
		guard projectID == project.id else { return }
		let changed = mixProject?.trackEffects != project.trackEffects || mixProject?.trackVolumes != project.trackVolumes || mixProject?.trackStereo != project.trackStereo
			|| mixProject?.masterVolume != project.masterVolume || mixProject?.mutedTracks != project.mutedTracks || mixSolo != solo
		mixProject = project
		mixSolo = solo
		guard changed || (!preview && mixNeedsInstall), let item = player.currentItem else { return }
		mixNeedsInstall = true
		warmup?.cancel()
		window = nil
		let rewindRate = reverse == nil ? nil : -speed
		if rewindRate != nil { stop(keepingAudio: true) }
		if scrubbing {
			scrubTask?.cancel()
			scrubTask = nil
			pendingScrub = nil
			node.stop()
			audibleScrubPosition = nil
		}
		do {
			if !preview {
				try installPendingMix()
			} else if isPreviewMix {
				for output in mixOutputs {
					let stereo = project.trackStereo?[output.channel] ?? .neutral
					let gain = level(output, project: project, solo: solo)
					liveProcessors[output.id]?.update(stereo.matrix(gain: Double(gain)), smoothing: project.trackEffects?[output.channel]?.smoothing, inputGain: Double(output.gain(in: project)))
				}
			} else {
				item.audioMix = try audioMix(project, solo: solo, live: true, previewingChanges: true)
			}
		} catch { failure = error.localizedDescription }
		updatePrimaryLevels(project)
		if let rewindRate {
			playReverse(rewindRate, item: item)
			transport.shuttleRate = -rewindRate
		}
	}

	private func updatePrimaryLevels(_ project: EditingProject) {
		primaryStereo = project.trackStereo?[TimelineTrack.primaryAudio.id] ?? .neutral
		narrationStereo = project.trackStereo?[EditingProject.descriptionMixID] ?? .neutral
		masterLevel = project.masterVolume ?? 1
		narrationLevel = project.mutedTracks?.contains(EditingProject.descriptionMixID) == true ? 0 : masterLevel * (project.trackVolumes?[EditingProject.descriptionMixID] ?? 1)
		primaryLevels = [:]
		for output in mixOutputs where output.channel == TimelineTrack.primaryAudio.id {
			primaryLevels[output.id] = level(output, project: project, solo: [])
		}
	}

	private func insertTake(_ take: DescriptionTake, url: URL, in composition: AVMutableComposition, media: StereoMedia) async throws -> AVMutableAudioMixInputParameters {
		let parameters = try await take.insert(in: composition, url: url)
		guard let track = composition.track(withTrackID: parameters.trackID),
			let segment = track.segments.first(where: { !$0.isEmpty }) else { throw CocoaError(.fileReadCorruptFile) }
		let asset = AVURLAsset(url: url)
		guard let input = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
		let mapping = segment.timeMapping
		let (source, range) = try await media.source(asset, track: input, range: mapping.source)
		if source !== input {
			track.removeTimeRange(mapping.target)
			try track.insertTimeRange(range, of: source, at: mapping.target.start)
			if range.duration != mapping.target.duration {
				track.scaleTimeRange(CMTimeRange(start: mapping.target.start, duration: range.duration), toDuration: mapping.target.duration)
			}
		}
		return parameters
	}

	func descriptionPreview(range: CMTimeRange, take: DescriptionTake?, url: URL?, duck: Bool = true) async throws -> AVPlayerItem {
		let item = player.currentItem
		let composition: AVMutableComposition
		if ready, let copy = item?.asset.mutableCopy() as? AVMutableComposition { composition = copy }
		else if !duck && duration == .zero { composition = AVMutableComposition() }
		else {
			throw ProjectFailure("Wait for the project timeline to finish loading.")
		}
		var levels: [AVMutableAudioMixInputParameters] = []
		for track in try await composition.loadTracks(withMediaType: .audio) {
			if let volume = primaryLevels[track.trackID] {
				let mix = AVMutableAudioMixInputParameters(track: track)
				try setLevel(volume, stereo: primaryStereo, on: mix, output: mixOutputs.first { $0.id == track.trackID })
				let ducking = duck ? descriptionDucking?.volumeRamps(takes: take.map { [$0] } ?? [], duration: range.end) ?? [] : []
				mix.applyTransitions(mixOutputs.first { $0.id == track.trackID }?.envelopes ?? [], base: 1, ducking: ducking, duration: duration)
				levels.append(mix)
			} else { composition.removeTrack(track) }
		}
		if let take, let url {
			let takeMedia = StereoMedia()
			let parameters = try await insertTake(take, url: url, in: composition, media: takeMedia)
			try setLevel(duck ? narrationLevel : masterLevel, stereo: duck ? narrationStereo : .neutral, on: parameters, media: takeMedia)
			levels.append(parameters)
		}
		let preview = AVPlayerItem(asset: composition)
		let mix = AVMutableAudioMix()
		mix.inputParameters = levels
		preview.audioMix = mix
		preview.videoComposition = item?.videoComposition
		preview.forwardPlaybackEndTime = range.end
		return preview
	}


	static func isOpen(_ id: UUID) -> Bool {
		openPlayers.allObjects.contains { $0.projectID == id }
	}

	func measureAudition(_ project: EditingProject, channel: String) async throws {
		for index in mixOutputs.indices where mixOutputs[index].channel == channel && mixOutputs[index].measurement == nil {
			guard let id = mixOutputs[index].auditionClip, let clip = project.placements.first(where: { $0.id == id }),
				let source = project.sources.first(where: { $0.id == clip.sourceID }), let access = media[clip.sourceID] else { throw CocoaError(.fileReadCorruptFile) }
			let measurement = try await measurements.measure(clip, source: source, asset: access.asset)
			try Task.checkCancellation()
			mixOutputs[index].measurement = measurement
		}
	}

	func prepare(_ project: EditingProject, audition: TimelineTrack? = nil) async {
		if audition == nil { measurements.retainClips(in: project) }
		if audition == nil && !Self.isOpen(project.id) { ProjectStorage.pruneUnusedRecordings(project) }
		if projectID != project.id { mixSolo = [] }
		projectID = project.id
		mixProject = project
		mixNeedsInstall = false
		Self.openPlayers.add(self)
		cancelPreparation()
		mixerLoop = nil
		let request = generation
		pause()
		window = nil
		failure = nil
		ready = false
		ended = nil
		playbackFailed = nil
		player.replaceCurrentItem(with: nil)
		media = [:]
		liveProcessors = [:]
		stereoMedia = StereoMedia()
		duration = project.duration
		preparing = duration > .zero
		playhead.position = min(position, duration)
		guard duration > .zero else { return }
		let composition = AVMutableComposition()
		var sources: [UUID: ProjectMediaAccess] = [:]
		var quality = MediaQuality()
		var layers: [(CMTimeRange, AVMutableVideoCompositionLayerInstruction)] = []
		var transitionLayers: [TransitionVideoLayer] = []
		let generatedVideoIDs = Set(project.sources.filter { $0.generator != nil && $0.picture != nil }.map(\.id))
		let usesTransitions = project.transitions?.isEmpty == false || project.placements.contains { $0.compositing != nil || generatedVideoIDs.contains($0.sourceID) }
		let preparedMedia = StereoMedia()
		var builtOutputs: [MixOutput] = []
		var currentName = ""
		do {
			for track in project.tracks {
				var videoOutput: AVMutableCompositionTrack?
				var audioOutputs: [Float: AVMutableCompositionTrack] = [:]
				for clip in project.clips(on: track) {
					try Task.checkCancellation()
					guard let source = project.sources.first(where: { $0.id == clip.sourceID }) else { throw CocoaError(.fileReadCorruptFile) }
					currentName = source.name
					let access: ProjectMediaAccess
					if let existing = sources[source.id] { access = existing }
					else {
						access = try await source.open()
						sources[source.id] = access
						quality.include(try await MediaQuality.inspect(access.asset))
					}
					guard try await access.asset.load(.duration) >= (clip.ranges.map { $0.range.end }.max() ?? .zero) else { throw CocoaError(.fileReadCorruptFile) }
					for type in [AVMediaType.video, .audio] {
						if type == .video && audition?.kind == .audio { continue }
						if type == .audio && clip.omitAudio == true { continue }
						let selected = type == .audio ? try await MediaQuality.playbackAudioTrack(access.asset) : try await access.asset.loadTracks(withMediaType: type).first
						guard let input = selected else {
							if type == .video && source.picture != nil || type == .audio && source.hasAudio { throw CocoaError(.fileReadCorruptFile) }
							continue
						}
						let channel = track.kind == .video ? project.audioPartner(for: track.id)?.id ?? track.id : track.id
						let needsMeasurement = type == .audio && project.trackEffects?[channel]?.loudness != nil
						let measurement = needsMeasurement ? try await measurements.measure(clip, source: source, asset: access.asset) : nil
						let clipGain = clip.loudnessGain ?? 1
						let renderedGain = project.trackEffects?[channel]?.loudness.flatMap { measurement?.gain(for: $0) } ?? clipGain
						let clipHasTransitions = !project.transitions(for: clip, channel: type == .audio ? channel : track.id).isEmpty
						let existing = clipHasTransitions ? nil : (type == .audio ? (audition != nil ? nil : audioOutputs[renderedGain]) : videoOutput)
						let output: AVMutableCompositionTrack
						if let existing { output = existing }
						else {
							guard let created = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
								throw CocoaError(.featureUnsupported)
							}
							output = created
							if type == .audio {
								if !clipHasTransitions { audioOutputs[renderedGain] = output }
								builtOutputs.append(MixOutput(id: output.trackID, channel: channel, video: channel == track.id ? nil : track.id, clipGain: clipGain, envelopes: project.audioEnvelopes(for: clip, channel: channel), auditionClip: audition != nil ? clip.id : nil, measurement: measurement))
							} else if !clipHasTransitions { videoOutput = output }
						}
						let available = try await input.load(.timeRange)
						let transitionMedia = project.transitionMedia(for: clip, channel: type == .audio ? channel : track.id)
						var cursor = transitionMedia.start
						for range in transitionMedia.ranges {
							let overlap = range.intersection(available)
							if overlap.isValid && !overlap.isEmpty {
								let (sourceTrack, sourceRange) = type == .audio ? try await preparedMedia.source(access.asset, track: input, range: overlap) : (input, overlap)
								try output.insertTimeRange(sourceRange, of: sourceTrack, at: cursor + (overlap.start - range.start))
							}
							cursor = cursor + range.duration
						}
						if type == .video, let picture = project.picture {
							let size = try await input.load(.naturalSize)
							let transform = try await input.load(.preferredTransform)
							let rect = CGRect(origin: .zero, size: size).applying(transform)
							let scale = min(CGFloat(picture.width) / rect.width, CGFloat(picture.height) / rect.height)
							let offset = CGAffineTransform(translationX: (CGFloat(picture.width) - rect.width * scale) / 2,
								y: (CGFloat(picture.height) - rect.height * scale) / 2)
							let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: output)
							layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
								.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(offset), at: clip.start.time)
							layers.append((CMTimeRange(start: clip.start.time, end: clip.end), layer))
							let generatedImage: CIImage?
							if let definition = clip.generatorOverride ?? source.generator {
								generatedImage = try await GeneratorRenderer.preparedImage(definition, size: CGSize(width: picture.width, height: picture.height))
							} else { generatedImage = nil }
							transitionLayers.append(TransitionVideoLayer(id: output.trackID, clipID: clip.id, trackID: track.id,
								range: CMTimeRange(start: transitionMedia.start, end: cursor),
								transform: transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
									.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(offset),
								generatedImage: generatedImage,
								compositing: clip.compositing ?? ClipCompositing()))
						}
					}
				}
			}
			for take in project.audioDescriptions ?? [] where take.start.time < duration {
				try Task.checkCancellation()
				currentName = take.name
				let url = try ProjectStorage.recording(take.recording, project: project.id)
				let parameters = try await insertTake(take, url: url, in: composition, media: preparedMedia)
				builtOutputs.append(MixOutput(id: parameters.trackID, channel: EditingProject.descriptionMixID))
			}
			if composition.duration > duration { composition.removeTimeRange(CMTimeRange(start: duration, end: composition.duration)) }
			try Task.checkCancellation()
			guard generation == request else { return }
			if composition.duration < duration { composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: duration)) }
			let item = AVPlayerItem(asset: composition)
			if layers.isEmpty { quality.hdr = false }
			mediaQuality = quality
			stereoMedia = preparedMedia
			mixOutputs = builtOutputs
			if !builtOutputs.isEmpty {
				do { try configureAudioSession() } catch {
					preparing = false
					failure = "Could not prepare project audio. Check the audio output and reopen the project."
					return
				}
				item.audioMix = try audioMix(mixProject ?? project, solo: mixSolo, live: true)
			}
			if !layers.isEmpty, let picture = project.picture {
				let boundaries = ([CMTime.zero, duration] + layers.flatMap { [$0.0.start, $0.0.end] }).sorted()
				var instructions: [AVMutableVideoCompositionInstruction] = []
				for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
					let instruction = Self.background(from: start, to: end)
					if let visible = layers.first(where: { $0.0.containsTime(start) }) {
						instruction.layerInstructions = [visible.1]
					}
					instructions.append(instruction)
				}
				let video = AVMutableVideoComposition()
				video.renderSize = CGSize(width: picture.width, height: picture.height)
				video.frameDuration = picture.frame.time
				if quality.hdr { MediaExportSupport.configureHDR(video) }
				if usesTransitions {
					let boundaries = Set([CMTime.zero, duration] + transitionLayers.flatMap { [$0.range.start, $0.range.end] }).sorted()
					video.customVideoCompositorClass = quality.hdr ? HDRTransitionCompositor.self : TransitionCompositor.self
					video.instructions = zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
						guard start < end else { return nil }
						return TransitionInstruction(range: CMTimeRange(start: start, end: end),
							layers: transitionLayers.filter { $0.range.containsTime(start) }, project: project, size: video.renderSize)
					}
				} else { video.instructions = instructions }
				item.videoComposition = video
			}
			media = sources
			updatePrimaryLevels(mixProject ?? project)
			descriptionDucking = project.descriptionDucking
			ended = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
				.receive(on: DispatchQueue.main)
				.sink { [weak self, weak item] _ in
					guard let self, let item, self.player.currentItem === item,
						self.playing, self.speed > 0 else { return }
					if let range = self.playbackRange, self.player.currentTime() >= range.end {
						self.restartLoop(at: range.start)
					} else if self.player.currentTime() >= self.duration { self.pause() }
				}
			playbackFailed = NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
				.receive(on: DispatchQueue.main)
				.sink { [weak self, weak item] _ in
					guard let self, let item, self.player.currentItem === item else { return }
					self.startup?.cancel()
					self.preparing = false
					self.pause()
					self.failure = "Could not play the project preview. Reopen the project to reload its media."
				}
			player.replaceCurrentItem(with: item)
			status = player.publisher(for: \.status).combineLatest(item.publisher(for: \.status))
				.receive(on: DispatchQueue.main)
				.sink { [weak self, weak item] _ in
					guard let self, let item, self.player.currentItem === item else { return }
					if item.status == .failed || self.player.status == .failed {
						self.startup?.cancel()
						self.ready = false
						self.preparing = false
						self.pause()
						self.failure = "Could not play the timeline. Reconnect the affected clip in Project Media."
					} else if self.preparing, self.startup == nil,
						self.player.status == .readyToPlay, item.status == .readyToPlay {
						self.startup = Task { await self.preparePlayback(item) }
					}
				}
		} catch {
			if generation == request {
				preparing = false
				if !Task.isCancelled { failure = "Could not play " + currentName + ". Reconnect the clip in Project Media." }
			}
		}
	}

	private func preparePlayback(_ item: AVPlayerItem) async {
		let start = playhead.position
		let positioned = await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
		guard !Task.isCancelled, player.currentItem === item else { return }
		var primed = positioned && player.status == .readyToPlay
		if primed, start < duration {
			primed = await player.preroll(atRate: 1)
		}
		guard !Task.isCancelled, player.currentItem === item else { return }
		ready = primed
		preparing = false
		startup = nil
		if !primed { failure = "Could not prepare playback. Close and reopen the project." }
	}

	private static func background(from start: CMTime, to end: CMTime) -> AVMutableVideoCompositionInstruction {
		let instruction = AVMutableVideoCompositionInstruction()
		instruction.timeRange = CMTimeRange(start: start, end: end)
		instruction.layerInstructions = []
		return instruction
	}
}

@MainActor struct ProjectExport {
	let name: String
	let captions: [CaptionCue]
	let item: AVPlayerItem
	let duration: CMTime
	// Keep security-scoped files open through rendering.
	let sources: [ProjectMediaAccess]
	let quality: MediaQuality
	var hasVideo: Bool { item.videoComposition != nil }

	func render(burnInCaptions: Bool = false, allowStereo: Bool = false) async throws -> ExportFile {
		if quality.needsAudioChoice && !allowStereo { throw MediaExportFailure.spatialProcessing }
		let type: AVFileType = hasVideo ? (quality.hdr ? .mov : .mp4) : .m4a
		let exporter = try await MediaExportSupport.exporter(asset: item.asset, video: hasVideo, hdr: quality.hdr, type: type)
		if burnInCaptions, let composition = item.videoComposition, !captions.isEmpty {
			exporter.videoComposition = try await captionedComposition(composition)
		} else {
			exporter.videoComposition = item.videoComposition
		}
		exporter.audioMix = item.audioMix
		exporter.timeRange = CMTimeRange(start: .zero, duration: duration)
		guard exporter.supportedFileTypes.contains(type) else {
			throw ProjectFailure("Could not export this media format. Check the project settings and try again.")
		}
		let output = try Self.temporaryFile(named: name, suffix: type == .mp4 ? "mp4" : type == .mov ? "mov" : "m4a")
		try await exporter.export(to: output.url, as: type)
		try await MediaExportSupport.validate(output.url, hdr: quality.hdr)
		try Task.checkCancellation()
		return output
	}

	static func temporaryFile(named name: String, suffix: String) throws -> ExportFile {
		try ExportFile(name: name, suffix: suffix)
	}

	private func captionedComposition(_ original: AVVideoComposition) async throws -> AVVideoComposition {
		guard let composition = original.mutableCopy() as? AVMutableVideoComposition else {
			throw ProjectFailure("Could not prepare the video for open captions.")
		}
		let size = composition.renderSize
		var starts = [CMTime: [Int]]()
		var ends = [CMTime: [Int]]()
		for (index, cue) in captions.enumerated() {
			let start = max(.zero, cue.start.time)
			let end = min(duration, cue.end.time)
			guard start < end else { continue }
			starts[start, default: []].append(index)
			ends[end, default: []].append(index)
		}
		let times = Set(starts.keys).union(ends.keys).sorted()
		var active = IndexSet()
		var changes = [CaptionPanelChange]()
		for time in times {
			await Task.yield()
			try Task.checkCancellation()
			for index in ends[time] ?? [] { active.remove(index) }
			for index in starts[time] ?? [] { active.insert(index) }
			var image: Data?
			if !active.isEmpty {
				let text = active.map { captions[$0].text }.joined(separator: "\n")
				let panel = CaptionPanel(text: text, height: size.height)
					.frame(width: size.width * CaptionPanel.widthFraction)
				guard let png = ImageRenderer(content: panel).uiImage?.pngData() else {
					throw ProjectFailure("Could not render the caption text.")
				}
				image = png
			}
			changes.append(CaptionPanelChange(time: time, image: image))
		}
		let panels = CaptionPanelTimeline(changes: changes)
		if original.instructions.first is TransitionInstruction {
			composition.instructions = try original.instructions.map {
				guard let instruction = $0 as? TransitionInstruction else { throw CocoaError(.fileReadCorruptFile) }
				return TransitionInstruction(instruction, panels: panels)
			}
			return composition
		}
		let instructions = try original.instructions.map { instruction in
			guard let video = instruction as? AVVideoCompositionInstruction else {
				throw ProjectFailure("Could not read the project video layout.")
			}
			return CaptionCompositionInstruction(video, panels: panels)
		}
		composition.customVideoCompositorClass = quality.hdr ? HDRCaptionCompositor.self : CaptionCompositor.self
		composition.instructions = instructions
		return composition
	}
}

nonisolated struct CaptionPanelChange {
	let time: CMTime
	let image: Data?
}

nonisolated struct CaptionPanelTimeline {
	let changes: [CaptionPanelChange]

	func image(at time: CMTime) -> Data? {
		var lower = 0
		var upper = changes.count
		while lower < upper {
			let middle = lower + (upper - lower) / 2
			if changes[middle].time <= time { lower = middle + 1 }
			else { upper = middle }
		}
		return lower > 0 ? changes[lower - 1].image : nil
	}
}

nonisolated private final class CaptionCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
	let timeRange: CMTimeRange
	let enablePostProcessing = false
	let containsTweening = false
	let passthroughTrackID = kCMPersistentTrackID_Invalid
	var requiredSourceTrackIDs: [NSValue]? { pictureTrack.map { [NSNumber(value: $0)] } ?? [] }
	let pictureTrack: CMPersistentTrackID?
	let transform: CGAffineTransform
	let panels: CaptionPanelTimeline

	init(_ original: AVVideoCompositionInstruction, panels: CaptionPanelTimeline) {
		timeRange = original.timeRange
		self.panels = panels
		let layer = original.layerInstructions.first
		pictureTrack = layer?.trackID
		var matrix = CGAffineTransform.identity
		layer?.getTransformRamp(for: original.timeRange.start, start: &matrix, end: nil, timeRange: nil)
		transform = matrix
	}
}

nonisolated private class CaptionCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
	var hdr: Bool { false }
	var supportsHDRSourceFrames: Bool { hdr }
	var supportsWideColorSourceFrames: Bool { hdr }
	var sourcePixelBufferAttributes: [String: any Sendable]? {
		[kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA]
	}
	var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
		[kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA]
	}
	private let context = CIContext(options: [.cacheIntermediates: false])
	private let hdrContext = CIContext(options: [.workingColorSpace: MediaExportSupport.hdrWorkingSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
	// NSCache supports concurrent requests from AVFoundation.
	nonisolated(unsafe) private let panels = NSCache<NSData, CIImage>()

	override init() {
		super.init()
		panels.countLimit = 3
	}

	func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

	func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
		guard let instruction = request.videoCompositionInstruction as? CaptionCompositionInstruction,
			let buffer = request.renderContext.newPixelBuffer() else {
			request.finish(with: ProjectFailure("Could not prepare an output video frame."))
			return
		}
		let size = request.renderContext.size
		let bounds = CGRect(origin: .zero, size: size)
		var image = CIImage(color: .black).cropped(to: bounds)
		var colorSpace = CGColorSpace(name: CGColorSpace.itur_709)
		if let track = instruction.pictureTrack, let frame = request.sourceFrame(byTrackID: track) {
			let source = CIImage(cvPixelBuffer: frame)
			colorSpace = source.colorSpace ?? colorSpace
			// The timeline uses top-left coordinates. Core Image uses bottom-left coordinates.
			let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: source.extent.height)
			let flipOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
			image = source.transformed(by: flipSource.concatenating(instruction.transform).concatenating(flipOutput))
				.composited(over: image)
		}
		if let data = instruction.panels.image(at: request.compositionTime) {
			let key = data as NSData
			guard let panel = panels.object(forKey: key) ?? CIImage(data: data) else {
				request.finish(with: ProjectFailure("Could not read the caption image."))
				return
			}
			panels.setObject(panel, forKey: key)
			let point = CGAffineTransform(translationX: (size.width - panel.extent.width) / 2,
				y: size.height * CaptionPanel.bottomFraction)
			image = panel.transformed(by: point).composited(over: image)
		}
		if hdr { MediaExportSupport.markHDR(buffer) }
		(hdr ? hdrContext : context).render(image, to: buffer, bounds: bounds, colorSpace: hdr ? MediaExportSupport.hdrColorSpace : colorSpace)
		request.finish(withComposedVideoFrame: buffer)
	}
}

nonisolated private final class HDRCaptionCompositor: CaptionCompositor, @unchecked Sendable {
	override var hdr: Bool { true }
}
