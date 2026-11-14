import Combine
import Foundation
import StoreKit

@MainActor
final class SupportStore: ObservableObject {
	static let identifiers = ["littleSlice", "juicyCut", "freshTake", "wholeTomato"].map { "com.marconius.trimatillo.support." + $0 }
	@Published private(set) var products: [Product] = []
	enum CatalogState { case idle, loading, available, incomplete }
	@Published private(set) var catalogState = CatalogState.idle
	@Published private(set) var purchasing = false
	@Published var notice: String?
	private var listener: Task<Void, Never>?
	private var handled: Set<UInt64> = []

	init() {
		listener = Task { [weak self] in
			for await update in Transaction.updates {
				await self?.receive(update)
			}
		}
		Task { [weak self] in
			for await transaction in Transaction.unfinished {
				await self?.receive(transaction)
			}
		}
	}

	deinit { listener?.cancel() }

	func load() async {
		guard catalogState != .loading else { return }
		catalogState = .loading
		do {
			let available = try await Product.products(for: Self.identifiers)
			products = Self.identifiers.compactMap { id in available.first { $0.id == id && $0.type == .consumable } }
			catalogState = products.count == Self.identifiers.count ? .available : .incomplete
		} catch {
			catalogState = .incomplete
		}
	}

	func buy(_ product: Product) async {
		guard !purchasing, products.contains(where: { $0.id == product.id }) else { return }
		purchasing = true
		defer { purchasing = false }
		do {
			switch try await product.purchase() {
			case .success(let result): await receive(result)
			case .pending: notice = "Your purchase is pending App Store approval."
			case .userCancelled: break
			@unknown default: notice = "Check the purchase in your App Store account."
			}
		} catch {
			notice = "Could not complete the purchase. Check your App Store account and try again."
		}
	}

	private func receive(_ result: VerificationResult<Transaction>) async {
		guard case let .verified(transaction) = result else {
			notice = "Could not verify the purchase. Check your App Store purchase history."
			return
		}
		guard Self.identifiers.contains(transaction.productID), handled.insert(transaction.id).inserted else { return }
		await transaction.finish()
		notice = "Thank you for supporting Trimatillo."
	}
}
