import SwiftUI
import CoreMedia

enum ProjectLauncher: String, Identifiable {
	case create = "Create Project"
	case open = "Open Project"
	var id: Self { self }
}

private enum ProjectResolutionChoice: String, CaseIterable, Identifiable, Sendable {
	case sameAsMedia
	case hd
	case fullHD
	case qhd
	case ultraHD
	case verticalHD
	case verticalFullHD
	case verticalUltraHD
	case square
	case portraitFourByFive
	case custom

	var id: String { rawValue }

	var label: String {
		switch self {
		case .sameAsMedia: "Same as Media"
		case .hd: "1280 by 720, HD"
		case .fullHD: "1920 by 1080, Full HD"
		case .qhd: "2560 by 1440, QHD"
		case .ultraHD: "3840 by 2160, 4K UHD"
		case .verticalHD: "720 by 1280, vertical HD"
		case .verticalFullHD: "1080 by 1920, vertical Full HD"
		case .verticalUltraHD: "2160 by 3840, vertical 4K"
		case .square: "1080 by 1080, square"
		case .portraitFourByFive: "1080 by 1350, portrait 4 by 5"
		case .custom: "Custom"
		}
	}

	var dimensions: (width: Int, height: Int)? {
		switch self {
		case .hd: (1_280, 720)
		case .fullHD: (1_920, 1_080)
		case .qhd: (2_560, 1_440)
		case .ultraHD: (3_840, 2_160)
		case .verticalHD: (720, 1_280)
		case .verticalFullHD: (1_080, 1_920)
		case .verticalUltraHD: (2_160, 3_840)
		case .square: (1_080, 1_080)
		case .portraitFourByFive: (1_080, 1_350)
		case .custom, .sameAsMedia: nil
		}
	}
}

struct ProjectLauncherView: View {
	let mode: ProjectLauncher
	let open: (EditingProject) -> Void
	@Environment(\.dismiss) private var dismiss
	private struct SavedProject: Identifiable {
		let id: URL
		let name: String
	}
	@State private var saved: [SavedProject] = []
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				if mode == .create {
					ProjectSettingsForm(project: EditingProject(name: ""), saving: false) { project in
						try ProjectLibrary.save(project)
						open(project)
						dismiss()
					}
				} else {
					if saved.isEmpty { Text("No saved projects") }
					ForEach(saved) { project in
						Button(project.name) {
							do {
								open(try ProjectLibrary.load(project.id))
								dismiss()
							} catch let failure as ProjectFailure {
								error = failure.localizedDescription
							} catch {
								self.error = "Could not open this project. Restore its project file from backup."
							}
						}
					}
				}
			}
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle(mode.rawValue)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
			.task {
				guard mode == .open else { return }
				do {
					var unreadable = false
					saved = try ProjectLibrary.savedFiles().compactMap {
						do { return try SavedProject(id: $0, name: ProjectLibrary.name(at: $0)) }
						catch { unreadable = true; return nil }
					}.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
					if unreadable { error = "A saved project could not be read. Restore its project file from backup." }
				} catch { self.error = "Could not read saved projects. Reopen Open Project." }
			}
			.alert("Project", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK") { error = nil }
			} message: { Text(error ?? "") }
		}
		.editorAppearance()
	}
}

struct ProjectSettingsForm: View {
	let project: EditingProject
	let saving: Bool
	let submit: (EditingProject) throws -> Void
	@State private var name = ""
	@State private var resolution = ProjectResolutionChoice.sameAsMedia
	@State private var locked = true
	@State private var aspect = 16.0 / 9.0
	@State private var width = "1920"
	@State private var height = "1080"
	@State private var rate = 30.0
	@State private var target = false
	@State private var seconds = 60.0
	@State private var error: String?

