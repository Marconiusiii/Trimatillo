import MessageUI
import StoreKit
import SwiftUI

struct SettingsView: View {
	@ObservedObject var support: SupportStore
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@AppStorage("appearance", store: EditorPreferences.shared) private var appearance = EditorAppearance.system
	@AppStorage("shakeToUndo", store: EditorPreferences.shared) private var shake = true
	@AppStorage("controlColor", store: EditorPreferences.shared) private var color = ControlColor.teal
	@AppStorage("timecodeFormat", store: EditorPreferences.shared) private var format = TimecodeFormat.milliseconds
	@State private var composing = false
	@State private var mailFailed = false
	@AccessibilityFocusState private var feedbackFocused: Bool

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Picker("Appearance", selection: $appearance) {
						ForEach(EditorAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					Picker("Control Color", selection: $color) {
						ForEach(ControlColor.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
				} header: { heading("Appearance") }
				Section {
					Picker("Timecode", selection: $format) {
						ForEach(TimecodeFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					Toggle("Shake to Undo", isOn: $shake)
				} header: { heading("Editing") }
				if !support.products.isEmpty {
					Section {
						ForEach(support.products) { product in
							Button {
								Task { await support.buy(product) }
							} label: { LabeledContent(product.displayName, value: product.displayPrice) }
						}
						.disabled(support.purchasing)
					} header: { heading("Support Trimatillo") }
				}
				Section {
					Button("Send App Feedback") {
						if MFMailComposeViewController.canSendMail() {
							composing = true
						} else if let url = MailComposerView.fallback {
							openURL(url) { if !$0 { mailFailed = true } }
						}
					}
					.accessibilityFocused($feedbackFocused)
					.sheet(isPresented: $composing, onDismiss: { feedbackFocused = true }) {
						MailComposerView { failed in
							composing = false
							mailFailed = failed
						}
					}
					Link("Privacy Policy", destination: URL(string: "https://marconius.com/trimato/privacy/")!)
						.accessibilityRemoveTraits(.isButton)
						.accessibilityAddTraits(.isLink)
				} header: { heading("About") } footer: {
					let year = Calendar(identifier: .gregorian).component(.year, from: Date())
					Text(verbatim: "© \(year) Marco Salsiccia, \(MailComposerView.version)")
				}
			}
			.scrollContentBackground(.hidden)
			.background(EditorTheme.workspace)
			.navigationTitle("Settings")
			.toolbar { Button("Done") { dismiss() } }
			.alert("Send App Feedback", isPresented: $mailFailed) {
				Button("OK") { feedbackFocused = true }
			} message: { Text("Email marco@marconius.com with your feedback.") }
			.alert("Support Trimatillo", isPresented: Binding(get: { support.notice != nil }, set: { if !$0 { support.notice = nil } })) {
				Button("OK") { support.notice = nil }
			} message: { Text(support.notice ?? "") }
			.task { await support.load() }
		}
		.editorAppearance()
	}

	private func heading(_ title: String) -> some View {
		Text(title).accessibilityAddTraits(.isHeader)
	}
}
