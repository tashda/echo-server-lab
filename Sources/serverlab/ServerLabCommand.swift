import ArgumentParser
import Foundation
import ServerLabCatalog
import ServerLabKit
import ServerLabWorkloads

@main
struct ServerLabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serverlab",
        abstract: "Start disposable database servers from recipes.",
        discussion: "The host is testlab unless SERVERLAB_HOST=local.",
        subcommands: [Recipes.self, Build.self, Up.self, Run.self, Down.self, List.self, StopPart.self, StartPart.self, Promote.self, Fault.self, Workload.self,
                      Images.self, Prune.self, Reap.self, Wire.self, Explain.self, Sqlcmd.self, MySQLCommand.self, SQLite.self, Pcap.self]
    )
}

struct Recipes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the recipes.")

    @Flag(help: "Only the names, one per line (for scripts).") var names = false

    func run() async throws {
        let lab = try ServerLab.standard()
        let recipes = lab.recipes.recipes
        // Pad to the longest name: a fixed width cut long names short.
        let width = recipes.map(\.name.count).max() ?? 0
        for recipe in recipes {
            print(names ? recipe.name : "\(recipe.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(recipe.summary)")
        }
    }
}

struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build a recipe's seeded image (or reuse it).")

    @Argument(help: "Recipe name.") var recipe: String

    func run() async throws {
        let lab = try ServerLab.standard()
        let tag = try await lab.seededImage(for: lab.recipes.recipe(named: recipe), log: { print($0) })
        print(tag)
    }
}

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a fresh server and print how to connect.")

    @Argument(help: "Recipe name.") var recipe: String
    @Option(help: "Minutes before the server is removed automatically.") var lease = 120
    @Flag(help: "Print SERVERLAB_* variables for `eval`.") var env = false
    @Flag(help: "Print JSON.") var json = false
    @Option(help: "Who asked for the server (shown in `serverlab ps`).") var owner = "cli"
    @Flag(help: "Record the server's traffic (see `serverlab wire` and `serverlab pcap`).") var capture = false
    @Flag(help: "Put a fault proxy in front of the server (part `proxy`; see `serverlab fault`).") var faults = false

    func run() async throws {
        let lab = try ServerLab.standard()
        let log: LabLog = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        var server = try await lab.start(recipeNamed: recipe, owner: owner, lease: .seconds(lease * 60), log: log)
        if faults { server = try await lab.startFaultProxy(for: server, log: log) }
        if capture { try await lab.startCapture(of: server) }
        if env {
            for (key, value) in server.environment.sorted(by: { $0.key < $1.key }) { print("export \(key)='\(value)'") }
        } else if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(server), as: UTF8.self))
        } else {
            print("\(server.containerName)  \(server.engine.rawValue) \(server.version)  \(server.host):\(server.port)  user \(server.username)")
            for part in server.parts.dropFirst() { print("  \(part.role)  \(server.host):\(part.port)  \(part.containerName)") }
            print("Password: SERVERLAB_PASSWORD / ~/.echo-testlab/credentials.env. Removed after \(lease) minutes or `serverlab down \(server.containerName)`.")
        }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start fresh servers, run a command with their variables, then remove the servers.",
        discussion: """
            The command gets every server's variables: SERVERLAB_* and the drivers' test URLs
            (SQLSERVER_TEST_URL, POSTGRES_TEST_TLS_URL, …). The servers go when the command ends,
            also when it fails or is interrupted. Exits with the command's status.

              serverlab run --recipe pg-17-empty -- swift test
              serverlab run --recipe mssql-2022-empty --recipe mssql-2022-tls-required -- swift test --filter TLS
            """
    )

    @Option(name: .customLong("recipe"), help: "A recipe to start; repeat for several servers.") var recipes: [String]
    @Option(help: "Minutes before the servers are removed if this process dies.") var lease = 120
    @Option(help: "Who asked for the servers (shown in `serverlab ps`).") var owner = "serverlab-run"
    @Argument(parsing: .postTerminator, help: "The command, after --.") var command: [String]

    func run() async throws {
        guard !recipes.isEmpty, !command.isEmpty else { throw ValidationError("Give --recipe and a command after --") }
        let lab = try ServerLab.standard()
        let log: LabLog = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        var servers: [LabServer] = []
        let status: Int32
        do {
            var environment = ProcessInfo.processInfo.environment
            for recipe in recipes {
                let server = try await lab.start(recipeNamed: recipe, owner: owner, lease: .seconds(lease * 60), log: log)
                servers.append(server)
                environment.merge(server.environment) { _, new in new }
                log("\(server.containerName) (\(recipe)) at \(server.host):\(server.port)")
            }
            status = try Self.runCommand(command, environment: environment)
        } catch {
            for server in servers { try? await lab.stop(server) }
            throw error
        }
        for server in servers { try? await lab.stop(server) }
        if status != 0 { throw ExitCode(status) }
    }

    /// Runs the command in the foreground: Ctrl-C reaches it, and this process carries on to
    /// remove the servers once it ends.
    static func runCommand(_ command: [String], environment: [String: String]) throws -> Int32 {
        signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, SIG_DFL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove lab servers by container name, or all of one owner's.")

    @Argument(help: "Container names.") var names: [String] = []
    @Flag(help: "Remove every lab server of --owner (default cli: the ones `serverlab up` started).") var all = false
    @Option(help: "With --all: whose servers (a suite name, cli, echo-labs).") var owner = "cli"
    @Flag(help: "With --all: every owner's servers, other agents' included. Look at `serverlab ps` first.") var everyone = false
    @Option(help: "With --all: the servers of every owner under this prefix (SERVERLAB_OWNER_PREFIX of a test run).")
    var ownerPrefix: String?
    @Flag(help: "The servers whose owner is a process on this machine that has ended (owners `<name>@<machine>:<pid>`).")
    var abandoned = false

    func run() async throws {
        let lab = try ServerLab.standard()
        let running = try await lab.running()
        func owned(_ owner: String) -> Bool {
            if let ownerPrefix { return owner.hasPrefix(ownerPrefix + "/") }
            return owner == self.owner
        }
        let containers = running.filter { container in
            names.contains(container.name) || names.contains(container.server)
                || (all && (everyone || owned(container.owner) || running.contains { $0.name == container.server && owned($0.owner) }))
                || (abandoned && Self.ownerProcessEnded(container.owner))
        }
        for server in Set(containers.map(\.server)).sorted() {
            try await lab.remove(serverNamed: server)
            print("removed \(server)")
        }
    }

    /// True for an owner `…@<this machine>:<pid>` whose process is gone.
    static func ownerProcessEnded(_ owner: String) -> Bool {
        guard let at = owner.lastIndex(of: "@") else { return false }
        let parts = owner[owner.index(after: at)...].split(separator: ":")
        guard parts.count == 2, let pid = Int32(parts[1]) else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count - 1)
        guard String(parts[0]) == String(cString: buffer) else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "Show lab containers and the memory they reserve.")

    func run() async throws {
        let lab = try ServerLab.standard()
        let formatter = RelativeDateTimeFormatter()
        for server in try await lab.running() {
            let role = server.part.isEmpty || server.part == "server" ? server.role : "\(server.role) (\(server.part))"
            print("\(server.name)  \(role)  \(server.recipe)  owner \(server.owner)  \(server.status)  expires \(formatter.localizedString(for: server.expires, relativeTo: Date()))")
        }
        print("Reserved \(try await lab.reservedMemoryMB()) of \(lab.host.memoryBudgetMB) MB on \(lab.host.name)")
    }
}

