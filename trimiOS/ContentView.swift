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
	@State private var loading = false
	@State private var failure: String?
	@State private var closing = false
	@State private var showingInfo = false
	@State private var incomingFiles: [URL] = []
	@State private var choosingIncoming = false

	var body: some View {
		Group {
			if let session {
				VStack(spacing: 0) {
					HStack(spacing: 0) {
						Button {
							session.stop()
							if session.canUndo { closing = true } else { close() }
						} label: { Text("Close").padding(.horizontal).frame(minHeight: 48) }
						.confirmationDialog("Discard this clip edit?", isPresented: $closing) {
							Button("Discard and Close", role: .destructive) { close() }
							Button("Keep Editing", role: .cancel) {}
						}
						Text(session.hasVideo ? "Video Cutting Board" : "Audio Cutting Board")
							.font(.headline)
							.frame(maxWidth: .infinity, minHeight: 48)
							.accessibilityAddTraits(.isHeader)
						Button { session.stop(); showingInfo = true } label: {
							Text("Clip Info").padding(.horizontal).frame(minHeight: 48)
						}
						.sheet(isPresented: $showingInfo) { ClipInfoView(session: session) }
					}
					CuttingBoardKeyboard(session: session).id(ObjectIdentifier(session))
				}
			} else {
				WelcomeView(loading: loading) {
					ClipSourceMenu(title: "Trim a Clip", choose: present)
						.buttonStyle(.borderedProminent)
						.controlSize(.large)
						.disabled(loading)
						.photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .videos, photoLibrary: .shared())
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
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(EditorTheme.workspace)
		.tint(EditorTheme.accent)
		.onOpenURL { url in
			guard url.isFileURL else { return }
			incomingFiles.append(url)
			handleIncomingFile()
		}
		.alert("Open shared clip?", isPresented: $choosingIncoming) {
			Button("Keep Editing", role: .cancel) {
				if !incomingFiles.isEmpty { discardInboxCopy(incomingFiles.removeFirst()) }
			}
			Button("Close Current Clip and Open", role: .destructive) { openIncomingFile() }
		} message: {
			Text("Opening the shared clip closes the current Cutting Board.")
		}
		.onChange(of: choosingIncoming) { _, presented in
			if !presented { handleIncomingFile() }
		}
		.onChange(of: failure) { _, error in
			if error == nil { handleIncomingFile() }
		}
		.onChange(of: photo) { _, item in
			guard let item else { return }
			photo = nil
			openClip(errorMessage: "Could not open this video. Select it again in Photo Library.") {
				guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
					throw CocoaError(.fileReadCorruptFile)
				}
				return try await CuttingBoardSession.open(movie.url, importedMovie: movie, photoIdentifier: item.itemIdentifier)
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

	private func handleIncomingFile() {
		guard !incomingFiles.isEmpty, !loading, failure == nil, !choosingIncoming else { return }
		if session != nil {
			choosingIncoming = true
		} else {
			openIncomingFile()
		}
	}

	private func openIncomingFile() {
		guard !incomingFiles.isEmpty else { return }
		let url = incomingFiles.removeFirst()
		openClip(errorMessage: "Could not open the shared clip. Choose a playable audio or video file and share it again.") {
			let accessed = url.startAccessingSecurityScopedResource()
			defer {
				if accessed { url.stopAccessingSecurityScopedResource() }
				discardInboxCopy(url)
			}
			let copy = try await ImportedMovie.snapshot(of: url)
			return try await CuttingBoardSession.open(copy.url, importedMovie: copy)
		}
	}

	private func discardInboxCopy(_ url: URL) {
		let inbox = URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
		if url.deletingLastPathComponent().resolvingSymlinksInPath().path == inbox.resolvingSymlinksInPath().path {
			try? FileManager.default.removeItem(at: url)
		}
	}

	private func close() {
		session?.releaseAudio()
		session = nil
	}

	private func present(_ source: ClipSource) {
		switch source {
		case .photos: pickingPhoto = true
		case .files: pickingFile = true
		}
	}

	private func openClip(errorMessage: String, load: @escaping () async throws -> CuttingBoardSession) {
		loading = true
		Task {
			defer {
				loading = false
				handleIncomingFile()
			}
			do {
				let next = try await load()
				session?.releaseAudio()
				closing = false
				showingInfo = false
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

private struct WelcomeView<Actions: View>: View {
	let loading: Bool
	@ViewBuilder let actions: () -> Actions

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
				actions()
				if loading { ProgressView("Opening clip") }
			}
			.multilineTextAlignment(.center)
			.frame(maxWidth: .infinity)
			.padding()
		}
		.defaultScrollAnchor(.center, for: .alignment)
	}
}
