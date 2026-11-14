import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
	@Environment(\.scenePhase) private var phase
	@State private var session: CuttingBoardSession?
	@State private var picking = false
	@State private var loading = false
	@State private var failure: String?
	@State private var replacing = false

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Text(session?.title ?? "Trimato").font(.headline).lineLimit(1)
				Spacer()
				if session != nil {
					Button("Open Clip") {
						session?.stop()
						if session?.canUndo == true { replacing = true } else { picking = true }
					}
				}
			}
			.padding(.horizontal)
			.frame(minHeight: 44)
			if loading {
				Spacer()
				ProgressView("Opening clip")
				Spacer()
			} else if let session {
				CuttingBoardKeyboard(session: session).id(ObjectIdentifier(session))
			} else {
				Spacer()
				Button("Open Clip") { picking = true }.buttonStyle(.borderedProminent)
				Spacer()
			}
		}
		.background(EditorTheme.workspace)
		.tint(EditorTheme.accent)
		.accessibilityAction(.magicTap) { session?.toggle() }
		.confirmationDialog("Replace the current edit?", isPresented: $replacing) {
			Button("Choose Another Clip") { picking = true }
		} message: { Text("Opening another clip discards this edit.") }
		.fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie]) { result in
			do {
				let url = try result.get()
				loading = true
				Task {
					defer { loading = false }
					do {
						let next = try await CuttingBoardSession.open(url)
						session?.releaseAudio()
						session = next
					} catch { failure = "Could not open this clip. Choose a playable audio or video file from Files." }
				}
			} catch {
				if (error as NSError).code != NSUserCancelledError { failure = "Could not read the file. Select it again in Files." }
			}
		}
		.alert("Could Not Open Clip", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
			Button("OK") { failure = nil }
		} message: { Text(failure ?? "") }
		.onChange(of: phase) { _, phase in
			if phase == .background { session?.releaseAudio() }
		}
		.onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
			if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
				session?.releaseAudio()
			}
		}
	}
}
