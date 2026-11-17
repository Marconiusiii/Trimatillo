import AVFoundation
import AVKit
import Combine
import SwiftUI

@MainActor final class ProjectRecording: NSObject, ObservableObject, AVAudioRecorderDelegate {
	enum Phase { case idle, preparing, recording }
	@Published private(set) var phase = Phase.idle
	@Published private(set) var draft: UUID?
	@Published var failure: String?
	let player = AVPlayer()
	private let voiceOver: Bool

	init(voiceOver: Bool = false) {
		self.voiceOver = voiceOver
		super.init()
	}

	private var recorder: AVAudioRecorder?
	private var cue: AVAudioPlayer?
	private var stopCue: AVAudioPlayer?
	private var generation = 0
	private var ownsSession = false
	private static var reserved = Set<UUID>()
	private static weak var micOwner: ProjectRecording?

	static var microphoneInUse: Bool { micOwner != nil }

	static let inputKey = "recordingInput"
	static func configureInput() throws {
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
		try session.setActive(true)
		let input = EditorPreferences.shared.string(forKey: inputKey)
		try session.setPreferredInput(session.availableInputs?.first { $0.uid == input })
	}

	static func restorePlayback() {
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
	}

	func preview(playback: ProjectPlayback, range: CMTimeRange, take: DescriptionTake?, url: URL?, duck: Bool = true) async {
		stopPreview()
		let request = generation
		do {
			let item = try await playback.descriptionPreview(range: range, take: take, url: url, duck: duck)
			guard generation == request else { return }
			player.replaceCurrentItem(with: item)
			guard await player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero), generation == request else { return }
			player.play()
		} catch { if generation == request { failure = error.localizedDescription } }
	}

	func playTake(_ url: URL) {
		stopPreview()
		player.replaceCurrentItem(with: AVPlayerItem(url: url))
		player.play()
	}

	func stopPreview() {
		stopCue?.stop()
		generation += 1
		player.pause()
		player.replaceCurrentItem(with: nil)
	}

	func start(project: EditingProject, playback: ProjectPlayback, range: CMTimeRange) async {
		guard phase == .idle else { return }
		if let owner = Self.micOwner, owner !== self {
			guard owner.phase == .idle else { failure = "Stop the recording in the other window first."; return }
			owner.interrupt()
		}
		Self.micOwner = self
		stopPreview()
		let request = generation
		phase = .preparing
		do {
			let allowed = await AVAudioApplication.requestRecordPermission()
			guard request == generation else { return }
			guard allowed else { throw ProjectFailure("Allow microphone access for Trimatillo in Settings to record a take.") }
			let home = ProjectLibrary.directory.appendingPathComponent(project.id.uuidString)
			if try !ProjectStorage.directoryExists(home) { try ProjectLibrary.save(project, replacing: project) }
			let directory = try ProjectStorage.recordings(project.id, drafts: true, create: true, voiceOver: voiceOver)
			let item: AVPlayerItem?
			if voiceOver {
				if range.duration > .zero {
					guard let current = playback.player.currentItem, playback.ready else { throw ProjectFailure("Wait for the timeline to finish loading.") }
					let monitor = AVPlayerItem(asset: current.asset)
					monitor.audioMix = current.audioMix
					monitor.videoComposition = current.videoComposition
					item = monitor
				} else { item = nil }
			} else { item = try await playback.descriptionPreview(range: range, take: nil, url: nil) }
			guard request == generation else { return }
			if !ownsSession {
				ownsSession = true
				try Self.configureInput()
			}
			stopCue = try AVAudioPlayer(data: Self.fallingCue)
			stopCue?.prepareToPlay()
			player.replaceCurrentItem(with: item)
			if item != nil, !(await player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)) {
				throw ProjectFailure("Could not position the preview. Choose Record again.")
			}
			guard request == generation else { return }
			let id = UUID()
			let url = directory.appendingPathComponent(id.uuidString + ".caf")
			let capture = try AVAudioRecorder(url: url, settings: [
				AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
				AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false
			])
			capture.delegate = self
			do {
				guard capture.prepareToRecord() else { throw ProjectFailure("Could not prepare the microphone. Check the input in Settings.") }
				try await playStartCue(request: request)
				guard request == generation else { throw CancellationError() }
			} catch {
				capture.stop()
				capture.deleteRecording()
				throw error
			}
			guard capture.record() else {
				capture.deleteRecording()
				throw ProjectFailure("Could not start recording. Check the microphone and available storage.")
			}
			selectDraft(id)
			recorder = capture
			phase = .recording
			if voiceOver {
				if item != nil { player.playImmediately(atRate: 1) }
			} else { player.play() }
		} catch {
			if request == generation { interrupt(); failure = error.localizedDescription }
		}
	}

	func stop() {
		guard phase == .recording else { return }
		player.pause()
		recorder?.stop()
		recorder = nil
		phase = .idle
		if stopCue?.play() != true { failure = "Could not play the recording cue. Check the audio output." }
	}

	func interrupt() {
		stopPreview()
		recorder?.stop()
		recorder = nil
		cue?.stop()
		cue = nil
		stopCue = nil
		if ownsSession { Self.restorePlayback(); ownsSession = false }
		if Self.micOwner === self { Self.micOwner = nil }
		phase = .idle
	}

	nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
		recordingEnded(ObjectIdentifier(recorder), succeeded: false)
	}

	nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
		recordingEnded(ObjectIdentifier(recorder), succeeded: flag)
	}

	private nonisolated func recordingEnded(_ id: ObjectIdentifier, succeeded: Bool) {
		Task { @MainActor [weak self] in
			guard let self, let recorder = self.recorder, ObjectIdentifier(recorder) == id, phase == .recording else { return }
			interrupt()
			if !succeeded { failure = "Recording stopped. Check available storage and review the take." }
		}
	}

	func selectDraft(_ id: UUID?) {
		if let draft { Self.reserved.remove(draft) }
		draft = id
		if let id { Self.reserved.insert(id) }
	}

	func availableDrafts(project: UUID) -> [URL] {
		guard let directory = try? ProjectStorage.recordings(project, drafts: true, voiceOver: voiceOver),
			let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
		return files.filter {
			guard $0.pathExtension == "caf", let id = UUID(uuidString: $0.deletingPathExtension().lastPathComponent) else { return false }
			return !Self.reserved.contains(id) && (try? ProjectStorage.recording(id, project: project, draft: true, voiceOver: voiceOver)) != nil
		}.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	func recover(_ id: UUID) throws {
		guard !Self.reserved.contains(id) else { throw ProjectFailure("Close this take in the other window first.") }
		selectDraft(id)
	}

	private static let risingCue = cueData(start: true)
	private static let fallingCue = cueData(start: false)

	private static func cueData(start: Bool) -> Data {
		// The same 100 ms rising/falling pair as Trimato. The mic opens after playback finishes.
		var data = Data()
		func word<T: FixedWidthInteger>(_ n: T) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
		data.append(contentsOf: "RIFF".utf8); word(UInt32(19236)); data.append(contentsOf: "WAVEfmt ".utf8)
		word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(48000)); word(UInt32(96000)); word(UInt16(2)); word(UInt16(16))
		data.append(contentsOf: "data".utf8); word(UInt32(19200))
		for i in 0..<9600 {
			let t = Double(i) / 48000
			let local = Double(i % 4800) / 48000
			let frequency = (i < 4800) == start ? 660.0 : 880.0
			word(Int16(5200 * min(1, local / 0.008, (0.1 - local) / 0.008) * sin(2 * .pi * frequency * t)))
		}
		return data
	}

	private func playStartCue(request: Int) async throws {
		let sound = try AVAudioPlayer(data: Self.risingCue)
		cue = sound
		guard sound.play() else { throw ProjectFailure("Could not play the recording cue. Check the audio output.") }
		while sound.isPlaying {
			try await Task.sleep(for: .milliseconds(10))
			guard generation == request else { throw CancellationError() }
		}
	}
}

