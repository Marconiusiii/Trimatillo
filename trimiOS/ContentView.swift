import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@Environment(\.scenePhase) private var phase
	@State private var project: EditingProject?
	@State private var launcher: ProjectLauncher?
	@State private var projectTrigger = ProjectLauncher.create
	@AccessibilityFocusState private var projectFocus: ProjectLauncher?
	@State private var session: CuttingBoardSession?
	@State private var pickingFile = false
	@State private var pickingPhoto = false
	@State private var photo: PhotosPickerItem?
	@State private var loading = false
	@State private var failure: String?
	@State private var showingHelp = false
	@State private var showingSettings = false
	@AccessibilityFocusState private var helpFocused: Bool
	@AccessibilityFocusState private var settingsFocused: Bool
	@StateObject private var support = SupportStore()
	@State private var incomingFiles: [URL] = []
	@State private var choosingIncoming = false

	var body: some View {
		Group {
			if let project {
				ProjectEditorView(project: project) {
					self.project = nil
					projectFocus = projectTrigger
					handleIncomingFile()
				}.id(project.id)
			} else if let session {
				CuttingBoardKeyboard(session: session, close: close).id(ObjectIdentifier(session))
			} else {
				WelcomeView(loading: loading) {
					ClipSourceMenu(title: "Trim a Clip", choose: present)
						.buttonStyle(.borderedProminent)
						.tint(color.fill)
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
					ForEach([ProjectLauncher.create, .open], id: \.self) { mode in
						Button(mode.rawValue) { projectTrigger = mode; launcher = mode }
							.accessibilityFocused($projectFocus, equals: mode)
							.disabled(loading)
					}
					Button("Help") { showingHelp = true }
						.accessibilityFocused($helpFocused)
						.sheet(isPresented: $showingHelp, onDismiss: { helpFocused = true }) { HelpView() }
					Button("Settings") { showingSettings = true }
						.accessibilityFocused($settingsFocused)
						.sheet(isPresented: $showingSettings, onDismiss: { settingsFocused = true }) { SettingsView(support: support) }
				}
			}
		}
		.sheet(item: $launcher, onDismiss: { if project == nil { projectFocus = projectTrigger }; handleIncomingFile() }) { mode in
			ProjectLauncherView(mode: mode) { project = $0 }
		}
		.editorAppearance()
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(EditorTheme.workspace)
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
		guard project == nil, launcher == nil, !incomingFiles.isEmpty, !loading, failure == nil, !choosingIncoming else { return }
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
				showingHelp = false
				showingSettings = false
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
		.accessibilityAction(named: "Photo Library") { choose(.photos) }
		.accessibilityAction(named: "Files") { choose(.files) }
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
				Text("Welcome to Trimatillo")
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
