import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
	private var loading: Task<Void, Never>?
	private var session: CuttingBoardSession?

	override func viewDidLoad() {
		super.viewDidLoad()
		display(ProgressView("Opening video"))
		loading = Task { [self] in
			do {
				let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
					.flatMap { $0.attachments ?? [] }
					.filter { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
				guard providers.count == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
				let movie: ImportedMovie = try await withCheckedThrowingContinuation { continuation in
					providers[0].loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
						guard let url else {
							continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
							return
						}
						// The provider owns this URL only for the duration of its callback.
						continuation.resume(with: Result { try ImportedMovie(copying: url) })
					}
				}
				let board = try await CuttingBoardSession.open(movie.url, importedMovie: movie)
				try Task.checkCancellation()
				session = board
				display(CuttingBoardKeyboard(session: board, close: { [weak self] in self?.finish() }))
			} catch {
				guard !Task.isCancelled else { return }
				display(VStack {
					Text("Could not open the video. Select a playable video and share it again.")
					Button("Close") { [weak self] in self?.finish() }
				})
			}
		}
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
		session?.releaseAudio()
		extensionContext?.completeRequest(returningItems: nil)
	}
}
