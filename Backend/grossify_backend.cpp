// Grossify Backend API - C++17 + SQLite + macOS/POSIX sockets
// Build: clang++ -std=c++17 -Wall -Wextra grossify_backend.cpp -lsqlite3 -o grossify_backend
// Run:   ./grossify_backend [port]
// API:   http://127.0.0.1:8080
//
// This is a local development backend. It is not an internet-hosted production server.

#include <sqlite3.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using namespace std;

static sqlite3* db = nullptr;

string jsonEscape(const string& s) {
    string out;
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    const char* hex = "0123456789abcdef";
                    out += "\\u00";
                    out += hex[(c >> 4) & 0xf];
                    out += hex[c & 0xf];
                } else out += static_cast<char>(c);
        }
    }
    return out;
}

string getString(const string& body, const string& key, const string& fallback = "") {
    // Deliberately small JSON reader for this project's flat request objects.
    // Supports ordinary escaped quotes/backslashes only; no external JSON library required.
    string needle = "\"" + key + "\"";
    size_t p = body.find(needle);
    if (p == string::npos) return fallback;
    p = body.find(':', p + needle.size());
    if (p == string::npos) return fallback;
    p = body.find('"', p + 1);
    if (p == string::npos) return fallback;
    ++p;
    string value;
    bool escaped = false;
    for (; p < body.size(); ++p) {
        char c = body[p];
        if (escaped) {
            if (c == 'n') value += '\n';
            else if (c == 'r') value += '\r';
            else if (c == 't') value += '\t';
            else value += c;
            escaped = false;
        } else if (c == '\\') escaped = true;
        else if (c == '"') return value;
        else value += c;
    }
    return fallback;
}

bool getNumber(const string& body, const string& key, double& value) {
    string needle = "\"" + key + "\"";
    size_t p = body.find(needle);
    if (p == string::npos) return false;
    p = body.find(':', p + needle.size());
    if (p == string::npos) return false;
    ++p;
    while (p < body.size() && isspace(static_cast<unsigned char>(body[p]))) ++p;
    size_t end = p;
    while (end < body.size() && (isdigit(static_cast<unsigned char>(body[end])) ||
           body[end] == '-' || body[end] == '+' || body[end] == '.')) ++end;
    if (end == p) return false;
    try {
        size_t used = 0;
        value = stod(body.substr(p, end - p), &used);
        return used == end - p;
    } catch (...) { return false; }
}

string makeResponse(int status, const string& body, const string& statusText = "OK") {
    ostringstream out;
    out << "HTTP/1.1 " << status << " " << statusText << "\r\n"
        << "Content-Type: application/json; charset=utf-8\r\n"
        << "Access-Control-Allow-Origin: *\r\n"
        << "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        << "Access-Control-Allow-Headers: Content-Type\r\n"
        << "Content-Length: " << body.size() << "\r\n"
        << "Connection: close\r\n\r\n" << body;
    return out.str();
}

bool runSQL(const string& sql) {
    char* error = nullptr;
    int rc = sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &error);
    if (rc != SQLITE_OK) {
        cerr << "SQLite: " << (error ? error : "unknown error") << '\n';
        sqlite3_free(error);
        return false;
    }
    return true;
}

