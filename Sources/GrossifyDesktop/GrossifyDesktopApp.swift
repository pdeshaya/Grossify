import SwiftUI
import Foundation
import AppKit




struct Product: Decodable, Identifiable {
    let id: Int
    let name: String
    let category: String
    let price: Double
    let quantity: Int
    let low_stock: Int
    let low_stock_alert: Bool
}

struct ProductsResponse: Decodable {
    let success: Bool
    let products: [Product]
}

struct HealthResponse: Decodable {
    let success: Bool
    let service: String
    let database: String
}

struct ActionResponse: Decodable {
    let success: Bool
    let message: String?
    let error: String?
    let id: Int?
}

struct CartItem: Identifiable, Equatable {
    let product: Product
    var quantity: Int

    var id: Int { product.id }
    var lineTotal: Double { product.price * Double(quantity) }

    static func == (lhs: CartItem, rhs: CartItem) -> Bool {
        lhs.product.id == rhs.product.id && lhs.quantity == rhs.quantity
    }
}

struct BillSummary: Decodable, Identifiable {
    let id: Int
    let bill_number: String
    let customer_name: String
    let customer_phone: String
    let total: Double
    let payment_mode: String
    let created_at: String
    let items_count: Int
}

struct BillsResponse: Decodable {
    let success: Bool
    let bills: [BillSummary]
}

struct BillItem: Decodable, Identifiable {
    let id: Int
    let product_id: Int
    let product_name: String
    let quantity: Int
    let unit_price: Double
    let line_total: Double
}

struct BillDetail: Decodable, Identifiable {
    let id: Int
    let bill_number: String
    let customer_name: String
    let customer_phone: String
    let total: Double
    let payment_mode: String
    let created_at: String
    let items: [BillItem]
}

struct BillDetailResponse: Decodable {
    let success: Bool
    let bill: BillDetail
}

struct CheckoutResponse: Decodable {
    let success: Bool
    let message: String?
    let error: String?
    let duplicate: Bool?
    let bill: BillSummary?
}

enum APIError: LocalizedError {
    case badResponse
    case server(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The backend returned an unexpected response."
        case .server(let message): return message
        case .unavailable: return "Cannot reach Grossify's backend. Start the backend first."
        }
    }
}

@MainActor
final class GrossifyStore: ObservableObject {
    @Published var products: [Product] = []
    @Published var selected: Screen = .dashboard
    @Published var showingAddProduct = false
    @Published var backendOnline = false
    @Published var databaseOnline = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    // Billing & Cart State
    @Published var cart: [CartItem] = []
    @Published var customerName: String = ""
    @Published var customerPhone: String = ""
    @Published var paymentMode: String = "Cash"
    @Published var posSearchText: String = ""
    @Published var billSearchText: String = ""
    @Published var bills: [BillSummary] = []
    @Published var selectedBillDetail: BillDetail? = nil
    @Published var showingBillDetail: Bool = false
    @Published var isCheckingOut: Bool = false

    var cartSubtotal: Double {
        cart.reduce(0) { $0 + $1.lineTotal }
    }

    var cartItemCount: Int {
        cart.reduce(0) { $0 + $1.quantity }
    }

    func isPhoneValid(_ phone: String) -> Bool {
        let p = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count == 10 else { return false }
        guard let first = p.first, "6789".contains(first) else { return false }
        return p.allSatisfy { $0.isNumber }
    }

    var isCustomerValid: Bool {
        !customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isPhoneValid(customerPhone)
    }

    var canCheckout: Bool {
        !cart.isEmpty && isCustomerValid && !isCheckingOut
    }

    func addToCart(product: Product) {
        guard product.quantity > 0 else { return }
        if let idx = cart.firstIndex(where: { $0.id == product.id }) {
            if cart[idx].quantity < product.quantity {
                cart[idx].quantity += 1
            }
        } else {
            cart.append(CartItem(product: product, quantity: 1))
        }
    }

    func increaseQuantity(productID: Int) {
        guard let idx = cart.firstIndex(where: { $0.id == productID }) else { return }
        let currentProd = products.first(where: { $0.id == productID }) ?? cart[idx].product
        if cart[idx].quantity < currentProd.quantity {
            cart[idx].quantity += 1
        }
    }