struct StopPart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a server (or one part of it) without removing it.")

    @Argument(help: "Server container name.") var name: String
    @Option(help: "The part: primary, standby, …; the main one when omitted.") var part: String?

    func run() async throws {
        let lab = try ServerLab.standard()
        try await lab.stop(part: part, of: lab.server(named: name))
        print("stopped \(part ?? "main part of") \(name)")
    }
}

struct StartPart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start a stopped server (or part) again, on the same port.")

    @Argument(help: "Server container name.") var name: String
    @Option(help: "The part: primary, standby, …; the main one when omitted.") var part: String?

    func run() async throws {
        let lab = try ServerLab.standard()
        let log: LabLog = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        try await lab.start(part: part, of: lab.server(named: name), log: log)
        print("started \(part ?? "main part of") \(name)")
    }
}

struct Promote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Promote a standby (or secondary) to primary.")

    @Argument(help: "Server container name.") var name: String
    @Option(help: "The part to promote.") var part = "standby"

    func run() async throws {
        let lab = try ServerLab.standard()
        try await lab.promote(part: part, of: lab.server(named: name))
        print("promoted \(part) of \(name)")
    }
}

struct Workload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a live workload on a server until the time is up or Ctrl-C.",
        discussion: """
            Kinds: blocking-chain (a session holds a row lock, --waiters more wait for it) and
            idle-in-transaction. Sessions report the application name serverlab-workload.
            """
    )

    @Argument(help: "Server container name.") var name: String
    @Argument(help: "blocking-chain or idle-in-transaction.") var kind: String
    @Option(help: "Sessions waiting on the lock (blocking-chain).") var waiters = 2
    @Option(help: "How long to keep it running.") var minutes = 10

    func run() async throws {
        guard let kind = LabWorkloadKind(rawValue: kind) else {
            throw ValidationError("Kinds: \(LabWorkloadKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let server = try await ServerLab.standard().server(named: name)
        let workload = try await server.startWorkload(kind, waiters: waiters)
        print("Running \(kind.rawValue) on \(name) for \(minutes) minutes; Ctrl-C stops it (the server rolls back).")
        try? await Task.sleep(for: .seconds(minutes * 60))
        await workload.stop()
        print("Stopped.")
    }
}

struct Fault: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add or remove network faults on a server's proxy part (`up --faults`).",
        discussion: """
            Kinds: latency <ms>, bandwidth <KB/s>, timeout <ms> (0 = silent), reset <ms>, slow-close <ms>,
            limit <bytes>, slicer <bytes>; and clear [name], cut, restore. Prints the fault's name.
            """
    )

    @Argument(help: "Server container name.") var name: String
    @Argument(help: "latency, bandwidth, timeout, reset, slow-close, limit, slicer, clear, cut or restore.") var kind: String
    @Argument(help: "The fault's value (or the fault to clear).") var value: String?
    @Flag(help: "Act on data sent to the server instead of data sent to the client.") var upstream = false

    func run() async throws {
        let lab = try ServerLab.standard()
        let server = try await lab.server(named: name)
        switch kind {
        case "clear": try await lab.clearFaults(value, of: server)
        case "cut": try await lab.cutConnections(of: server)
        case "restore": try await lab.restoreConnections(of: server)
        default:
            guard let number = value.flatMap({ Int($0) }) else { throw ValidationError("\(kind) needs a number") }
            let fault: LabFault = switch kind {
            case "latency": .latency(milliseconds: number)
            case "bandwidth": .bandwidth(kilobytesPerSecond: number)
            case "timeout": .timeout(milliseconds: number)
            case "reset": .resetPeer(afterMilliseconds: number)
            case "slow-close": .slowClose(milliseconds: number)
            case "limit": .limitData(bytes: number)
            case "slicer": .slicer(averageBytes: number, delayMicroseconds: 1_000)
            default: throw ValidationError("Unknown fault \(kind)")
            }
            print(try await lab.addFault(fault, direction: upstream ? .upstream : .downstream, to: server))
            return
        }
        print("\(kind) \(name)")
    }
}

