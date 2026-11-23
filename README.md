# Grossify — Grocery Store Management & Point of Sale (POS) System

Grossify is a modern, local-first Grocery Store Management and Point of Sale (POS) desktop application designed for retail store operations, product catalogue management, real-time inventory control, and billing.

The application combines a high-performance **C++17 SQLite backend** with a native **macOS SwiftUI desktop interface**, built using lightweight Apple Command Line Tools without requiring a full Xcode installation.

---

## 🌟 Key Features

### 1. Store Dashboard
- **Store Overview**: Real-time KPI summary displaying Total Catalogue Items, Total Inventory Units, and Items Requiring Attention.
- **Connection Monitor**: Live health monitoring indicator verifying the local C++ backend and SQLite database status.
- **Recent Inventory Table**: Quick-glance list of store products with visual in-stock and low-stock badges.

### 2. Product Catalogue
- **Product Management**: View store items with name, category, unit price (₹ INR), available stock, and status.
- **Add Product Modal**: Clean modal sheet to add new inventory items with input validation for price, initial stock, and custom low-stock alert thresholds.
- **Live Search**: Fast local filtering by product name and category.

### 3. Inventory Control
- **Quick Stock Adjustments**: Instant single-click quantity increments (`+`) and decrements (`−`).
- **Negative Stock Protection**: Backend transactions strictly enforce non-negative stock constraints.
- **Low-Stock Alerting**: Automatic warning tags triggered when stock drops below designated thresholds.

### 4. Retail Point of Sale (POS) & Billing
- **2-Column POS Layout**:
  - **Left Column**: Live product catalogue with search and "+ Add" buttons reflecting current in-cart counts.
  - **Right Column**: Customer information form, payment mode selector, real-time shopping cart, and checkout actions.
- **Customer Information & Validation**:
  - Full Name (required).
  - 10-digit Indian Mobile Number (required), strictly validated against `^[6-9]\d{9}$` with real-time visual indicator badges.
  - Payment Mode selection (**Cash**, **UPI**, **Card**).
- **Interactive Shopping Cart**:
  - Real-time line items with unit price, item quantity, and line totals.
  - Quantity controls (`+` / `−`) automatically clamped to available database stock.
  - Item deletion and single-click cart clearing.
  - Automatic calculation of subtotal and grand total.
- **Atomic Checkout**:
  - Executes inside an atomic SQLite transaction (`BEGIN IMMEDIATE`).
  - Deducts inventory only upon successful transaction commit.
  - Generates sequential unique bill numbers formatted as `GROSS-YYYYMMDD-XXXX`.
  - Built-in idempotency keys to prevent duplicate transaction submissions.
- **Instant Digital Receipt (`BillDetailSheet`)**:
  - Automatically pops up on successful checkout with full itemized breakdown and customer details.

### 5. Bill History & Sales Ledger
- **Transaction History**: Reverse-chronological table of all recorded store sales.
- **Detailed Records**: Displays Bill Number, Customer Name, Phone Number, Total Items Count, Grand Total, and Date/Time.
- **Search & Filter**: Search transactions by bill number, customer name, or phone number.
- **Receipt Inspection**: "View Bill" action to inspect the itemized receipt for any past sale.

---

## 🏗️ System Architecture

```text
┌────────────────────────────────────────────────────────┐
│            GrossifyDesktop (Native macOS UI)           │
│     - SwiftUI Desktop Interface (Dark Charcoal Theme)   │
│     - MVVM Architecture with Observable Store          │
│     - Local POS Cart State & Input Validation           │
└───────────────────────────┬────────────────────────────┘
                            │
                            │ HTTP / JSON REST APIs
                            │ (Localhost: 127.0.0.1:8080)
                            ▼
┌────────────────────────────────────────────────────────┐
│             Grossify C++17 HTTP Backend                │
│     - POSIX Sockets & Native POSIX Threading           │
│     - Atomic SQLite3 Transactions (BEGIN IMMEDIATE)    │
│     - Idempotent Request Handling & Validation         │
└───────────────────────────┬────────────────────────────┘
                            │
                            │ Embedded C SQL API
                            ▼
┌────────────────────────────────────────────────────────┐
│                 SQLite3 Local Database                 │
│     - products (catalogue, stock levels, thresholds)   │
│     - bills (bill numbers, customer info, totals)      │
│     - bill_items (line items, unit prices, quantities) │
│     - sync_events (offline ledger event logging)       │
└────────────────────────────────────────────────────────┘
```

