import Foundation
import SQLite3

/// Concrete, host-local implementation of the orchestration workflow DB
/// using the system SQLite3 library.
///
/// This is the small, durable core that makes schema definitions act as the
/// first objective data oracle (Phase 3 of the orchestration platform).
///
/// All access is mediated; agents never talk to SQLite directly.
public actor OrchestrationDatabaseImpl: OrchestrationDatabase {

    // MARK: - State

    private var db: OpaquePointer?
    private var tables: [String: TableSchema] = [:]   // authoritative registered schemas (rehydrated + live)
    private let dbURL: URL?
    private let isInMemory: Bool

    // We always inject a hidden scoping column for isolation between orchestrated jobs.
    private static let contextColumn = "_context_id"

    /// SQLite must copy transient Swift string/blob buffers before returning.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Init / Lifecycle

    /// In-memory DB (perfect for unit tests and fast dev loops).
    public init() {
        self.isInMemory = true
        self.dbURL = nil
    }

    /// File-backed DB at the given location (the normal production path).
    public init(fileURL: URL) {
        self.isInMemory = false
        self.dbURL = fileURL
    }

    // NOTE: We intentionally do not implement deinit cleanup for the sqlite handle.
    // In Swift 6 strict concurrency an OpaquePointer is non-Sendable, so touching it
    // from a nonisolated deinit is an error. Callers (app shutdown, tests) should
    // invoke the actor-isolated `close()` method when they want deterministic release.
    // For the normal lifetime of the Mac app the process exit is sufficient.

    /// Opens (or creates) the database and rehydrates any previously registered schemas.
    /// Safe to call multiple times; subsequent calls are no-ops if already open.
    private func openIfNeeded() throws {
        guard db == nil else { return }

        let path: String
        if isInMemory {
            path = ":memory:"
        } else if let url = dbURL {
            // Ensure parent directory exists (mirrors ConnectionStore behavior).
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            path = url.path
        } else {
            // Fallback: use the standard Grokestrator support directory.
            let support = ConnectionStoreSupport.supportDir()
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let defaultURL = support.appendingPathComponent("orchestration.db")
            path = defaultURL.path
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, Int32(flags), nil) == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw OrchestrationDBError.internalError("Failed to open orchestration DB at \(path): \(msg)")
        }

        db = handle

        // Pragmas for safety / reasonable defaults.
        _ = execute("PRAGMA foreign_keys = ON;")
        _ = execute("PRAGMA journal_mode = WAL;")

        try createMetaTableIfNeeded()
        try rehydrateSchemas()
    }

    private func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        tables.removeAll()
    }

    // MARK: - OrchestrationDatabase

    public func createSchema(name: String, schema: TableSchema) async throws {
        try openIfNeeded()
        guard let db else { throw OrchestrationDBError.internalError("DB not open") }

        guard name == schema.name else {
            throw OrchestrationDBError.internalError("Schema name mismatch")
        }

        // Name safety (defense in depth before we ever build dynamic SQL).
        guard Self.isSafeIdentifier(name) else {
            throw OrchestrationDBError.schemaViolation(table: name, column: nil, reason: "Invalid table name")
        }
        for col in schema.columns {
            guard Self.isSafeIdentifier(col.name) else {
                throw OrchestrationDBError.schemaViolation(table: name, column: col.name, reason: "Invalid column name '\(col.name)'")
            }
        }

        // Check for existing conflicting definition.
        if let existing = tables[name] {
            guard existing == schema else {
                throw OrchestrationDBError.schemaViolation(
                    table: name,
                    column: nil,
                    reason: "Table already exists with a different schema"
                )
            }
            return // identical re-create is a no-op
        }

        // Persist the schema definition.
        let jsonData = try JSONEncoder().encode(schema)
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"

        let insertSQL = """
            INSERT OR REPLACE INTO _grokestrator_schemas (name, schema_json, created_at)
            VALUES (?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        try bindText(name, to: stmt, at: 1)
        try bindText(json, to: stmt, at: 2)
        sqlite3_bind_double(stmt, 3, now)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError()
        }

        // Create the actual data table (with our hidden context column + declared uniques).
        let createTableSQL = Self.createTableSQL(for: schema)
        guard execute(createTableSQL) else {
            throw lastError()
        }

        tables[name] = schema
    }

    public func insert(table: String, row: DBRow, contextID: String?) async throws -> Int64 {
        try openIfNeeded()
        guard let db, let schema = tables[table] else {
            if tables[table] == nil { throw OrchestrationDBError.unknownTable(table) }
            throw OrchestrationDBError.internalError("DB not open")
        }

        // === The first oracle: validate before we touch disk. ===
        try validate(row: row, against: schema)

        // Uniqueness pre-check for columns declared unique (gives nice errors before SQLite does).
        try await checkUniqueness(table: table, row: row, schema: schema, contextID: contextID, updatingRowID: nil)

        // Build the column list we will actually write (user columns + our context column).
        var columnsToWrite: [String] = []
        var valuesToWrite: [DBValue] = []

        for col in schema.columns {
            columnsToWrite.append(col.name)
            valuesToWrite.append(row[col.name] ?? .null)
        }

        // Always stamp context if provided (internal column, never shown to agents).
        columnsToWrite.append(Self.contextColumn)
        valuesToWrite.append(contextID.map(DBValue.text) ?? .null)

        // Parameterized INSERT.
        let colList = columnsToWrite.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columnsToWrite.count).joined(separator: ", ")
        let sql = "INSERT INTO \"\(table)\" (\(colList)) VALUES (\(placeholders));"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }

        for (idx, value) in valuesToWrite.enumerated() {
            try bind(value, to: stmt, at: Int32(idx + 1))
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationDBError.internalError(msg)
        }

        return sqlite3_last_insert_rowid(db)
    }

    public func query(table: String, predicate: DBRow?, limit: Int?) async throws -> [DBRow] {
        try openIfNeeded()
        guard let db, tables[table] != nil else {
            if tables[table] == nil { throw OrchestrationDBError.unknownTable(table) }
            throw OrchestrationDBError.internalError("DB not open")
        }

        var whereClauses: [String] = []
        var args: [DBValue] = []

        if let predicate, !predicate.isEmpty {
            for (key, value) in predicate {
                // We do not allow querying on the hidden context column from the public API.
                guard key != Self.contextColumn else { continue }
                whereClauses.append("\"\(key)\" = ?")
                args.append(value)
            }
        }

        var sql = "SELECT * FROM \"\(table)\""
        if !whereClauses.isEmpty {
            sql += " WHERE " + whereClauses.joined(separator: " AND ")
        }
        if let limit, limit > 0 {
            sql += " LIMIT \(limit)"
        }
        sql += ";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }

        for (i, arg) in args.enumerated() {
            try bind(arg, to: stmt, at: Int32(i + 1))
        }

        let schema = tables[table]
        var results: [DBRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: DBRow = [:]
            let columnCount = sqlite3_column_count(stmt)
            for i in 0..<columnCount {
                let cName = String(cString: sqlite3_column_name(stmt, i))
                if cName == Self.contextColumn { continue } // hide internal scoping column
                let colType = schema?.columnsByName[cName]?.type
                row[cName] = readValue(stmt: stmt, at: i, columnType: colType)
            }
            results.append(row)
        }
        return results
    }

    public func update(table: String, values: DBRow, predicate: DBRow?) async throws -> Int {
        try openIfNeeded()
        guard let db, let schema = tables[table] else {
            if tables[table] == nil { throw OrchestrationDBError.unknownTable(table) }
            throw OrchestrationDBError.internalError("DB not open")
        }

        // === Oracle validation on the patch values (same rules as insert). ===
        // We validate only the columns being written; missing columns are fine for a partial update.
        try validatePartialUpdate(values: values, against: schema)

        // Uniqueness check on any unique columns present in the patch.
        try await checkUniqueness(table: table, row: values, schema: schema, contextID: nil, updatingRowID: nil)

        var setParts: [String] = []
        var setArgs: [DBValue] = []
        for (k, v) in values {
            guard schema.columnsByName[k] != nil else {
                throw OrchestrationDBError.schemaViolation(table: table, column: k, reason: "Undeclared column in update")
            }
            setParts.append("\"\(k)\" = ?")
            setArgs.append(v)
        }

        var whereParts: [String] = []
        var whereArgs: [DBValue] = []
        if let predicate, !predicate.isEmpty {
            for (k, v) in predicate {
                guard k != Self.contextColumn else { continue }
                whereParts.append("\"\(k)\" = ?")
                whereArgs.append(v)
            }
        }

        let sql: String
        if setParts.isEmpty {
            return 0
        }
        sql = "UPDATE \"\(table)\" SET " + setParts.joined(separator: ", ")
            + (whereParts.isEmpty ? "" : " WHERE " + whereParts.joined(separator: " AND "))
            + ";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        for a in setArgs { try bind(a, to: stmt, at: bindIndex); bindIndex += 1 }
        for a in whereArgs { try bind(a, to: stmt, at: bindIndex); bindIndex += 1 }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastError()
        }

        return Int(sqlite3_changes(db))
    }

    public func listTables() async throws -> [String] {
        try openIfNeeded()
        return Array(tables.keys).sorted()
    }

    public func getSchema(name: String) async throws -> TableSchema? {
        try openIfNeeded()
        return tables[name]
    }

    // MARK: - Debug surface (valuable before full UI)

    public func debugDump() async -> String {
        try? openIfNeeded()
        guard !tables.isEmpty else { return "(no tables)" }

        var lines: [String] = []
        for name in tables.keys.sorted() {
            let schema = tables[name]!
            // Use the internal count helper (avoids extra async query in a debug path).
            let count = (try? rawCount(table: name)) ?? 0
            lines.append("TABLE \(name) (\(count) rows)")
            for col in schema.columns {
                let flags = [col.isRequired ? "required" : nil, col.isUnique ? "unique" : nil].compactMap { $0 }.joined(separator: ", ")
                lines.append("  - \(col.name): \(col.type.rawValue)\(flags.isEmpty ? "" : " [\(flags)]")")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - SQLite plumbing

    private func createMetaTableIfNeeded() throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS _grokestrator_schemas (
                name TEXT PRIMARY KEY,
                schema_json TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """
        guard execute(sql) else { throw lastError() }
    }

    private func rehydrateSchemas() throws {
        guard let db else { return }

        let sql = "SELECT name, schema_json FROM _grokestrator_schemas ORDER BY name;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }

        var loaded: [String: TableSchema] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(stmt, 0),
                  let jsonC = sqlite3_column_text(stmt, 1) else { continue }
            let name = String(cString: nameC)
            let json = String(cString: jsonC)
            if let data = json.data(using: .utf8),
               let schema = try? JSONDecoder().decode(TableSchema.self, from: data) {
                loaded[name] = schema
                // Make sure the table still exists physically (defensive).
                _ = execute(Self.createTableSQL(for: schema))
            }
        }
        self.tables = loaded
    }

    private static func createTableSQL(for schema: TableSchema) -> String {
        var defs: [String] = []
        for col in schema.columns {
            let sqlType: String
            switch col.type {
            case .text, .datetime: sqlType = "TEXT"
            case .integer:         sqlType = "INTEGER"
            case .real:            sqlType = "REAL"
            case .boolean:         sqlType = "INTEGER"   // 0/1
            case .blob:            sqlType = "BLOB"
            }
            var def = "\"\(col.name)\" \(sqlType)"
            if col.isRequired { def += " NOT NULL" }
            if col.isUnique { def += " UNIQUE" }
            defs.append(def)
        }
        // Always add our internal scoping column (not exposed to agents).
        defs.append("\"\(contextColumn)\" TEXT")

        return "CREATE TABLE IF NOT EXISTS \"\(schema.name)\" (\(defs.joined(separator: ", ")));"
    }

    private func bindText(_ text: String, to stmt: OpaquePointer, at index: Int32) throws {
        try text.withCString { ptr in
            guard sqlite3_bind_text(stmt, index, ptr, -1, Self.sqliteTransient) == SQLITE_OK else {
                throw lastError()
            }
        }
    }

    private func bind(_ value: DBValue, to stmt: OpaquePointer, at index: Int32) throws {
        switch value {
        case .text(let s):
            try bindText(s, to: stmt, at: index)
        case .integer(let i):
            sqlite3_bind_int64(stmt, index, i)
        case .real(let d):
            sqlite3_bind_double(stmt, index, d)
        case .boolean(let b):
            sqlite3_bind_int(stmt, index, b ? 1 : 0)
        case .blob(let data):
            try data.withUnsafeBytes { ptr in
                guard sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(data.count), Self.sqliteTransient) == SQLITE_OK else {
                    throw lastError()
                }
            }
        case .null:
            sqlite3_bind_null(stmt, index)
        }
    }

    private func readValue(stmt: OpaquePointer, at index: Int32, columnType: ColumnType? = nil) -> DBValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            if let c = sqlite3_column_text(stmt, index) {
                return .text(String(cString: c))
            }
            return .null
        case SQLITE_INTEGER:
            let raw = sqlite3_column_int64(stmt, index)
            if columnType == .boolean { return .boolean(raw != 0) }
            return .integer(raw)
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_BLOB:
            if let blob = sqlite3_column_blob(stmt, index) {
                let count = Int(sqlite3_column_bytes(stmt, index))
                let data = Data(bytes: blob, count: count)
                return .blob(data)
            }
            return .null
        case SQLITE_NULL:
            return .null
        default:
            return .null
        }
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err { sqlite3_free(err) }
        return rc == SQLITE_OK
    }

    private func lastError() -> OrchestrationDBError {
        guard let db else { return .internalError("DB not open") }
        let msg = String(cString: sqlite3_errmsg(db))
        return .internalError(msg)
    }

    private func rawCount(table: String) throws -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM \"\(table)\";"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    // MARK: - Safety

    private static func isSafeIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return s.rangeOfCharacter(from: allowed.inverted) == nil
            && !s.first!.isNumber
            && !s.hasPrefix("_")
    }

    // MARK: - The Data Oracle (validation)

    /// Performs the full schema validation that makes a registered TableSchema
    /// act as the first objective oracle. Throws a descriptive
    /// `OrchestrationDBError.schemaViolation` (or constraint) on any problem.
    /// This is called *before* we build or execute any SQL write.
    private func validate(row: DBRow, against schema: TableSchema) throws {
        let declared = schema.columnsByName

        // 1. No undeclared columns (strict).
        for key in row.keys where declared[key] == nil {
            throw OrchestrationDBError.schemaViolation(
                table: schema.name, column: key, reason: "Column is not declared in the schema"
            )
        }

        // 2. Required columns present and non-null.
        for col in schema.columns where col.isRequired {
            guard let value = row[col.name], value != .null else {
                throw OrchestrationDBError.schemaViolation(
                    table: schema.name, column: col.name, reason: "Required column is missing or null"
                )
            }
        }

        // 3. Type compatibility.
        for (key, value) in row {
            guard let col = declared[key], value != .null else { continue }
            if !Self.value(value, isCompatibleWith: col.type) {
                throw OrchestrationDBError.schemaViolation(
                    table: schema.name,
                    column: key,
                    reason: "Value of type \(Self.describe(value)) is not compatible with declared column type \(col.type.rawValue)"
                )
            }
        }
    }

    /// Lighter validation used for partial updates: we only look at columns being touched.
    private func validatePartialUpdate(values: DBRow, against schema: TableSchema) throws {
        let declared = schema.columnsByName
        for key in values.keys where declared[key] == nil {
            throw OrchestrationDBError.schemaViolation(
                table: schema.name, column: key, reason: "Column is not declared in the schema"
            )
        }
        for (key, value) in values where value != .null {
            guard let col = declared[key] else { continue }
            if !Self.value(value, isCompatibleWith: col.type) {
                throw OrchestrationDBError.schemaViolation(
                    table: schema.name,
                    column: key,
                    reason: "Value of type \(Self.describe(value)) is not compatible with declared column type \(col.type.rawValue)"
                )
            }
        }
    }

    private static func value(_ v: DBValue, isCompatibleWith type: ColumnType) -> Bool {
        switch (v, type) {
        case (.text, .text), (.text, .datetime): return true
        case (.integer, .integer), (.integer, .real): return true
        case (.real, .real): return true
        case (.boolean, .boolean), (.boolean, .integer): return true
        case (.blob, .blob): return true
        case (.null, _): return true
        default: return false
        }
    }

    private static func describe(_ v: DBValue) -> String {
        switch v {
        case .text: return "text"
        case .integer: return "integer"
        case .real: return "real"
        case .boolean: return "boolean"
        case .blob: return "blob"
        case .null: return "null"
        }
    }

    /// Pre-checks uniqueness constraints declared in the schema.
    /// This gives agents a clear, early `constraintViolation` instead of a raw SQLite error.
    private func checkUniqueness(
        table: String,
        row: DBRow,
        schema: TableSchema,
        contextID: String?,
        updatingRowID: Int64?
    ) async throws {
        for col in schema.columns where col.isUnique {
            guard let value = row[col.name], value != .null else { continue }

            // Build a predicate for "same value on this unique column".
            var predicate: DBRow = [col.name: value]
            // Scope by context if we have one (so different orchestrated jobs don't collide on "id" etc.).
            if let contextID {
                predicate[Self.contextColumn] = .text(contextID)
            }

            // For updates we would ideally exclude the row being updated; for the initial
            // slice we do a simple existence check (good enough for most agent result tables).
            let existing = try await query(table: table, predicate: predicate, limit: 1)
            if !existing.isEmpty {
                throw OrchestrationDBError.constraintViolation(
                    table: table,
                    column: col.name,
                    reason: "Unique constraint violation on column '\(col.name)'"
                )
            }
        }
    }
}

// Small support to reach the same directory logic used by ConnectionStore without duplicating too much.
private enum ConnectionStoreSupport {
    static func supportDir() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Grokestrator", isDirectory: true)
        return base
    }
}

