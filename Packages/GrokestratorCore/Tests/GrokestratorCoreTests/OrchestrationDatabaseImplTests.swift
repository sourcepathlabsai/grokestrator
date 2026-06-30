import XCTest
@testable import GrokestratorCore

final class OrchestrationDatabaseImplTests: XCTestCase {

    private func makeDB() -> OrchestrationDatabaseImpl {
        OrchestrationDatabaseImpl()
    }

    private func tasksSchema() -> TableSchema {
        TableSchema(
            name: "tasks",
            columns: [
                Column(name: "id", type: .integer, isRequired: true, isUnique: true),
                Column(name: "title", type: .text, isRequired: true),
                Column(name: "done", type: .boolean, isRequired: false),
            ]
        )
    }

    func testCreateSchemaAndInsertQuery() async throws {
        let db = makeDB()
        let schema = tasksSchema()
        try await db.createSchema(name: "tasks", schema: schema)

        let rowID = try await db.insert(table: "tasks", row: [
            "id": .integer(1),
            "title": .text("Ship run view"),
            "done": .boolean(false),
        ], contextID: "orch-1")

        XCTAssertGreaterThan(rowID, 0)

        let rows = try await db.query(table: "tasks", predicate: ["id": .integer(1)], limit: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["title"], .text("Ship run view"))
    }

    func testSchemaViolationRejectsBadInsert() async throws {
        let db = makeDB()
        try await db.createSchema(name: "tasks", schema: tasksSchema())

        do {
            _ = try await db.insert(table: "tasks", row: [
                "id": .integer(1),
                "title": .text("ok"),
                "extra": .text("nope"),
            ])
            XCTFail("expected schema violation")
        } catch let err as OrchestrationDBError {
            if case .schemaViolation(let table, let column, _) = err {
                XCTAssertEqual(table, "tasks")
                XCTAssertEqual(column, "extra")
            } else {
                XCTFail("wrong error: \(err)")
            }
        }
    }

    func testUniqueConstraintViolation() async throws {
        let db = makeDB()
        try await db.createSchema(name: "tasks", schema: tasksSchema())

        _ = try await db.insert(table: "tasks", row: [
            "id": .integer(1),
            "title": .text("first"),
        ])

        do {
            _ = try await db.insert(table: "tasks", row: [
                "id": .integer(1),
                "title": .text("duplicate id"),
            ])
            XCTFail("expected constraint violation")
        } catch let err as OrchestrationDBError {
            if case .constraintViolation = err { /* ok */ }
            else { XCTFail("wrong error: \(err)") }
        }
    }

    func testUpdateChangesRows() async throws {
        let db = makeDB()
        try await db.createSchema(name: "tasks", schema: tasksSchema())
        _ = try await db.insert(table: "tasks", row: ["id": .integer(1), "title": .text("a")])

        let changed = try await db.update(
            table: "tasks",
            values: ["done": .boolean(true)],
            predicate: ["id": .integer(1)]
        )
        XCTAssertEqual(changed, 1)

        let rows = try await db.query(table: "tasks", predicate: ["id": .integer(1)], limit: nil)
        XCTAssertEqual(rows[0]["done"], .boolean(true))
    }

    func testListTables() async throws {
        let db = makeDB()
        try await db.createSchema(name: "tasks", schema: tasksSchema())
        let tables = try await db.listTables()
        XCTAssertEqual(tables, ["tasks"])
    }
}