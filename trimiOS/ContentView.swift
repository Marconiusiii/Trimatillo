import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import AVFoundation
import Combine

struct ContentView: View {
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@Environment(\.scenePhase) private var phase
	@State private var project: EditingProject?
	@State private var launcher: ProjectLauncher?
	@State private var projectTrigger = ProjectLauncher.create
	@AccessibilityFocusState private var projectFocus: ProjectLauncher?
	@State private var session: CuttingBoardSession?
	@AccessibilityFocusState private var trimFocused: Bool
	@State private var pickingFile = false
	@State private var pickingPhoto = false
	@State private var confirmedPhoto: (movie: ImportedMovie, identifier: String?)?
	@State private var loadingTask: Task<Void, Never>?
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
			if loadingTask != nil {
				LoadingStatusView("Opening clip", cancel: cancelOpening)
			} else if let project {
				ProjectWorkspaceView(project: project) {
					self.project = nil
					projectFocus = projectTrigger
					handleIncomingFile()
				}.id(project.id)
			} else if let session {
				CuttingBoardKeyboard(session: session, close: close).id(ObjectIdentifier(session))
			} else {
				WelcomeView {
					ClipSourceMenu(title: "Trim a Clip", choose: present)
						.buttonStyle(.borderedProminent)
						.tint(color.fill)
						.controlSize(.large)
						.accessibilityFocused($trimFocused)
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
						Button { projectTrigger = mode; launcher = mode } label: { Text(mode.rawValue).editorTouchRow() }
							.accessibilityFocused($projectFocus, equals: mode)
					}
					Button { showingHelp = true } label: { Text("Help").editorTouchRow() }
						.accessibilityFocused($helpFocused)
						.sheet(isPresented: $showingHelp, onDismiss: { helpFocused = true }) { HelpView() }
					Button { showingSettings = true } label: { Text("Settings").editorTouchRow() }
						.accessibilityFocused($settingsFocused)
						.sheet(isPresented: $showingSettings, onDismiss: { settingsFocused = true }) { SettingsView(support: support) }
				}
			}
		}
		.sheet(isPresented: $pickingPhoto, onDismiss: finishPhotoSelection) {
			PhotoClipPickerView { item in
				guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
					throw CocoaError(.fileReadCorruptFile)
				}
				return (AVURLAsset(url: movie.url), (movie, item.itemIdentifier))
			} use: { confirmedPhoto = $0 }
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
		.onChange(of: pickingFile) { _, open in if !open { trimFocused = true } }
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

	private func finishPhotoSelection() {
		guard let confirmedPhoto else {
			trimFocused = true
			handleIncomingFile()
			return
		}
		self.confirmedPhoto = nil
		openClip(errorMessage: "Could not open this video. Select it again in Photo Library.") {
			try await CuttingBoardSession.open(confirmedPhoto.movie.url, importedMovie: confirmedPhoto.movie,
				photoIdentifier: confirmedPhoto.identifier)
		}
	}

	private func handleIncomingFile() {
		guard project == nil, launcher == nil, !pickingPhoto, confirmedPhoto == nil, !incomingFiles.isEmpty, loadingTask == nil, failure == nil, !choosingIncoming else { return }
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
		trimFocused = true
	}

	private func present(_ source: ClipSource) {
		switch source {
		case .photos: pickingPhoto = true
		case .files: pickingFile = true
		}
	}

	private func cancelOpening() {
		loadingTask?.cancel()
		loadingTask = nil
		trimFocused = true
		handleIncomingFile()
	}

	private func openClip(errorMessage: String, load: @escaping () async throws -> CuttingBoardSession) {
		loadingTask = Task {
			defer {
				if !Task.isCancelled {
					loadingTask = nil
					handleIncomingFile()
				}
			}
			do {
				let next = try await load()
				try await next.waitForOpeningPlayback()
				try Task.checkCancellation()
				session?.releaseAudio()
				showingHelp = false
				showingSettings = false
				session = next
			} catch { if !Task.isCancelled { failure = errorMessage } }
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
		Menu {
			Button("Photo Library") { choose(.photos) }
			Button("Files") { choose(.files) }
		} label: { Text(title).editorTouchRow() }
		.accessibilityAction(named: "Photo Library") { choose(.photos) }
		.accessibilityAction(named: "Files") { choose(.files) }
	}
}

private struct WelcomeView<Actions: View>: View {
	@ViewBuilder let actions: () -> Actions

	var body: some View {
		ViewThatFits(in: .vertical) {
			welcomeContent
			ScrollView { welcomeContent }
		}
	}

	private var welcomeContent: some View {
		VStack(spacing: 0) {
			VStack {
				Image(decorative: "AppIcon60x60")
					.resizable()
					.scaledToFit()
					.frame(width: 104, height: 104)
				Text("Welcome to Trimatillo")
					.font(.largeTitle.weight(.semibold))
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.padding(.vertical)
			.contentShape(Rectangle())
			.accessibilityElement(children: .combine)
			.accessibilityAddTraits(.isHeader)
			actions()
		}
		.multilineTextAlignment(.center)
	}
}

extension CuttingBoardSession {
	func waitForOpeningPlayback() async throws {
		try Task.checkCancellation()
		guard let item = player.currentItem else { throw CocoaError(.fileReadCorruptFile) }
		let statuses = item.publisher(for: \.status, options: [.initial, .new]).filter { $0 != .unknown }
		for await status in statuses.values {
			try Task.checkCancellation()
			switch status {
			case .readyToPlay: return
			case .failed: throw item.error ?? CocoaError(.fileReadCorruptFile)
			default: continue
			}
		}
		throw CancellationError()
	}
}

struct LoadingStatusView: View {
	let title: LocalizedStringKey
	let cancel: (() -> Void)?

	init(_ title: LocalizedStringKey, cancel: (() -> Void)? = nil) {
		self.title = title
		self.cancel = cancel
	}

	var body: some View {
		VStack(spacing: 0) {
			ProgressView(title)
				.editorTouchRow()
			if let cancel {
				Button("Cancel", role: .cancel, action: cancel)
					.buttonStyle(EditorButtonStyle())
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(EditorTheme.workspace)
	}
}
