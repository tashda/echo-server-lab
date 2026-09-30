import Foundation

/// The recipes a lab knows, loaded from `*.json` files.
public struct RecipeCatalog: Sendable {
    public private(set) var recipes: [Recipe]

    public init(recipes: [Recipe]) {
        self.recipes = recipes.sorted { $0.name < $1.name }
    }

    /// Loads every `*.json` file in `directory`. A file whose name differs from its recipe name is an error.
    public init(directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        var loaded: [Recipe] = []
        for file in files {
            let recipe = try decoder.decode(Recipe.self, from: Data(contentsOf: file))
            let expected = file.deletingPathExtension().lastPathComponent
            guard recipe.name == expected else {
                throw ServerLabError.invalidParameter("name in \(file.lastPathComponent)", expected: "'\(expected)'")
            }
            loaded.append(recipe)
        }
        self.init(recipes: loaded)
    }

    public func recipe(named name: String) throws -> Recipe {
        guard let recipe = recipes.first(where: { $0.name == name }) else { throw ServerLabError.unknownRecipe(name) }
        return recipe
    }
}
