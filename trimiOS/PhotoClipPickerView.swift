import AVKit
import Combine
import PhotosUI
import SwiftUI

struct PhotoClipPickerView<Clip>: View {
	let prepare: (PhotosPickerItem) async throws -> (AVAsset, Clip)
	let use: (Clip) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var selection: [PhotosPickerItem] = []

	var body: some View {
		NavigationStack(path: $selection) {
			PhotosPicker(selection: $selection, maxSelectionCount: 1, selectionBehavior: .continuous,
				matching: .videos, photoLibrary: .shared()) { Text("Photo Library") }
				.photosPickerStyle(.inline)
				.photosPickerDisabledCapabilities(.selectionActions)
				.navigationTitle("Photo Library")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
				}
				.navigationDestination(for: PhotosPickerItem.self) { item in
					PhotoClipPreview(item: item, prepare: prepare) { clip in
						use(clip)
						dismiss()
					}
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
		Group {
			if let failure {
				Text(failure).padding()
			} else if let player, let current = player.currentItem {
				Group {
					if ready {
						VideoPlayer(player: player)
							.accessibilityAction(.magicTap) { toggle(player) }
					} else {
						LoadingStatusView("Loading clip preview")
					}
				}
				.onReceive(current.publisher(for: \.status, options: [.initial, .new]).removeDuplicates()) { status in
					if status == .failed { playbackFailed() }
					else { ready = status == .readyToPlay }
				}
				.onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: current)) { _ in
					playbackFailed()
				}
			} else {
				LoadingStatusView("Loading clip preview")
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
			do {
				let (asset, candidate) = try await prepare(item)
				try Task.checkCancellation()
				try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
				clip = candidate
				player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
			} catch {
				if !Task.isCancelled {
					failure = (error as? ProjectFailure)?.localizedDescription ?? "Could not load the preview. Go back and choose the video again."
				}
			}
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