---

## 🛠️ Technology Stack

- **Desktop Interface**: Swift 5.9+ / 6.x, SwiftUI, AppKit (macOS 13.0+ Ventura / Sonoma / Sequoia).
- **Backend Service**: C++17, POSIX Sockets, POSIX Threads.
- **Database**: SQLite 3 with embedded C bindings.
- **Toolchain**: Apple Command Line Tools (`clang++`, `swift`, `sqlite3`). No external Swift package dependencies or full Xcode installation required.

---

## 📋 Prerequisites

Before running the project, verify that Apple Command Line Tools are installed:

```bash
xcode-select -p
```

If not installed, install them using:
```bash
xcode-select --install
```

---

## 🚀 Getting Started

To run Grossify locally, start the C++ backend first, followed by the desktop application.

### Step 1: Start the Backend

Open a Terminal window:

```bash
cd Backend
clang++ -std=c++17 -Wall -Wextra grossify_backend.cpp -lsqlite3 -o grossify_backend
./grossify_backend 8080
```

*Alternatively, you can run the helper script:*
```bash
./Scripts/start_backend.command
```

The backend starts listening on `http://127.0.0.1:8080` and creates or connects to `Backend/grossify.db`.

### Step 2: Launch the Desktop Application

Open a second Terminal window:

```bash
swift run
```

*Or run the named executable target directly:*
```bash
swift run GrossifyDesktop
```

The Grossify desktop window will launch, automatically connect to the local backend, and display the Dashboard.

---

## 📡 API Reference

The backend exposes the following REST endpoints on `http://127.0.0.1:8080`:

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/health` | Health check verifying HTTP server and SQLite database connection. |
| `GET` | `/api/products` | Retrieve all catalogue products with stock quantities and alert thresholds. |
| `POST` | `/api/products` | Create a new product (`name`, `category`, `price`, `quantity`, `low_stock_threshold`). |
| `POST` | `/api/inventory/adjust` | Increment or decrement stock quantity (`product_id`, `quantity_delta`). Prevents negative stock. |
| `POST` | `/api/checkout` | Process atomic retail checkout (`customer_name`, `customer_phone`, `payment_mode`, `items`, `idempotency_key`). |
| `GET` | `/api/bills` | List all historical retail sales sorted by most recent first. |
| `GET` | `/api/bills/details?id=<id>` | Retrieve full itemized receipt details for a specific bill ID. |
| `POST` | `/api/sync` | Offline-first synchronization endpoint with duplicate sequence protection. |

---

## 📂 Project Directory Structure

```text
Grossify_Milestone_5_Desktop/
├── .gitignore                      # Git ignore rules for macOS, SPM, and local databases
├── Package.swift                   # Swift Package Manager manifest
├── README.md                       # Complete project documentation
├── Backend/
│   ├── grossify_backend.cpp        # C++17 HTTP POSIX socket server & SQLite transactions
│   └── grossify.db                 # Runtime SQLite database (auto-generated)
├── Scripts/
│   └── start_backend.command       # One-click shell script to compile and run backend
└── Sources/
    └── GrossifyDesktop/
        └── GrossifyDesktopApp.swift # Native SwiftUI desktop app, POS, Cart, Store, & Views
```

---

## 🔒 Security & Privacy

- **Local-First Architecture**: All customer information, inventory figures, and transaction ledgers reside strictly in the local SQLite database on your device.
- **Zero Third-Party Tracking**: No telemetry, analytics, or external API keys are used.
- **Input Sanitization**: Phone numbers, customer strings, and transaction payloads undergo strict validation and parameter binding to protect data integrity.

---

## 📄 License

This project is created for educational and academic micro-project evaluation.
