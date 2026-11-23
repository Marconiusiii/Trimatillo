import AVFoundation
import AudioToolbox
import Photos
import Combine
import CoreTransferable
import UniformTypeIdentifiers
import UIKit
#if DEBUG
import OSLog

@MainActor
final class EditPointFocusTrace: NSObject {
	private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trimatillo", category: "EditPointFocus")
	private var startTime: TimeInterval?

	func begin() {
		if startTime == nil {
			NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)),
				name: UIAccessibility.elementFocusedNotification, object: nil)
		}
		startTime = ProcessInfo.processInfo.systemUptime
		event("Edit Point requested, VoiceOver running = \(UIAccessibility.isVoiceOverRunning)")
	}

	func end() {
		NotificationCenter.default.removeObserver(self, name: UIAccessibility.elementFocusedNotification, object: nil)
		startTime = nil
	}

	func event(_ description: String) {
		guard let startTime else { return }
		let elapsed = Int((ProcessInfo.processInfo.systemUptime - startTime) * 1000)
		logger.notice("EditPointFocus +\(elapsed)ms \(description, privacy: .public)")
	}

	@objc private func focusChanged(_ notification: Notification) {
		let info = notification.userInfo
		let from = element(info?[UIAccessibility.unfocusedElementUserInfoKey])
		let to = element(info?[UIAccessibility.focusedElementUserInfoKey])
		event("Focus moved from \(from) to \(to)")
	}

	private func element(_ value: Any?) -> String {
		guard let element = value as? NSObject else { return "unknown" }
		let knownLabels = ["Outgoing Out Point", "Incoming In Point", "Cancel", "Save", "Done",
			"Source time", "Source frame", "Edit Actions", "Direct Touch Editor"]
		let label = element.accessibilityLabel.flatMap { knownLabels.contains($0) ? $0 : nil } ?? "other"
		return "\(label) (\(type(of: element)), \(ObjectIdentifier(element)))"
	}
}
#endif

// Shared by the app and Photos extension. A directory lock lasts as long as the
// import, export, or share owns its files. The kernel releases it on process exit.
nonisolated final class MediaWorkDirectory: Sendable {
	let url: URL
	private let descriptor: Int32

	private static func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
		let manager = FileManager.default
		guard let container = manager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.marconius.trimato-ios") else {
			throw CocoaError(.fileNoSuchFile)
		}
		let root = container.appendingPathComponent("Library/Caches/TrimatilloWork", isDirectory: true)
		try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
		let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		defer { close(fd) }
		guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
		if try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true {
			var marked = root
			var values = URLResourceValues()
			values.isExcludedFromBackup = true
			try marked.setResourceValues(values)
		}
		return try body(root)
	}

	init() throws {
		(url, descriptor) = try Self.withRoot { root in
			let job = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
			let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			guard fd >= 0 else { throw POSIXError(.EIO) }
			guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw POSIXError(.EIO) }
			return (job, fd)
		}
	}

	deinit {
		try? FileManager.default.removeItem(at: url)
		close(descriptor)
	}

	static func inspect(clear: Bool) throws -> (total: Int64, available: Int64) {
		try withRoot { root in
			let manager = FileManager.default
			var total: Int64 = 0
			var available: Int64 = 0
			for job in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: job.lastPathComponent) != nil {
				let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
				guard fd >= 0 else {
					if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { continue }
					throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
				}
				defer { close(fd) }
				let unused = flock(fd, LOCK_EX | LOCK_NB) == 0
				if clear && unused {
					try manager.removeItem(at: job)
				} else {
					do {
						let size = try storedBytes(at: job)
						total += size
						if unused { available += size }
					} catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
						continue
					}
				}
			}
			return (total, available)
		}
	}

	static func storedBytes(at url: URL) throws -> Int64 {
		let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
		if info.isSymbolicLink == true { return 0 }
		if info.isDirectory == true {
			return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).reduce(0) {
				try $0 + storedBytes(at: $1)
			}
		}
		return info.isRegularFile == true ? Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0) : 0
	}
}