struct Reap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove servers whose lease has passed.")

    func run() async throws {
        print("removed \(try await ServerLab.standard().reapExpired())")
    }
}

struct Images: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the seeded images on the host.")

    func run() async throws {
        for image in try await ServerLab.standard().seededImages().sorted(by: { $0.recipe < $1.recipe }) {
            print("\(image.recipe.padding(toLength: 34, withPad: " ", startingAt: 0)) \(image.size.padding(toLength: 9, withPad: " ", startingAt: 0)) \(image.created)")
        }
    }
}

struct Prune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove seeded images no shipped recipe uses any more.")

    func run() async throws {
        let removed = try await ServerLab.standard().pruneOutdatedImages()
        for tag in removed { print("removed \(tag)") }
        print("\(removed.count) outdated images removed")
    }
}

struct Wire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a captured server's traffic, decoded by Wireshark.")

    @Argument(help: "Server container name.") var name: String
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let lab = try ServerLab.standard()
        let messages = try await lab.wireMessages(of: lab.server(named: name))
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(messages), as: UTF8.self))
        } else {
            for message in messages {
                let arrow = message.toServer ? "→" : "←"
                print(String(format: "%8.3f", message.time), arrow, message.kind, message.text.map { ": \($0.prefix(120))" } ?? "")
            }
            print("\(messages.requests.count) requests")
        }
    }
}

