import AVFoundation
import Combine

@MainActor final class ProjectPlayback: ObservableObject {
	let player = AVPlayer()
	@Published private(set) var position: CMTime = .zero
	@Published private(set) var playing = false
	@Published private(set) var ready = false
	@Published var failure: String?
	private var media: [UUID: ProjectMediaAccess] = [:]
	private var observer: Any?
	private var status: NSKeyValueObservation?
	private var audioActive = false
	private var generation = 0
	private var reverse: Task<Void, Never>?
	private let engine = AVAudioEngine()
	private let node = AVAudioPlayerNode()
	private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
	private var speed: Double = 0
	private var duration: CMTime = .zero

	init() {
		engine.attach(node)
		engine.connect(node, to: engine.mainMixerNode, format: format)
		observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.playing, self.reverse == nil else { return }
				let time = self.player.currentTime()
				guard time.isNumeric else { return }
				self.position = min(time, self.duration)
				if (time >= self.duration || time <= .zero) && self.player.rate == 0 { self.pause() }
			}
		}
	}

	deinit { if let observer { player.removeTimeObserver(observer) } }

	func makePreview() -> PreviewPlayback? {
		guard let item = player.currentItem else { return nil }
		let forwardRate = max(0, speed)
		pause()
		return PreviewPlayback(item: item, start: position, rate: Float(forwardRate)) { [weak self] time in
			self?.seek(time)
		}
	}

	func pause() {
		let wasRewinding = reverse != nil
		reverse?.cancel()
		reverse = nil
		node.stop()
		engine.stop()
		speed = 0
		player.pause()
		if !wasRewinding, playing, player.currentTime().isNumeric { position = min(duration, player.currentTime()) }
		playing = false
		if audioActive {
			try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
			audioActive = false
		}
	}

	func toggle() {
		guard ready else { return }
		if playing { pause(); return }
		if position >= duration { seek(.zero) }
		playForward(1)
	}

	private func playForward(_ rate: Double) {
		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
			try session.setActive(true)
			audioActive = true
			speed = rate
			player.playImmediately(atRate: Float(rate))
			playing = true
		} catch { failure = "Could not start project audio. Check the audio output and choose Play again." }
	}

	func shuttle(forward: Bool) {
		guard ready else { return }
		let current = forward ? speed : -speed
		guard let next = [1.0, 1.5, 2, 4, 8].first(where: { $0 > current }) else { return }
		pause()
		if forward {
			if position >= duration { seek(.zero) }
			playForward(next)
		} else if let item = player.currentItem {
			if position <= .zero { seek(duration) }
			let start = position
			do {
				let audio = AVAudioSession.sharedInstance()
				try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
				try audio.setActive(true)
				audioActive = true
			} catch { failure = "Could not rewind. Check the audio output and try again."; return }
			playing = true
			speed = -next
			reverse = Task {
				do {
					let hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty
					try await ReverseAudioPlayback.run(from: start, speed: next, asset: item.asset, mix: item.audioMix,
						hasAudio: hasAudio, engine: engine, node: node, format: format) { time in
						position = time
						player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
					}
					try Task.checkCancellation()
					seek(.zero)
				} catch {
					if !Task.isCancelled { pause(); failure = "Could not rewind the project. Check the audio output and try again." }
				}
			}
		}
	}

	func seek(_ time: CMTime) {
		pause()
		position = min(duration, max(.zero, time))
		player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
	}

	func prepare(_ project: EditingProject) async {
		generation += 1
		let request = generation
		pause()
		ready = false
		status = nil
		player.replaceCurrentItem(with: nil)
		media = [:]
		duration = project.duration
		position = min(position, duration)
		guard duration > .zero else { return }
		let composition = AVMutableComposition()
		var sources: [UUID: ProjectMediaAccess] = [:]
		var layers: [(CMTimeRange, AVMutableVideoCompositionLayerInstruction)] = []
		var levels: [AVMutableAudioMixInputParameters] = []
		var currentName = ""
		do {
			for track in project.tracks {
				var outputs: [AVMediaType: AVMutableCompositionTrack] = [:]
				for clip in project.clips(on: track) {
					try Task.checkCancellation()
					guard let source = project.sources.first(where: { $0.id == clip.sourceID }) else { throw CocoaError(.fileReadCorruptFile) }
					currentName = source.name
					let access: ProjectMediaAccess
					if let existing = sources[source.id] { access = existing }
					else {
						access = try await source.open()
						sources[source.id] = access
					}
					guard try await access.asset.load(.duration) >= (clip.ranges.map { $0.range.end }.max() ?? .zero) else { throw CocoaError(.fileReadCorruptFile) }
					for type in [AVMediaType.video, .audio] {
						if type == .audio && clip.omitAudio == true { continue }
						guard let input = try await access.asset.loadTracks(withMediaType: type).first else {
							if type == .video && source.picture != nil || type == .audio && source.hasAudio { throw CocoaError(.fileReadCorruptFile) }
							continue
						}
						if outputs[type] == nil {
							outputs[type] = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
							if type == .audio, let output = outputs[type] {
								let parameters = AVMutableAudioMixInputParameters(track: output)
								var volume = project.trackVolumes?[track.id] ?? 1
								if track == .primaryVideo { volume *= project.trackVolumes?[TimelineTrack.primaryAudio.id] ?? 1 }
								parameters.setVolume(volume, at: .zero)
								levels.append(parameters)
							}
						}
						guard let output = outputs[type] else { throw CocoaError(.featureUnsupported) }
						let available = try await input.load(.timeRange)
						var cursor = clip.start.time
						for range in clip.ranges.map(\.range) {
							let overlap = range.intersection(available)
							if overlap.isValid && !overlap.isEmpty {
								try output.insertTimeRange(overlap, of: input, at: cursor + (overlap.start - range.start))
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
						}
					}
				}
			}
			try Task.checkCancellation()
			guard generation == request else { return }
			if composition.duration < duration { composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: duration)) }
			let item = AVPlayerItem(asset: composition)
			if !levels.isEmpty {
				let mix = AVMutableAudioMix()
				mix.inputParameters = levels
				item.audioMix = mix
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
				video.instructions = instructions
				item.videoComposition = video
			}
			media = sources
			player.replaceCurrentItem(with: item)
			seek(position)
			status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
				Task { @MainActor [weak self] in
					guard let self, self.player.currentItem === item else { return }
					self.ready = item.status == .readyToPlay
					if item.status == .failed {
						self.pause()
						self.failure = "Could not play the timeline. Reconnect the affected clip in Project Media."
					}
				}
			}
		} catch {
			if generation == request && !Task.isCancelled { failure = "Could not play " + currentName + ". Reconnect the clip in Project Media." }
		}
	}

	private static func background(from start: CMTime, to end: CMTime) -> AVMutableVideoCompositionInstruction {
		let instruction = AVMutableVideoCompositionInstruction()
		instruction.timeRange = CMTimeRange(start: start, end: end)
		instruction.layerInstructions = []
		return instruction
	}
}
