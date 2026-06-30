import Foundation

/// Errors surfaced by the orchestration workflow DB.
/// These are the "first oracle" failures: schema violations are the primary
/// mechanism by which bad data from agents is rejected before it can propagate.
public enum OrchestrationDBError: Error, LocalizedError, Sendable, Equatable {
    /// No table with this name has been registered via createSchema.
    case unknownTable(String)

    /// A write was rejected because it violated the registered schema.
    /// `column` may be nil for whole-row problems (e.g. unknown columns when strict).
    case schemaViolation(table: String, column: String?, reason: String)

    /// Uniqueness (or other declared constraint) violation.
    case constraintViolation(table: String, column: String?, reason: String)

    /// The DB could not be opened, a statement failed for internal reasons, etc.
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTable(let name):
            return "Unknown table '\(name)'. An orchestrator must call db.createSchema first."
        case .schemaViolation(let table, let column, let reason):
            let col = column.map { ".\($0)" } ?? ""
            return "Schema violation on '\(table)\(col)': \(reason)"
        case .constraintViolation(let table, let column, let reason):
            let col = column.map { ".\($0)" } ?? ""
            return "Constraint violation on '\(table)\(col)': \(reason)"
        case .internalError(let message):
            return "Orchestration DB internal error: \(message)"
        }
    }
}

/// The narrow public seam for the orchestration workflow database.
///
/// Orchestrators and agents interact with this **only** through the future
/// Grokestrator-hosted Orchestration MCP tools (`db.createSchema`, `db.insert`,
/// `db.query`, `db.update`, ...). Direct access is intentionally impossible.
///
/// The concrete implementation is host-local (the Mac that owns the Connections).
/// Remote clients will eventually be able to observe (read) state for inspector UIs.
public protocol OrchestrationDatabase: Sendable {
    /// Registers (or re-registers) a table schema. The schema definition itself
    /// becomes the enforceable data oracle for all subsequent writes to the table.
    ///
    /// Implementations must reject a conflicting re-definition of an existing table.
    func createSchema(name: String, schema: TableSchema) async throws

    /// Insert a row. The row is validated against the registered schema for `table`.
    /// On success returns the SQLite rowid. On any validation failure throws
    /// `OrchestrationDBError.schemaViolation` (or constraint) **without writing**.
    ///
    /// `contextID` is an optional scoping key (typically the parent orchestrator's
    /// Connection UUID or a Run ID) used for isolation between independent jobs.
    func insert(table: String, row: DBRow, contextID: String?) async throws -> Int64

    /// Query rows from a table. `predicate` is a simple equality map for Phase 3
    /// (exact column = value). Implementations may support a small set of additional
    /// operators later; start deliberately narrow.
    ///
    /// Results are returned as plain dictionaries for easy serialization into
    /// MCP tool results.
    func query(table: String, predicate: DBRow?, limit: Int?) async throws -> [DBRow]

    /// Update rows matching an optional predicate. Updated values are validated
    /// against the schema the same way inserts are. Returns number of rows changed.
    func update(table: String, values: DBRow, predicate: DBRow?) async throws -> Int

    /// Returns the names of all tables that have a registered schema.
    func listTables() async throws -> [String]

    /// Returns the authoritative schema for a table (if registered).
    func getSchema(name: String) async throws -> TableSchema?
}

// MARK: - Default convenience overloads (for call sites that don't care about context)

extension OrchestrationDatabase {
    public func insert(table: String, row: DBRow) async throws -> Int64 {
        try await insert(table: table, row: row, contextID: nil)
    }
}