struct Explain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Explain a captured server's traffic (TDS or PostgreSQL) field by field with the lab's decoders.",
        discussion: "Ends with every byte the decoders could not match to the protocol (MS-TDS, PostgreSQL 3.x); nothing there means the traffic matches."
    )

    @Argument(help: "Server container name.") var name: String
    @Option(help: "Only messages whose explanation contains this text.") var contains: String?
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let lab = try ServerLab.standard()
        let messages = try await lab.explainedWire(of: lab.server(named: name))
            .filter { message in contains.map { message.explanation.text.localizedCaseInsensitiveContains($0) } ?? true }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(messages), as: UTF8.self))
            return
        }
        for message in messages {
            print(String(format: "%8.3fs %@ ", message.time, message.toServer ? "client →" : "server ←") + message.explanation.text + "\n")
        }
        let problems = messages.specProblems
        print(problems.isEmpty ? "\(messages.count) messages, all match the protocol." : "Not in the protocol:\n" + problems.joined(separator: "\n"))
    }
}

struct Sqlcmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run SQL through Microsoft's sqlcmd (ODBC Driver 18) from the server's image.",
        discussion: "A second client to compare with ours. With --encryption optional only the login is encrypted, so a capture can be read."
    )

    @Argument(help: "Server container name.") var name: String
    @Argument(help: "The SQL to run.") var sql: String
    @Option(help: "Database.") var database = "master"
    @Option(help: "optional (login only), mandatory or strict.") var encryption = "optional"

    func run() async throws {
        let lab = try ServerLab.standard()
        let mode: MicrosoftClientEncryption = switch encryption {
        case "mandatory": .mandatory
        case "strict": .strict
        default: .optional
        }
        print(try await lab.runMicrosoftClient(lab.server(named: name), sql: sql, database: database, encryption: mode))
    }
}

struct MySQLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mysql",
        abstract: "Run SQL through the MySQL or MariaDB image's own client, without TLS.",
        discussion: "A second client to compare with mysql-wire, and readable in a capture."
    )

    @Argument(help: "Server container name.") var name: String
    @Argument(help: "The SQL to run.") var sql: String
    @Option(help: "Database.") var database: String?

    func run() async throws {
        let lab = try ServerLab.standard()
        print(try await lab.runMySQLClient(lab.server(named: name), sql: sql, database: database))
    }
}

struct SQLite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sqlite",
        abstract: "Print the path of a fresh copy of a SQLite fixture (built through sqlite-nio the first time).",
        discussion: "Fixtures: " + LabSQLiteFixture.allCases.map { "\($0.rawValue): \($0.summary)" }.joined(separator: " ")
    )

    @Argument(help: "all-types, programmability or chinook.") var fixture: String
    @Flag(help: "Print the shared built file instead of a copy (do not change it).") var shared = false

    func run() async throws {
        guard let chosen = LabSQLiteFixture(rawValue: fixture) else {
            throw ValidationError("Fixtures: " + LabSQLiteFixture.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let log: LabLog = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        print(shared ? try await LabSQLite.file(chosen, log: log).path : try await LabSQLite.freshCopy(chosen, log: log).path)
    }
}

struct Pcap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a captured server's traffic as a .pcap file (opens in Wireshark).")

    @Argument(help: "Server container name.") var name: String
    @Option(name: .shortAndLong, help: "Output file.") var output: String?

    func run() async throws {
        let lab = try ServerLab.standard()
        let data = try await lab.captureData(of: lab.server(named: name))
        let path = output ?? "\(name).pcap"
        try data.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}
