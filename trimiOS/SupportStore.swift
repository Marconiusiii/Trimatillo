import Combine
import Foundation
import StoreKit

@MainActor
final class SupportStore: ObservableObject {
	struct Option: Identifiable {
		let id: String
		let name: String

		init(_ suffix: String, _ name: String) {
			id = "com.marconius.trimatillo.support." + suffix
			self.name = name
		}
	}

	static let options = [
		Option("littleSlice", "A little slice"),
		Option("juicyCut", "A juicy cut"),
		Option("freshTake", "A fresh take"),
		Option("wholeTomato", "The whole tomato")
	]

	struct Receipt: Codable, Identifiable {
		let id: UInt64
		let productID: String
		let date: Date
	}

	enum Outcome {
		case received(Receipt), pending, cancelled, failed, unverified
	}

	enum CatalogState { case idle, loading, available, incomplete }
	@Published private(set) var products: [String: Product] = [:]
	@Published private(set) var catalogState = CatalogState.idle
	@Published private(set) var purchasing = false
	@Published private(set) var latest: Receipt?
	private static let receiptKey = "trimatillo.latestContribution"
	private var listener: Task<Void, Never>?
	private var unfinished: Task<Void, Never>?

	init() {
		if let data = UserDefaults.standard.data(forKey: Self.receiptKey) {
			latest = try? JSONDecoder().decode(Receipt.self, from: data)
		}
		listener = Task { [weak self] in
			for await update in Transaction.updates {
				await self?.receive(update)
			}
		}
		unfinished = Task { [weak self] in
			for await transaction in Transaction.unfinished {
				await self?.receive(transaction)
			}
		}
	}

	deinit {
		listener?.cancel()
		unfinished?.cancel()
	}

	func load() async {
		guard catalogState != .loading, catalogState != .available else { return }
		catalogState = .loading
		do {
			let available = try await Product.products(for: Self.options.map(\.id))
			products = Dictionary(uniqueKeysWithValues: available.filter { $0.type == .consumable }.map { ($0.id, $0) })
			catalogState = products.count == Self.options.count ? .available : .incomplete
		} catch {
			catalogState = .incomplete
		}
	}

	func buy(_ option: Option) async -> Outcome {
		guard !purchasing, let product = products[option.id] else { return .failed }
		purchasing = true
		defer { purchasing = false }
		do {
			switch try await product.purchase() {
			case .success(let result): return await receive(result)
			case .pending: return .pending
			case .userCancelled: return .cancelled
			@unknown default: return .failed
			}
		} catch StoreKitError.userCancelled {
			return .cancelled
		} catch {
			return .failed
		}
	}

	@discardableResult
	private func receive(_ result: VerificationResult<Transaction>) async -> Outcome {
		guard case let .verified(transaction) = result else { return .unverified }
		guard Self.options.contains(where: { $0.id == transaction.productID }) else { return .failed }
		guard transaction.revocationDate == nil else {
			await transaction.finish()
			return .failed
		}

		let receipt = Receipt(id: transaction.id, productID: transaction.productID, date: transaction.purchaseDate)
		if latest.map({ (receipt.date, receipt.id) > ($0.date, $0.id) }) ?? true {
			guard let data = try? JSONEncoder().encode(receipt) else { return .failed }
			UserDefaults.standard.set(data, forKey: Self.receiptKey)
			latest = receipt
		}
		await transaction.finish()
		return .received(receipt)
	}

	func thankYou(for receipt: Receipt) -> String {
		let option = Self.options.first { $0.id == receipt.productID }
		let name = products[receipt.productID]?.displayName ?? option?.name ?? "Contribution"
		let date = receipt.date.formatted(date: .long, time: .omitted)
		return "Thank you for supporting Trimatillo with \"\(name)\" on \(date)."
	}
}
