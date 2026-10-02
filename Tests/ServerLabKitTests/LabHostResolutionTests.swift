import Foundation
import Testing
@testable import ServerLabKit

@Suite struct LabHostResolutionTests {
    private let configuration = LabHostConfiguration(
        default: "lab",
        hosts: ["lab": .init(dockerHost: "ssh://lab", address: "192.0.2.10", memoryBudgetMB: 4096,
                             isDedicated: true, samplesDirectory: "/srv/samples")]
    )

    @Test func usesLocalDockerWithoutConfiguration() {
        let host = LabHost.fromEnvironment([:], configuration: nil)
        #expect(host == .local)
    }

    @Test func usesTheConfiguredDefault() {
        let host = LabHost.fromEnvironment([:], configuration: configuration)
        #expect(host.name == "lab")
        #expect(host.dockerHost == "ssh://lab")
        #expect(host.address == "192.0.2.10")
        #expect(host.memoryBudgetMB == 4096)
        #expect(host.isDedicated)
    }

    @Test func localOverridesTheConfiguredDefault() {
        #expect(LabHost.fromEnvironment(["SERVERLAB_HOST": "local"], configuration: configuration) == .local)
    }

    @Test func unknownNamesAreReachedOverSSH() {
        let host = LabHost.fromEnvironment(["SERVERLAB_HOST": "buildbox"], configuration: configuration)
        #expect(host.dockerHost == "ssh://buildbox")
        #expect(host.address == "buildbox")
    }

    @Test func theEnvironmentCanDefineAHost() {
        let host = LabHost.fromEnvironment([
            "SERVERLAB_DOCKER_HOST": "ssh://ci-lab", "SERVERLAB_ADDRESS": "198.51.100.7",
            "SERVERLAB_MEMORY_MB": "2048", "SERVERLAB_DEDICATED": "1",
        ], configuration: configuration)
        #expect(host.dockerHost == "ssh://ci-lab")
        #expect(host.address == "198.51.100.7")
        #expect(host.memoryBudgetMB == 2048)
        #expect(host.isDedicated)
    }

    @Test func readsTheConfigurationFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"default":"lab","hosts":{"lab":{"address":"192.0.2.10","dockerHost":"ssh://lab"}}}"#.utf8).write(to: file)
        let loaded = try #require(LabHostConfiguration.load(from: file))
        #expect(loaded.hosts["lab"]?.host(named: "lab").memoryBudgetMB == 16_384)
    }
}
