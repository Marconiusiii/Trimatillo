import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
	private var loading: Task<Void, Never>?
	private var session: CuttingBoardSession?

	override func viewDidLoad() {
		super.viewDidLoad()
		display(ProgressView("Opening video"))
		let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
			.flatMap { $0.attachments ?? [] }
			.filter { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
		loading = Task { [weak self] in
			do {
				guard providers.count == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
				let movie = try await SharedMovieRequest().load(providers[0])
				try Task.checkCancellation()
				let board = try await CuttingBoardSession.open(movie.url, importedMovie: movie)
				try Task.checkCancellation()
				guard let self else { return }
				loading = nil
				session = board
				display(CuttingBoardKeyboard(session: board, close: { [weak self] in self?.finish() }))
			} catch {
				guard !Task.isCancelled, let self else { return }
				loading = nil
				display(VStack {
					Text("Could not open the video. Select a playable video and share it again.")
					Button("Close") { [weak self] in self?.finish() }
				})
			}
		}
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)
		if presentedViewController == nil { cancelLoading() }
	}

	deinit { loading?.cancel() }

	private func cancelLoading() {
		loading?.cancel()
		loading = nil
	}

	private func display(_ content: some View) {
		for child in children {
			child.willMove(toParent: nil)
			child.view.removeFromSuperview()
			child.removeFromParent()
		}
		let host = UIHostingController(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(EditorTheme.workspace).editorAppearance())
		addChild(host)
		host.view.frame = view.bounds
		host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		view.addSubview(host.view)
		host.didMove(toParent: self)
	}

	private func finish() {
		cancelLoading()
		session?.releaseAudio()
		extensionContext?.completeRequest(returningItems: nil)
	}
}

// The provider callback may race cancellation or run before it returns Progress.
// Resume the waiter once, and keep the borrowed file inside the callback.
nonisolated private final class SharedMovieRequest: @unchecked Sendable {
	private let lock = NSLock()
	private var cancelled = false
	private var continuation: CheckedContinuation<ImportedMovie, Error>?
	private var progress: Progress?

	func load(_ provider: NSItemProvider) async throws -> ImportedMovie {
		try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { waiter in
				let start = lock.withLock {
					guard !cancelled else { return false }
					continuation = waiter
					return true
				}
				guard start else { waiter.resume(throwing: CancellationError()); return }
				let request = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [self] url, error in
					guard !lock.withLock({ cancelled }) else { return }
					let result = Result<ImportedMovie, Error> {
						guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
						return try ImportedMovie(copying: url)
					}
					let waiter = lock.withLock {
						let waiter = continuation
						continuation = nil
						progress = nil
						return waiter
					}
					waiter?.resume(with: result)
				}
				let cancel = lock.withLock {
					if cancelled { return true }
					if continuation != nil { progress = request }
					return false
				}
				if cancel { request.cancel() }
			}
		} onCancel: { self.cancel() }
	}

	private func cancel() {
		let pending = lock.withLock {
			cancelled = true
			let pending = (continuation, progress)
			continuation = nil
			progress = nil
			return pending
		}
		pending.0?.resume(throwing: CancellationError())
		pending.1?.cancel()
	}
}