    func decreaseQuantity(productID: Int) {
        guard let idx = cart.firstIndex(where: { $0.id == productID }) else { return }
        if cart[idx].quantity > 1 {
            cart[idx].quantity -= 1
        } else {
            cart.remove(at: idx)
        }
    }

    func removeFromCart(productID: Int) {
        cart.removeAll { $0.id == productID }
    }

    func clearCart() {
        cart.removeAll()
        customerName = ""
        customerPhone = ""
    }

    func checkout() async {
        guard canCheckout else { return }
        isCheckingOut = true
        defer { isCheckingOut = false }

        let idempotencyKey = UUID().uuidString
        let itemsPayload: [[String: Any]] = cart.map { [
            "product_id": $0.product.id,
            "quantity": $0.quantity
        ]}
        let payload: [String: Any] = [
            "idempotency_key": idempotencyKey,
            "customer_name": customerName.trimmingCharacters(in: .whitespacesAndNewlines),
            "customer_phone": customerPhone.trimmingCharacters(in: .whitespacesAndNewlines),
            "payment_mode": paymentMode,
            "items": itemsPayload
        ]

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/checkout"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
            let decoded = try? JSONDecoder().decode(CheckoutResponse.self, from: data)
            guard (200...299).contains(http.statusCode), decoded?.success == true, let bill = decoded?.bill else {
                throw APIError.server(decoded?.error ?? "Checkout failed (HTTP \(http.statusCode)).")
            }

            clearCart()
            successMessage = "Bill \(bill.bill_number) generated successfully for ₹\(String(format: "%.2f", bill.total))."
            await refresh()
            await fetchBills()
            await fetchBillDetail(id: bill.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchBills() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/bills"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            bills = try JSONDecoder().decode(BillsResponse.self, from: data).bills
        } catch {
            // Keep existing bills list if offline
        }
    }

    func fetchBillDetail(id: Int) async {
        do {
            var comp = URLComponents(url: baseURL.appendingPathComponent("api/bills/details"), resolvingAgainstBaseURL: false)!
            comp.queryItems = [URLQueryItem(name: "id", value: String(id))]
            guard let url = comp.url else { return }
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let res = try JSONDecoder().decode(BillDetailResponse.self, from: data)
            selectedBillDetail = res.bill
            showingBillDetail = true
        } catch {
            errorMessage = "Could not load bill details."
        }
    }

    private let baseURL = URL(string: "http://127.0.0.1:8080")!

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var healthRequest = URLRequest(url: baseURL.appendingPathComponent("api/health"))
            healthRequest.timeoutInterval = 3
            let (healthData, healthResponse) = try await URLSession.shared.data(for: healthRequest)
            guard (healthResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw APIError.badResponse
            }
            let health = try JSONDecoder().decode(HealthResponse.self, from: healthData)
            backendOnline = health.success
            databaseOnline = health.database == "connected"

            let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/products"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw APIError.badResponse
            }
            products = try JSONDecoder().decode(ProductsResponse.self, from: data).products
            errorMessage = nil
        } catch {
            backendOnline = false
            databaseOnline = false
            errorMessage = (error as? APIError)?.errorDescription ?? APIError.unavailable.errorDescription
        }
    }

    func addProduct(name: String, category: String, price: Double, quantity: Int, lowStock: Int) async {
        do {
            let payload: [String: Any] = [
                "name": name, "category": category, "price": price,
                "quantity": quantity, "low_stock": lowStock
            ]
            try await post(path: "api/products", payload: payload)
            successMessage = "Product added successfully."
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func adjustStock(productID: Int, delta: Int) async {
        do {
            let payload: [String: Any] = ["product_id": productID, "quantity_delta": delta]
            try await post(path: "api/inventory/adjust", payload: payload)
            successMessage = "Inventory updated."
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func post(path: String, payload: [String: Any]) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        let decoded = try? JSONDecoder().decode(ActionResponse.self, from: data)
        guard (200...299).contains(http.statusCode), decoded?.success == true else {
            throw APIError.server(decoded?.error ?? "Request failed (HTTP \(http.statusCode)).")
        }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case products = "Products"
    case inventory = "Inventory"
    case billing = "Billing"
    case billHistory = "Bill History"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .products: return "shippingbox.fill"
        case .inventory: return "chart.bar.fill"
        case .billing: return "cart.fill"
        case .billHistory: return "clock.arrow.circlepath"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct GrossifyDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 650)
        }
        .windowStyle(.titleBar)
    }
}

