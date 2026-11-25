import Accessibility
import AVKit
import Combine
import PhotosUI
import SwiftUI

struct SelectedPhotoClip {
	let item: PhotosPickerItem
	let asset: AVAsset
	private let transferredMovie: ImportedMovie?

	static func load(_ item: PhotosPickerItem) async throws -> Self {
		if let id = item.itemIdentifier, let asset = try await ProjectMediaSource.accessibleVideo(id) {
			return Self(item: item, asset: asset, transferredMovie: nil)
		}
		let movie = try await transfer(item)
		return Self(item: item, asset: AVURLAsset(url: movie.url), transferredMovie: movie)
	}

	func openCuttingBoard() async throws -> CuttingBoardSession {
		let movie: ImportedMovie
		if let transferredMovie { movie = transferredMovie }
		else { movie = try await Self.transfer(item) }
		try Task.checkCancellation()
		return try await CuttingBoardSession.open(movie.url, importedMovie: movie, photoIdentifier: item.itemIdentifier)
	}

	private static func transfer(_ item: PhotosPickerItem) async throws -> ImportedMovie {
		try Task.checkCancellation()
		guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
			throw CocoaError(.fileReadCorruptFile)
		}
		return movie
	}
}

private final class PhotoPreviewRequest: Identifiable {
	let preparation: Task<SelectedPhotoClip, Error>

	init(item: PhotosPickerItem) {
		preparation = Task { try await SelectedPhotoClip.load(item) }
	}

	deinit { preparation.cancel() }
}

struct PhotoClipPickerView: View {
	let use: (SelectedPhotoClip) -> Void
	let useClips: (([PhotosPickerItem]) -> Void)?

	init(useClips: (([PhotosPickerItem]) -> Void)? = nil, use: @escaping (SelectedPhotoClip) -> Void) {
		self.useClips = useClips
		self.use = use
	}

	@Environment(\.dismiss) private var dismiss
	@State private var request: PhotoPreviewRequest?
	@State private var confirmed = false
	@State private var reviewing = false
	@AccessibilityFocusState(for: .voiceOver) private var previewFocused: Bool
	@State private var selectionError = false
	@State private var selection: [PhotosPickerItem] = []

	var body: some View {
		NavigationStack {
			PhotosPicker(selection: $selection, maxSelectionCount: useClips == nil ? 1 : nil, selectionBehavior: useClips == nil ? .continuous : .continuousAndOrdered,
				matching: .videos, preferredItemEncoding: .current, photoLibrary: .shared()) { Text("Photo Library") }
				.photosPickerStyle(.inline)
				.photosPickerDisabledCapabilities(.selectionActions)
				.navigationTitle("Photo Library")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
					if useClips != nil {
						ToolbarItem(placement: .topBarTrailing) {
							Button("Preview Clips") {
								if selection.isEmpty { selectionError = true } else { reviewing = true }
							}.accessibilityFocused($previewFocused)
						}
					}
				}
				.onChange(of: selection) { _, items in
					if useClips == nil, let item = items.first { request = PhotoPreviewRequest(item: item) }
				}
		}
		.alert("Choose a Clip", isPresented: $selectionError) {
			Button("OK", role: .cancel) {}
		} message: { Text("Select at least one video to preview.") }
		.sheet(isPresented: $reviewing, onDismiss: { if confirmed { dismiss() } else { previewFocused = true } }) {
			PhotoClipsPreview(items: selection) { items in
				useClips?(items)
				confirmed = true
				reviewing = false
			}
		}
		.sheet(item: $request, onDismiss: {
			if confirmed { dismiss() }
		}) { preview in
			NavigationStack {
				PhotoClipPreview(request: preview) { clip in
					use(clip)
					confirmed = true
					request = nil
				}
				.toolbar {
					ToolbarItem(placement: .topBarLeading) { Button("Back") { request = nil } }
				}
			}
			.editorAppearance()
		}
		.editorAppearance()
	}
}

@MainActor private final class PhotoPreviewPlayback: ObservableObject {
	@Published private(set) var clip: SelectedPhotoClip?
	@Published private(set) var player: AVPlayer?
	@Published private(set) var ready = false
	@Published private(set) var failure: String?
	private var observation: AnyCancellable?
	private var generation = UUID()

