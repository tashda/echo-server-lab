import ArgumentParser
import Foundation
import ServerLabCatalog
import ServerLabKit

@main
struct ServerLabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serverlab",
        abstract: "Start disposable database servers from recipes.",
        discussion: "The host is testlab unless SERVERLAB_HOST=local.",
        subcommands: [Recipes.self, Build.self, Up.self, Down.self, List.self, StopPart.self, StartPart.self, Promote.self, Fault.self,
                      Images.self, Prune.self, Reap.self, Wire.self, Pcap.self]
    )
}

struct Recipes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the recipes.")

    func run() async throws {
        let lab = try ServerLab.standard()
        for recipe in lab.recipes.recipes {
            print("\(recipe.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(recipe.summary)")
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

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove lab servers by container name, or all of them.")

    @Argument(help: "Container names.") var names: [String] = []
    @Flag(help: "Remove every lab server and builder on the host.") var all = false

    func run() async throws {
        let lab = try ServerLab.standard()
        let containers = try await lab.running().filter { all || names.contains($0.name) || names.contains($0.server) }
        for server in Set(containers.map(\.server)).sorted() {
            try await lab.remove(serverNamed: server)
            print("removed \(server)")
        }
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
