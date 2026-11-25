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
	private var readiness: CheckedContinuation<Void, Error>?
	private var readinessObservation: AnyCancellable?
	private var readinessTimeout: Task<Void, Never>?

	func load(_ request: PhotoPreviewRequest, announce: Bool = true) async {
		stop()
		let generation = self.generation
		if announce && UIAccessibility.isVoiceOverRunning {
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
			if !announce { item.preferredForwardBufferDuration = 1 }
			let player = AVPlayer()
			self.player = player
			observation = item.publisher(for: \.status, options: [.initial, .new])
				.receive(on: DispatchQueue.main)
				.sink { [weak self, weak item] status in
					guard let self, let item, generation == self.generation, item === self.player?.currentItem else { return }
					if status == .failed { self.playbackFailed() }
					else if status == .readyToPlay && !self.ready {
						self.ready = true
						if announce && UIAccessibility.isVoiceOverRunning {
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

	func prepare(_ request: PhotoPreviewRequest) async throws {
		await load(request, announce: false)
		try Task.checkCancellation()
		guard failure == nil, let player, let item = player.currentItem else { throw CocoaError(.fileReadCorruptFile) }
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				readiness = continuation
				readinessTimeout = Task { [weak self] in
					do { try await Task.sleep(for: .seconds(30)) } catch { return }
					self?.finishReadiness(.failure(CocoaError(.fileReadUnknown)))
				}
				readinessObservation = player.publisher(for: \.status, options: [.initial, .new])
					.combineLatest(item.publisher(for: \.status, options: [.initial, .new]))
					.receive(on: DispatchQueue.main)
					.sink { [weak self] playerStatus, itemStatus in
						if playerStatus == .failed || itemStatus == .failed {
							self?.finishReadiness(.failure(CocoaError(.fileReadCorruptFile)))
						} else if playerStatus == .readyToPlay && itemStatus == .readyToPlay {
							self?.finishReadiness(.success(()))
						}
					}
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.finishReadiness(.failure(CancellationError())) }
		}
		try Task.checkCancellation()
		let timeout = Task { @MainActor [weak player] in
			do { try await Task.sleep(for: .seconds(30)) } catch { return }
			player?.cancelPendingPrerolls()
		}
		defer { timeout.cancel() }
		let primed = await withTaskCancellationHandler {
			await player.preroll(atRate: 1)
		} onCancel: {
			Task { @MainActor [weak player] in player?.cancelPendingPrerolls() }
		}
		try Task.checkCancellation()
		guard primed else { throw CocoaError(.fileReadUnknown) }
	}

	private func finishReadiness(_ result: Result<Void, Error>) {
		let continuation = readiness
		readiness = nil
		readinessObservation?.cancel()
		readinessObservation = nil
		readinessTimeout?.cancel()
		readinessTimeout = nil
		continuation?.resume(with: result)
	}

	func preparationFailed() {
		stop()
		failure = "Could not prepare this video. Turn off Include Clip to import the other videos, or go back and choose it again."
	}

	func stop() {
		finishReadiness(.failure(CancellationError()))
		player?.cancelPendingPrerolls()
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

@MainActor private final class PhotoPreviewCollection: ObservableObject {
	@Published private(set) var previews: [PhotoPreviewPlayback] = []
	@Published private(set) var prepared = false
	private var pending: PhotoPreviewPlayback?
	private var request: PhotoPreviewRequest?
	private var generation = UUID()

	func prepare(_ items: [PhotosPickerItem]) async {
		stop()
		let generation = self.generation
		for item in items {
			guard generation == self.generation else { return }
			guard !Task.isCancelled else { stop(); return }
			let preview = PhotoPreviewPlayback()
			let request = PhotoPreviewRequest(item: item)
			pending = preview
			self.request = request
			do { try await preview.prepare(request) }
			catch {
				guard generation == self.generation else { return }
				if Task.isCancelled { stop(); return }
				preview.preparationFailed()
			}
			guard generation == self.generation else { return }
			guard !Task.isCancelled else { stop(); return }
			previews.append(preview)
			pending = nil
			self.request = nil
		}
		prepared = true
	}

	func stop() {
		generation = UUID()
		prepared = false
		request?.preparation.cancel()
		request = nil
		pending?.stop()
		pending = nil
		previews.forEach { $0.stop() }
		previews = []
	}
}

private struct PhotoClipsPreview: View {
	let items: [PhotosPickerItem]
	let use: ([PhotosPickerItem]) -> Void
	@Environment(\.dismiss) private var dismiss
	@StateObject private var collection = PhotoPreviewCollection()
	@State private var page = 0
	@State private var excluded: Set<Int> = []
	@State private var inclusionError = false

	var body: some View {
		NavigationStack {
			Group {
				if collection.prepared { pages }
				else {
					ProgressView("Preparing Clip Previews", value: Double(collection.previews.count), total: Double(max(1, items.count)))
						.padding()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.background(EditorTheme.workspace)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { Button(collection.prepared ? "Back" : "Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) {
					Text("Clip Preview").font(.headline).accessibilityAddTraits(.isHeader)
				}
				if collection.prepared {
					ToolbarItem(placement: .topBarTrailing) {
						Button("Use Clips") {
							let included = items.indices.filter { !excluded.contains($0) }.map { items[$0] }
							if included.isEmpty { inclusionError = true }
							else { collection.previews[page].player?.pause(); use(included) }
						}
					}
				}
			}
		}
		.editorAppearance()
		.accessibilityAction(.magicTap) {
			if collection.prepared { collection.previews[page].toggle() }
		}
		.alert("Include a Clip", isPresented: $inclusionError) {
			Button("OK", role: .cancel) {}
		} message: { Text("Turn on Include Clip for at least one video, then choose Use Clips.") }
		.task {
			if UIAccessibility.isVoiceOverRunning {
				var message = AttributedString("Preparing Clip Previews")
				message.accessibilitySpeechAnnouncementPriority = .high
				AccessibilityNotification.Announcement(message).post()
			}
			await collection.prepare(items)
			if !Task.isCancelled, collection.prepared, UIAccessibility.isVoiceOverRunning {
				var message = AttributedString("Clip previews ready")
				message.accessibilitySpeechAnnouncementPriority = .low
				AccessibilityNotification.Announcement(message).post()
			}
		}
		.onDisappear { collection.stop() }
	}

	private var pages: some View {
		VStack(spacing: 0) {
			PhotoPreviewPager(previews: collection.previews, selection: $page)
			Toggle("Include Clip", isOn: Binding(get: { !excluded.contains(page) }, set: {
				if $0 { excluded.remove(page) } else { excluded.insert(page) }
			})).padding()
		}
	}
}

// UIKit owns the pager and page control for the entire review session.
// SwiftUI updates do not replace either control or the hosted preview roots.
private struct PhotoPreviewPager: UIViewControllerRepresentable {
	let previews: [PhotoPreviewPlayback]
	@Binding var selection: Int
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal

	func makeUIViewController(context: Context) -> PhotoPreviewPageController {
		PhotoPreviewPageController(previews: previews, selection: selection) { selection = $0 }
	}

	func updateUIViewController(_ controller: PhotoPreviewPageController, context: Context) {
		controller.selectionChanged = { selection = $0 }
		controller.view.tintColor = UIColor(color.accent)
		controller.pageControl.currentPageIndicatorTintColor = UIColor(color.accent)
	}

	static func dismantleUIViewController(_ controller: PhotoPreviewPageController, coordinator: ()) {
		controller.close()
	}
}

@MainActor private final class PhotoPreviewPageController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
	let pageControl = UIPageControl()
	var selectionChanged: (Int) -> Void
	private let previews: [PhotoPreviewPlayback]
	private let pages: [UIHostingController<PhotoPreviewContent>]
	private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
	private var selected: Int
	private var requested: Int?
	private var transitioning = false
	private var closed = false

	init(previews: [PhotoPreviewPlayback], selection: Int, selectionChanged: @escaping (Int) -> Void) {
		self.previews = previews
		pages = previews.map { UIHostingController(rootView: PhotoPreviewContent(playback: $0)) }
		selected = selection
		self.selectionChanged = selectionChanged
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = UIColor(EditorTheme.workspace)
		pager.dataSource = self
		pager.delegate = self
		addChild(pager)
		view.addSubview(pager.view)
		pager.view.translatesAutoresizingMaskIntoConstraints = false
		pager.didMove(toParent: self)
		pageControl.numberOfPages = pages.count
		pageControl.currentPage = selected
		pageControl.accessibilityLabel = "Clip Preview"
		pageControl.backgroundStyle = .prominent
		pageControl.pageIndicatorTintColor = .secondaryLabel
		pageControl.addTarget(self, action: #selector(pageChanged), for: .valueChanged)
		view.addSubview(pageControl)
		pageControl.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			pager.view.topAnchor.constraint(equalTo: view.topAnchor),
			pager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			pager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			pager.view.bottomAnchor.constraint(equalTo: pageControl.topAnchor),
			pageControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			pageControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			pageControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			pageControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
		])
		if pages.indices.contains(selected) { pager.setViewControllers([pages[selected]], direction: .forward, animated: false) }
	}

	@objc private func pageChanged() {
		guard !closed, pages.indices.contains(pageControl.currentPage) else { return }
		requested = pageControl.currentPage
		showRequestedPage()
	}

	private func showRequestedPage() {
		guard !closed, !transitioning, let target = requested else { return }
		requested = nil
		guard target != selected else { return }
		previews[selected].player?.pause()
		let direction: UIPageViewController.NavigationDirection = target > selected ? .forward : .reverse
		transitioning = true
		pager.setViewControllers([pages[target]], direction: direction, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] _ in
			self?.finishTransition()
		}
	}

	private func finishTransition() {
		guard !closed else { return }
		transitioning = false
		if let visible = pager.viewControllers?.first, let index = pages.firstIndex(where: { $0 === visible }) {
			selected = index
			selectionChanged(index)
		}
		if requested == nil { pageControl.currentPage = selected }
		showRequestedPage()
	}

	func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
		guard let index = pages.firstIndex(where: { $0 === viewController }), index > 0 else { return nil }
		return pages[index - 1]
	}

	func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
		guard let index = pages.firstIndex(where: { $0 === viewController }), index + 1 < pages.count else { return nil }
		return pages[index + 1]
	}

	func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
		transitioning = true
		previews[selected].player?.pause()
	}

	func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
		finishTransition()
	}

	func close() {
		closed = true
		requested = nil
		selectionChanged = { _ in }
		previews.forEach { $0.player?.pause() }
		pager.delegate = nil
		pager.dataSource = nil
	}
}