struct MainView: View {
    @StateObject private var store = GrossifyStore()

    private let background = Color(red: 0.055, green: 0.075, blue: 0.075)
    private let panel = Color(red: 0.085, green: 0.115, blue: 0.11)
    private let accent = Color(red: 0.30, green: 0.78, blue: 0.58)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    Group {
                        switch store.selected {
                        case .dashboard: dashboard
                        case .products: productsView
                        case .inventory: inventoryView
                        case .billing: billingView
                        case .billHistory: billHistoryView
                        }
                    }
                    .padding(28)
                }
            }
        }
        .background(background)
        .task {
            await store.refresh()
            await store.fetchBills()
        }
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
        .sheet(isPresented: $store.showingAddProduct) {
            AddProductSheet { name, category, price, quantity, low in
                Task { await store.addProduct(name: name, category: category, price: price, quantity: quantity, lowStock: low) }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $store.showingBillDetail) {
            if let bill = store.selectedBillDetail {
                BillDetailSheet(bill: bill)
                    .preferredColorScheme(.dark)
            }
        }
        .alert("Grossify", isPresented: Binding(
            get: { store.errorMessage != nil || store.successMessage != nil },
            set: { if !$0 { store.errorMessage = nil; store.successMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil; store.successMessage = nil }
        } message: {
            Text(store.errorMessage ?? store.successMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(accent)
                    Image(systemName: "basket.fill").font(.system(size: 19, weight: .bold)).foregroundStyle(background)
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GROSSIFY").font(.system(size: 17, weight: .black, design: .rounded)).tracking(1.2)
                    Text("STORE MANAGEMENT").font(.system(size: 8, weight: .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.42))
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("WORKSPACE").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.35)).padding(.leading, 12)
                ForEach(Screen.allCases) { screen in
                    Button { store.selected = screen } label: {
                        HStack(spacing: 12) {
                            Image(systemName: screen.symbol).frame(width: 18)
                            Text(screen.rawValue)
                            Spacer()
                            if screen == .billing && store.cartItemCount > 0 {
                                Text("\(store.cartItemCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(background)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(accent, in: Capsule())
                            }
                            if store.selected == screen {
                                Circle().fill(accent).frame(width: 6, height: 6)
                            }
                        }
                        .font(.system(size: 13, weight: store.selected == screen ? .semibold : .medium))
                        .foregroundStyle(store.selected == screen ? accent : .white.opacity(0.62))
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background(store.selected == screen ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(store.backendOnline ? accent : .orange).frame(width: 7, height: 7)
                    Text(store.backendOnline ? "Backend connected" : "Backend offline")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                }
                Text("MILESTONE 5 · DESKTOP").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.28))
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(panel, in: RoundedRectangle(cornerRadius: 11))
        }
        .padding(20)
        .frame(width: 225)
        .background(Color(red: 0.07, green: 0.095, blue: 0.09))
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.selected.rawValue).font(.system(size: 21, weight: .bold))
                Text("Manage your store from one place").font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            Button { Task { await store.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(panel, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
            Button { store.showingAddProduct = true } label: {
                Label("Add product", systemImage: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(background)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(accent, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 28).padding(.vertical, 19)
        .background(background)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                metricCard(title: "TOTAL PRODUCTS", value: "\(store.products.count)", subtitle: "Items in catalogue", icon: "shippingbox", color: accent)
                metricCard(title: "LOW STOCK", value: "\(store.products.filter { $0.low_stock_alert }.count)", subtitle: "Need attention", icon: "exclamationmark.triangle", color: .orange)
                metricCard(title: "TOTAL UNITS", value: "\(store.products.reduce(0) { $0 + $1.quantity })", subtitle: "Units in inventory", icon: "cube.box", color: .cyan)
            }
            HStack {
                Text("Recent inventory").font(.system(size: 16, weight: .bold))
                Spacer()
                Button("View all") { store.selected = .products }.font(.system(size: 11, weight: .semibold)).foregroundStyle(accent).buttonStyle(.plain)
            }
            productTable(showCategory: true)
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill").foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your workspace is connected to the local database").font(.system(size: 12, weight: .semibold))
                    Text("Changes made here are saved by the existing Grossify C++ backend.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Text(store.databaseOnline ? "DATABASE ONLINE" : "DATABASE OFFLINE")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(store.databaseOnline ? accent : .orange)
            }
            .padding(15).background(panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func metricCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Image(systemName: icon).foregroundStyle(color).padding(8).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .background(panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.045), lineWidth: 1))
    }

    private var productsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Product catalogue").font(.system(size: 18, weight: .bold))
                    Text("Products currently stored in Grossify's database").font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Text("\(store.products.count) ITEMS").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(accent)
            }
            productTable(showCategory: true)
        }
    }

    private var inventoryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Inventory control").font(.system(size: 18, weight: .bold))
            Text("Use the + and − controls to adjust stock. The backend prevents stock from becoming negative.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            ForEach(store.products) { product in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 9).fill(accent.opacity(0.12))
                        .frame(width: 38, height: 38)
                        .overlay(Image(systemName: "shippingbox").foregroundStyle(accent))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(product.name).font(.system(size: 13, weight: .semibold))
                        Text(product.category.isEmpty ? "Uncategorised" : product.category)
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Text("\(product.quantity) units").font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(product.low_stock_alert ? .orange : .white)
                    Button { Task { await store.adjustStock(productID: product.id, delta: -1) } } label: {
                        Image(systemName: "minus").frame(width: 28, height: 28)
                    }.buttonStyle(StockButtonStyle())
                    Button { Task { await store.adjustStock(productID: product.id, delta: 1) } } label: {
                        Image(systemName: "plus").frame(width: 28, height: 28)
                    }.buttonStyle(StockButtonStyle())
                }.padding(13).background(panel, in: RoundedRectangle(cornerRadius: 11))
            }
            if store.products.isEmpty { emptyState }
        }
    }

    private func productTable(showCategory: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                tableHeader("PRODUCT", width: 2)
                if showCategory { tableHeader("CATEGORY", width: 1.2) }
                tableHeader("PRICE", width: 0.8)
                tableHeader("STOCK", width: 0.7)
                tableHeader("STATUS", width: 0.9)
            }.padding(13).background(Color.white.opacity(0.035))
            if store.products.isEmpty {
                emptyState.padding(30)
            } else {
                ForEach(store.products) { product in
                    HStack {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 7).fill(accent.opacity(0.12)).frame(width: 30, height: 30)
                                .overlay(Image(systemName: "cube").font(.system(size: 12)).foregroundStyle(accent))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.name).font(.system(size: 12, weight: .semibold))
                                Text("#\(product.id)").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if showCategory { Text(product.category.isEmpty ? "—" : product.category).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity, alignment: .leading) }
                        Text(product.price, format: .currency(code: "INR")).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(product.quantity)").font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(product.low_stock_alert ? "LOW STOCK" : "IN STOCK")
                            .font(.system(size: 9, weight: .bold)).tracking(0.5)
                            .foregroundStyle(product.low_stock_alert ? .orange : accent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background((product.low_stock_alert ? Color.orange : accent).opacity(0.11), in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(13)
                    Rectangle().fill(Color.white.opacity(0.045)).frame(height: 1)
                }
            }
        }
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tableHeader(_ title: String, width: CGFloat) -> some View {
        Text(title).font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(.white.opacity(0.38))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox").font(.system(size: 25)).foregroundStyle(.white.opacity(0.25))
            Text("No products yet").font(.system(size: 13, weight: .semibold))
            Text("Add your first product to populate the catalogue.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }.frame(maxWidth: .infinity).padding(.vertical, 25)
    }

    private var filteredPOSProducts: [Product] {
        if store.posSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return store.products
        }
        return store.products.filter {
            $0.name.localizedCaseInsensitiveContains(store.posSearchText) ||
            $0.category.localizedCaseInsensitiveContains(store.posSearchText)
        }
    }

    private var filteredBills: [BillSummary] {
        if store.billSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return store.bills
        }
        return store.bills.filter {
            $0.bill_number.localizedCaseInsensitiveContains(store.billSearchText) ||
            $0.customer_name.localizedCaseInsensitiveContains(store.billSearchText) ||
            $0.customer_phone.localizedCaseInsensitiveContains(store.billSearchText)
        }
    }

    private var billingView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Point of Sale").font(.system(size: 21, weight: .bold))
                    Text("Select items from the catalogue, enter customer details and complete billing")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                if !store.cart.isEmpty {
                    Button {
                        store.clearCart()
                    } label: {
                        Label("Clear Cart", systemImage: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.85))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .top, spacing: 22) {
                // Left Column: Product Catalogue
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
                        TextField("Search catalogue by name or category...", text: $store.posSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !store.posSearchText.isEmpty {
                            Button { store.posSearchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(panel, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 1))

                    VStack(spacing: 0) {
                        HStack {
                            Text("PRODUCT").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
                            Text("PRICE").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 80, alignment: .leading)
                            Text("STOCK").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 80, alignment: .leading)
                            Text("ACTION").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 90, alignment: .trailing)
                        }
                        .padding(12).background(Color.white.opacity(0.035))

                        if filteredPOSProducts.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.white.opacity(0.3))
                                Text("No matching products in catalogue").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity).padding(30)
                        } else {
                            ForEach(filteredPOSProducts) { product in
                                let inCartQty = store.cart.first(where: { $0.id == product.id })?.quantity ?? 0
                                let canAdd = product.quantity > inCartQty
                                HStack {
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.12)).frame(width: 28, height: 28)
                                            .overlay(Image(systemName: "cube").font(.system(size: 11)).foregroundStyle(accent))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(product.name).font(.system(size: 12, weight: .semibold))
                                            Text(product.category.isEmpty ? "Uncategorised" : product.category)
                                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(product.price, format: .currency(code: "INR"))
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(width: 80, alignment: .leading)

                                    HStack(spacing: 4) {
                                        Text("\(product.quantity) units")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(product.quantity == 0 ? .red : (product.low_stock_alert ? .orange : .white))
                                    }
                                    .frame(width: 80, alignment: .leading)

                                    Button {
                                        store.addToCart(product: product)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus")
                                            Text(inCartQty > 0 ? "(\(inCartQty)) Add" : "Add")
                                        }
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(canAdd ? accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                        .foregroundStyle(canAdd ? background : Color.white.opacity(0.3))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canAdd)
                                    .frame(width: 90, alignment: .trailing)
                                }
                                .padding(11)
                                Rectangle().fill(Color.white.opacity(0.045)).frame(height: 1)
                            }
                        }
                    }
                    .background(panel, in: RoundedRectangle(cornerRadius: 11))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .frame(maxWidth: .infinity)

                // Right Column: Customer Info & Shopping Cart
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("CUSTOMER INFORMATION")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(accent)
                            Spacer()
                            if store.isCustomerValid {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                                    Text("Valid").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Full Name *")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                            TextField("Customer Name (e.g. Ramesh Kumar)", text: $store.customerName)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Mobile Number *")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.65))
                                Spacer()
                                if !store.customerPhone.isEmpty && !store.isPhoneValid(store.customerPhone) {
                                    Text("10 digits (starts 6-9)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.orange)
                                }
                            }
                            TextField("10-digit mobile (e.g. 9876543210)", text: $store.customerPhone)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Payment Mode")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                            Picker("", selection: $store.paymentMode) {
                                Text("Cash").tag("Cash")
                                Text("UPI").tag("UPI")
                                Text("Card").tag("Card")
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding(15)
                    .background(panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.045), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("SHOPPING CART")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(accent)
                            Spacer()
                            Text("\(store.cartItemCount) items")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }

                        if store.cart.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "cart").font(.system(size: 24)).foregroundStyle(.white.opacity(0.25))
                                Text("Cart is empty").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                                Text("Click '+ Add' on products to begin").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(store.cart) { item in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.product.name).font(.system(size: 12, weight: .semibold))
                                            Text(item.product.price, format: .currency(code: "INR"))
                                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                                        }
                                        Spacer()

                                        Button {
                                            store.decreaseQuantity(productID: item.id)
                                        } label: {
                                            Image(systemName: "minus").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 22)
                                        }
                                        .buttonStyle(StockButtonStyle())

                                        Text("\(item.quantity)")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .frame(minWidth: 20, alignment: .center)

                                        Button {
                                            store.increaseQuantity(productID: item.id)
                                        } label: {
                                            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 22)
                                        }
                                        .buttonStyle(StockButtonStyle())
                                        .disabled(item.quantity >= item.product.quantity)

                                        Text(item.lineTotal, format: .currency(code: "INR"))
                                            .font(.system(size: 12, weight: .bold))
                                            .frame(width: 65, alignment: .trailing)

                                        Button {
                                            store.removeFromCart(productID: item.id)
                                        } label: {
                                            Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.red.opacity(0.7))
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.leading, 4)
                                    }
                                    .padding(.vertical, 4)
                                    Divider().background(Color.white.opacity(0.06))
                                }
                            }
                        }

                        VStack(spacing: 10) {
                            HStack {
                                Text("Grand Total")
                                    .font(.system(size: 13, weight: .bold))
                                Spacer()
                                Text(store.cartSubtotal, format: .currency(code: "INR"))
                                    .font(.system(size: 22, weight: .black, design: .rounded))
                                    .foregroundStyle(accent)
                            }
                            .padding(.top, 4)

                            Button {
                                Task { await store.checkout() }
                            } label: {
                                HStack(spacing: 8) {
                                    if store.isCheckingOut {
                                        ProgressView().scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                    Text(store.isCheckingOut ? "Processing..." : "Complete Checkout")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(background)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(store.canCheckout ? accent : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .disabled(!store.canCheckout)

                            if !store.cart.isEmpty && !store.isCustomerValid {
                                Text("Enter customer name and valid 10-digit mobile to checkout")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                    }
                    .padding(15)
                    .background(panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.045), lineWidth: 1))
                }
                .frame(width: 360)
            }
        }
    }

    private var billHistoryView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bill History").font(.system(size: 21, weight: .bold))
                    Text("View past retail sales, customer records and receipts")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Button {
                    Task { await store.fetchBills() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(panel, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
                TextField("Search by bill number, customer name, or phone...", text: $store.billSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !store.billSearchText.isEmpty {
                    Button { store.billSearchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                    }.buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 1))

            VStack(spacing: 0) {
                HStack {
                    Text("BILL NUMBER").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 140, alignment: .leading)
                    Text("CUSTOMER").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
                    Text("PHONE").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 105, alignment: .leading)
                    Text("ITEMS").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 60, alignment: .leading)
                    Text("TOTAL").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 90, alignment: .leading)
                    Text("DATE").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 130, alignment: .leading)
                    Text("ACTION").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 80, alignment: .trailing)
                }
                .padding(13)
                .background(Color.white.opacity(0.035))

                if filteredBills.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 24)).foregroundStyle(.white.opacity(0.25))
                        Text(store.bills.isEmpty ? "No bills recorded yet" : "No matching bills found")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                        Text("Completed sales in the Billing screen will appear here.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(36)
                } else {
                    ForEach(filteredBills) { bill in
                        HStack {
                            Text(bill.bill_number)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(accent)
                                .frame(width: 140, alignment: .leading)

                            Text(bill.customer_name)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text("+91 " + bill.customer_phone)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 105, alignment: .leading)

                            Text("\(bill.items_count)")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 60, alignment: .leading)

                            Text(bill.total, format: .currency(code: "INR"))
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 90, alignment: .leading)

                            Text(bill.created_at)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 130, alignment: .leading)

                            Button("View Bill") {
                                Task { await store.fetchBillDetail(id: bill.id) }
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .buttonStyle(.plain)
                            .frame(width: 80, alignment: .trailing)
                        }
                        .padding(13)
                        Rectangle().fill(Color.white.opacity(0.045)).frame(height: 1)
                    }
                }
            }
            .background(panel, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct StockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.4 : 0.8))
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

