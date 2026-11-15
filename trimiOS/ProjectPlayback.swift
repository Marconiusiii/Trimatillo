import AVFoundation
import Combine
import UIKit

@MainActor final class ProjectPlayhead: ObservableObject {
	@Published var position: CMTime = .zero
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
	private var ended: AnyCancellable?
	@Published private(set) var shuttleRate: Double = 0
	@Published private(set) var playing = false
	@Published private(set) var ready = false
	@Published var failure: String?
	private var media: [UUID: ProjectMediaAccess] = [:]
	private var observer: Any?
	private var status: NSKeyValueObservation?
	private var audioActive = false
	private var generation = 0
	private var reverse: Task<Void, Never>?
	private var scrubbing = false
	private var pendingScrub: CMTime?
	private var scrubTask: Task<Void, Never>?
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
				self.playhead.position = min(time, self.duration)
			}
		}
	}

	deinit { if let observer { player.removeTimeObserver(observer) } }

	func exportTimeline(named name: String) -> ProjectExport? {
		guard ready, let item = player.currentItem else { return nil }
		pause()
		return ProjectExport(name: name, item: item, duration: duration, sources: Array(media.values))
	}

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
		scrubTask?.cancel()
		scrubTask = nil
		pendingScrub = nil
		reverse?.cancel()
		reverse = nil
		if wasRewinding || scrubbing {
			scrubbing = false
			node.stop()
			engine.stop()
		}
		speed = 0
		if shuttleRate != 0 { shuttleRate = 0 }
		player.pause()
		if !wasRewinding, playing, player.currentTime().isNumeric { playhead.position = min(duration, player.currentTime()) }
		if playing { playing = false }
		if audioActive {
			try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
			audioActive = false
		}
	}

	func toggle() {
		guard ready else { return }
		if playing { pause(); return }
		if scrubbing { setScrubbing(false) }
		if position >= duration { seek(.zero) }
		playForward(1)
	}

	private func activateAudio() throws {
		guard !audioActive else { return }
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
		try session.setActive(true)
		audioActive = true
	}

	private func playForward(_ rate: Double) {
		do {
			try activateAudio()
			speed = rate
			if rate == 1 { player.play() }
			else { player.playImmediately(atRate: Float(rate)) }
			playing = true
		} catch { failure = "Could not start project audio. Check the audio output and choose Play again." }
	}

	func shuttle(forward: Bool) {
		guard ready else { return }
		let current = forward ? shuttleRate : -shuttleRate
		guard let next = [1.0, 1.5, 2, 4, 8].first(where: { $0 > current }) else { return }
		pause()
		if forward {
			if position >= duration { seek(.zero) }
			playForward(next)
		} else if let item = player.currentItem {
			if position <= .zero { seek(duration) }
			let start = position
			do {
				try activateAudio()
			} catch { failure = "Could not rewind. Check the audio output and try again."; return }
			playing = true
			speed = -next
			reverse = Task {
				do {
					let hasAudio = try await !item.asset.loadTracks(withMediaType: .audio).isEmpty
					try await ReverseAudioPlayback.run(from: start, speed: next, asset: item.asset, mix: item.audioMix,
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
		if playing {
			shuttleRate = speed
			UIAccessibility.post(notification: .announcement, argument: (forward ? "Forward " : "Rewind ") + next.formatted() + "x")
		}
	}

	func setScrubbing(_ active: Bool) {
		guard active != scrubbing else { return }
		pause()
		if active, ready {
			scrubbing = true
			scrub(to: position)
		} else {
			seek(position)
		}
	}

	func scrub(to time: CMTime) {
		guard scrubbing, let item = player.currentItem else {
			seek(time)
			return
		}
		playhead.position = min(duration, max(.zero, time))
		pendingScrub = playhead.position
		guard scrubTask == nil else { return }
		// Preview the latest position instead of queuing each touch behind a decode.
		scrubTask = Task {
			defer { if !Task.isCancelled { scrubTask = nil } }
			do {
				while let point = pendingScrub {
					try Task.checkCancellation()
					pendingScrub = nil
					player.seek(to: point, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
					if let mix = item.audioMix {
						let samples = try await FrameAudioSamples.read(asset: item.asset, mix: mix, at: point)
						try Task.checkCancellation()
						node.stop()
						if let buffer = ReverseAudioPlayback.pcmBuffer(samples, format: format) {
							try activateAudio()
							if !engine.isRunning { try engine.start() }
							node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in }
							node.play()
						}
					}
					try await Task.sleep(for: .milliseconds(65))
				}
			} catch {
				if !Task.isCancelled {
					setScrubbing(false)
					failure = "Could not preview project audio. Check the audio output and try again."
				}
			}
		}
	}

	func seek(_ time: CMTime) {
		if playing || scrubbing { pause() }
		playhead.position = min(duration, max(.zero, time))
		player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
	}

	func prepare(_ project: EditingProject) async {
		generation += 1
		let request = generation
		pause()
		ready = false
		status = nil
		ended = nil
		player.replaceCurrentItem(with: nil)
		media = [:]
		duration = project.duration
		playhead.position = min(position, duration)
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
			ended = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
				.receive(on: DispatchQueue.main)
				.sink { [weak self, weak item] _ in
					guard let self, let item, self.player.currentItem === item,
						self.playing, self.speed > 0, self.player.currentTime() >= self.duration else { return }
					self.pause()
				}
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

@MainActor struct ProjectExport {
	let name: String
	let item: AVPlayerItem
	let duration: CMTime
	// Keep security-scoped files open through rendering.
	let sources: [ProjectMediaAccess]
	var hasVideo: Bool { item.videoComposition != nil }

	func render() async throws -> ExportFile {
		let preset = hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
		guard let exporter = AVAssetExportSession(asset: item.asset, presetName: preset) else {
			throw ProjectFailure("Could not prepare the export. Reopen the project and try again.")
		}
		exporter.videoComposition = item.videoComposition
		exporter.audioMix = item.audioMix
		exporter.timeRange = CMTimeRange(start: .zero, duration: duration)
		let type: AVFileType = hasVideo ? (exporter.supportedFileTypes.contains(.mp4) ? .mp4 : .mov) : .m4a
		guard exporter.supportedFileTypes.contains(type) else {
			throw ProjectFailure("Could not export this media format. Check the project settings and try again.")
		}
		let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
		let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
		let cleaned = name.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
		let stem = String(decoding: cleaned.utf8.prefix(240), as: UTF8.self)
		let file = directory.appending(component: stem.isEmpty ? "Project" : stem)
			.appendingPathExtension(type == .mp4 ? "mp4" : type == .mov ? "mov" : "m4a")
		let output = ExportFile(url: file)
		try await exporter.export(to: file, as: type)
		try Task.checkCancellation()
		return output
	}
}