struct RecordingRouteSettings: View {
	@AppStorage(ProjectRecording.inputKey, store: EditorPreferences.shared) private var input = ""
	@State private var configuredSession = false
	@State private var inputs: [AVAudioSessionPortDescription] = []
	@State private var failure: String?
	var body: some View {
		Form {
			Picker("Microphone", selection: $input) {
				Text("Same as System").tag("")
				ForEach(inputs, id: \.uid) { Text($0.portName).tag($0.uid) }
				if !input.isEmpty && !inputs.contains(where: { $0.uid == input }) { Text("Unavailable Microphone").tag(input) }
			}
			LabeledContent("Audio Output") { RecordingRoutePicker().frame(width: 48, height: 48) }
			if let failure { Text(failure) }
		}
		.editorListMargins()
		.navigationTitle("Audio")
		.onAppear {
			do {
				if !ProjectRecording.microphoneInUse {
					configuredSession = true
					try ProjectRecording.configureInput()
				}
				inputs = AVAudioSession.sharedInstance().availableInputs ?? []
			}
			catch { failure = "Could not load audio inputs. Reconnect the microphone and reopen Audio." }
		}
		.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
			inputs = AVAudioSession.sharedInstance().availableInputs ?? []
		}
		.onDisappear { if configuredSession && !ProjectRecording.microphoneInUse { ProjectRecording.restorePlayback() } }
	}
}

private struct RecordingRoutePicker: UIViewRepresentable {
	func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
	func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
