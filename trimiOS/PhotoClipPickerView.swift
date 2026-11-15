import Accessibility
import AVKit
import Combine
import PhotosUI
import SwiftUI

struct PhotoClipPickerView<Clip>: View {
	let prepare: (PhotosPickerItem) async throws -> (AVAsset, Clip)
	let use: (Clip) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var showingPreview = false
	@State private var confirmed = false
	@State private var selection: [PhotosPickerItem] = []

	var body: some View {
		NavigationStack {
			PhotosPicker(selection: $selection, maxSelectionCount: 1, selectionBehavior: .continuous,
				matching: .videos, photoLibrary: .shared()) { Text("Photo Library") }
				.photosPickerStyle(.inline)
				.photosPickerDisabledCapabilities(.selectionActions)
				.navigationTitle("Photo Library")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
				}
				.onChange(of: selection) { _, items in
					if !items.isEmpty { showingPreview = true }
				}
		}
		.sheet(isPresented: $showingPreview, onDismiss: {
			if confirmed { dismiss() }
		}) {
			if let item = selection.first {
				NavigationStack {
					PhotoClipPreview(item: item, prepare: prepare) { clip in
						use(clip)
						confirmed = true
						showingPreview = false
					}
					.toolbar {
						ToolbarItem(placement: .topBarLeading) { Button("Back") { showingPreview = false } }
					}
				}
				.editorAppearance()
			}
		}
		.editorAppearance()
	}
}

private struct PhotoClipPreview<Clip>: View {
	let item: PhotosPickerItem
	let prepare: (PhotosPickerItem) async throws -> (AVAsset, Clip)
	let use: (Clip) -> Void

	@Environment(\.scenePhase) private var phase
	@State private var clip: Clip?
	@State private var player: AVPlayer?
	@State private var ready = false
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
		.task(id: item) {
			if UIAccessibility.isVoiceOverRunning {
				var message = AttributedString("Loading Clip Preview")
				message.accessibilitySpeechAnnouncementPriority = .high
				AccessibilityNotification.Announcement(message).post()
			}
			do {
				let (asset, candidate) = try await prepare(item)
				try Task.checkCancellation()
				try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
				clip = candidate
				let current = AVPlayerItem(asset: asset)
				player = AVPlayer(playerItem: current)
				for await status in current.publisher(for: \.status, options: [.initial, .new]).values {
					try Task.checkCancellation()
					if status == .failed { playbackFailed(); break }
					ready = status == .readyToPlay
				}
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
		.onDisappear { player?.pause() }
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
