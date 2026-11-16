import AVFoundation
import Combine
import UIKit
import Observation
import SwiftUI
import CoreImage

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

	static func read(item: AVPlayerItem, at time: CMTime) async throws -> Self {
		let start = max(0, frame(at: time) - 9600)
		let samples = try await FrameAudioSamples.read(asset: item.asset, mix: item.audioMix,
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
	private var captionLoop: CMTimeRange?
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
	private var audioActive = false
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

	func exportTimeline(named name: String, captions: [CaptionCue]) -> ProjectExport? {
		guard ready, let item = player.currentItem else { return nil }
		pause()
		return ProjectExport(name: name, captions: captions, item: item, duration: duration, sources: Array(media.values))
	}

	func makePreview() -> PreviewPlayback? {
		guard let item = player.currentItem else { return nil }
		let forwardRate = max(0, speed)
		pause()
		return PreviewPlayback(item: item, start: position, rate: Float(forwardRate)) { [weak self] time in
			self?.seek(time)
		}
	}

	func playCaptionSelection(_ range: CMTimeRange) {
		guard ready, range.isValid, range.duration > .zero, range.start >= .zero, range.end <= duration else { return }
		stop(keepingAudio: true)
		captionLoop = range
		player.currentItem?.forwardPlaybackEndTime = range.end
		restartCaptionLoop(range)
	}

	private func restartCaptionLoop(_ range: CMTimeRange) {
		let request = loopGeneration
		playhead.position = range.start
		player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
			Task { @MainActor [weak self] in
				guard let self, finished, request == loopGeneration, captionLoop != nil else { return }
				playForward(1)
			}
		}
	}

	func pause() { stop(keepingAudio: false) }

	private func stop(keepingAudio: Bool) {
		if captionLoop != nil {
			loopGeneration += 1
			captionLoop = nil
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
		if audioActive && !keepingAudio {
			try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
			audioActive = false
		}
	}

	func toggle() {
		guard ready else { return }
		if playing { pause(); return }
		if scrubbing {
			stop(keepingAudio: true)
			seek(position)
		}
		if framePreview != nil { stop(keepingAudio: true) }
		if position >= duration { seek(.zero) }
		playForward(1)
	}

	private func configureAudioSession() throws {
		let session = AVAudioSession.sharedInstance()
		if session.category != .playback || session.mode != .moviePlayback || !session.categoryOptions.contains(.mixWithOthers) {
			try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
		}
	}

	private func activateAudio() throws {
		guard !audioActive else { return }
		try configureAudioSession()
		try AVAudioSession.sharedInstance().setActive(true)
		audioActive = true
	}

	private func playForward(_ rate: Double) {
		warmup?.cancel()
		warmup = nil
		do {
			// AVPlayer activates the configured session when forward playback starts.
			try configureAudioSession()
			speed = rate
			if rate == 1 { player.play() }
			else { player.playImmediately(atRate: Float(rate)) }
			transport.playing = true
		} catch { failure = "Could not start project audio. Check the audio output and choose Play again." }
	}

	func shuttle(forward: Bool) {
		guard ready else { return }
		let current = forward ? transport.shuttleRate : -transport.shuttleRate
		guard let next = [1.0, 1.5, 2, 4, 8].first(where: { $0 > current }) else { return }
		stop(keepingAudio: true)
		if forward {
			if position >= duration { seek(.zero) }
			playForward(next)
		} else if let item = player.currentItem {
			if position <= .zero { seek(duration) }
			let start = position
			do {
				try activateAudio()
			} catch { failure = "Could not rewind. Check the audio output and try again."; return }
			transport.playing = true
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
			transport.shuttleRate = speed
			UIAccessibility.post(notification: .announcement, argument: (forward ? "Forward " : "Rewind ") + next.formatted() + "x")
		}
	}

	func stepWithAudio(forward: Bool, frame: CMTime) {
		guard ready, let item = player.currentItem else { return }
		stop(keepingAudio: true)
		let target = min(duration, max(.zero, position + (forward ? frame : .zero - frame)))
		let moved = target != position
		seek(target)
		guard moved, item.audioMix != nil else { pause(); return }
		let start = target == duration ? max(.zero, duration - frame) : target
		framePreview = Task {
			do {
				let samples = try await FrameAudioSamples.read(asset: item.asset, mix: item.audioMix,
					at: start, length: min(frame, duration - start).seconds)
				try Task.checkCancellation()
				if let buffer = ReverseAudioPlayback.pcmBuffer(samples, format: format) {
					try activateAudio()
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
			guard let decoded = try? await ScrubAudioWindow.read(item: item, at: target),
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
						let decoded = try await ScrubAudioWindow.read(item: item, at: point)
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
					try activateAudio()
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
		if playing || scrubbing || framePreview != nil { pause() }
		playhead.position = min(duration, max(.zero, time))
		player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
	}

	func cancelPreparation() {
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
	private var primaryLevels: [CMPersistentTrackID: Float] = [:]

	func descriptionPreview(range: CMTimeRange, take: DescriptionTake?, url: URL?) async throws -> AVPlayerItem {
		guard ready, let item = player.currentItem, let composition = item.asset.mutableCopy() as? AVMutableComposition else {
			throw ProjectFailure("Wait for the project timeline to finish loading.")
		}
		var levels: [AVMutableAudioMixInputParameters] = []
		for track in try await composition.loadTracks(withMediaType: .audio) {
			if let volume = primaryLevels[track.trackID] {
				let mix = AVMutableAudioMixInputParameters(track: track)
				mix.setVolume(volume, at: .zero)
				if let take { descriptionDucking?.apply(to: mix, volume: volume, takes: [take], duration: range.end) }
				levels.append(mix)
			} else { composition.removeTrack(track) }
		}
		if let take, let url { levels.append(try await take.insert(in: composition, url: url)) }
		let preview = AVPlayerItem(asset: composition)
		let mix = AVMutableAudioMix()
		mix.inputParameters = levels
		preview.audioMix = mix
		preview.videoComposition = item.videoComposition
		preview.forwardPlaybackEndTime = range.end
		return preview
	}


	static func isOpen(_ id: UUID) -> Bool {
		openPlayers.allObjects.contains { $0.projectID == id }
	}

	func prepare(_ project: EditingProject) async {
		if !Self.isOpen(project.id) { ProjectStorage.pruneUnusedRecordings(project) }
		projectID = project.id
		Self.openPlayers.add(self)
		cancelPreparation()
		let request = generation
		pause()
		window = nil
		ready = false
		ended = nil
		playbackFailed = nil
		player.replaceCurrentItem(with: nil)
		media = [:]
		duration = project.duration
		preparing = duration > .zero
		playhead.position = min(position, duration)
		guard duration > .zero else { return }
		let composition = AVMutableComposition()
		var sources: [UUID: ProjectMediaAccess] = [:]
		var layers: [(CMTimeRange, AVMutableVideoCompositionLayerInstruction)] = []
		var levels: [AVMutableAudioMixInputParameters] = []
		var primary: [CMPersistentTrackID: Float] = [:]
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
								if track.kind == .video, let partner = project.audioPartner(for: track.id) {
									volume *= project.trackVolumes?[partner.id] ?? 1
								}
								parameters.setVolume(volume, at: .zero)
								if track.id == TimelineTrack.primaryVideo.id || track.id == TimelineTrack.primaryAudio.id { primary[output.trackID] = volume }
								project.descriptionDucking?.apply(to: parameters, volume: volume, takes: project.audioDescriptions ?? [], duration: duration)
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
			for take in project.audioDescriptions ?? [] where take.start.time < duration {
				try Task.checkCancellation()
				currentName = take.name
				let url = try ProjectStorage.recording(take.recording, project: project.id)
				levels.append(try await take.insert(in: composition, url: url))
			}
			if composition.duration > duration { composition.removeTimeRange(CMTimeRange(start: duration, end: composition.duration)) }
			try Task.checkCancellation()
			guard generation == request else { return }
			if composition.duration < duration { composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: duration)) }
			let item = AVPlayerItem(asset: composition)
			if !levels.isEmpty {
				do { try configureAudioSession() } catch {
					preparing = false
					failure = "Could not prepare project audio. Check the audio output and reopen the project."
					return
				}
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
			primaryLevels = primary
			descriptionDucking = project.descriptionDucking
			ended = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
				.receive(on: DispatchQueue.main)
				.sink { [weak self, weak item] _ in
					guard let self, let item, self.player.currentItem === item,
						self.playing, self.speed > 0 else { return }
					if let range = self.captionLoop, self.player.currentTime() >= range.end {
						self.restartCaptionLoop(range)
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
	var hasVideo: Bool { item.videoComposition != nil }

	func render(burnInCaptions: Bool = false) async throws -> ExportFile {
		let preset = hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
		guard let exporter = AVAssetExportSession(asset: item.asset, presetName: preset) else {
			throw ProjectFailure("Could not prepare the export. Reopen the project and try again.")
		}
		if burnInCaptions, let composition = item.videoComposition, !captions.isEmpty {
			exporter.videoComposition = try await captionedComposition(composition)
		} else {
			exporter.videoComposition = item.videoComposition
		}
		exporter.audioMix = item.audioMix
		exporter.timeRange = CMTimeRange(start: .zero, duration: duration)
		let type: AVFileType = hasVideo ? (exporter.supportedFileTypes.contains(.mp4) ? .mp4 : .mov) : .m4a
		guard exporter.supportedFileTypes.contains(type) else {
			throw ProjectFailure("Could not export this media format. Check the project settings and try again.")
		}
		let output = try Self.temporaryFile(named: name, suffix: type == .mp4 ? "mp4" : type == .mov ? "mov" : "m4a")
		try await exporter.export(to: output.url, as: type)
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
		let instructions = try original.instructions.map { instruction in
			guard let video = instruction as? AVVideoCompositionInstruction else {
				throw ProjectFailure("Could not read the project video layout.")
			}
			return CaptionCompositionInstruction(video, panels: panels)
		}
		composition.customVideoCompositorClass = CaptionCompositor.self
		composition.instructions = instructions
		return composition
	}
}

nonisolated private struct CaptionPanelChange {
	let time: CMTime
	let image: Data?
}

nonisolated private struct CaptionPanelTimeline {
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

nonisolated private final class CaptionCompositor: NSObject, AVVideoCompositing {
	let sourcePixelBufferAttributes: [String: any Sendable]? = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
	]
	let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
	]
	private let context = CIContext(options: [.cacheIntermediates: false])
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
		context.render(image, to: buffer, bounds: bounds, colorSpace: colorSpace)
		request.finish(withComposedVideoFrame: buffer)
	}
}