	init(project: EditingProject, saving: Bool, submit: @escaping (EditingProject) throws -> Void) {
		self.project = project
		self.saving = saving
		self.submit = submit
		_name = State(initialValue: project.name)
		_target = State(initialValue: project.targetSeconds != nil)
		_seconds = State(initialValue: project.targetSeconds ?? 60)
		if let picture = project.picture {
			let choice = ProjectResolutionChoice.allCases.first {
				$0.dimensions?.width == picture.width && $0.dimensions?.height == picture.height
			} ?? .custom
			_resolution = State(initialValue: project.matchesMedia == true ? .sameAsMedia : choice)
			_width = State(initialValue: String(picture.width))
			_height = State(initialValue: String(picture.height))
			_aspect = State(initialValue: Double(picture.width) / Double(picture.height))
			_rate = State(initialValue: 1 / picture.frame.time.seconds)
		}
	}

	var body: some View {
		Group {
			TextField("Project Name", text: $name)
			Picker("Resolution", selection: $resolution) {
				ForEach(ProjectResolutionChoice.allCases) { Text($0.label).tag($0) }
			}
			.onChange(of: resolution) { _, choice in
				if let size = choice.dimensions {
					width = String(size.width)
					height = String(size.height)
					aspect = Double(size.width) / Double(size.height)
				}
			}
			if resolution == .custom {
				dimensionField("Width", horizontal: true)
				dimensionField("Height", horizontal: false)
				Toggle("Lock Aspect Ratio", isOn: $locked)
					.onChange(of: locked) { _, enabled in
						if enabled, let w = dimension(width), let h = dimension(height) {
							aspect = Double(w) / Double(h)
						}
					}
			}
			if resolution != .sameAsMedia {
				LabeledContent("Frames per Second") { TextField("Frames per Second", value: $rate, format: .number).keyboardType(.decimalPad) }
			}
			Toggle("Use Set Project Duration", isOn: $target)
			if target {
				LabeledContent("Duration in Seconds") { TextField("Duration in Seconds", value: $seconds, format: .number).keyboardType(.decimalPad) }
			}
			Button(saving ? "Save" : "Create") { apply() }
				.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
		}
		.alert("Project Settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
			Button("OK") { error = nil }
		} message: { Text(error ?? "") }
	}

	private func dimension(_ text: String) -> Int? {
		guard let n = Int(text), (1...16384).contains(n) else { return nil }
		return n
	}

	private func dimensionField(_ label: String, horizontal: Bool) -> some View {
		LabeledContent {
			TextField(label, text: Binding(get: { horizontal ? width : height }, set: { text in
				if horizontal { width = text } else { height = text }
				guard locked, let value = dimension(text) else { return }
				if horizontal {
					height = String(max(1, Int((Double(value) / aspect).rounded())))
				} else {
					width = String(max(1, Int((Double(value) * aspect).rounded())))
				}
			}))
			.keyboardType(.numberPad)
			.multilineTextAlignment(.trailing)
		} label: { Text(label) }
	}

	private func apply() {
		var updated = project
		updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
		updated.matchesMedia = resolution == .sameAsMedia
		if resolution != .sameAsMedia {
			guard let width = dimension(width), let height = dimension(height), rate.isFinite, rate > 0, rate <= 1000 else {
				error = "Enter a width and height from 1 to 16384 pixels and a frame rate greater than zero and at most 1000."
				return
			}
			let original = project.picture?.frame
			let frame = original.flatMap { rate == 1 / $0.time.seconds ? $0 : nil }
				?? ProjectTime(CMTime(seconds: 1 / rate, preferredTimescale: 600000))
			updated.picture = ProjectPicture(width: width, height: height, frame: frame)
		} else if project.matchesMedia != true {
			let first = project.placements.first { $0.track == .video }
			updated.picture = project.sources.first { $0.id == first?.sourceID }?.picture
		}
		if target {
			guard seconds.isFinite, seconds > 0 else { error = "Enter a positive duration in seconds."; return }
			updated.targetSeconds = seconds
		} else {
			updated.targetSeconds = nil
		}
		do {
			try submit(updated)
		} catch { self.error = (error as? ProjectFailure)?.message ?? "Could not save the project settings. Check available storage and try again." }
	}
}