enum AddProductField: Hashable {
    case name
    case category
    case price
    case quantity
    case lowStock
}

final class AddProductModel: ObservableObject {
    @Published var name = ""
    @Published var category = ""
    @Published var price = ""
    @Published var quantity = "0"
    @Published var lowStock = "5"

    var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanCategory: String { category.trimmingCharacters(in: .whitespacesAndNewlines) }
    var parsedPrice: Double? { Double(price.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var parsedQuantity: Int? { Int(quantity.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var parsedLowStock: Int? { Int(lowStock.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var valid: Bool {
        !cleanName.isEmpty &&
        (parsedPrice ?? -1) >= 0 &&
        (parsedQuantity ?? -1) >= 0 &&
        (parsedLowStock ?? -1) >= 0
    }
}

struct AddProductSheet: View {
    let onSave: (String, String, Double, Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AddProductModel()
    @FocusState private var focusedField: AddProductField?

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Add a product").font(.system(size: 20, weight: .bold))
            Text("The product will be saved to the Grossify SQLite database.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
            field("Product name", text: $model.name, hint: "e.g. Amul Milk", field: .name)
            field("Category", text: $model.category, hint: "e.g. Dairy", field: .category)
            HStack(spacing: 12) {
                field("Price (₹)", text: $model.price, hint: "60", field: .price)
                field("Quantity", text: $model.quantity, hint: "20", field: .quantity)
            }
            field("Low-stock alert at", text: $model.lowStock, hint: "5", field: .lowStock)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save product") {
                    onSave(model.cleanName, model.cleanCategory,
                           model.parsedPrice ?? 0, model.parsedQuantity ?? 0, model.parsedLowStock ?? 5)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!model.valid)
                    .buttonStyle(.borderedProminent).tint(Color(red: 0.30, green: 0.78, blue: 0.58))
            }.padding(.top, 5)
        }
        .padding(25).frame(width: 430)
        .background(Color(red: 0.07, green: 0.095, blue: 0.09))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedField = .name
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, hint: String, field: AddProductField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
            TextField(hint, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
        }
        .frame(maxWidth: .infinity)
    }
}

struct BillDetailSheet: View {
    let bill: BillDetail
    @Environment(\.dismiss) private var dismiss

    private let background = Color(red: 0.055, green: 0.075, blue: 0.075)
    private let panel = Color(red: 0.085, green: 0.115, blue: 0.11)
    private let accent = Color(red: 0.30, green: 0.78, blue: 0.58)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GROSSIFY RETAIL RECEIPT")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(accent)
                    Text(bill.bill_number)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }

            // Customer details row
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CUSTOMER").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    Text(bill.customer_name).font(.system(size: 13, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("PHONE").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    Text("+91 " + bill.customer_phone).font(.system(size: 13, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("DATE").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    Text(bill.created_at).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("PAYMENT").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                    Text(bill.payment_mode).font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 10))

            // Items table
            VStack(spacing: 0) {
                HStack {
                    Text("PRODUCT").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
                    Text("UNIT PRICE").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 85, alignment: .trailing)
                    Text("QTY").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 55, alignment: .trailing)
                    Text("LINE TOTAL").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)).frame(width: 90, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(0.04))

                ForEach(bill.items) { item in
                    HStack {
                        Text(item.product_name)
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.unit_price, format: .currency(code: "INR"))
                            .font(.system(size: 12))
                            .frame(width: 85, alignment: .trailing)
                        Text("\(item.quantity)")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 55, alignment: .trailing)
                        Text(item.line_total, format: .currency(code: "INR"))
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                }
            }
            .background(panel, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Grand Total
            HStack {
                Text("TOTAL AMOUNT PAID").font(.system(size: 12, weight: .bold))
                Spacer()
                Text(bill.total, format: .currency(code: "INR"))
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(accent)
            }
            .padding(14)
            .background(panel, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(background)
    }
}