	func load(_ request: PhotoPreviewRequest) async {
		stop()
		let generation = self.generation
		if UIAccessibility.isVoiceOverRunning {
			var message = AttributedString("Loading Clip Preview")
			message.accessibilitySpeechAnnouncementPriority = .high
			AccessibilityNotification.Announcement(message).post()
		}
		do {
			let candidate = try await request.preparation.value
			try Task.checkCancellation()
			guard generation == self.generation else { return }
			try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
			clip = candidate
			let item = AVPlayerItem(asset: candidate.asset)
			let player = AVPlayer()
			self.player = player
			observation = item.publisher(for: \.status, options: [.initial, .new])
				.receive(on: DispatchQueue.main)
				.sink { [weak self, weak item] status in
					guard let self, let item, generation == self.generation, item === self.player?.currentItem else { return }
					if status == .failed { self.playbackFailed() }
					else if status == .readyToPlay && !self.ready {
						self.ready = true
						if UIAccessibility.isVoiceOverRunning {
							var message = AttributedString("Clip preview ready")
							message.accessibilitySpeechAnnouncementPriority = .low
							AccessibilityNotification.Announcement(message).post()
						}
					}
				}
			player.replaceCurrentItem(with: item)
		} catch {
			if !Task.isCancelled, generation == self.generation {
				failure = (error as? ProjectFailure)?.localizedDescription ?? "Could not load the preview. Go back and choose the video again."
			}
		}
	}

	func stop() {
		generation = UUID()
		observation?.cancel()
		observation = nil
		player?.pause()
		player?.replaceCurrentItem(with: nil)
		player = nil
		clip = nil
		ready = false
		failure = nil
	}

	func playbackFailed() {
		player?.pause()
		ready = false
		failure = "Could not play this video. Go back and choose it again."
	}

	func toggle() {
		guard ready, let player else { return }
		if player.timeControlStatus == .paused {
			if let end = player.currentItem?.duration, end.isNumeric, player.currentTime() >= end { player.seek(to: .zero) }
			player.play()
		} else { player.pause() }
	}
}

private struct PhotoPreviewContent: View {
	@ObservedObject var playback: PhotoPreviewPlayback
	@Environment(\.scenePhase) private var phase

	var body: some View {
		VStack(spacing: 0) {
			if let failure = playback.failure { Text(failure).padding() }
			else if playback.ready, let player = playback.player {
				VideoPlayer(player: player).accessibilityAction(.magicTap) { playback.toggle() }
			} else { LoadingStatusView("Loading Clip Preview") }
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(EditorTheme.workspace)
		.onChange(of: phase) { _, value in if value != .active { playback.player?.pause() } }
		.onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { notification in
			guard let item = notification.object as? AVPlayerItem, item === playback.player?.currentItem else { return }
			playback.playbackFailed()
		}
	}
}

private struct PhotoClipPreview: View {
	let request: PhotoPreviewRequest
	let use: (SelectedPhotoClip) -> Void
	@StateObject private var playback = PhotoPreviewPlayback()

	var body: some View {
		PhotoPreviewContent(playback: playback)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .principal) { Text("Clip Preview").font(.headline).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .topBarTrailing) {
					Button("Use Clip") {
						if let clip = playback.clip, playback.ready { playback.player?.pause(); use(clip) }
					}.disabled(!playback.ready)
				}
			}
			.accessibilityAction(.magicTap) { playback.toggle() }
			.task(id: request.id) { await playback.load(request) }
			.onDisappear { request.preparation.cancel(); playback.stop() }
	}
}

private struct PhotoClipsPreview: View {
	let items: [PhotosPickerItem]
	let use: ([PhotosPickerItem]) -> Void
	@Environment(\.dismiss) private var dismiss
	@StateObject private var playback = PhotoPreviewPlayback()
	@State private var page = 0
	@State private var excluded: Set<Int> = []
	@State private var inclusionError = false
	@State private var request: PhotoPreviewRequest?

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				TabView(selection: Binding(get: { page }, set: { next in
					guard next != page else { return }
					request?.preparation.cancel()
					playback.stop()
					page = next
				})) {
					ForEach(items.indices, id: \.self) { index in
						Group {
							if index == page { PhotoPreviewContent(playback: playback) }
							else { Color.clear.accessibilityHidden(true) }
						}.tag(index)
					}
				}
				.tabViewStyle(.page(indexDisplayMode: .always))
				.indexViewStyle(.page(backgroundDisplayMode: .always))
				Toggle("Include Clip", isOn: Binding(get: { !excluded.contains(page) }, set: {
					if $0 { excluded.remove(page) } else { excluded.insert(page) }
				})).padding()
			}
			.background(EditorTheme.workspace)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button("Back") { dismiss() } }
				ToolbarItem(placement: .principal) {
					Text("Clip \(page + 1) of \(items.count)").font(.headline).accessibilityAddTraits(.isHeader)
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button("Use Clips") {
						let included = items.indices.filter { !excluded.contains($0) }.map { items[$0] }
						if included.isEmpty { inclusionError = true }
						else { playback.player?.pause(); use(included) }
					}
				}
			}
		}
		.editorAppearance()
		.accessibilityAction(.magicTap) { playback.toggle() }
		.alert("Include a Clip", isPresented: $inclusionError) {
			Button("OK", role: .cancel) {}
		} message: { Text("Turn on Include Clip for at least one video, then choose Use Clips.") }
		.task(id: page) {
			let request = PhotoPreviewRequest(item: items[page])
			self.request = request
			await playback.load(request)
		}
		.onDisappear { request?.preparation.cancel(); playback.stop() }
	}
}
