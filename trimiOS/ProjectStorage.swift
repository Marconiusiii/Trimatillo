import Foundation

nonisolated enum ProjectStorage {
	static let didClean = Notification.Name("TrimatilloStorageDidClean")
	static let clearRequestKey = "clearTemporaryFilesOnNextLaunch"

	static func directoryExists(_ url: URL) throws -> Bool {
		do {
			let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
			guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
			return true
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
			return false
		}
	}

	static func prepareDirectory(_ directory: URL) throws {
		if try !directoryExists(directory) {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
				attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
		}
	}

	@concurrent static func sizes() async throws -> (projects: Int64, temporary: Int64, available: Int64) {
		let projects = try ProjectLibrary.savedFiles().reduce(Int64(0)) {
			try $0 + MediaWorkDirectory.storedBytes(at: $1)
		}
		let work = try MediaWorkDirectory.inspect(clear: false)
		let pending = try ProjectLibrary.pendingDeletions().reduce(Int64(0)) { try $0 + MediaWorkDirectory.storedBytes(at: $1) }
		return (projects, work.total + pending, work.available + pending)
	}

	@concurrent static func clearTemporaryFiles() async throws {
		_ = try MediaWorkDirectory.inspect(clear: true)
		try await ProjectLibrary.finishDeletions()
	}

	static func recordings(_ project: UUID, drafts: Bool, create: Bool = false) throws -> URL {
		let home = ProjectLibrary.directory.appendingPathComponent(project.uuidString, isDirectory: true)
		guard try directoryExists(ProjectLibrary.directory), try directoryExists(home) else {
			throw ProjectFailure("Save the project before recording.")
		}
		let directory = home.appendingPathComponent(drafts ? "Draft Recordings" : "Recordings", isDirectory: true)
		if create { try prepareDirectory(directory) }
		else { _ = try directoryExists(directory) }
		return directory
	}

	static func recording(_ id: UUID, project: UUID, draft: Bool = false) throws -> URL {
		let url = try recordings(project, drafts: draft).appendingPathComponent(id.uuidString + ".caf")
		let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
		guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
		return url
	}

	static func pruneUnusedRecordings(_ project: EditingProject) {
		let folder = ProjectLibrary.directory.appendingPathComponent(project.id.uuidString)
		guard let directory = try? recordings(project.id, drafts: false),
			let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
			!files.isEmpty, (try? ProjectLibrary.load(folder)) == project else { return }
		let retained = Set((project.audioDescriptions ?? []).map(\.recording))
		for file in files where file.pathExtension == "caf" {
			if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !retained.contains(id) {
				try? FileManager.default.removeItem(at: file)
			}
		}
	}

	static func formatted(_ bytes: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
	}
}
