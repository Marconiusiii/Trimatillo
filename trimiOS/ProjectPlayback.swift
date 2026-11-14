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
	private var duration: CMTime = .zero

	init() {
		observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.playing else { return }
				let time = self.player.currentTime()
				guard time.isNumeric else { return }
				self.position = min(time, self.duration)
				if time >= self.duration { self.pause() }
			}
		}
	}

	deinit { if let observer { player.removeTimeObserver(observer) } }

	func pause() {
		player.pause()
		if playing, player.currentTime().isNumeric { position = min(duration, player.currentTime()) }
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
		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
			try session.setActive(true)
			audioActive = true
			player.play()
			playing = true
		} catch { failure = "Could not start project audio. Check the audio output and choose Play again." }
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
		var instructions: [AVMutableVideoCompositionInstruction] = []
		var videoEnd = CMTime.zero
		var currentName = ""
		do {
			for track in ProjectTrack.allCases {
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
						guard let input = try await access.asset.loadTracks(withMediaType: type).first else {
							if type == .video && source.picture != nil || type == .audio && source.hasAudio { throw CocoaError(.fileReadCorruptFile) }
							continue
						}
						if outputs[type] == nil { outputs[type] = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) }
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
							if clip.start.time > videoEnd {
								instructions.append(Self.background(from: videoEnd, to: clip.start.time))
							}
							let size = try await input.load(.naturalSize)
							let transform = try await input.load(.preferredTransform)
							let rect = CGRect(origin: .zero, size: size).applying(transform)
							let scale = min(CGFloat(picture.width) / rect.width, CGFloat(picture.height) / rect.height)
							let offset = CGAffineTransform(translationX: (CGFloat(picture.width) - rect.width * scale) / 2,
								y: (CGFloat(picture.height) - rect.height * scale) / 2)
							let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: output)
							layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
								.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(offset), at: clip.start.time)
							let instruction = Self.background(from: clip.start.time, to: clip.end)
							instruction.layerInstructions = [layer]
							instructions.append(instruction)
							videoEnd = clip.end
						}
					}
				}
			}
			try Task.checkCancellation()
			guard generation == request else { return }
			if composition.duration < duration { composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: duration)) }
			let item = AVPlayerItem(asset: composition)
			if !instructions.isEmpty, let picture = project.picture {
				if videoEnd < duration { instructions.append(Self.background(from: videoEnd, to: duration)) }
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
