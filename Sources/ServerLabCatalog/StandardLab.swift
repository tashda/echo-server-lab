import Foundation
import ServerLabKit
import ServerLabMySQL
import ServerLabPostgres
import ServerLabSQLServer

extension ServerLab {
    /// Every engine and the recipes shipped with this package, on the host `SERVERLAB_HOST` selects.
    public static func standard(host: LabHost = .fromEnvironment()) throws -> ServerLab {
        try ServerLab(host: host, engines: standardEngines, recipes: shippedRecipes())
    }

    public static var standardEngines: [any LabEngine] {
        [SQLServerEngine(), PostgresEngine(), MySQLEngine(.mysql), MySQLEngine(.mariadb)]
    }

    /// The recipes in `Sources/ServerLabCatalog/Recipes`.
    public static func shippedRecipes() throws -> RecipeCatalog {
        guard let directory = Bundle.module.url(forResource: "Recipes", withExtension: nil) else {
            return RecipeCatalog(recipes: [])
        }
        return try RecipeCatalog(directory: directory)
    }
}
