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

	static func formatted(_ bytes: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
	}
}
