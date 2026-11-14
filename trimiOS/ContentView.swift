import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
	@Environment(\.scenePhase) private var phase
	@State private var session: CuttingBoardSession?
	@State private var pickingFile = false
	@State private var pickingPhoto = false
	@State private var photo: PhotosPickerItem?
	@State private var pendingSource: ClipSource?
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
						ClipSourceMenu(title: "Open Clip", choose: choose)
					}
					.padding(.horizontal)
					.frame(minHeight: 44)
					CuttingBoardKeyboard(session: session).id(ObjectIdentifier(session))
				}
			} else {
				WelcomeView(choose: choose)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(EditorTheme.workspace)
		.tint(EditorTheme.accent)
		.confirmationDialog("Replace the current edit?", isPresented: $replacing) {
			Button("Choose Another Clip") {
				if let pendingSource { present(pendingSource) }
			}
		} message: { Text("Opening another clip discards this edit.") }
		.photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .videos, photoLibrary: .shared())
		.onChange(of: photo) { _, item in
			guard let item else { return }
			photo = nil
			openClip(errorMessage: "Could not open this video. Select it again in Photo Library.") {
				guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
					throw CocoaError(.fileReadCorruptFile)
				}
				return try await CuttingBoardSession.open(movie.url, importedMovie: movie)
			}
		}
		.fileImporter(isPresented: $pickingFile, allowedContentTypes: [.audio, .movie]) { result in
			switch result {
			case .success(let url):
				openClip(errorMessage: "Could not open this clip. Choose a playable audio or video file from Files.") {
					try await CuttingBoardSession.open(url)
				}
			case .failure(let error):
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

	private func choose(_ source: ClipSource) {
		session?.stop()
		if session?.canUndo == true {
			pendingSource = source
			replacing = true
		} else { present(source) }
	}

	private func present(_ source: ClipSource) {
		pendingSource = nil
		switch source {
		case .photos: pickingPhoto = true
		case .files: pickingFile = true
		}
	}

	private func openClip(errorMessage: String, load: @escaping () async throws -> CuttingBoardSession) {
		loading = true
		Task {
			defer { loading = false }
			do {
				let next = try await load()
				session?.releaseAudio()
				session = next
			} catch { failure = errorMessage }
		}
	}
}

private enum ClipSource {
	case photos, files
}

private struct ClipSourceMenu: View {
	let title: String
	let choose: (ClipSource) -> Void

	var body: some View {
		Menu(title) {
			Button("Photo Library") { choose(.photos) }
			Button("Files") { choose(.files) }
		}
	}
}

private struct WelcomeView: View {
	let choose: (ClipSource) -> Void

	var body: some View {
		ScrollView {
			VStack(spacing: 20) {
				Image(decorative: "AppIcon60x60")
					.resizable()
					.scaledToFit()
					.frame(width: 104, height: 104)
				Text("Welcome to Trimato")
					.font(.largeTitle.weight(.semibold))
					.accessibilityAddTraits(.isHeader)
				ClipSourceMenu(title: "Trim a Clip", choose: choose)
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
