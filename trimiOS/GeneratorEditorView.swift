import SwiftUI
import AVFoundation

struct GeneratorRequest: Identifiable {
	let id = UUID()
	let track: TimelineTrack
	let time: CMTime
	var source: ProjectMediaSource?
	var clip: ProjectPlacement?
}

private enum GeneratorPlacement: String, CaseIterable {
	case append = "Append", insert = "Insert at Playhead", overwrite = "Overwrite at Playhead", newTrack = "New Track at Playhead"
}

struct GeneratorEditorView: View {
	let project: EditingProject
	let request: GeneratorRequest
	let save: (EditingProject, String) throws -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var definition: GeneratorDefinition
	@State private var placement = GeneratorPlacement.append
	@State private var trackName = ""
	@State private var error: String?
	@FocusState private var typing: Bool
	@AccessibilityFocusState private var previewFocused: Bool
	@State private var previewProject: EditingProject?
	@State private var previewStart = CMTime.zero
	private let sourceID = UUID()
	private var editing: Bool { request.source != nil }

	init(project: EditingProject, request: GeneratorRequest, save: @escaping (EditingProject, String) throws -> Void) {
		self.project = project
		self.request = request
		self.save = save
		var definition = request.clip?.generatorOverride ?? request.source?.generator ?? GeneratorDefinition()
		if request.source == nil {
			definition.picture = project.picture ?? definition.picture
			definition.fontPoints = definition.effectiveFontPoints.rounded()
			definition.kind = request.track.kind == .audio ? .silence : .text
			definition.seconds = 5
			if let start = project.markIn?.time, let end = project.markOut?.time,
				start >= .zero, end > start, end <= project.duration {
				definition.seconds = (end - start).seconds
			}
		}
		// Separate legacy panel/background colors without changing their appearance.
		definition.panelColor = definition.panelColor ?? definition.background
		_definition = State(initialValue: definition)
	}

