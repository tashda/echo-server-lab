import Foundation
import ServerLabKit
import SQLServerKit

/// SQL Server Agent jobs on every kind of schedule, some succeeding, some failing, one disabled,
/// one on demand only, plus an operator that failing jobs notify. The jobs keep running in the
/// seeded image, so job history fills up while a suite uses the server.
///
/// Needs `"agent": true` in the recipe settings. Parameters: `jobCount` (default 20).
struct SQLServerAgentJobsPack: ContentPack {
    let name = "agent-jobs"
    let version = 1
    let summary = "Agent jobs on minute, hourly, daily, weekly, monthly, one-time and no schedules; failures and an operator."

    func apply(to server: ServerEndpoint, recipe: Recipe, parameters: PackParameters, context: PackContext) async throws {
        guard recipe.settings.agent == true else {
            throw ServerLabError.packRequirement(pack: name, reason: "set \"agent\": true in the recipe settings")
        }
        let jobCount = try parameters.int("jobCount", default: 20)
        try await SQLServerSession.with(server) { client in
            try await Self.waitForAgent(client)
            try await Self.waitUntilAgentAcceptsJobs(client)
            try await client.agent.createOperator(name: Self.operatorName, emailAddress: "lab-operator@echodb.dev")
            let existing = Set(try await client.agent.listJobs().map(\.name))
            // Agent accepts jobs now, so they are created without retries (a retried job would
            // already half exist).
            for index in 1...max(jobCount, 1) where !existing.contains(Self.jobName(index)) {
                _ = try await Self.builder(index: index, agent: client.agent).commit()
            }
        }
        context.log("  \(jobCount) jobs")
    }

    func verify(on server: ServerEndpoint, recipe: Recipe, parameters: PackParameters) async throws {
        let jobCount = try parameters.int("jobCount", default: 20)
        let (jobs, status) = try await SQLServerSession.with(server) { client in
            (try await client.agent.listJobs(), try await client.metadata.fetchAgentStatus())
        }
        let labJobs = jobs.filter { $0.name.hasPrefix(Self.jobPrefix) }
        guard labJobs.count == jobCount else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "found \(labJobs.count) lab jobs, expected \(jobCount)")
        }
        guard status.isSqlAgentRunning else {
            throw ServerLabError.packCheckFailed(pack: name, reason: "SQL Server Agent is not running")
        }
    }

    static let jobPrefix = "Lab Job "
    static let operatorName = "Lab Operator"

    static func jobName(_ index: Int) -> String {
        jobPrefix + String(format: "%02d", index)
    }

    /// Agent starts a little after the server; msdb procedures fail until it has.
    static func waitForAgent(_ client: SQLServerClient) async throws {
        try await retryUntilReady("SQL Server Agent", timeout: .seconds(120)) {
            guard try await client.metadata.fetchAgentStatus().isSqlAgentRunning else {
                throw ServerLabError.packRequirement(pack: "agent-jobs", reason: "Agent not running yet")
            }
        }
        // Running is reported before Agent accepts job changes (SQL Server 2017 and 2025 both).
        try await SQLServerEngine.waitForAgent(client)
    }

    /// SQL Server 2017 reports Agent as running while it still refuses job changes with
    /// "Cannot perform this operation while SQLServerAgent is starting". A throwaway job proves it
    /// accepts them.
    static func waitUntilAgentAcceptsJobs(_ client: SQLServerClient) async throws {
        let probe = "Lab Agent Probe"
        try await whileAgentStarts {
            if try await client.agent.listJobs().contains(where: { $0.name == probe }) {
                try await client.agent.deleteJob(named: probe)
            }
            try await client.agent.createJob(named: probe)
            try await client.agent.addJobServer(jobName: probe)
            try await client.agent.deleteJob(named: probe)
        }
    }

    /// Retries `body` while Agent is still starting, for up to two minutes.
    static func whileAgentStarts(_ body: () async throws -> Void) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while true {
            do {
                try await body()
                return
            } catch where String(describing: error).contains("SQLServerAgent is starting") && clock.now < deadline {
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Ten patterns, repeated: the job number picks one.
    static func builder(index: Int, agent: SQLServerAgentOperations) -> SQLServerAgentJobBuilder {
        let name = jobName(index)
        let pattern = (index - 1) % 10
        let job = SQLServerAgentJobBuilder(
            agent: agent,
            jobName: name,
            description: "Lab job, pattern \(pattern)",
            enabled: pattern != 9
        )
        let quick = SQLServerAgentJobStep(name: "Quick check", command: "SELECT 1;", database: "master")
        let failing = SQLServerAgentJobStep(name: "Fail on purpose", command: "RAISERROR('Lab job failure', 16, 1);", database: "master")
        let wait = SQLServerAgentJobStep(name: "Wait two seconds", command: "WAITFOR DELAY '00:00:02';", database: "master")
        let schedule = "\(name) schedule"

        switch pattern {
        case 0:
            _ = job.addStep(quick)
                .addSchedule(.init(name: schedule, kind: .daily(everyDays: 1, startTime: 0), subdayType: 4, subdayInterval: 1))
        case 1:
            _ = job.addStep(failing)
                .addSchedule(.init(name: schedule, kind: .daily(everyDays: 1, startTime: 0), subdayType: 4, subdayInterval: 5))
                .setNotification(.init(operatorName: operatorName, level: .onFailure))
        case 2:
            _ = job.addStep(wait)
                .addSchedule(.init(name: schedule, kind: .daily(everyDays: 1, startTime: 0), subdayType: 8, subdayInterval: 1))
        case 3:
            _ = job.addStep(quick).addStep(wait)
                .addSchedule(.init(name: schedule, kind: .daily(everyDays: 1, startTime: 20_000)))
        case 4:
            _ = job.addStep(quick)
                .addSchedule(.init(name: schedule, kind: .weekly(days: [.monday, .wednesday, .friday], everyWeeks: 1, startTime: 63_000)))
        case 5:
            _ = job.addStep(quick)
                .addSchedule(.init(name: schedule, kind: .monthly(day: 1, everyMonths: 1, startTime: 30_000)))
        case 6:
            _ = job.addStep(quick)
                .addSchedule(.init(name: schedule, kind: .monthlyRelative(week: .first, day: .monday, everyMonths: 1, startTime: 40_000)))
        case 7:
            _ = job.addStep(quick)
                .addSchedule(.init(name: schedule, kind: .oneTime(startDate: 20_991_231, startTime: 120_000)))
        case 8:
            // On demand only: several steps with branching.
            var first = quick
            first.onSuccess = .goToStep(3)
            first.onFail = .goToNextStep
            var second = failing
            second.onFail = .quitWithFailure
            _ = job.addStep(first).addStep(second).addStep(wait)
        default:
            // A disabled job with a disabled schedule.
            _ = job.addStep(quick)
                .addSchedule(.init(name: schedule, enabled: false, kind: .daily(everyDays: 1, startTime: 10_000)))
        }
        return job
    }
}
