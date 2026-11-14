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
		Group {
			if loading {
				ProgressView("Opening clip")
			} else if let session {
				VStack(spacing: 0) {
					HStack {
						Text(session.title).font(.headline).lineLimit(1)
						Spacer()
						Button("Open Clip") {
							session.stop()
							if session.canUndo { replacing = true } else { picking = true }
						}
					}
					.padding(.horizontal)
					.frame(minHeight: 44)
					CuttingBoardKeyboard(session: session).id(ObjectIdentifier(session))
				}
			} else {
				WelcomeView { picking = true }
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(EditorTheme.workspace)
		.tint(EditorTheme.accent)
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

private struct WelcomeView: View {
	let chooseClip: () -> Void

	var body: some View {
		ScrollView {
			VStack(spacing: 20) {
				Image(decorative: "AppIcon60x60")
					.resizable()
					.scaledToFit()
					.frame(width: 104, height: 104)
				Text("Welcome to Trimato")
					.font(.largeTitle.weight(.semibold))
					.accessibilityHeading(.h1)
				Button("Trim a Clip", action: chooseClip)
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
			}
			.multilineTextAlignment(.center)
			.frame(maxWidth: .infinity)
			.padding()
		}
		.defaultScrollAnchor(.center, for: .alignment)
	}
}
