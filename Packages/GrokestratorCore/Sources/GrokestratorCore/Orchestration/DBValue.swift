import Foundation

/// A single cell value that can be stored in / retrieved from the orchestration DB.
/// This is the wire/contract representation used by the `db.*` MCP tools and
/// the internal engine. It is deliberately small and Codable so it can be
/// serialized in tool arguments/results.
public enum DBValue: Codable, Sendable, Hashable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case blob(Data)
    case null

    /// Convenience for "missing / absent" in tool payloads.
    public static var nullValue: DBValue { .null }

    // MARK: - Convenience initializers from common Swift types

    public init(_ value: String) { self = .text(value) }
    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: Bool) { self = .boolean(value) }
    public init(_ value: Data) { self = .blob(value) }

    /// Returns the underlying Swift value for pattern matching or bridging.
    public var value: Any? {
        switch self {
        case .text(let v): return v
        case .integer(let v): return v
        case .real(let v): return v
        case .boolean(let v): return v
        case .blob(let v): return v
        case .null: return nil
        }
    }
}

/// A row as returned by queries and accepted by insert/update.
/// Keys are column names; values are the cell data.
public typealias DBRow = [String: DBValue]
