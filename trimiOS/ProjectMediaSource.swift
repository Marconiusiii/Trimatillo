import AVFoundation
import Photos

nonisolated final class ProjectMediaAccess: @unchecked Sendable {
	let asset: AVAsset
	private let scoped: URL?
	private let generatedFile: ExportFile?

	init(asset: AVAsset, scoped: URL? = nil, generatedFile: ExportFile? = nil) {
		self.asset = asset
		self.scoped = scoped
		self.generatedFile = generatedFile
	}

	deinit { scoped?.stopAccessingSecurityScopedResource() }
}

nonisolated struct ProjectMediaSource: Codable, Equatable, Identifiable {
	enum Reference: Codable, Equatable {
		case file(Data)
		case generated(GeneratorDefinition)
		case recording(project: UUID, id: UUID)
		case photos(local: String, cloud: String?)
	}

	var id = UUID()
	let name: String
	var projectName: String?
	var displayName: String { projectName ?? name }
	var reference: Reference
	let duration: ProjectTime
	let picture: ProjectPicture?
	let hasAudio: Bool

	@MainActor static func file(_ url: URL) async throws -> Self {
		let accessed = url.startAccessingSecurityScopedResource()
		defer { if accessed { url.stopAccessingSecurityScopedResource() } }
		let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
		return try await inspect(asset: AVURLAsset(url: url), name: url.lastPathComponent, reference: .file(data))
	}

	@MainActor static func accessibleVideo(_ id: String) async throws -> AVAsset? {
		let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
		guard permission == .authorized || permission == .limited,
			let photo = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
		do { return try await video(photo) }
		catch {
			try Task.checkCancellation()
			return nil
		}
	}

	@MainActor static func photo(_ id: String, asset: AVAsset) async throws -> Self {
		let photo = try await photoAsset(id, cloud: nil)
		let name = PHAssetResource.assetResources(for: photo).first { $0.type == .video || $0.type == .fullSizeVideo }?.originalFilename ?? "Video"
		let result = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [id])[id]
		let cloud = (try? result?.get())?.stringValue
		return try await inspect(asset: asset, name: name, reference: .photos(local: id, cloud: cloud))
	}

	@MainActor private static func inspect(asset: AVAsset, name: String, reference: Reference) async throws -> Self {
		let duration = try await asset.load(.duration)
		let video = try await asset.loadTracks(withMediaType: .video).first
		let audio = try await MediaQuality.playbackAudioTrack(asset)
		guard duration.isNumeric, duration > .zero, video != nil || audio != nil else {
			throw ProjectFailure("Choose a playable video or audio clip.")
		}
		var picture: ProjectPicture?
		if let video {
			let size = try await video.load(.naturalSize)
			let oriented = size.applying(try await video.load(.preferredTransform))
			var frame = try await video.load(.minFrameDuration)
			if !frame.isNumeric || frame <= .zero {
				let rate = try await video.load(.nominalFrameRate)
				guard rate > 0 else { throw ProjectFailure("Choose a video with a readable frame rate.") }
				frame = CMTime(seconds: 1 / Double(rate), preferredTimescale: 600000)
			}
			picture = ProjectPicture(width: Int(abs(oriented.width).rounded()), height: Int(abs(oriented.height).rounded()), frame: ProjectTime(frame))
		}
		return Self(name: name, reference: reference, duration: ProjectTime(duration), picture: picture, hasAudio: audio != nil)
	}

	@MainActor private static func photoAsset(_ id: String, cloud: String?) async throws -> PHAsset {
		let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
		guard status == .authorized || status == .limited else {
			throw ProjectFailure("Allow access to the selected video in Settings, then choose it again.")
		}
		if let photo = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject { return photo }
		if let cloud {
			let key = PHCloudIdentifier(stringValue: cloud)
			if let mapping = PHPhotoLibrary.shared().localIdentifierMappings(for: [key])[key],
				let local = try? mapping.get(), let photo = PHAsset.fetchAssets(withLocalIdentifiers: [local], options: nil).firstObject { return photo }
		}
		throw ProjectFailure("Open Project Media and reconnect the video from Photos.")
	}

	@MainActor private static func video(_ photo: PHAsset) async throws -> AVAsset {
		let options = PHVideoRequestOptions()
		options.isNetworkAccessAllowed = true
		options.deliveryMode = .highQualityFormat
		let request = ProjectPhotoRequest()
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await request.load(photo, options: options)
		} onCancel: {
			Task { @MainActor in request.cancel() }
		}
	}

	var generator: GeneratorDefinition? {
		if case .generated(let definition) = reference { return definition }
		return nil
	}

	@MainActor func renewedFileReference() throws -> Reference? {
		guard case .file(let data) = reference else { return nil }
		var stale = false
		// Unavailable sources retain their existing reconnect flow.
		guard let url = try? URL(resolvingBookmarkData: data, options: .withoutUI,
			relativeTo: nil, bookmarkDataIsStale: &stale), stale else { return nil }
		let accessed = url.startAccessingSecurityScopedResource()
		defer { if accessed { url.stopAccessingSecurityScopedResource() } }
		do {
			return .file(try url.bookmarkData(options: .minimalBookmark,
				includingResourceValuesForKeys: nil, relativeTo: nil))
		} catch {
			throw ProjectFailure("Could not update the file reference for " + displayName + ". Reconnect the clip in Project Media.")
		}
	}

	@MainActor func open() async throws -> ProjectMediaAccess {
		switch reference {
		case .generated(let definition): return try await GeneratorRenderer.access(definition)
		case .recording(let project, let id):
			return ProjectMediaAccess(asset: AVURLAsset(url: try ProjectStorage.recording(id, project: project)))
		case .file(let data):
			var stale = false
			let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
			let accessed = url.startAccessingSecurityScopedResource()
			return ProjectMediaAccess(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]), scoped: accessed ? url : nil)
		case .photos(let local, let cloud):
			let photo = try await Self.photoAsset(local, cloud: cloud)
			return ProjectMediaAccess(asset: try await Self.video(photo))
		}
	}
}

@MainActor private final class ProjectPhotoRequest {
	private var identifier: PHImageRequestID?
	private var continuation: CheckedContinuation<AVAsset, Error>?

	func load(_ photo: PHAsset, options: PHVideoRequestOptions) async throws -> AVAsset {
		try Task.checkCancellation()
		return try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
			identifier = PHImageManager.default().requestAVAsset(forVideo: photo, options: options) { @Sendable asset, _, _ in
				Task { @MainActor in
					guard let continuation = self.continuation else { return }
					self.continuation = nil
					self.identifier = nil
					if let asset { continuation.resume(returning: asset) }
					else { continuation.resume(throwing: ProjectFailure("Download the video in Photos, then reopen it.")) }
				}
			}
		}
	}

	func cancel() {
		if let identifier { PHImageManager.default().cancelImageRequest(identifier) }
		identifier = nil
		continuation?.resume(throwing: CancellationError())
		continuation = nil
	}
}
