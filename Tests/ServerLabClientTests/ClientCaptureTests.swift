import Foundation
import PostgresKit
import ServerLabClient
import Testing

/// ServerLabClient drives the serverlab tool. Run with SERVERLAB_INTEGRATION=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SERVERLAB_INTEGRATION"] == "1"), .server("pg-17-empty", capture: true))
struct ClientCaptureTests {
    @Test func serverAndCaptureThroughTheTool() async throws {
        let server = try #require(LabServer.current)
        let wire = try #require(LabWire.current)
        #expect(server.isPostgres)
        let client = try await PostgresClient.connect(configuration: PostgresConfiguration(
            host: server.host, port: server.port, database: "postgres",
            username: server.username, password: server.password, sslMode: .disable
        ))
        for try await _ in try await client.simpleQuery("SELECT 7 AS client_capture_marker") {}
        client.close()
        #expect(try await wire.messages().roundTrips(containing: "client_capture_marker") == 1)
        #expect(try await wire.containsPlaintext(server.password) == false)
    }
}
