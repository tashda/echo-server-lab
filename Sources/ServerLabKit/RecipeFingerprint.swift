import CryptoKit
import Foundation

/// Identifies a seeded image: the same recipe, pack versions, base image and password give the same
/// fingerprint, so an existing image is reused; any change builds a new one.
public enum RecipeFingerprint {
    /// Raise when the way images are built changes.
    static let formatVersion = 1

    public static func compute(
        recipe: Recipe,
        packVersions: [String: Int],
        baseImageID: String,
        password: String
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        hash.update(data: Data("format:\(formatVersion)\n".utf8))
        hash.update(data: try encoder.encode(recipe))
        for (name, version) in packVersions.sorted(by: { $0.key < $1.key }) {
            hash.update(data: Data("pack:\(name)=\(version)\n".utf8))
        }
        hash.update(data: Data("base:\(baseImageID)\n".utf8))
        hash.update(data: Data(SHA256.hash(data: Data(password.utf8))))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `serverlab/<recipe>:<first 12 characters>`.
    public static func imageTag(recipe: String, fingerprint: String) -> String {
        "serverlab/\(recipe):\(fingerprint.prefix(12))"
    }
}
