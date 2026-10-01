import Foundation
import NIOCore
import SQLiteNIO

/// What each fixture holds. SQLite has no first-party driver of ours: statements go through
/// sqlite-nio, as the owner decided.
enum SQLiteFixtures {
    static func allTypes(_ connection: SQLiteConnection) async throws {
        let columns: [(name: String, type: String)] = [
            ("integer_col", "INTEGER"), ("real_col", "REAL"), ("text_col", "TEXT"), ("blob_col", "BLOB"), ("numeric_col", "NUMERIC"),
            ("int_col", "INT"), ("bigint_col", "BIGINT"), ("tinyint_col", "TINYINT"), ("varchar_col", "VARCHAR(255)"),
            ("nvarchar_col", "NVARCHAR(100)"), ("char_col", "CHAR(10)"), ("clob_col", "CLOB"), ("double_col", "DOUBLE PRECISION"),
            ("float_col", "FLOAT"), ("decimal_col", "DECIMAL(10,5)"), ("boolean_col", "BOOLEAN"), ("date_col", "DATE"),
            ("datetime_col", "DATETIME"), ("timestamp_col", "TIMESTAMP"), ("json_col", "JSON"), ("uuid_col", "UUID"),
            ("untyped_col", ""),
        ]
        _ = try await connection.query("CREATE TABLE all_types (id INTEGER PRIMARY KEY, "
            + columns.map { "\($0.name) \($0.type)".trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") + ")")
        let insert = "INSERT INTO all_types (" + columns.map(\.name).joined(separator: ", ") + ") VALUES ("
            + columns.map { _ in "?" }.joined(separator: ", ") + ")"
        func blob(_ count: Int, _ byte: UInt8) -> SQLiteData { .blob(ByteBuffer(bytes: [UInt8](repeating: byte, count: count))) }
        let minimum: [SQLiteData] = [.integer(.min), .float(-1.7976931348623157e308), .text(""), blob(0, 0), .text("-99999999999999999999.99999"),
                                     .integer(Int(Int32.min)), .integer(.min), .integer(0), .text(""), .text(""), .text(""), .text(""),
                                     .float(-Double.greatestFiniteMagnitude), .float(-3.4e38), .text("-99999.99999"), .integer(0),
                                     .text("0001-01-01"), .text("0001-01-01 00:00:00"), .integer(0), .text("{}"),
                                     .text("00000000-0000-0000-0000-000000000000"), .integer(0)]
        let maximum: [SQLiteData] = [.integer(.max), .float(1.7976931348623157e308), .text(String(repeating: "Ωé😀", count: 20_000)),
                                     blob(65_536, 0xFF), .text("99999999999999999999.99999"), .integer(Int(Int32.max)), .integer(.max),
                                     .integer(255), .text(String(repeating: "v", count: 255)), .text(String(repeating: "ñ", count: 100)),
                                     .text("ZZZZZZZZZZ"), .text(String(repeating: "Long text. ", count: 100_000)),
                                     .float(Double.greatestFiniteMagnitude), .float(3.4e38), .text("99999.99999"), .integer(1),
                                     .text("9999-12-31"), .text("9999-12-31 23:59:59.999"), .integer(253_402_300_799),
                                     .text(#"{"a":[1,2,{"b":null}],"s":"é","n":1.5e10}"#), .text("ffffffff-ffff-ffff-ffff-ffffffffffff"),
                                     .text("text in an untyped column")]
        _ = try await connection.query(insert, minimum)
        _ = try await connection.query(insert, maximum)
        _ = try await connection.query(insert, columns.map { _ in SQLiteData.null })
        for index in 0..<200 {
            // The untyped column takes integer, real, text and blob values in turn.
            let untyped: SQLiteData = [.integer(index), .float(Double(index) + 0.5), .text("row \(index)"), blob(4, UInt8(index % 256))][index % 4]
            let row: [SQLiteData] = [.integer(index), .float(Double(index) / 3), .text("row \(index)"), blob(index % 32, UInt8(index % 256)),
                                     .text("\(index).25"), .integer(index), .integer(index * 1_000_000_007), .integer(index % 256),
                                     .text("v\(index)"), .text("n\(index)"), .text("c\(index % 10)"), .text("clob \(index)"),
                                     .float(Double(index) * 1.5), .float(Double(index) * 0.25), .text("\(index).12345"), .integer(index % 2),
                                     .text(String(format: "2024-%02d-%02d", index % 12 + 1, index % 28 + 1)),
                                     .text(String(format: "2024-01-01 %02d:00:00", index % 24)), .integer(1_700_000_000 + index),
                                     .text("{\"row\":\(index)}"), .text(UUID().uuidString), untyped]
            _ = try await connection.query(insert, row)
        }
        _ = try await connection.query("""
            CREATE TABLE strict_types (id INTEGER PRIMARY KEY, int_col INT NOT NULL, integer_col INTEGER, real_col REAL,
            text_col TEXT, blob_col BLOB, any_col ANY) STRICT
            """)
        for index in 0..<50 {
            let any: SQLiteData = [.integer(index), .float(Double(index)), .text("any \(index)"), .null][index % 4]
            _ = try await connection.query("INSERT INTO strict_types (int_col, integer_col, real_col, text_col, blob_col, any_col) VALUES (?, ?, ?, ?, ?, ?)",
                                           [.integer(index), .integer(-index), .float(Double(index) / 7), .text("strict \(index)"),
                                            .blob(ByteBuffer(bytes: [UInt8(index)])), any])
        }
    }

    static func programmability(_ connection: SQLiteConnection) async throws {
        let statements = [
            "PRAGMA foreign_keys = ON",
            """
            CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL COLLATE NOCASE, email TEXT UNIQUE,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)))
            """,
            """
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
            amount REAL NOT NULL CHECK (amount >= 0), status TEXT NOT NULL DEFAULT 'open',
            total_with_tax REAL GENERATED ALWAYS AS (amount * 1.25) VIRTUAL,
            amount_cents INTEGER GENERATED ALWAYS AS (CAST(amount * 100 AS INTEGER)) STORED)
            """,
            "CREATE TABLE audit_log (id INTEGER PRIMARY KEY, action TEXT NOT NULL, order_id INTEGER, logged_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
            "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID",
            "CREATE INDEX ix_orders_customer ON orders (customer_id)",
            "CREATE UNIQUE INDEX ux_customers_name_email ON customers (name, email)",
            "CREATE INDEX ix_orders_open ON orders (customer_id) WHERE status = 'open'",
            "CREATE INDEX ix_customers_lower_email ON customers (lower(email))",
            "CREATE INDEX ix_orders_amount_desc ON orders (amount DESC)",
            "CREATE VIEW open_orders AS SELECT o.id, c.name, o.amount, o.total_with_tax FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.status = 'open'",
            "CREATE TRIGGER orders_audit AFTER INSERT ON orders BEGIN INSERT INTO audit_log (action, order_id) VALUES ('insert', NEW.id); END",
            "CREATE TRIGGER customers_keep_active BEFORE DELETE ON customers WHEN OLD.active = 1 BEGIN SELECT RAISE(ABORT, 'deactivate the customer first'); END",
            "CREATE VIRTUAL TABLE documents USING fts5 (title, body)",
        ]
        for statement in statements { _ = try await connection.query(statement) }
        // R*Tree is a compile-time option; add it when this SQLite has it.
        let options = try await connection.query("PRAGMA compile_options").compactMap { $0.column("compile_options")?.string }
        if options.contains("ENABLE_RTREE") {
            _ = try await connection.query("CREATE VIRTUAL TABLE places USING rtree (id, min_x, max_x, min_y, max_y)")
            _ = try await connection.query("INSERT INTO places VALUES (1, 0, 10, 0, 10), (2, 5, 15, 5, 15)")
        }
        for index in 1...20 {
            _ = try await connection.query("INSERT INTO customers (name, email, active) VALUES (?, ?, ?)",
                                           [.text("Customer \(index)"), .text("customer\(index)@example.com"), .integer(index % 5 == 0 ? 0 : 1)])
        }
        for index in 1...100 {
            _ = try await connection.query("INSERT INTO orders (customer_id, amount, status) VALUES (?, ?, ?)",
                                           [.integer(index % 20 + 1), .float(Double(index) + 0.5), .text(index % 3 == 0 ? "shipped" : "open")])
        }
        _ = try await connection.query("INSERT INTO settings (key, value) VALUES ('theme', 'dark'), ('page_size', '50')")
        _ = try await connection.query("INSERT INTO documents (title, body) VALUES ('SQLite', 'A small fast database'), ('FTS5', 'Full-text search for SQLite')")
    }

    /// Runs a plain SQL script: statements end at a semicolon outside quotes and comments (the
    /// samples have no triggers, whose bodies would need more).
    static func wal(_ connection: SQLiteConnection) async throws {
        _ = try await connection.query("PRAGMA journal_mode = WAL")
        _ = try await connection.query("CREATE TABLE journal_entries (id INTEGER PRIMARY KEY, note TEXT NOT NULL)")
        for index in 1...100 {
            _ = try await connection.query("INSERT INTO journal_entries (note) VALUES (?)", [.text("entry \(index)")])
        }
    }

    static func edgeNames(_ connection: SQLiteConnection) async throws {
        for statement in [
            #"CREATE TABLE "Order Details" ("Order ID" INTEGER PRIMARY KEY, "Unit Price" REAL, "Quantity" INTEGER)"#,
            #"CREATE TABLE "select" ("from" TEXT, "where" TEXT, "group" INTEGER)"#,
            #"CREATE TABLE "it's ""quoted""" ("col with 'quote'" TEXT, "col""double" TEXT)"#,
            #"CREATE TABLE "Café ☕️ 数据" ("名前" TEXT, "émoji 🎉" TEXT)"#,
            #"CREATE TABLE "MixedCase" ("ID" INTEGER, "id2" INTEGER, "Id3" INTEGER)"#,
            #"CREATE INDEX "idx on spaces" ON "Order Details" ("Unit Price")"#,
            #"CREATE VIEW "view of select" AS SELECT "from", "where" FROM "select""#,
            #"INSERT INTO "Order Details" VALUES (1, 9.5, 3), (2, 0.25, 10)"#,
            #"INSERT INTO "select" VALUES ('a', 'b', 1)"#,
            #"INSERT INTO "it's ""quoted""" VALUES ('x', 'y')"#,
            #"INSERT INTO "Café ☕️ 数据" VALUES ('山田', '🎉🎉')"#,
            #"INSERT INTO "MixedCase" VALUES (1, 2, 3)"#,
        ] {
            _ = try await connection.query(statement)
        }
    }

    static func wide(_ connection: SQLiteConnection) async throws {
        // 2,000 columns including the key: SQLITE_MAX_COLUMN's default.
        let columns = (1..<2000).map { "c\($0) INTEGER" }.joined(separator: ", ")
        _ = try await connection.query("CREATE TABLE wide_table (id INTEGER PRIMARY KEY, \(columns))")
        _ = try await connection.query("INSERT INTO wide_table (id, c1, c999, c1999) VALUES (1, 1, 999, 1999)")
    }

    static func large(_ connection: SQLiteConnection, rows: Int) async throws {
        _ = try await connection.query("CREATE TABLE readings (id INTEGER PRIMARY KEY, sensor TEXT NOT NULL, value REAL NOT NULL, taken_at TEXT NOT NULL)")
        _ = try await connection.query("BEGIN")
        let batch = 500
        for start in stride(from: 0, to: rows, by: batch) {
            let count = min(batch, rows - start)
            let placeholders = Array(repeating: "(?, ?, ?)", count: count).joined(separator: ", ")
            let values: [SQLiteData] = (start..<start + count).flatMap { index -> [SQLiteData] in
                [.text("sensor-\(index % 50)"), .float(Double(index % 1000) / 10), .text("2026-01-01T00:\(String(format: "%02d", index % 60)):00Z")]
            }
            _ = try await connection.query("INSERT INTO readings (sensor, value, taken_at) VALUES \(placeholders)", values)
        }
        _ = try await connection.query("COMMIT")
        _ = try await connection.query("CREATE INDEX readings_sensor ON readings (sensor)")
    }

    /// Overwrites the middle of the file (table pages, past the schema page) so reading fails.
    static func damage(_ file: URL) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size / 2)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 8192))
    }

    static func run(script: String, on connection: SQLiteConnection) async throws {
        var statement = ""
        var quote: Character?
        var lineComment = false, blockComment = false
        var previous: Character = " "
        for character in script.replacingOccurrences(of: "\r\n", with: "\n") {
            if lineComment { if character == "\n" { lineComment = false }; previous = character; continue }
            if blockComment { if previous == "*" && character == "/" { blockComment = false; previous = " "; continue }; previous = character; continue }
            if let open = quote {
                statement.append(character)
                if character == open { quote = nil }
            } else if character == "-" && previous == "-" {
                statement.removeLast()
                lineComment = true
            } else if character == "*" && previous == "/" {
                statement.removeLast()
                blockComment = true
            } else if character == ";" {
                let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { _ = try await connection.query(trimmed) }
                statement = ""
            } else {
                if character == "'" || character == "\"" { quote = character }
                statement.append(character)
            }
            previous = character
        }
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { _ = try await connection.query(trimmed) }
    }
}
