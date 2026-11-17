import MessageUI
import SwiftUI

struct MailComposerView: UIViewControllerRepresentable {
	static let recipient = "marco@marconius.com"
	static let subject = "Trimatillo iOS Feedback"
	static var version: String {
		let info = Bundle.main.infoDictionary
		return "Version \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
	}
	static var bodyText: String {
		"Trimatillo \(version)\n\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n\nPlease describe the issue below.\n\n"
	}
	static var fallback: URL? {
		var components = URLComponents()
		components.scheme = "mailto"
		components.path = recipient
		components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: bodyText)]
		return components.url
	}

	let finish: (Bool) -> Void
	func makeCoordinator() -> Coordinator { Coordinator(finish) }
	func makeUIViewController(context: Context) -> MFMailComposeViewController {
		let controller = MFMailComposeViewController()
		controller.mailComposeDelegate = context.coordinator
		controller.setToRecipients([Self.recipient])
		controller.setSubject(Self.subject)
		controller.setMessageBody(Self.bodyText, isHTML: false)
		return controller
	}
	func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

	final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
		let finish: (Bool) -> Void
		init(_ finish: @escaping (Bool) -> Void) { self.finish = finish }
		func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
			finish(result == .failed || error != nil)
		}
	}
}