bool initDB() {
    if (sqlite3_open("grossify.db", &db) != SQLITE_OK) {
        cerr << "Cannot open grossify.db: " << sqlite3_errmsg(db) << '\n';
        return false;
    }
    sqlite3_busy_timeout(db, 3000);
    runSQL("PRAGMA foreign_keys = ON;");
    runSQL(R"SQL(
        CREATE TABLE IF NOT EXISTS products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            category TEXT NOT NULL DEFAULT '',
            price REAL NOT NULL CHECK(price >= 0),
            quantity INTEGER NOT NULL CHECK(quantity >= 0),
            low_stock INTEGER NOT NULL DEFAULT 5 CHECK(low_stock >= 0)
        );
        CREATE TABLE IF NOT EXISTS bills (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bill_number TEXT NOT NULL DEFAULT '',
            customer_name TEXT NOT NULL DEFAULT '',
            customer_phone TEXT NOT NULL DEFAULT '',
            total REAL NOT NULL DEFAULT 0,
            payment_mode TEXT NOT NULL DEFAULT 'Cash',
            created_at TEXT NOT NULL DEFAULT (datetime('now','localtime')),
            idempotency_key TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS bill_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bill_id INTEGER NOT NULL,
            product_id INTEGER NOT NULL,
            product_name TEXT NOT NULL,
            quantity INTEGER NOT NULL,
            unit_price REAL NOT NULL,
            line_total REAL NOT NULL,
            FOREIGN KEY (bill_id) REFERENCES bills(id),
            FOREIGN KEY (product_id) REFERENCES products(id)
        );
        CREATE TABLE IF NOT EXISTS sync_events (
            event_id TEXT PRIMARY KEY,
            product_id INTEGER NOT NULL,
            quantity_delta INTEGER NOT NULL,
            received_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
        );
    )SQL");

    // Safe column migrations for existing databases
    auto ensureColumn = [](const string& table, const string& col, const string& def) {
        sqlite3_stmt* st = nullptr;
        string sql = "PRAGMA table_info(" + table + ");";
        if (sqlite3_prepare_v2(db, sql.c_str(), -1, &st, nullptr) == SQLITE_OK) {
            bool found = false;
            while (sqlite3_step(st) == SQLITE_ROW) {
                const unsigned char* name = sqlite3_column_text(st, 1);
                if (name && col == reinterpret_cast<const char*>(name)) {
                    found = true;
                    break;
                }
            }
            sqlite3_finalize(st);
            if (!found) {
                runSQL("ALTER TABLE " + table + " ADD COLUMN " + col + " " + def + ";");
            }
        }
    };

    ensureColumn("bills", "bill_number", "TEXT NOT NULL DEFAULT ''");
    ensureColumn("bills", "customer_name", "TEXT NOT NULL DEFAULT ''");
    ensureColumn("bills", "customer_phone", "TEXT NOT NULL DEFAULT ''");
    ensureColumn("bills", "idempotency_key", "TEXT NOT NULL DEFAULT ''");

    return true;
}

string productsJSON() {
    sqlite3_stmt* st = nullptr;
    sqlite3_prepare_v2(db,
        "SELECT id,name,category,price,quantity,low_stock FROM products ORDER BY id", -1, &st, nullptr);
    string out = "{\"success\":true,\"products\":[";
    bool first = true;
    while (sqlite3_step(st) == SQLITE_ROW) {
        if (!first) out += ",";
        first = false;
        const unsigned char* n = sqlite3_column_text(st, 1);
        const unsigned char* c = sqlite3_column_text(st, 2);
        int qty = sqlite3_column_int(st, 4), low = sqlite3_column_int(st, 5);
        ostringstream item;
        item << "{\"id\":" << sqlite3_column_int(st, 0)
             << ",\"name\":\"" << jsonEscape(n ? reinterpret_cast<const char*>(n) : "") << "\""
             << ",\"category\":\"" << jsonEscape(c ? reinterpret_cast<const char*>(c) : "") << "\""
             << ",\"price\":" << sqlite3_column_double(st, 3)
             << ",\"quantity\":" << qty
             << ",\"low_stock\":" << low
             << ",\"low_stock_alert\":" << (qty <= low ? "true" : "false") << "}";
        out += item.str();
    }
    sqlite3_finalize(st);
    return out + "]}";
}

struct CheckoutItemRequest {
    int product_id;
    int quantity;
};

vector<CheckoutItemRequest> parseCheckoutItems(const string& body) {
    vector<CheckoutItemRequest> items;
    string needle = "\"items\"";
    size_t p = body.find(needle);
    if (p == string::npos) return items;
    p = body.find('[', p + needle.size());
    if (p == string::npos) return items;
    size_t end = body.find(']', p);
    if (end == string::npos) return items;

    size_t cur = p + 1;
    while (cur < end) {
        size_t objStart = body.find('{', cur);
        if (objStart == string::npos || objStart >= end) break;
        size_t objEnd = body.find('}', objStart);
        if (objEnd == string::npos || objEnd > end) break;

        string obj = body.substr(objStart, objEnd - objStart + 1);
        double pid = 0, qty = 0;
        if (getNumber(obj, "product_id", pid) && getNumber(obj, "quantity", qty)) {
            if (pid >= 1 && qty >= 1) {
                items.push_back({static_cast<int>(pid), static_cast<int>(qty)});
            }
        }
        cur = objEnd + 1;
    }
    return items;
}

