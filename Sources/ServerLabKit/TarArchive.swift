import Foundation

/// A minimal ustar archive, so files reach a container with their owner and mode
/// (`docker cp --archive -` keeps both; a plain `docker cp` makes everything root's).
/// Paths must fit ustar's 100-byte name field.
enum TarArchive {
    static func make(_ files: [String: ContainerFile]) -> Data {
        var archive = Data()
        // No directory entries: Docker creates missing parents (root, 0755) and leaves existing
        // ones alone, where an entry would change the owner of e.g. /var/opt/mssql.
        for (path, file) in files.sorted(by: { $0.key < $1.key }) {
            archive += header(name: relative(path), size: file.contents.count, mode: file.mode, owner: file.owner, type: "0")
            archive += file.contents
            archive += Data(count: (512 - file.contents.count % 512) % 512)
        }
        archive += Data(count: 1024)
        return archive
    }

    private static func relative(_ path: String) -> String { String(path.drop { $0 == "/" }) }

    static func header(name: String, size: Int, mode: Int, owner: Int, type: Character) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() { block[offset + index] = byte }
        }
        func octal(_ value: Int, length: Int) -> String {
            let digits = String(value, radix: 8)
            return String(repeating: "0", count: max(0, length - 1 - digits.count)) + digits
        }
        put(name, at: 0, length: 100)
        put(octal(mode, length: 8), at: 100, length: 7)
        put(octal(owner, length: 8), at: 108, length: 7)
        put(octal(owner, length: 8), at: 116, length: 7)
        put(octal(size, length: 12), at: 124, length: 11)
        put(octal(Int(Date().timeIntervalSince1970), length: 12), at: 136, length: 11)
        put("        ", at: 148, length: 8)
        put(String(type), at: 156, length: 1)
        put("ustar\u{0}00", at: 257, length: 8)
        let checksum = block.reduce(0) { $0 + Int($1) }
        put(octal(checksum, length: 7) + "\u{0} ", at: 148, length: 8)
        return Data(block)
    }
}
