import SwiftUI
import CoreMedia

enum ProjectLauncher: String, Identifiable {
	case create = "Create Project"
	case open = "Open Project"
	var id: Self { self }
}

struct ProjectLauncherView: View {
	let mode: ProjectLauncher
	let open: (EditingProject) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var custom = false
	@State private var width = 1920
	@State private var height = 1080
	@State private var rate = 30.0
	@State private var target = false
	@State private var seconds = 60.0
	@State private var saved: [EditingProject] = []
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				if mode == .create {
					TextField("Project Name", text: $name)
					Toggle("Custom Resolution", isOn: $custom)
					if custom {
						LabeledContent("Width") { TextField("Width", value: $width, format: .number).keyboardType(.numberPad) }
						LabeledContent("Height") { TextField("Height", value: $height, format: .number).keyboardType(.numberPad) }
						LabeledContent("Frames per Second") { TextField("Frames per Second", value: $rate, format: .number).keyboardType(.decimalPad) }
					}
					Toggle("Use Target Duration", isOn: $target)
					if target {
						LabeledContent("Target in Seconds") { TextField("Target in Seconds", value: $seconds, format: .number).keyboardType(.decimalPad) }
					}
					Button("Create") { create() }
						.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
				} else {
					if saved.isEmpty { Text("No saved projects") }
					ForEach(saved) { project in
						Button(project.name) { open(project); dismiss() }
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
						do { return try ProjectLibrary.load($0) }
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

	private func create() {
		var project = EditingProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
		if custom {
			guard (1...16384).contains(width), (1...16384).contains(height), rate.isFinite, rate > 0, rate <= 1000 else {
				error = "Enter a width and height from 1 to 16384 pixels and a frame rate greater than zero and at most 1000."
				return
			}
			project.picture = ProjectPicture(width: width, height: height, frame: ProjectTime(CMTime(seconds: 1 / rate, preferredTimescale: 600000)))
		}
		if target {
			guard seconds.isFinite, seconds > 0 else { error = "Enter a positive target duration in seconds."; return }
			project.targetSeconds = seconds
		}
		do {
			try ProjectLibrary.save(project)
			open(project)
			dismiss()
		} catch { self.error = "Could not save the project. Check available storage and choose Create again." }
	}
}