// Photos lends the transfer a file URL. Keep a private copy for the lifetime of the edit.
nonisolated final class ImportedMovie: Transferable, Sendable {
	let url: URL
	private let work: MediaWorkDirectory

	init(copying source: URL) throws {
		let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
		guard info.isRegularFile == true, info.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
		work = try MediaWorkDirectory()
		url = work.url.appendingPathComponent(source.lastPathComponent)
		try FileManager.default.copyItem(at: source, to: url)
		try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
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

}

@MainActor final class CuttingBoardPlayhead: ObservableObject {
	@Published var position = CMTime.zero
}

@MainActor
final class CuttingBoardSession: ObservableObject {
	#if DEBUG
	let editPointTrace = EditPointFocusTrace()
	#endif

	struct Snapshot {
		var timeline: ClipEditTimeline
		var position: CMTime = .zero
		var markIn: CMTime?
		var markOut: CMTime?
	}

	let player = AVPlayer()
	let title: String
	let videoAspect: CGFloat?
	let hasVideo: Bool
	let hasAudio: Bool
	private let source: AVAsset
	private var projectAccess: AnyObject?
	private var openingTimeline: ClipEditTimeline?
	private let scopedURL: URL?
	private let importedMovie: ImportedMovie?
	private let originalFile: URL?
	private let photoIdentifier: String?
	private var originalModification: Date?
	private let tracks: [(AVAssetTrack, CMTimeRange)]
	private let transform: CGAffineTransform
	private let originalDuration: CMTime
	private let sourceFrames: [CMTime]
	private var frames: [CMTime] = []
	private var history: [(action: String, before: Snapshot, after: Snapshot)] = []
	private var historyIndex = 0
	private var playbackObservation: Any?
	private var endObservation: NSObjectProtocol?
	private var itemObservation: NSKeyValueObservation?
	private var editAsset: AVAsset
	private var reverseTask: Task<Void, Never>?
	private var idleAudioTask: Task<Void, Never>?
	private var previewSequence = 0
	private var previewTask: Task<Void, Never>?
	private var pendingScrubTime: CMTime?
	private let engine = AVAudioEngine()
	private let node = AVAudioPlayerNode()
	private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
	private let audioSession = EditorPlaybackAudioSession()
	private var holdingBoundaryAudio = false
	private var seekGeneration = 0
	private var startingForward = false
	let playhead = CuttingBoardPlayhead()
	private(set) var state: Snapshot {
		willSet {
			if state.timeline != newValue.timeline || state.markIn != newValue.markIn || state.markOut != newValue.markOut {
				objectWillChange.send()
			}
		}
		didSet {
			if playhead.position != state.position { playhead.position = state.position }
		}
	}
	@Published private(set) var rate = 0.0
	var speedLabel: String { abs(rate).formatted() + "x" }
	var shuttleLabel: String { (rate < 0 ? "Rewind " : "Forward ") + speedLabel }
	@Published var choosingPlacement = false
	@Published var sheet: BoardSheet? {
		didSet {
			if holdingBoundaryAudio, case .join = oldValue, sheet != oldValue {
				stopAudioPreview()
				deactivateAudio()
			}
		}
	}
	@Published var message: String?
	var duration: CMTime { state.timeline.duration }
	var canUndo: Bool { historyIndex > 0 }
	var canRedo: Bool { historyIndex < history.count }
	var hasTimelineEdits: Bool { state.timeline != (openingTimeline ?? ClipEditTimeline(sourceDuration: originalDuration)) }
	var currentJoin: ClipEditTimeline.EditPoint? {
		state.timeline.editPoints.first { CMTimeCompare($0.time, position) == 0 }
	}
	var position: CMTime { state.position }
	var currentPosition: CMTime {
		let time = rate > 0 && player.rate > 0 ? player.currentTime() : position
		return time.isNumeric ? min(duration, max(.zero, time)) : position
	}
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
			return try await load(asset: asset, title: copy.url.lastPathComponent, importedMovie: copy,
				originalFile: importedMovie == nil ? url : nil, photoIdentifier: photoIdentifier,
				modification: importedMovie == nil ? modification : Date(), scopedURL: scoped ? url : nil)
		} catch {
			if scoped { url.stopAccessingSecurityScopedResource() }
			throw error
		}
	}

	private var generatedFrame: CMTime?

	static func openReferenced(asset: AVAsset, title: String, access: AnyObject, ranges: [CMTimeRange]?, generatedFrame: CMTime? = nil) async throws -> CuttingBoardSession {
		let session = try await load(asset: asset, title: title)
		session.projectAccess = access
		session.generatedFrame = generatedFrame
		if let ranges {
			guard ranges.allSatisfy({ $0.start >= .zero && $0.end <= session.originalDuration }) else { throw CocoaError(.fileReadCorruptFile) }
			let timeline = ClipEditTimeline(sourceRanges: ranges)
			try session.apply(Snapshot(timeline: timeline), action: nil)
			session.openingTimeline = timeline
		}
		return session
	}

	private static func load(asset: AVAsset, title: String, importedMovie: ImportedMovie? = nil, originalFile: URL? = nil,
		photoIdentifier: String? = nil, modification: Date? = nil, scopedURL: URL? = nil) async throws -> CuttingBoardSession {
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
		let size = try await video?.load(.naturalSize)
		let displaySize = size.map { CGRect(origin: .zero, size: $0).applying(transform).standardized.size }
		let frames = try await MediaTimelineReader.shared.frameTimes(asset: asset, track: video)
		try Task.checkCancellation()
		return CuttingBoardSession(asset: asset, title: title, importedMovie: importedMovie, originalFile: originalFile,
			photoIdentifier: photoIdentifier, modification: modification, scopedURL: scopedURL, duration: duration,
			tracks: tracks, transform: transform, displaySize: displaySize, frames: frames, hasVideo: video != nil, hasAudio: audio != nil)
	}

	private init(asset: AVAsset, title: String, importedMovie: ImportedMovie?, originalFile: URL?, photoIdentifier: String?, modification: Date?, scopedURL: URL?, duration: CMTime, tracks: [(AVAssetTrack, CMTimeRange)],
		transform: CGAffineTransform, displaySize: CGSize?, frames: [CMTime], hasVideo: Bool, hasAudio: Bool) {
		source = asset
		editAsset = asset
		self.scopedURL = scopedURL
		self.importedMovie = importedMovie
		self.originalFile = originalFile
		self.photoIdentifier = photoIdentifier
		originalModification = modification
		self.title = title
		self.tracks = tracks
		self.transform = transform
		if let displaySize, displaySize.width > 0, displaySize.height > 0 {
			videoAspect = displaySize.width / displaySize.height
		} else {
			videoAspect = nil
		}
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
				guard let self, self.rate > 0, !self.startingForward, let item = self.player.currentItem else { return }
				let now = self.player.currentTime()
				guard now.isNumeric else { return }
				let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : self.duration
				if self.player.rate == 0 && now >= end {
					self.stop()
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
				guard let self, self.player.currentItem === item, self.rate > 0, !self.startingForward else { return }
				let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : self.duration
				guard self.player.currentTime() >= end else { return }
				self.seek(end)
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

	func makePreview() -> PreviewPlayback? {
		guard let item = player.currentItem else { return nil }
		let forwardRate = max(0, rate)
		releaseAudio()
		return PreviewPlayback(item: item, start: position, rate: Float(forwardRate)) { [weak self] time in
			self?.seek(time)
		}
	}

	func stop() {
		seekGeneration += 1
		startingForward = false
		player.currentItem?.cancelPendingSeeks()
		if rate > 0, player.rate > 0, player.currentTime().isNumeric {
			state.position = min(duration, max(.zero, player.currentTime()))
		}
		rate = 0
		player.pause()
		player.currentItem?.forwardPlaybackEndTime = .invalid
		reverseTask?.cancel()
		reverseTask = nil
		stopAudioPreview()
	}

	func stopAudioPreview() {
		previewTask?.cancel()
		previewTask = nil
		pendingScrubTime = nil
		previewSequence += 1
		node.stop()
		scheduleIdleEngineStop()
	}

	func releaseAudio() {
		stop()
		deactivateAudio()
	}

	private func deactivateAudio() {
		holdingBoundaryAudio = false
		idleAudioTask?.cancel()
		idleAudioTask = nil
		engine.stop()
		audioSession.release()
	}

	private func scheduleIdleEngineStop() {
		guard !holdingBoundaryAudio else { return }
		guard engine.isRunning else { return }
		idleAudioTask?.cancel()
		idleAudioTask = Task { [weak self] in
			do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
			guard let self, rate == 0, !holdingBoundaryAudio else { return }
			engine.stop()
		}
	}

	private func activateAudio() async throws {
		idleAudioTask?.cancel()
		idleAudioTask = nil
		try await audioSession.activate()
	}

	#if DEBUG
	var keyboardPlaybackState: String {
		"position=\(position.seconds), in=\(state.markIn?.seconds.description ?? "none"), out=\(state.markOut?.seconds.description ?? "none"), undo=\(historyIndex), joins=\(state.timeline.editPoints.count), rate=\(rate), player=\(player.rate), status=\(player.timeControlStatus.rawValue), generation=\(seekGeneration), starting=\(startingForward), reverse=\(reverseTask != nil), engine=\(engine.isRunning), node=\(node.isPlaying)"
	}
	#endif

	func seek(_ time: CMTime, audible: Bool = false) {
		stop()
		state.position = min(duration, max(.zero, time))
		player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
		if audible && hasAudio {
			let start = min(position, max(.zero, stepped(from: duration, by: -1)))
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

	func scrub(to time: CMTime, generation: Int, initial: Bool = false) {
		guard generation == seekGeneration else { return }
		let next = min(duration, max(.zero, time))
		guard initial || next != position else { return }
		state.position = next
		if hasVideo { player.seek(to: next, toleranceBefore: .zero, toleranceAfter: .zero) }
		guard hasAudio else { return }
		pendingScrubTime = min(next, max(.zero, stepped(from: duration, by: -1)))
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

	private var audioStep: CMTime { CMTime(value: 1, timescale: 30) }

	func stepped(from time: CMTime, by count: Int, sourceTime: Bool = false) -> CMTime {
		if let generatedFrame {
			let index = (time.seconds / generatedFrame.seconds).rounded(count > 0 ? .down : .up) + Double(count)
			return min(sourceTime ? originalDuration : duration, max(.zero, CMTimeMultiplyByFloat64(generatedFrame, multiplier: index)))
		}
		let times = sourceTime ? sourceFrames : frames
		if !hasVideo { return time + CMTimeMultiply(audioStep, multiplier: Int32(count)) }
		let end = sourceTime ? originalDuration : duration
		guard !times.isEmpty else { return count > 0 ? end : .zero }
		let index = times.lowerBound(time)
		let base = count > 0 && (index == times.count || times[index] != time) ? index - 1 : index
		let next = base + count
		if next >= times.count { return end }
		return next < 0 ? .zero : times[next]
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
		let position = currentPosition
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

	func goToBoundary(end: Bool) {
		seek(end ? duration : .zero)
		announce(end ? "End" : "Start")
	}

	func mark(_ isIn: Bool, toggleAtPlayhead: Bool = false, spoken: Bool = false) {
		let time = currentPosition
		if toggleAtPlayhead, (isIn ? state.markIn : state.markOut) == time {
			clear(isIn)
			announce(isIn ? "In Removed" : "Out Removed")
			return
		}
		let previous = isIn ? state.markIn : state.markOut
		guard previous != time else {
			if spoken { announce(isIn ? "Marked In" : "Marked Out") }
			return
		}
		let action = (previous == nil ? "Mark " : "Move ") + (isIn ? "In" : "Out")
		let before = state
		if isIn { state.markIn = time } else { state.markOut = time }
		record(action, before: before, after: state)
		if toggleAtPlayhead || spoken { announce(isIn ? "Marked In" : "Marked Out") }
	}

	func clear(_ isIn: Bool, spoken: Bool = false) {
		guard (isIn ? state.markIn : state.markOut) != nil else { return }
		let before = state
		if isIn { state.markIn = nil } else { state.markOut = nil }
		record(isIn ? "Remove In" : "Remove Out", before: before, after: state)
		if spoken { announce(isIn ? "In Removed" : "Out Removed") }
	}

	func delete(_ range: CMTimeRange?, spoken: Bool = false) {
		guard removeRange(range, action: "Delete Marked Range"), spoken else { return }
		announce(["Content deleted", currentJoin?.name].compactMap { $0 }.joined(separator: ", "))
	}

	private func removeRange(_ range: CMTimeRange?, action: String) -> Bool {
		guard let range else { message = "Set In before Out to delete a marked range."; return false }
		do {
			var timeline = state.timeline
			try timeline.delete(editedRange: range)
			try apply(Snapshot(timeline: timeline, position: range.start), action: action)
			return true
		} catch {
			message = error.localizedDescription
			return false
		}
	}

	func trim(head: Bool, spoken: Bool = false) {
		let point = rate > 0 && player.rate > 0 ? player.currentTime() : position
		let range = CMTimeRange(start: head ? .zero : point, end: head ? point : duration)
		if removeRange(range, action: head ? "Trim Head to Playhead" : "Trim Tail to Playhead"), spoken {
			announce(head ? "Head trimmed to playhead" : "Tail trimmed to playhead")
		}
	}

	func saveJoin(_ point: ClipEditTimeline.EditPoint, inTime: CMTime, outTime: CMTime) throws {
		guard currentJoin == point else { throw ClipEditError.invalidSelection }
		guard inTime != point.inTime || outTime != point.outTime else { return }
		let timeline = try state.timeline.adjustingEditPoint(point.index, inTime: inTime, outTime: outTime)
		let position = timeline.editPoints[point.index].time
		try apply(Snapshot(timeline: timeline, position: position), action: "Adjust " + point.name)
	}

	func prepareBoundaryAudio() {
		guard hasAudio else { return }
		do {
			try audioSession.prepareBoundary()
			if !engine.isRunning { try engine.start() }
			holdingBoundaryAudio = true
			#if DEBUG
			editPointTrace.event("Preview engine ready before Edit Point presentation")
			#endif
		} catch {
			deactivateAudio()
			#if DEBUG
			editPointTrace.event("Preview engine preparation failed; next preview will retry")
			#endif
		}
	}

	func previewBoundary(at time: CMTime, preceding: Bool) {
		guard hasAudio, case .join = sheet else { return }
		#if DEBUG
		editPointTrace.event("Boundary preview requested, engine running = \(engine.isRunning)")
		#endif
		holdingBoundaryAudio = true
		idleAudioTask?.cancel()
		stopAudioPreview()
		let length = CMTime(seconds: 0.15, preferredTimescale: 48000)
		let start = preceding ? max(.zero, time - length) : time
		let end = preceding ? time : min(originalDuration, time + length)
		previewTask = Task { [weak self] in
			guard let self else { return }
			await preview(at: start, length: (end - start).seconds, asset: source)
		}
	}

	private func record(_ action: String, before: Snapshot, after: Snapshot) {
		history.removeSubrange(historyIndex..<history.count)
		history.append((action, before, after))
		historyIndex = history.count
	}

	private func restore(_ snapshot: Snapshot) throws {
		if state.timeline == snapshot.timeline {
			stop()
			state = snapshot
			seek(snapshot.position)
		} else {
			try apply(snapshot, action: nil)
		}
	}

	func undo() {
		guard canUndo else { announce("Nothing to undo"); return }
		let entry = history[historyIndex - 1]
		do {
			try restore(entry.before)
			historyIndex -= 1
			announce("Undo " + entry.action)
		} catch { message = error.localizedDescription }
	}

	func redo() {
		guard canRedo else { announce("Nothing to redo"); return }
		let entry = history[historyIndex]
		do {
			try restore(entry.after)
			historyIndex += 1
			announce("Redo " + entry.action)
		} catch { message = error.localizedDescription }
	}

	private nonisolated static func composition(for timeline: ClipEditTimeline, tracks: [(AVAssetTrack, CMTimeRange)], transform: CGAffineTransform) throws -> AVMutableComposition {
		let composition = AVMutableComposition()
		for (track, available) in tracks {
			guard let output = composition.addMutableTrack(withMediaType: track.mediaType,
				preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.featureUnsupported) }
			if track.mediaType == .video { output.preferredTransform = transform }
			var cursor = CMTime.zero
			for range in timeline.sourceRanges {
				try Task.checkCancellation()
				let overlap = CMTimeRangeGetIntersection(range, otherRange: available)
				if overlap.isValid && !overlap.isEmpty {
					try output.insertTimeRange(overlap, of: track, at: cursor + (overlap.start - range.start))
				}
				cursor = cursor + range.duration
			}
		}
		if composition.duration < timeline.duration {
			composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: timeline.duration))
		}
		return composition
	}

	private func apply(_ snapshot: Snapshot, action: String?, prepared: AVMutableComposition? = nil) throws {
		let composition = try prepared ?? Self.composition(for: snapshot.timeline, tracks: tracks, transform: transform)
		stop()
		if let action { record(action, before: state, after: snapshot) }
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

	func silencePauses(range: CMTimeRange, decibels: Int, minimum: Double, retained: Double) async throws -> [SilencePause] {
		let cuts = try await ClipSilenceTrimming.analyze(asset: editAsset, range: range, decibels: decibels,
			minimum: minimum, retained: retained)
		return cuts.enumerated().compactMap { index, cut in
			var start = cut.start
			var end = cut.end
			if hasVideo {
				let first = frames.lowerBound(start)
				start = first < frames.count ? frames[first] : duration
				if end < duration {
					let last = frames.lowerBound(end)
					if last >= frames.count || frames[last] != end {
						end = last > 0 ? frames[last - 1] : .zero
					}
				}
			}
			guard start < end else { return nil }
			let limits = CMTimeRange(start: index == 0 ? range.start : cuts[index - 1].end,
				end: index + 1 == cuts.count ? range.end : cuts[index + 1].start)
			return SilencePause(id: index, limits: limits, cut: CMTimeRange(start: start, end: end))
		}
	}

	private func silenceSnapshot(_ pauses: [SilencePause]) throws -> Snapshot {
		let cuts = pauses.filter(\.included).map(\.cut)
		var cursor = CMTime.zero
		var ranges: [CMTimeRange] = []
		for cut in cuts {
			guard cut.start >= cursor, cut.end <= duration, cut.end > cut.start else { throw ClipEditError.invalidSelection }
			ranges += state.timeline.sourceRanges(in: CMTimeRange(start: cursor, end: cut.start))
			cursor = cut.end
		}
		ranges += state.timeline.sourceRanges(in: CMTimeRange(start: cursor, end: duration))
		guard !ranges.isEmpty else { throw ClipEditError.entireClip }
		func mapped(_ time: CMTime) -> CMTime {
			cuts.reduce(time) { $0 - max(.zero, min(time, $1.end) - $1.start) }
		}
		return Snapshot(timeline: ClipEditTimeline(sourceRanges: ranges), position: mapped(position),
			markIn: state.markIn.map(mapped), markOut: state.markOut.map(mapped))
	}

	private func preparedSilenceEdit(_ pauses: [SilencePause]) async throws -> (Snapshot, AVMutableComposition) {
		let snapshot = try silenceSnapshot(pauses)
		let asset = try await Self.prepareComposition(for: snapshot.timeline, tracks: tracks, transform: transform)
		try Task.checkCancellation()
		return (snapshot, asset)
	}

	@concurrent private static func prepareComposition(for timeline: ClipEditTimeline, tracks: [(AVAssetTrack, CMTimeRange)],
		transform: CGAffineTransform) async throws -> AVMutableComposition {
		try composition(for: timeline, tracks: tracks, transform: transform)
	}

	func silencePreview(_ pauses: [SilencePause]?, context: CMTimeRange? = nil) async throws -> AVPlayerItem {
		if let context {
			let timeline = ClipEditTimeline(sourceRanges: state.timeline.sourceRanges(in: context))
			return AVPlayerItem(asset: try await Self.prepareComposition(for: timeline, tracks: tracks, transform: transform))
		}
		return AVPlayerItem(asset: try await preparedSilenceEdit(pauses ?? []).1)
	}

	func applySilenceCuts(_ pauses: [SilencePause]) async throws {
		let (snapshot, asset) = try await preparedSilenceEdit(pauses)
		try apply(snapshot, action: "Trim Silences", prepared: asset)
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
		rate = -speed
		announce(shuttleLabel)
		state.position = start
		reverseTask = Task { [weak self] in
			guard let self else { return }
			do {
				try await self.activateAudio()
				try Task.checkCancellation()
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
		try await ReverseAudioPlayback.run(from: start, speed: speed, asset: editAsset, mix: nil,
			hasAudio: hasAudio, engine: engine, node: node, format: audioFormat) { next in
			guard next != self.position else { return }
			self.state.position = next
			if self.hasVideo { self.player.seek(to: next, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in }) }
		}
	}

	func playMarked() {
		guard let selection else { return }
		play(from: selection.start, to: selection.end, speed: 1)
	}

	private func play(from start: CMTime, to end: CMTime, speed: Double) {
		stop()
		state.position = start
		if engine.isRunning { engine.stop() }
		do { try audioSession.configure() } catch { message = "Could not start audio. Check the audio output and try Play again."; return }
		player.currentItem?.forwardPlaybackEndTime = end
		let generation = seekGeneration
		rate = speed
		if player.currentTime() == start {
			player.playImmediately(atRate: Float(speed))
			return
		}
		startingForward = true
		player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
			Task { @MainActor [weak self] in
				guard let self, generation == self.seekGeneration, self.rate == speed else { return }
				self.startingForward = false
				guard finished else { self.stop(); return }
				self.player.playImmediately(atRate: Float(speed))
			}
		}
	}

	private func preview(at time: CMTime, length: Double = 0.2, asset: AVAsset? = nil) async {
		do {
			let samples = try await FrameAudioSamples.read(asset: asset ?? editAsset, mix: nil, at: time, length: length)
			try Task.checkCancellation()
			guard !samples.isEmpty else { return }
			try await activateAudio()
			guard let buffer = ReverseAudioPlayback.pcmBuffer(samples, format: audioFormat) else { return }
			node.stop()
			if !engine.isRunning { try engine.start() }
			playBuffer(buffer)
		} catch {
			if !Task.isCancelled { stop(); message = "Audio preview failed. Check the audio output and reopen the clip." }
		}
	}


	private func playBuffer(_ buffer: AVAudioPCMBuffer) {
		previewSequence += 1
		let sequence = previewSequence
		node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
			Task { @MainActor [weak self] in
				guard let self, previewSequence == sequence else { return }
				scheduleIdleEngineStop()
			}
		}
		node.play()
	}

	func frameNumber(at time: CMTime, sourceTime: Bool = false) -> Int64 {
		if let generatedFrame {
			let atEnd = time >= (sourceTime ? originalDuration : duration)
			return Int64((time.seconds / generatedFrame.seconds).rounded(atEnd ? .up : .down))
		}
		let timestamps = sourceTime ? sourceFrames : frames
		let atEnd = time >= (sourceTime ? originalDuration : duration)
		if !hasVideo {
			return CMTimeConvertScale(time, timescale: audioStep.timescale, method: atEnd ? .roundTowardPositiveInfinity : .roundTowardZero).value
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
		if let generatedFrame { return CMTimeMultiplyByFloat64(generatedFrame, multiplier: Double(index)) }
		let timestamps = sourceTime ? sourceFrames : frames
		return hasVideo ? timestamps[Int(index)] : CMTime(value: index, timescale: audioStep.timescale)
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
			let count = CMSampleBufferGetNumSamples(sample)
			guard count > 0 else { continue }
			let flags = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
			let hiddenKey = kCMSampleAttachmentKey_DoNotDisplay as String
			if count == 1 {
				guard flags?.first?[hiddenKey] as? Bool != true else { continue }
				let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
				if time.isNumeric, time >= .zero { times.append(time) }
				continue
			}
			var timing = Array(repeating: CMSampleTimingInfo(), count: count)
			var entries = 0
			guard CMSampleBufferGetOutputSampleTimingInfoArray(sample, entryCount: count,
				arrayToFill: &timing, entriesNeededOut: &entries) == noErr,
				entries == count || (entries == 1 && timing[0].duration.isNumeric && timing[0].duration > .zero)
			else { throw CocoaError(.fileReadCorruptFile) }
			var sharedTime = timing[0].presentationTimeStamp
			for index in 0..<count {
				let time = entries == 1 ? sharedTime : timing[index].presentationTimeStamp
				if entries == 1 { sharedTime = sharedTime + timing[0].duration }
				if flags?[index][hiddenKey] as? Bool != true, time.isNumeric, time >= .zero { times.append(time) }
			}
		}
		guard reader.status == .completed, !times.isEmpty else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
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
		let properties = try? (source as? AVURLAsset)?.url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
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
			let output = try await exportClip(type: originalType)
			defer { withExtendedLifetime(output) {} }
			let file = output.url
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
		let rendered = try await exportClip(type: type)
		defer { withExtendedLifetime(rendered) {} }
		let file = rendered.url
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
		let output = try await exportClip()
		defer { withExtendedLifetime(output) {} }
		let file = output.url
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

	func exportClip(type requested: AVFileType? = nil) async throws -> ExportFile {
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
		let name = (title as NSString).deletingPathExtension + " Edited"
		let output = try ExportFile(name: name, suffix: type == .mp4 ? "mp4" : type == .mov ? "mov" : "m4a")
		try await exporter.export(to: output.url, as: type)
		try Task.checkCancellation()
		return output
	}
}

/// Serializes explicit engine activation off the main thread. Forward AVPlayer
/// playback activates the configured session itself. Pause keeps the session;
/// leaving the editor releases it after any queued activation has finished.
@MainActor final class EditorPlaybackAudioSession {
	nonisolated private static let queue = DispatchQueue(label: "com.marconius.trimato-ios.editor-audio")
	private static var owner: UUID?
	private let id = UUID()
	private var generation = 0
	private var active = false
	private var requested = false
	#if DEBUG
	private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Trimatillo", category: "EditorAudio")
	private func trace(_ event: String) {
		logger.notice("Audio \(self.id.uuidString, privacy: .public): \(event, privacy: .public), generation=\(self.generation), uptime=\(ProcessInfo.processInfo.systemUptime)")
	}
	#endif

	func configure() throws {
		let session = AVAudioSession.sharedInstance()
		if session.category != .playback || session.mode != .default || session.categoryOptions != [.mixWithOthers] {
			try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
			active = false
		}
		if Self.owner != id { active = false }
		Self.owner = id
		requested = true
	}

	func activate() async throws {
		try Task.checkCancellation()
		try configure()
		if active { return }
		let request = generation
		#if DEBUG
		trace("activation queued")
		#endif
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Self.queue.async {
				do {
					try AVAudioSession.sharedInstance().setActive(true)
					continuation.resume()
				} catch { continuation.resume(throwing: error) }
			}
		}
		guard request == generation, Self.owner == id else { throw CancellationError() }
		active = true
		#if DEBUG
		trace("activation completed")
		#endif
		try Task.checkCancellation()
	}

	// Edit-point presentation already prepares its audio before opening the sheet.
	func prepareBoundary() throws {
		try configure()
		guard !active else { return }
		try Self.queue.sync { try AVAudioSession.sharedInstance().setActive(true) }
		active = true
	}

	func release() {
		generation += 1
		defer { active = false; requested = false }
		guard requested, Self.owner == id else { return }
		#if DEBUG
		trace("release requested")
		#endif
		// This boundary must finish before a recording or another player takes over.
		Self.queue.sync { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
		Self.owner = nil
		#if DEBUG
		trace("release completed")
		#endif
	}
}

@MainActor enum ReverseAudioPlayback {
	static func run(from start: CMTime, speed: Double, asset: AVAsset, mix: AVAudioMix?, hasAudio: Bool,
		engine: AVAudioEngine, node: AVAudioPlayerNode, format: AVAudioFormat, update: (CMTime) -> Void) async throws {
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
				let samples = try await FrameAudioSamples.read(asset: asset, mix: mix,
					at: CMTime(value: first, timescale: scale), length: Double(count) / Double(scale))
				try Task.checkCancellation()
				guard let buffer = pcmBuffer(samples, format: format, reverseSpeed: speed) else { throw CocoaError(.fileReadCorruptFile) }
				if !engine.isRunning { try engine.start() }
				node.scheduleBuffer(buffer, completionHandler: nil)
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
			update(next)
			try await Task.sleep(for: .milliseconds(16))
		}
	}
	static func pcmBuffer(_ samples: [Float], format audioFormat: AVAudioFormat, reverseSpeed: Double? = nil) -> AVAudioPCMBuffer? {
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
}
