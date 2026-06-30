import Foundation

/// A column type supported by the orchestration workflow DB.
/// These map directly to SQLite storage classes with light validation/coercion.
public enum ColumnType: String, Codable, Sendable, CaseIterable, Hashable {
    case text
    case integer
    case real
    case boolean
    case blob
    case datetime   // stored as ISO8601 text or integer (unix seconds); validator accepts either
}

/// Definition of one column inside a `TableSchema`.
public struct Column: Codable, Sendable, Hashable {
    public var name: String
    public var type: ColumnType
    public var isRequired: Bool
    public var isUnique: Bool

    public init(
        name: String,
        type: ColumnType,
        isRequired: Bool = true,
        isUnique: Bool = false
    ) {
        self.name = name
        self.type = type
        self.isRequired = isRequired
        self.isUnique = isUnique
    }
}

/// Schema for a table that an orchestrator can register via `db.createSchema`.
/// The schema (and its registered form on disk) is the first objective "data oracle":
/// every insert/update is validated against it and rejected on violation.
public struct TableSchema: Codable, Sendable, Hashable {
    public var name: String
    public var columns: [Column]
    public var description: String?

    public init(name: String, columns: [Column], description: String? = nil) {
        self.name = name
        self.columns = columns
        self.description = description
    }

    /// Convenience lookup by column name.
    public var columnsByName: [String: Column] {
        Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
    }
}