	var body: some View {
		NavigationStack {
			Form {
				if !editing {
					Picker("Generator", selection: $definition.kind) {
						ForEach(GeneratorDefinition.Kind.allCases.filter { request.track.kind == .audio ? $0 == .silence : $0 != .silence }, id: \.self) { Text($0.rawValue).tag($0) }
					}
					TextField("", value: Binding(get: { definition.seconds }, set: { definition.seconds = ($0 * 100).rounded() / 100 }), format: .number.precision(.fractionLength(0...2))).keyboardType(.decimalPad).focused($typing).editorFieldLabel("Duration in Seconds")
				}
				if definition.kind == .text { textControls }
				if definition.kind == .color { color("Color", $definition.background) }
				if definition.kind == .gradient {
					color("Start Color", $definition.background)
					color("End Color", $definition.secondColor)
					Picker("Direction", selection: $definition.verticalGradient) { Text("Top to Bottom").tag(true); Text("Left to Right").tag(false) }
				}
				if !editing {
					Picker("Placement", selection: $placement) { ForEach(GeneratorPlacement.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
					if placement == .newTrack { TextField("", text: $trackName).focused($typing).editorFieldLabel("Track Name") }
				}
				Button("Preview") {
					typing = false
					do {
						if editing && request.clip == nil {
							let source = definition.source
							var next = EditingProject(name: source.displayName, picture: source.picture)
							next.sources = [source]
							try next.place(source, ranges: [CMTimeRange(start: .zero, duration: source.duration.time)], at: .zero, on: source.picture == nil ? .primaryAudio : .primaryVideo, mode: .append)
							previewStart = .zero
							previewProject = next
						} else {
							let (next, start) = try draft()
							previewStart = start
							previewProject = next
						}
					}
					catch { self.error = error.localizedDescription }
				}
				.disabled(!valid)
				.accessibilityFocused($previewFocused)
			}
			.dismissKeyboardToolbar(while: typing) { typing = false }
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) { Text(editing ? "Edit Generator" : "Add Generator").font(.headline).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .confirmationAction) { Button(editing ? "Save" : "Add") {
					do { let (next, _) = try draft(); try save(next, editing ? "Edit Generator" : "Add Generator"); dismiss() }
					catch { self.error = error.localizedDescription }
				}.disabled(!valid) }
			}
			.sheet(item: $previewProject, onDismiss: { previewFocused = true }) { draft in GeneratorProjectPreview(project: draft, start: previewStart, title: "Generator Preview") }
			.alert("Could Not Save Generator", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
		}
		.editorAppearance()
	}

	private var valid: Bool { definition.isValid && (definition.kind != .text || !definition.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && (editing || placement != .newTrack || !trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

	@ViewBuilder private var textControls: some View {
		Picker("Preset", selection: Binding(get: { definition.preset }, set: { definition.apply($0) })) {
			ForEach(GeneratorDefinition.Preset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
		}
		TextField("", text: $definition.text, axis: .vertical).focused($typing).editorFieldLabel("Text")
		if [.subtitle, .name].contains(definition.preset) { TextField("", text: $definition.subheading, axis: .vertical).focused($typing).editorFieldLabel(definition.preset == .name ? "Role" : "Subheading") }
		DisclosureGroup("Typography") {
			Picker("Font", selection: $definition.font) { ForEach(GeneratorDefinition.Font.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
			Toggle("Bold", isOn: $definition.bold)
			GeneratorSlider("Font Size", value: Binding(get: { definition.effectiveFontPoints.rounded() }, set: { definition.fontPoints = $0.rounded() }), range: 1...max(512, (Double(definition.picture.height) * 0.3).rounded(.up)), unit: " points", step: 1)
			GeneratorSlider("Line Spacing", value: $definition.lineSpacing, range: 0.5...3, unit: "x", fraction: 1)
		}
		DisclosureGroup("Appearance") {
			color("Text Color", $definition.foreground)
			Toggle("Transparent Background", isOn: $definition.transparent)
			if !definition.transparent { color("Background Color", $definition.background) }
			Toggle("Outline", isOn: $definition.outline)
			if definition.outline { color("Outline Color", Binding(get: { definition.outlineColor ?? .black }, set: { definition.outlineColor = $0 })) }
			Toggle("Shadow", isOn: $definition.shadow)
			if definition.shadow { color("Shadow Color", Binding(get: { definition.shadowColor ?? .black }, set: { definition.shadowColor = $0 })) }
			Toggle("Text Panel", isOn: $definition.panel)
			if definition.panel {
				color("Panel Color", Binding(get: { definition.panelColor ?? .black }, set: { definition.panelColor = $0 }))
				GeneratorSlider("Panel Opacity", value: $definition.panelOpacity, range: 0...100, unit: "%")
			}
		}
		DisclosureGroup("Layout") {
			Picker("Text Position", selection: $definition.position) { ForEach(GeneratorDefinition.Position.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
			GeneratorSlider("Safe Margin", value: $definition.margin, range: 0...25, unit: "%")
			GeneratorSlider("Text Width", value: $definition.width, range: 10...100, unit: "%")
		}
	}

	private func color(_ title: String, _ value: Binding<GeneratorColor>) -> some View {
		GeneratorColorButton(title: title, color: value)
	}

	private func draft() throws -> (EditingProject, CMTime) {
		guard valid else { throw ProjectFailure("Enter text and a valid duration for the generated clip.") }
		var next = project
		if let source = request.source {
			if let clip = request.clip, let index = next.placements.firstIndex(where: { $0.id == clip.id }) {
				next.placements[index].generatorOverride = definition
				return (next, clip.start.time)
			}
			guard let index = next.sources.firstIndex(where: { $0.id == source.id }) else { throw CocoaError(.fileNoSuchFile) }
			next.sources[index].reference = .generated(definition)
			return (next, next.placements.first { $0.sourceID == source.id }?.start.time ?? .zero)
		}
		var source = definition.source
		source.id = sourceID
		next.sources.append(source)
		let track = try placement == .newTrack ? next.createTrack(trackName, kind: request.track.kind) : request.track
		let start = placement == .append ? next.clips(on: track).last?.end ?? .zero : request.time
		let mode: PlacementMode = placement == .insert ? .split : placement == .overwrite ? .overwrite : .append
		try next.place(source, ranges: [CMTimeRange(start: .zero, duration: source.duration.time)], at: start, on: track, mode: mode)
		return (next, start)
	}
}

struct GeneratorSlider: View {
	let title: String
	@Binding var value: Double
	let range: ClosedRange<Double>
	let unit: String
	var fraction = 0
	var step: Double? = nil
	init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, fraction: Int = 0, step: Double? = nil) {
		self.title = title; _value = value; self.range = range; self.unit = unit; self.fraction = fraction; self.step = step
	}
	var body: some View {
		VStack(alignment: .leading) {
			Text(title).accessibilityHidden(true)
			control
				.accessibilityValue(value.formatted(.number.precision(.fractionLength(fraction))) + unit)
			Text(value.formatted(.number.precision(.fractionLength(fraction))) + unit).accessibilityHidden(true)
		}
	}
	@ViewBuilder private var control: some View {
		if let step { Slider(value: $value, in: range, step: step) { Text(title) } }
		else { Slider(value: $value, in: range) { Text(title) } }
	}
}

struct GeneratorProjectPreview: View {
	let project: EditingProject
	let start: CMTime
	let title: String
	@Environment(\.dismiss) private var dismiss
	@StateObject private var playback = ProjectPlayback()
	@State private var loading = true
	@State private var error: String?
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	private func previewTime(_ time: CMTime) -> String {
		if format == .frames { return "Frame " + String(Int64((time.seconds / project.frame.seconds).rounded(.down))) }
		let ticks = CMTimeConvertScale(time, timescale: 1000, method: .roundTowardZero).value
		let seconds = ticks / 1000
		let clock = String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
		return format == .milliseconds ? clock + String(format: ".%03lld", ticks % 1000) : clock
	}
	var body: some View {
		NavigationStack {
			Group {
				if loading { LoadingStatusView("Preparing Preview", cancel: { dismiss() }) }
				else if let error { ContentUnavailableView("Preview Unavailable", systemImage: "exclamationmark.triangle", description: Text(error)) }
				else {
					Form {
						if project.picture != nil { ProjectPreview(player: playback.player).aspectRatio(CGFloat(project.picture!.width) / CGFloat(project.picture!.height), contentMode: .fit) }
						ProjectTimelineSlider(playhead: playback.playhead, playback: playback, duration: project.duration, points: [.zero, project.duration], frame: project.frame, format: format, formatTime: { previewTime($0) })
						HStack {
							Button { playback.shuttle(forward: false) } label: { Label("Rewind", systemImage: "backward.fill").labelStyle(.iconOnly).editorTouchRow() }.accessibilityAction(named: "Go to Start") { playback.seek(.zero) }
							Button { playback.toggle() } label: { Label(playback.transport.playing ? "Pause" : "Play", systemImage: playback.transport.playing ? "pause.fill" : "play.fill").labelStyle(.iconOnly).editorTouchRow() }
							Button { playback.shuttle(forward: true) } label: { Label("Fast Forward", systemImage: "forward.fill").labelStyle(.iconOnly).editorTouchRow() }.accessibilityAction(named: "Go to End") { playback.seek(project.duration) }
						}
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
				ToolbarItem(placement: .principal) { Text(title).font(.headline).accessibilityAddTraits(.isHeader) }
			}
			.accessibilityAction(.magicTap) { if !loading && error == nil { playback.toggle() } }
		}
		.editorAppearance()
		.task { await playback.prepare(project); guard !Task.isCancelled else { return }; error = playback.failure; playback.seek(start); loading = false }
		.onDisappear { playback.cancelPreparation(); playback.releaseAudio() }
	}
}

struct ClipCompositingSheet: View {
	let project: EditingProject
	let clip: ProjectPlacement
	let save: (EditingProject, String) throws -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var settings: ClipCompositing
	@State private var preview = false
	@AccessibilityFocusState private var previewFocused: Bool
	@State private var error: String?
	init(project: EditingProject, clip: ProjectPlacement, save: @escaping (EditingProject, String) throws -> Void) {
		self.project = project; self.clip = clip; self.save = save
		_settings = State(initialValue: clip.compositing ?? ClipCompositing())
	}
	private var draft: EditingProject {
		var next = project
		if let index = next.placements.firstIndex(where: { $0.id == clip.id }) { next.placements[index].compositing = settings }
		return next
	}
	var body: some View {
		NavigationStack {
			Form {
				GeneratorSlider("Opacity", value: $settings.opacity, range: 0...100, unit: "%")
				Picker("Blend Mode", selection: $settings.blend) { ForEach(ClipCompositing.Blend.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
				Picker("Position", selection: $settings.position) { ForEach(GeneratorDefinition.Position.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
				GeneratorSlider("Scale", value: $settings.scale, range: 1...400, unit: "%")
				GeneratorSlider("Horizontal Offset", value: $settings.horizontal, range: -100...100, unit: "%")
				GeneratorSlider("Vertical Offset", value: $settings.vertical, range: -100...100, unit: "%")
				Button("Preview") { preview = true }.accessibilityFocused($previewFocused)
				Button("Reset Compositing") { settings = ClipCompositing() }
			}
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) { Text("Compositing").font(.headline).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .confirmationAction) { Button("Save") { do { try save(draft, "Compositing"); dismiss() } catch { self.error = error.localizedDescription } } }
			}
			.sheet(isPresented: $preview, onDismiss: { previewFocused = true }) { GeneratorProjectPreview(project: draft, start: clip.start.time, title: "Compositing Preview") }
			.alert("Could Not Save Compositing", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
		}
		.editorAppearance()
	}
}

private enum GeneratorNamedColor: String, CaseIterable {
	case black = "Black", white = "White", gray = "Gray", red = "Red", orange = "Orange", yellow = "Yellow", green = "Green", blue = "Blue", purple = "Purple", pink = "Pink", brown = "Brown", teal = "Teal", cyan = "Cyan", mint = "Mint", navy = "Navy", indigo = "Indigo", lavender = "Lavender", cream = "Cream", custom = "Custom"
	var color: GeneratorColor? {
		switch self {
		case .black: .black
		case .white: .white
		case .gray: GeneratorColor(red: 0.5, green: 0.5, blue: 0.5)
		case .red: GeneratorColor(red: 1, green: 0, blue: 0)
		case .orange: GeneratorColor(red: 1, green: 0.5, blue: 0)
		case .yellow: GeneratorColor(red: 1, green: 1, blue: 0)
		case .green: GeneratorColor(red: 0, green: 0.5, blue: 0)
		case .blue: .blue
		case .purple: GeneratorColor(red: 0.5, green: 0, blue: 0.5)
		case .pink: GeneratorColor(red: 1, green: 0.5, blue: 0.75)
		case .brown: GeneratorColor(red: 0.6, green: 0.3, blue: 0.1)
		case .teal: GeneratorColor(red: 0, green: 0.5, blue: 0.5)
		case .cyan: GeneratorColor(red: 0, green: 1, blue: 1)
		case .mint: GeneratorColor(red: 0.6, green: 0.9, blue: 0.75)
		case .navy: GeneratorColor(red: 0, green: 0, blue: 0.5)
		case .indigo: GeneratorColor(red: 0.29, green: 0, blue: 0.51)
		case .lavender: GeneratorColor(red: 0.75, green: 0.65, blue: 0.9)
		case .cream: GeneratorColor(red: 1, green: 0.98, blue: 0.85)
		case .custom: nil
		}
	}
	static func selection(for color: GeneratorColor) -> Self {
		allCases.first { $0.color == color } ?? .custom
	}
	static func value(for color: GeneratorColor) -> String {
		let choice = selection(for: color)
		if choice != .custom { return choice.rawValue }
		return "Custom, Red \(Int((color.red * 255).rounded())), Green \(Int((color.green * 255).rounded())), Blue \(Int((color.blue * 255).rounded()))"
	}
}

private struct GeneratorColorButton: View {
	let title: String
	@Binding var color: GeneratorColor
	@State private var editing = false
	@AccessibilityFocusState private var focused: Bool
	var body: some View {
		Button { editing = true } label: {
			HStack {
				Text(title)
				Spacer()
				Text(GeneratorNamedColor.selection(for: color).rawValue).foregroundStyle(.secondary).accessibilityHidden(true)
				RoundedRectangle(cornerRadius: 3).fill(Color(cgColor: color.cg))
					.frame(width: 24, height: 24).overlay { RoundedRectangle(cornerRadius: 3).stroke(.secondary) }
					.accessibilityHidden(true)
			}
			.frame(maxWidth: .infinity, minHeight: 44)
			.contentShape(Rectangle())
		}
		.accessibilityValue(GeneratorNamedColor.value(for: color))
		.accessibilityFocused($focused)
		.fullScreenCover(isPresented: $editing, onDismiss: { focused = true }) {
			GeneratorColorEditor(initial: color) { color = $0 }
		}
	}
}

private struct GeneratorColorEditor: View {
	let save: (GeneratorColor) -> Void
	@State private var initial: GeneratorColor
	@State private var initialComponents: [String]
	@Environment(\.dismiss) private var dismiss
	@State private var custom: Bool
	@State private var choice: GeneratorNamedColor
	@State private var red: String
	@State private var green: String
	@State private var blue: String
	@State private var lastValid: GeneratorColor
	@State private var invalidColor = false
	@FocusState private var typing: Bool

	init(initial: GeneratorColor, save: @escaping (GeneratorColor) -> Void) {
		_initial = State(initialValue: initial)
		self.save = save
		let components = [initial.red, initial.green, initial.blue].map { String(Int(($0 * 255).rounded())) }
		_initialComponents = State(initialValue: components)
		_red = State(initialValue: components[0])
		_green = State(initialValue: components[1])
		_blue = State(initialValue: components[2])
		_lastValid = State(initialValue: initial)
		let selection = GeneratorNamedColor.selection(for: initial)
		_custom = State(initialValue: selection == .custom)
		_choice = State(initialValue: selection == .custom ? .black : selection)
	}

	private var components: [String] { [red, green, blue] }
	private var customColor: GeneratorColor? {
		var values: [Double] = []
		for component in components {
			let text = component.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty, text.allSatisfy({ $0.isNumber }), let value = Int(text), (0...255).contains(value) else { return nil }
			values.append(Double(value) / 255)
		}
		// Opening and confirming a saved color must not quantize its existing components.
		if components == initialComponents { return initial }
		return GeneratorColor(red: values[0], green: values[1], blue: values[2])
	}

	var body: some View {
		NavigationStack {
			Form {
				HStack {
					Picker("Preset Color", selection: $choice) {
						ForEach(GeneratorNamedColor.allCases.filter { $0 != .custom }, id: \.self) { preset in
							Text(preset.rawValue).tag(preset)
						}
					}
					.pickerStyle(.menu)
					.disabled(custom)
					RoundedRectangle(cornerRadius: 3)
						.fill(Color(cgColor: (choice.color ?? .black).cg))
						.frame(width: 24, height: 24)
						.overlay { RoundedRectangle(cornerRadius: 3).stroke(choice == .white ? Color.black : Color.secondary) }
						.opacity(custom ? 0.5 : 1)
						.accessibilityHidden(true)
				}
				Toggle("Custom Color", isOn: $custom)
				if custom {
					channel("Red", text: $red)
					channel("Green", text: $green)
					channel("Blue", text: $blue)
					RoundedRectangle(cornerRadius: 4)
						.fill(Color(cgColor: (customColor ?? lastValid).cg))
						.frame(height: 64)
						.overlay { RoundedRectangle(cornerRadius: 4).stroke(.secondary) }
						.accessibilityHidden(true)
				}
			}
			.dismissKeyboardToolbar(while: typing) { typing = false }
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .principal) { Text("Color Chooser").font(.headline).accessibilityAddTraits(.isHeader) }
				ToolbarItem(placement: .confirmationAction) { Button("Done") {
					guard let color = custom ? customColor : choice.color else { invalidColor = true; return }
					typing = false
					save(color)
					dismiss()
				} }
			}
			.onChange(of: components) { if let color = customColor { lastValid = color } }
			.onChange(of: choice) { _, selection in
				guard let color = selection.color else { return }
				let values = [color.red, color.green, color.blue].map { String(Int(($0 * 255).rounded())) }
				initial = color
				initialComponents = values
				red = values[0]
				green = values[1]
				blue = values[2]
				lastValid = color
			}
			.onChange(of: custom) { _, enabled in if !enabled { typing = false } }
			.alert("Invalid Color", isPresented: $invalidColor) {
				Button("OK", role: .cancel) {}
			} message: { Text("Enter whole numbers from 0 to 255 for Red, Green, and Blue.") }
		}
		.editorAppearance()
	}

	private func channel(_ title: String, text: Binding<String>) -> some View {
		TextField("", text: text)
			.keyboardType(.numberPad)
			.focused($typing)
			.editorFieldLabel(title)
	}

}
