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

	@Environment(\.dismiss) private var dismiss
	@State private var request: PhotoPreviewRequest?
	@State private var confirmed = false
	@State private var selection: [PhotosPickerItem] = []

	var body: some View {
		NavigationStack {
			PhotosPicker(selection: $selection, maxSelectionCount: 1, selectionBehavior: .continuous,
				matching: .videos, preferredItemEncoding: .current, photoLibrary: .shared()) { Text("Photo Library") }
				.photosPickerStyle(.inline)
				.photosPickerDisabledCapabilities(.selectionActions)
				.navigationTitle("Photo Library")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
				}
				.onChange(of: selection) { _, items in
					if let item = items.first { request = PhotoPreviewRequest(item: item) }
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

private struct PhotoClipPreview: View {
	let request: PhotoPreviewRequest
	let use: (SelectedPhotoClip) -> Void

	@Environment(\.scenePhase) private var phase
	@State private var clip: SelectedPhotoClip?
	@State private var player: AVPlayer?
	@State private var statusObservation: AnyCancellable?
	@State private var ready = false
	@State private var announcedReady = false
	@State private var failure: String?

	var body: some View {
		VStack(spacing: 0) {
			if let failure {
				Text(failure).padding()
			} else if ready, let player {
				VideoPlayer(player: player)
					.accessibilityAction(.magicTap) { toggle(player) }
			} else {
				LoadingStatusView("Loading Clip Preview")
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(EditorTheme.workspace)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .principal) {
				Text("Clip Preview").font(.headline).accessibilityAddTraits(.isHeader)
			}
			ToolbarItem(placement: .topBarTrailing) {
				Button("Use Clip") {
					if let clip, ready {
						player?.pause()
						use(clip)
					}
				}
				.disabled(!ready)
			}
		}
		.accessibilityAction(.magicTap) {
			if ready, let player { toggle(player) }
		}
		.task(id: request.id) {
			if UIAccessibility.isVoiceOverRunning {
				var message = AttributedString("Loading Clip Preview")
				message.accessibilitySpeechAnnouncementPriority = .high
				AccessibilityNotification.Announcement(message).post()
			}
			do {
				let candidate = try await request.preparation.value
				try Task.checkCancellation()
				try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
				clip = candidate
				let current = AVPlayerItem(asset: candidate.asset)
				let previewPlayer = AVPlayer()
				player = previewPlayer
				statusObservation = current.publisher(for: \.status, options: [.initial, .new])
					.receive(on: DispatchQueue.main)
					.sink { status in
						guard current === player?.currentItem else { return }
						if status == .failed { playbackFailed() }
						else {
							ready = status == .readyToPlay
							if ready, !announcedReady, UIAccessibility.isVoiceOverRunning {
								announcedReady = true
								var message = AttributedString("Clip preview ready")
								message.accessibilitySpeechAnnouncementPriority = .low
								AccessibilityNotification.Announcement(message).post()
							}
						}
					}
				previewPlayer.replaceCurrentItem(with: current)
			} catch {
				if !Task.isCancelled {
					failure = (error as? ProjectFailure)?.localizedDescription ?? "Could not load the preview. Go back and choose the video again."
				}
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { notification in
			guard let failed = notification.object as? AVPlayerItem, failed === player?.currentItem else { return }
			playbackFailed()
		}
		.onDisappear {
			request.preparation.cancel()
			statusObservation?.cancel()
			statusObservation = nil
			player?.pause()
			player?.replaceCurrentItem(with: nil)
			player = nil
			clip = nil
			ready = false
		}
		.onChange(of: phase) { _, value in
			if value != .active { player?.pause() }
		}
	}

	private func playbackFailed() {
		player?.pause()
		ready = false
		failure = "Could not play this video. Go back and choose it again."
	}

	private func toggle(_ player: AVPlayer) {
		if player.timeControlStatus == .paused {
			if let end = player.currentItem?.duration, end.isNumeric, player.currentTime() >= end {
				player.seek(to: .zero)
			}
			player.play()
		} else {
			player.pause()
		}
	}
}
