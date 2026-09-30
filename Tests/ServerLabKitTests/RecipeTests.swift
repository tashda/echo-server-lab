import Foundation
import ServerLabCatalog
import ServerLabKit
import Testing

@Suite struct RecipeTests {
    @Test func decodesRecipeWithDefaults() throws {
        let json = #"{ "name": "x", "engine": "sqlserver", "version": "2022" }"#
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(json.utf8))
        #expect(recipe.packs.isEmpty)
        #expect(recipe.settings == ServerSettings())
        #expect(recipe.summary.isEmpty)
    }

    @Test func decodesPackParametersOfEveryKind() throws {
        let json = #"{ "pack": "p", "params": { "count": 20, "flag": true, "text": "LabData" } }"#
        let use = try JSONDecoder().decode(PackUse.self, from: Data(json.utf8))
        #expect(try use.params.int("count", default: 0) == 20)
        #expect(try use.params.bool("flag", default: false))
        #expect(try use.params.string("text", default: "") == "LabData")
        #expect(try use.params.int("missing", default: 7) == 7)
        #expect(throws: ServerLabError.self) { try use.params.int("text", default: 0) }
    }

    @Test func everyShippedRecipeIsValid() throws {
        let catalog = try ServerLab.shippedRecipes()
        #expect(catalog.recipes.count >= 20)
        let engines = Dictionary(uniqueKeysWithValues: ServerLab.standardEngines.map { ($0.kind, $0) })
        for recipe in catalog.recipes {
            let engine = try #require(engines[recipe.engine], "\(recipe.name)")
            #expect(engine.supportedVersions.contains(recipe.version), "\(recipe.name)")
            for use in recipe.packs {
                #expect(engine.pack(named: use.pack) != nil, "\(recipe.name) uses unknown pack \(use.pack)")
            }
            if recipe.packs.contains(where: { $0.pack == "agent-jobs" }) {
                #expect(recipe.settings.agent == true, "\(recipe.name) needs Agent on")
            }
        }
    }

    @Test func packNamesAreUniquePerEngine() {
        for engine in ServerLab.standardEngines {
            let names = engine.packs.map(\.name)
            #expect(Set(names).count == names.count, "\(engine.kind)")
        }
    }
}