bool isValidIndianPhone(const string& phone) {
    if (phone.size() != 10) return false;
    if (phone[0] < '6' || phone[0] > '9') return false;
    for (char c : phone) {
        if (!isdigit(static_cast<unsigned char>(c))) return false;
    }
    return true;
}

string getQueryParam(const string& query, const string& key) {
    string needle = key + "=";
    size_t p = query.find(needle);
    if (p == string::npos) return "";
    size_t start = p + needle.size();
    size_t end = query.find('&', start);
    if (end == string::npos) return query.substr(start);
    return query.substr(start, end - start);
}

string handleRequest(const string& method, const string& path, const string& body, const string& query = "") {
    if (method == "OPTIONS") return makeResponse(204, "{}", "No Content");

    if (method == "GET" && path == "/api/health")
        return makeResponse(200, "{\"success\":true,\"service\":\"Grossify Backend\",\"database\":\"connected\"}");

    if (method == "GET" && path == "/api/products")
        return makeResponse(200, productsJSON());

    if (method == "POST" && path == "/api/products") {
        string name = getString(body, "name");
        string category = getString(body, "category");
        double price = 0, quantity = -1, low = 5;
        if (name.empty() || !getNumber(body, "price", price) ||
            !getNumber(body, "quantity", quantity) || price < 0 ||
            quantity < 0 || quantity != static_cast<int>(quantity)) {
            return makeResponse(400, "{\"success\":false,\"error\":\"Required: name, non-negative price and whole-number quantity.\"}", "Bad Request");
        }
        getNumber(body, "low_stock", low);
        if (low < 0 || low != static_cast<int>(low))
            return makeResponse(400, "{\"success\":false,\"error\":\"low_stock must be a non-negative whole number.\"}", "Bad Request");

        sqlite3_stmt* st = nullptr;
        sqlite3_prepare_v2(db, "INSERT INTO products(name,category,price,quantity,low_stock) VALUES(?,?,?,?,?)", -1, &st, nullptr);
        sqlite3_bind_text(st, 1, name.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, category.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(st, 3, price);
        sqlite3_bind_int(st, 4, static_cast<int>(quantity));
        sqlite3_bind_int(st, 5, static_cast<int>(low));
        int rc = sqlite3_step(st);
        int id = static_cast<int>(sqlite3_last_insert_rowid(db));
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE) return makeResponse(500, "{\"success\":false,\"error\":\"Could not save product.\"}", "Internal Server Error");
        return makeResponse(201, "{\"success\":true,\"message\":\"Product created\",\"id\":" + to_string(id) + "}", "Created");
    }

    if (method == "POST" && path == "/api/inventory/adjust") {
        double id = 0, delta = 0;
        if (!getNumber(body, "product_id", id) || !getNumber(body, "quantity_delta", delta) ||
            id < 1 || id != static_cast<int>(id) || delta == 0 || delta != static_cast<int>(delta)) {
            return makeResponse(400, "{\"success\":false,\"error\":\"Provide product_id and a non-zero whole-number quantity_delta.\"}", "Bad Request");
        }
        sqlite3_stmt* st = nullptr;
        sqlite3_prepare_v2(db,
            "UPDATE products SET quantity=quantity+? WHERE id=? AND quantity+?>=0", -1, &st, nullptr);
        sqlite3_bind_int(st, 1, static_cast<int>(delta));
        sqlite3_bind_int(st, 2, static_cast<int>(id));
        sqlite3_bind_int(st, 3, static_cast<int>(delta));
        int rc = sqlite3_step(st);
        int changed = sqlite3_changes(db);
        sqlite3_finalize(st);
        if (rc != SQLITE_DONE) return makeResponse(500, "{\"success\":false,\"error\":\"Database update failed.\"}", "Internal Server Error");
        if (!changed) return makeResponse(409, "{\"success\":false,\"error\":\"Product not found or stock cannot become negative.\"}", "Conflict");
        return makeResponse(200, "{\"success\":true,\"message\":\"Inventory updated\"}");
    }

    if (method == "POST" && path == "/api/sync") {
        string eventId = getString(body, "event_id");
        double id = 0, delta = 0;
        if (eventId.empty() || !getNumber(body, "product_id", id) ||
            !getNumber(body, "quantity_delta", delta) || id < 1 ||
            id != static_cast<int>(id) || delta == 0 || delta != static_cast<int>(delta)) {
            return makeResponse(400, "{\"success\":false,\"error\":\"Required: unique event_id, product_id and non-zero whole-number quantity_delta.\"}", "Bad Request");
        }
        if (!runSQL("BEGIN IMMEDIATE;")) return makeResponse(500, "{\"success\":false,\"error\":\"Could not start sync transaction.\"}", "Internal Server Error");

        sqlite3_stmt* check = nullptr;
        sqlite3_prepare_v2(db, "SELECT 1 FROM sync_events WHERE event_id=?", -1, &check, nullptr);
        sqlite3_bind_text(check, 1, eventId.c_str(), -1, SQLITE_TRANSIENT);
        bool duplicate = sqlite3_step(check) == SQLITE_ROW;
        sqlite3_finalize(check);
        if (duplicate) {
            runSQL("COMMIT;");
            return makeResponse(200, "{\"success\":true,\"duplicate\":true,\"message\":\"Event was already synced; no change repeated.\"}");
        }

        sqlite3_stmt* update = nullptr;
        sqlite3_prepare_v2(db, "UPDATE products SET quantity=quantity+? WHERE id=? AND quantity+?>=0", -1, &update, nullptr);
        sqlite3_bind_int(update, 1, static_cast<int>(delta));
        sqlite3_bind_int(update, 2, static_cast<int>(id));
        sqlite3_bind_int(update, 3, static_cast<int>(delta));
        int updateRC = sqlite3_step(update);
        int changed = sqlite3_changes(db);
        sqlite3_finalize(update);
        if (updateRC != SQLITE_DONE || !changed) {
            runSQL("ROLLBACK;");
            return makeResponse(409, "{\"success\":false,\"error\":\"Product missing or sync would make stock negative.\"}", "Conflict");
        }

        sqlite3_stmt* insert = nullptr;
        sqlite3_prepare_v2(db, "INSERT INTO sync_events(event_id,product_id,quantity_delta) VALUES(?,?,?)", -1, &insert, nullptr);
        sqlite3_bind_text(insert, 1, eventId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(insert, 2, static_cast<int>(id));
        sqlite3_bind_int(insert, 3, static_cast<int>(delta));
        int insertRC = sqlite3_step(insert);
        sqlite3_finalize(insert);
        if (insertRC != SQLITE_DONE || !runSQL("COMMIT;")) {
            runSQL("ROLLBACK;");
            return makeResponse(500, "{\"success\":false,\"error\":\"Could not record sync event.\"}", "Internal Server Error");
        }
        return makeResponse(200, "{\"success\":true,\"duplicate\":false,\"message\":\"Offline change synchronised.\"}");
    }

    if (method == "POST" && path == "/api/checkout") {
        string custName = getString(body, "customer_name");
        string custPhone = getString(body, "customer_phone");
        string paymentMode = getString(body, "payment_mode", "Cash");
        string idempotencyKey = getString(body, "idempotency_key");

        auto trimStr = [](string s) {
            while (!s.empty() && isspace(static_cast<unsigned char>(s.front()))) s.erase(s.begin());
            while (!s.empty() && isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
            return s;
        };
        custName = trimStr(custName);
        custPhone = trimStr(custPhone);
        if (paymentMode.empty()) paymentMode = "Cash";

        if (custName.empty()) {
            return makeResponse(400, "{\"success\":false,\"error\":\"Customer full name is required.\"}", "Bad Request");
        }
        if (!isValidIndianPhone(custPhone)) {
            return makeResponse(400, "{\"success\":false,\"error\":\"Customer phone must be a valid 10-digit Indian mobile number.\"}", "Bad Request");
        }

        auto items = parseCheckoutItems(body);
        if (items.empty()) {
            return makeResponse(400, "{\"success\":false,\"error\":\"Shopping cart cannot be empty.\"}", "Bad Request");
        }

        if (!runSQL("BEGIN IMMEDIATE;")) {
            return makeResponse(500, "{\"success\":false,\"error\":\"Could not begin checkout transaction.\"}", "Internal Server Error");
        }

        if (!idempotencyKey.empty()) {
            sqlite3_stmt* checkIdemp = nullptr;
            sqlite3_prepare_v2(db, "SELECT id, bill_number, total, created_at FROM bills WHERE idempotency_key = ?", -1, &checkIdemp, nullptr);
            sqlite3_bind_text(checkIdemp, 1, idempotencyKey.c_str(), -1, SQLITE_TRANSIENT);
            if (sqlite3_step(checkIdemp) == SQLITE_ROW) {
                int existId = sqlite3_column_int(checkIdemp, 0);
                string existBillNo = reinterpret_cast<const char*>(sqlite3_column_text(checkIdemp, 1));
                double existTotal = sqlite3_column_double(checkIdemp, 2);
                string existDate = reinterpret_cast<const char*>(sqlite3_column_text(checkIdemp, 3));
                sqlite3_finalize(checkIdemp);
                runSQL("COMMIT;");
                return makeResponse(200, "{\"success\":true,\"duplicate\":true,\"message\":\"Checkout already processed.\",\"bill\":{\"id\":" + to_string(existId) + ",\"bill_number\":\"" + jsonEscape(existBillNo) + "\",\"total\":" + to_string(existTotal) + ",\"created_at\":\"" + jsonEscape(existDate) + "\"}}");
            }
            sqlite3_finalize(checkIdemp);
        }

        struct VerifiedItem {
            int product_id;
            string product_name;
            double unit_price;
            int quantity;
            double line_total;
        };
        vector<VerifiedItem> verifiedItems;
        double grandTotal = 0.0;

        for (const auto& itemReq : items) {
            sqlite3_stmt* pSt = nullptr;
            sqlite3_prepare_v2(db, "SELECT name, price, quantity FROM products WHERE id = ?", -1, &pSt, nullptr);
            sqlite3_bind_int(pSt, 1, itemReq.product_id);
            if (sqlite3_step(pSt) != SQLITE_ROW) {
                sqlite3_finalize(pSt);
                runSQL("ROLLBACK;");
                return makeResponse(404, "{\"success\":false,\"error\":\"Product not found for product_id " + to_string(itemReq.product_id) + ".\"}", "Not Found");
            }
            string pName = reinterpret_cast<const char*>(sqlite3_column_text(pSt, 0));
            double pPrice = sqlite3_column_double(pSt, 1);
            int pStock = sqlite3_column_int(pSt, 2);
            sqlite3_finalize(pSt);

            if (itemReq.quantity <= 0) {
                runSQL("ROLLBACK;");
                return makeResponse(400, "{\"success\":false,\"error\":\"Invalid quantity for product " + jsonEscape(pName) + ".\"}", "Bad Request");
            }
            if (itemReq.quantity > pStock) {
                runSQL("ROLLBACK;");
                return makeResponse(409, "{\"success\":false,\"error\":\"Insufficient stock for " + jsonEscape(pName) + ". Available: " + to_string(pStock) + ", in cart: " + to_string(itemReq.quantity) + ".\"}", "Conflict");
            }

            double lineTot = pPrice * itemReq.quantity;
            grandTotal += lineTot;
            verifiedItems.push_back({itemReq.product_id, pName, pPrice, itemReq.quantity, lineTot});
        }

        sqlite3_stmt* numSt = nullptr;
        sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) + 1 FROM bills", -1, &numSt, nullptr);
        int nextId = 1;
        if (sqlite3_step(numSt) == SQLITE_ROW) {
            nextId = sqlite3_column_int(numSt, 0);
        }
        sqlite3_finalize(numSt);

        time_t now = time(nullptr);
        tm* ltm = localtime(&now);
        char dateBuf[32];
        strftime(dateBuf, sizeof(dateBuf), "%Y%m%d", ltm);
        char billNumBuf[64];
        snprintf(billNumBuf, sizeof(billNumBuf), "GROSS-%s-%04d", dateBuf, nextId);
        string billNumber = billNumBuf;
        char createdBuf[32];
        strftime(createdBuf, sizeof(createdBuf), "%Y-%m-%d %H:%M:%S", ltm);
        string createdAt = createdBuf;

        sqlite3_stmt* bInsert = nullptr;
        sqlite3_prepare_v2(db, "INSERT INTO bills(bill_number, customer_name, customer_phone, total, payment_mode, created_at, idempotency_key) VALUES (?, ?, ?, ?, ?, ?, ?)", -1, &bInsert, nullptr);
        sqlite3_bind_text(bInsert, 1, billNumber.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(bInsert, 2, custName.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(bInsert, 3, custPhone.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(bInsert, 4, grandTotal);
        sqlite3_bind_text(bInsert, 5, paymentMode.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(bInsert, 6, createdAt.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(bInsert, 7, idempotencyKey.c_str(), -1, SQLITE_TRANSIENT);
        if (sqlite3_step(bInsert) != SQLITE_DONE) {
            sqlite3_finalize(bInsert);
            runSQL("ROLLBACK;");
            return makeResponse(500, "{\"success\":false,\"error\":\"Could not record bill.\"}", "Internal Server Error");
        }
        int newBillId = static_cast<int>(sqlite3_last_insert_rowid(db));
        sqlite3_finalize(bInsert);

        for (const auto& vi : verifiedItems) {
            sqlite3_stmt* itemInsert = nullptr;
            sqlite3_prepare_v2(db, "INSERT INTO bill_items(bill_id, product_id, product_name, quantity, unit_price, line_total) VALUES (?, ?, ?, ?, ?, ?)", -1, &itemInsert, nullptr);
            sqlite3_bind_int(itemInsert, 1, newBillId);
            sqlite3_bind_int(itemInsert, 2, vi.product_id);
            sqlite3_bind_text(itemInsert, 3, vi.product_name.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(itemInsert, 4, vi.quantity);
            sqlite3_bind_double(itemInsert, 5, vi.unit_price);
            sqlite3_bind_double(itemInsert, 6, vi.line_total);
            if (sqlite3_step(itemInsert) != SQLITE_DONE) {
                sqlite3_finalize(itemInsert);
                runSQL("ROLLBACK;");
                return makeResponse(500, "{\"success\":false,\"error\":\"Could not record bill items.\"}", "Internal Server Error");
            }
            sqlite3_finalize(itemInsert);

            sqlite3_stmt* stockUpdate = nullptr;
            sqlite3_prepare_v2(db, "UPDATE products SET quantity = quantity - ? WHERE id = ? AND quantity >= ?", -1, &stockUpdate, nullptr);
            sqlite3_bind_int(stockUpdate, 1, vi.quantity);
            sqlite3_bind_int(stockUpdate, 2, vi.product_id);
            sqlite3_bind_int(stockUpdate, 3, vi.quantity);
            int rc = sqlite3_step(stockUpdate);
            int changed = sqlite3_changes(db);
            sqlite3_finalize(stockUpdate);
            if (rc != SQLITE_DONE || changed == 0) {
                runSQL("ROLLBACK;");
                return makeResponse(409, "{\"success\":false,\"error\":\"Stock deduction failed for " + jsonEscape(vi.product_name) + ".\"}", "Conflict");
            }
        }

        if (!runSQL("COMMIT;")) {
            runSQL("ROLLBACK;");
            return makeResponse(500, "{\"success\":false,\"error\":\"Transaction commit failed.\"}", "Internal Server Error");
        }

        ostringstream res;
        res << "{\"success\":true,\"message\":\"Checkout completed successfully\",\"bill\":{"
            << "\"id\":" << newBillId
            << ",\"bill_number\":\"" << jsonEscape(billNumber) << "\""
            << ",\"customer_name\":\"" << jsonEscape(custName) << "\""
            << ",\"customer_phone\":\"" << jsonEscape(custPhone) << "\""
            << ",\"total\":" << grandTotal
            << ",\"payment_mode\":\"" << jsonEscape(paymentMode) << "\""
            << ",\"created_at\":\"" << jsonEscape(createdAt) << "\""
            << ",\"items_count\":" << verifiedItems.size() << "}}";
        return makeResponse(201, res.str(), "Created");
    }

    if (method == "GET" && (path == "/api/bills/details" || (path == "/api/bills" && !getQueryParam(query, "id").empty()))) {
        string idStr = getQueryParam(query, "id");
        if (idStr.empty()) return makeResponse(400, "{\"success\":false,\"error\":\"Provide bill id in query parameters (e.g. ?id=1).\"}", "Bad Request");
        int billId = 0;
        try { billId = stoi(idStr); } catch (...) { return makeResponse(400, "{\"success\":false,\"error\":\"Invalid bill id.\"}", "Bad Request"); }

        sqlite3_stmt* bSt = nullptr;
        sqlite3_prepare_v2(db, "SELECT id, bill_number, customer_name, customer_phone, total, payment_mode, created_at FROM bills WHERE id = ?", -1, &bSt, nullptr);
        sqlite3_bind_int(bSt, 1, billId);
        if (sqlite3_step(bSt) != SQLITE_ROW) {
            sqlite3_finalize(bSt);
            return makeResponse(404, "{\"success\":false,\"error\":\"Bill not found.\"}", "Not Found");
        }
        int id = sqlite3_column_int(bSt, 0);
        const unsigned char* bNum = sqlite3_column_text(bSt, 1);
        const unsigned char* cName = sqlite3_column_text(bSt, 2);
        const unsigned char* cPhone = sqlite3_column_text(bSt, 3);
        double total = sqlite3_column_double(bSt, 4);
        const unsigned char* pMode = sqlite3_column_text(bSt, 5);
        const unsigned char* cAt = sqlite3_column_text(bSt, 6);

        ostringstream json;
        json << "{\"success\":true,\"bill\":{"
             << "\"id\":" << id
             << ",\"bill_number\":\"" << jsonEscape(bNum ? reinterpret_cast<const char*>(bNum) : "") << "\""
             << ",\"customer_name\":\"" << jsonEscape(cName ? reinterpret_cast<const char*>(cName) : "") << "\""
             << ",\"customer_phone\":\"" << jsonEscape(cPhone ? reinterpret_cast<const char*>(cPhone) : "") << "\""
             << ",\"total\":" << total
             << ",\"payment_mode\":\"" << jsonEscape(pMode ? reinterpret_cast<const char*>(pMode) : "Cash") << "\""
             << ",\"created_at\":\"" << jsonEscape(cAt ? reinterpret_cast<const char*>(cAt) : "") << "\""
             << ",\"items\":[";
        sqlite3_finalize(bSt);

        sqlite3_stmt* itemSt = nullptr;
        sqlite3_prepare_v2(db, "SELECT id, product_id, product_name, quantity, unit_price, line_total FROM bill_items WHERE bill_id = ? ORDER BY id", -1, &itemSt, nullptr);
        sqlite3_bind_int(itemSt, 1, billId);
        bool first = true;
        while (sqlite3_step(itemSt) == SQLITE_ROW) {
            if (!first) json << ",";
            first = false;
            int itemId = sqlite3_column_int(itemSt, 0);
            int prodId = sqlite3_column_int(itemSt, 1);
            const unsigned char* pName = sqlite3_column_text(itemSt, 2);
            int qty = sqlite3_column_int(itemSt, 3);
            double uPrice = sqlite3_column_double(itemSt, 4);
            double lTotal = sqlite3_column_double(itemSt, 5);
            json << "{\"id\":" << itemId
                 << ",\"product_id\":" << prodId
                 << ",\"product_name\":\"" << jsonEscape(pName ? reinterpret_cast<const char*>(pName) : "") << "\""
                 << ",\"quantity\":" << qty
                 << ",\"unit_price\":" << uPrice
                 << ",\"line_total\":" << lTotal << "}";
        }
        sqlite3_finalize(itemSt);
        json << "]}}";
        return makeResponse(200, json.str());
    }

    if (method == "GET" && path == "/api/bills") {
        sqlite3_stmt* st = nullptr;
        sqlite3_prepare_v2(db,
            "SELECT b.id, b.bill_number, b.customer_name, b.customer_phone, b.total, b.payment_mode, b.created_at, "
            "(SELECT COALESCE(SUM(quantity), 0) FROM bill_items WHERE bill_id = b.id) AS total_items "
            "FROM bills b ORDER BY b.id DESC", -1, &st, nullptr);
        string out = "{\"success\":true,\"bills\":[";
        bool first = true;
        while (sqlite3_step(st) == SQLITE_ROW) {
            if (!first) out += ",";
            first = false;
            int id = sqlite3_column_int(st, 0);
            const unsigned char* bNum = sqlite3_column_text(st, 1);
            const unsigned char* cName = sqlite3_column_text(st, 2);
            const unsigned char* cPhone = sqlite3_column_text(st, 3);
            double total = sqlite3_column_double(st, 4);
            const unsigned char* pMode = sqlite3_column_text(st, 5);
            const unsigned char* cAt = sqlite3_column_text(st, 6);
            int totalItems = sqlite3_column_int(st, 7);

            ostringstream row;
            row << "{\"id\":" << id
                << ",\"bill_number\":\"" << jsonEscape(bNum ? reinterpret_cast<const char*>(bNum) : "") << "\""
                << ",\"customer_name\":\"" << jsonEscape(cName ? reinterpret_cast<const char*>(cName) : "") << "\""
                << ",\"customer_phone\":\"" << jsonEscape(cPhone ? reinterpret_cast<const char*>(cPhone) : "") << "\""
                << ",\"total\":" << total
                << ",\"payment_mode\":\"" << jsonEscape(pMode ? reinterpret_cast<const char*>(pMode) : "Cash") << "\""
                << ",\"created_at\":\"" << jsonEscape(cAt ? reinterpret_cast<const char*>(cAt) : "") << "\""
                << ",\"items_count\":" << totalItems << "}";
            out += row.str();
        }
        sqlite3_finalize(st);
        out += "]}";
        return makeResponse(200, out);
    }

    return makeResponse(404, "{\"success\":false,\"error\":\"Route not found. See README for available routes.\"}", "Not Found");
}

void serveClient(int client) {
    string request;
    char buffer[4096];
    // Read headers and body; cap request size to avoid unbounded memory use.
    while (request.size() < 1024 * 1024) {
        ssize_t n = recv(client, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        request.append(buffer, static_cast<size_t>(n));
        size_t headerEnd = request.find("\r\n\r\n");
        if (headerEnd != string::npos) {
            size_t contentLength = 0;
            istringstream headers(request.substr(0, headerEnd));
            string line;
            getline(headers, line);
            while (getline(headers, line)) {
                transform(line.begin(), line.end(), line.begin(), [](unsigned char c){ return static_cast<char>(tolower(c)); });
                if (line.rfind("content-length:", 0) == 0) {
                    try { contentLength = static_cast<size_t>(stoul(line.substr(15))); } catch (...) {}
                }
            }
            if (request.size() >= headerEnd + 4 + contentLength) break;
        }
    }

    size_t headerEnd = request.find("\r\n\r\n");
    if (headerEnd == string::npos) {
        string response = makeResponse(400, "{\"success\":false,\"error\":\"Malformed HTTP request.\"}", "Bad Request");
        send(client, response.c_str(), response.size(), 0);
        close(client);
        return;
    }

    istringstream firstLine(request.substr(0, request.find("\r\n")));
    string method, path, version;
    firstLine >> method >> path >> version;
    string body = request.substr(headerEnd + 4);
    string query;
    size_t qPos = path.find('?');
    if (qPos != string::npos) {
        query = path.substr(qPos + 1);
        path.resize(qPos);
    }

    string response = handleRequest(method, path, body, query);
    size_t sent = 0;
    while (sent < response.size()) {
        ssize_t n = send(client, response.data() + sent, response.size() - sent, 0);
        if (n <= 0) break;
        sent += static_cast<size_t>(n);
    }
    close(client);
}

int main(int argc, char** argv) {
    int port = 8080;
    if (argc > 1) {
        try { port = stoi(argv[1]); } catch (...) { cerr << "Invalid port.\n"; return 1; }
    }
    if (port < 1024 || port > 65535) {
        cerr << "Choose a port between 1024 and 65535.\n";
        return 1;
    }
    if (!initDB()) {
        if (db) sqlite3_close(db);
        return 1;
    }

    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) { perror("socket"); sqlite3_close(db); return 1; }
    int yes = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(static_cast<uint16_t>(port));

    if (::bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) {
        perror("bind");
        close(server);
        sqlite3_close(db);
        return 1;
    }
    if (listen(server, 10) < 0) {
        perror("listen");
        close(server);
        sqlite3_close(db);
        return 1;
    }

    cout << "Grossify Backend API is running on http://127.0.0.1:" << port << "\n"
         << "Database: grossify.db\n"
         << "Routes: GET /api/health, GET /api/products, POST /api/products,\n"
         << "        POST /api/inventory/adjust, POST /api/sync,\n"
         << "        POST /api/checkout, GET /api/bills, GET /api/bills/details\n"
         << "Press Ctrl+C to stop.\n";

    while (true) {
        sockaddr_in clientAddress{};
        socklen_t length = sizeof(clientAddress);
        int client = accept(server, reinterpret_cast<sockaddr*>(&clientAddress), &length);
        if (client < 0) { perror("accept"); continue; }
        serveClient(client);
    }

    close(server);
    sqlite3_close(db);
    return 0;
}
