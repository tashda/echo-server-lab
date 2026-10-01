import MySQLKit
import MySQLWire
import ServerLabKit
import ServerLabTesting
import Testing

func expectEveryPartitioningMethod(_ server: LabServer) async throws {
    let client = mysqlClient(server, .required)
    defer { Task { await client.close() } }
    let methods = try await ["sales_by_year", "sales_by_day", "sales_by_region", "sales_hashed", "sales_keyed"].asyncMap {
        Set(try await client.metadata.listPartitions(schema: "labdata", table: $0).map(\.method))
    }
    #expect(methods == [["RANGE"], ["RANGE COLUMNS"], ["LIST"], ["HASH"], ["KEY"]])
    let year = try await client.metadata.listPartitions(schema: "labdata", table: "sales_by_year")
    #expect(year.map(\.description) == ["2024", "2025", "2026", "MAXVALUE"])
    #expect(try await client.metadata.exactRowCount(schema: "labdata", table: "sales_by_region") == 120)
}

@Suite(.enabled(if: integrationEnabled), .server("mysql-8.4-partitioning"))
struct MySQLPartitioningServerTests {
    @Test func serverHoldsEveryPartitioningMethod() async throws {
        try await expectEveryPartitioningMethod(try #require(LabServer.current))
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mariadb-11.4-partitioning"))
struct MariaDBPartitioningServerTests {
    @Test func serverHoldsEveryPartitioningMethod() async throws {
        try await expectEveryPartitioningMethod(try #require(LabServer.current))
    }
}

@Suite(.enabled(if: integrationEnabled), .server("mariadb-11.4-temporal"))
struct MariaDBTemporalServerTests {
    @Test func versionedTableAndSequencesAreThere() async throws {
        let client = mysqlClient(try #require(LabServer.current), .required)
        defer { Task { await client.close() } }
        #expect(try await client.metadata.listSystemVersionedTables(schema: "labdata") == ["prices"])
        #expect(Set(try await client.metadata.listSequences(schema: "labdata")) == ["order_numbers", "ticket_wheel"])
        // The current rows only: one of the twenty was deleted (it stays in the history).
        #expect(try await client.metadata.exactRowCount(schema: "labdata", table: "prices") == 19)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
