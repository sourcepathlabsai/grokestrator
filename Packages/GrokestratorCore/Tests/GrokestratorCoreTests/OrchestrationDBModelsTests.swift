import XCTest
@testable import GrokestratorCore

final class OrchestrationDBModelsTests: XCTestCase {

    func testTableSchemaRoundtrip() throws {
        let schema = TableSchema(
            name: "sales",
            columns: [
                Column(name: "id", type: .integer, isRequired: true, isUnique: true),
                Column(name: "amount", type: .real, isRequired: true),
                Column(name: "note", type: .text, isRequired: false),
                Column(name: "captured_at", type: .datetime, isRequired: true)
            ],
            description: "Daily sales captured by the POS agent"
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(TableSchema.self, from: data)

        XCTAssertEqual(decoded, schema)
        XCTAssertEqual(decoded.columnsByName["amount"]?.type, .real)
    }

    func testDBValueVariantsRoundtrip() throws {
        let values: [DBValue] = [
            .text("hello"),
            .integer(42),
            .real(3.14159),
            .boolean(true),
            .blob(Data([0xDE, 0xAD, 0xBE, 0xEF])),
            .null
        ]

        for v in values {
            let data = try JSONEncoder().encode(v)
            let decoded = try JSONDecoder().decode(DBValue.self, from: data)
            XCTAssertEqual(decoded, v)
        }
    }

    func testDBRowAsToolPayloadShape() throws {
        // This shape is what we expect to serialize into MCP tool call arguments
        // and results for db.insert / db.query.
        let row: DBRow = [
            "id": .integer(7),
            "customer": .text("alice"),
            "total": .real(129.99),
            "paid": .boolean(true),
            "notes": .null
        ]

        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(DBRow.self, from: data)

        XCTAssertEqual(decoded["total"], .real(129.99))
        XCTAssertEqual(decoded["notes"], .null)
    }

    func testOrchestrationDBErrorDescriptions() {
        let err1 = OrchestrationDBError.unknownTable("tasks")
        XCTAssertTrue(err1.localizedDescription.contains("tasks"))

        let err2 = OrchestrationDBError.schemaViolation(
            table: "orders",
            column: "qty",
            reason: "value must be positive integer"
        )
        XCTAssertTrue(err2.localizedDescription.contains("orders.qty"))
        XCTAssertTrue(err2.localizedDescription.contains("positive"))
    }
}
