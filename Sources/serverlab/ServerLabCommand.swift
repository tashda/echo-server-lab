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
        subcommands: [Recipes.self, Build.self, Up.self, Down.self, List.self, Images.self, Prune.self, Reap.self]
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

    func run() async throws {
        let lab = try ServerLab.standard()
        let log: LabLog = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        let server = try await lab.start(recipeNamed: recipe, owner: "cli", lease: .seconds(lease * 60), log: log)
        if env {
            for (key, value) in server.environment.sorted(by: { $0.key < $1.key }) { print("export \(key)='\(value)'") }
        } else if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(server), as: UTF8.self))
        } else {
            print("\(server.containerName)  \(server.engine.rawValue) \(server.version)  \(server.host):\(server.port)  user \(server.username)")
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
        let targets = try await lab.running().filter { all || names.contains($0.name) }
        for server in targets {
            try await lab.remove(containerID: server.id)
            print("removed \(server.name)")
        }
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "Show lab containers and the memory they reserve.")

    func run() async throws {
        let lab = try ServerLab.standard()
        let formatter = RelativeDateTimeFormatter()
        for server in try await lab.running() {
            print("\(server.name)  \(server.role)  \(server.recipe)  owner \(server.owner)  \(server.status)  expires \(formatter.localizedString(for: server.expires, relativeTo: Date()))")
        }
        print("Reserved \(try await lab.reservedMemoryMB()) of \(lab.host.memoryBudgetMB) MB on \(lab.host.name)")
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
