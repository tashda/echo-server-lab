import Foundation
import PostgresKit

/// One column of the column-types pack. Values are PostgreSQL literals (nil is NULL), cast to the type.
struct PostgresTypeSample: Sendable {
    let column: String
    let type: String
    let minimumVersion: Int
    let minimum: String?
    let maximum: String?
    let generated: @Sendable (Int) -> String?

    func value(_ literal: String?) -> PostgresInsertValue {
        literal.map { PostgresTypeSamples.cast($0, type) } ?? .null
    }
}

enum PostgresTypeSamples {
    static func samples(forVersion version: Int) -> [PostgresTypeSample] {
        all.filter { version >= $0.minimumVersion }
    }

    static func cast(_ literal: String, _ type: String) -> PostgresInsertValue {
        .sql("'\(literal.replacingOccurrences(of: "'", with: "''"))'::\(type)")
    }

    private static func sample(
        _ column: String, _ type: String, since version: Int = 13,
        min minimum: String?, max maximum: String?, _ generated: @escaping @Sendable (Int) -> String?
    ) -> PostgresTypeSample {
        PostgresTypeSample(column: column, type: type, minimumVersion: version, minimum: minimum, maximum: maximum, generated: generated)
    }

    private static let all: [PostgresTypeSample] = [
        sample("smallint_col", "smallint", min: "-32768", max: "32767") { "\($0 * 7 % 32_767)" },
        sample("integer_col", "integer", min: "-2147483648", max: "2147483647") { "\($0 * 104_729)" },
        sample("bigint_col", "bigint", min: "-9223372036854775808", max: "9223372036854775807") { "\(Int64($0) * 9_999_999_967)" },
        sample("numeric_col", "numeric(38,10)", min: "-9999999999999999999999999999.9999999999",
               max: "9999999999999999999999999999.9999999999") { "\($0).\($0 * 7919 % 10_000)" },
        sample("numeric_free_col", "numeric", min: "NaN", max: "123456789012345678901234567890.123456789012345678901234567890") { "\($0)e\($0 % 30)" },
        sample("real_col", "real", min: "-Infinity", max: "3.4e38") { "\(Double($0) / 7)" },
        sample("double_col", "double precision", min: "-1.79e308", max: "NaN") { "\(Double($0) * 3.141592653589793)" },
        sample("money_col", "money", min: "-92233720368547758.08", max: "92233720368547758.07") { "\($0 * 101).25" },
        sample("boolean_col", "boolean", min: "false", max: "true") { $0 % 2 == 0 ? "true" : "false" },
        sample("text_col", "text", min: "", max: String(repeating: "t", count: 9_000)) { "row \($0) \(unicode[$0 % unicode.count])" },
        sample("varchar_col", "varchar(255)", min: "", max: String(repeating: "Ω", count: 255)) { unicode[$0 % unicode.count] },
        sample("char_col", "char(10)", min: "", max: "abcdefghij") { "c\($0)" },
        sample("name_col", "name", min: "", max: String(repeating: "n", count: 63)) { "name_\($0)" },
        sample("bytea_col", "bytea", min: "\\x", max: "\\x" + String(repeating: "ff", count: 256)) { "\\x" + String(format: "%08x", $0) },
        sample("date_col", "date", min: "4713-01-01 BC", max: "5874897-12-31") { day(offset: $0) },
        sample("time_col", "time(6)", min: "00:00:00", max: "24:00:00") { String(format: "%02d:%02d:%02d.%06d", $0 % 24, $0 % 60, $0 * 7 % 60, $0) },
        sample("timetz_col", "timetz", min: "00:00:00+15:59", max: "24:00:00-15:59") { "12:00:00+0\($0 % 9)" },
        sample("timestamp_col", "timestamp(6)", min: "4713-01-01 00:00:00 BC", max: "294276-12-31 23:59:59.999999") { "2020-09-13 08:15:30.\($0)" },
        sample("timestamptz_col", "timestamptz", min: "-infinity", max: "infinity") { "2020-09-13 08:15:30+0\($0 % 9)" },
        sample("interval_col", "interval", min: "-178000000 years", max: "178000000 years") { "\($0) days \($0 % 24) hours" },
        sample("uuid_col", "uuid", min: "00000000-0000-0000-0000-000000000000", max: "ffffffff-ffff-ffff-ffff-ffffffffffff") {
            String(format: "%08x-0000-4000-8000-%012x", $0, $0 &* 2_654_435_761 & 0xFFFF_FFFF_FFFF)
        },
        sample("json_col", "json", min: "{}", max: #"{"a": {"b": {"c": [1, 2, {"d": "deep"}]}}, "dup": 1, "dup": 2}"#) { #"{"n": \#($0), "tags": ["x", "y"]}"# },
        sample("jsonb_col", "jsonb", min: "null", max: #"{"nested": {"array": [1, "two", 3.0, true, null], "unicode": "Ærø 漢字 🚀"}}"#) {
            #"{"n": \#($0), "even": \#($0 % 2 == 0), "path": {"to": {"value": \#($0 * 3)}}}"#
        },
        sample("xml_col", "xml", min: "<empty/>", max: #"<order id="1"><line sku="A-1">Løbehjul</line></order>"#) { "<row n=\"\($0)\"/>" },
        sample("inet_col", "inet", min: "0.0.0.0", max: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff") { "10.\($0 % 256).\($0 / 256 % 256).1/24" },
        sample("cidr_col", "cidr", min: "0.0.0.0/0", max: "2001:db8::/32") { "192.168.\($0 % 256).0/24" },
        sample("macaddr_col", "macaddr", min: "00:00:00:00:00:00", max: "ff:ff:ff:ff:ff:ff") { String(format: "08:00:2b:01:%02x:%02x", $0 % 256, $0 / 256 % 256) },
        sample("macaddr8_col", "macaddr8", min: "00:00:00:00:00:00:00:00", max: "ff:ff:ff:ff:ff:ff:ff:ff") { String(format: "08:00:2b:ff:fe:01:%02x:%02x", $0 % 256, $0 / 256 % 256) },
        sample("point_col", "point", min: "(-1e300,-1e300)", max: "(1e300,1e300)") { "(\($0),\($0 * 2))" },
        sample("line_col", "line", min: "{1,-1,0}", max: "{0,1,-5}") { "{1,\($0 + 1),2}" },
        sample("lseg_col", "lseg", min: "[(0,0),(0,0)]", max: "[(-1e10,-1e10),(1e10,1e10)]") { "[(0,0),(\($0),\($0))]" },
        sample("box_col", "box", min: "(0,0),(0,0)", max: "(1e10,1e10),(-1e10,-1e10)") { "(\($0 + 1),\($0 + 1)),(0,0)" },
        sample("path_col", "path", min: "[(0,0)]", max: "((0,0),(1,1),(2,0))") { "[(0,0),(\($0),1),(\($0 + 1),0)]" },
        sample("polygon_col", "polygon", min: "((0,0))", max: "((0,0),(0,10),(10,10),(10,0))") { "((0,0),(0,\($0 + 1)),(\($0 + 1),0))" },
        sample("circle_col", "circle", min: "<(0,0),0>", max: "<(0,0),1e10>") { "<(\($0),\($0)),\($0 + 1)>" },
        sample("bit_col", "bit(8)", min: "00000000", max: "11111111") { String(String($0 % 256, radix: 2).leftPadded(to: 8)) },
        sample("varbit_col", "bit varying(64)", min: "", max: String(repeating: "1", count: 64)) { String($0, radix: 2) },
        sample("tsvector_col", "tsvector", min: "", max: "a fat cat sat on a mat and ate a fat rat") { "row \($0) quick brown fox" },
        sample("tsquery_col", "tsquery", min: "", max: "fat & (rat | cat) & !dog") { "fox & row\($0)" },
        sample("int4range_col", "int4range", min: "empty", max: "(,)") { "[\($0),\($0 + 10))" },
        sample("int8range_col", "int8range", min: "empty", max: "[-9223372036854775808,9223372036854775807)") { "[\($0),)" },
        sample("numrange_col", "numrange", min: "empty", max: "(,)") { "[\($0).5,\($0 + 1).5]" },
        sample("tsrange_col", "tsrange", min: "empty", max: "[-infinity,infinity]") { "[2020-01-01,2020-01-\($0 % 28 + 2))" },
        sample("tstzrange_col", "tstzrange", min: "empty", max: "(,)") { "[2020-01-01 00:00+00,2020-02-01 00:00+0\($0 % 9))" },
        sample("daterange_col", "daterange", min: "empty", max: "(,)") { "[2020-01-01,2020-\($0 % 12 + 1)-15)" },
        sample("int4multirange_col", "int4multirange", since: 14, min: "{}", max: "{[1,5), [10,20), [30,)}") { "{[\($0),\($0 + 2)), [\($0 + 5),\($0 + 7))}" },
        sample("int_array_col", "integer[]", min: "{}", max: "{{1,2,3},{4,5,6}}") { "{\($0),\($0 + 1),NULL}" },
        sample("text_array_col", "text[]", min: "{}", max: #"{"with space","with \"quote\"","Ærø",NULL}"#) { "{a\($0),b\($0)}" },
        sample("jsonb_array_col", "jsonb[]", min: "{}", max: #"{"{\"a\": 1}","[1, 2]"}"#) { #"{"{\"n\": \#($0)}"}"# },
        sample("oid_col", "oid", min: "0", max: "4294967295") { "\($0)" },
        sample("pg_lsn_col", "pg_lsn", min: "0/0", max: "FFFFFFFF/FFFFFFFF") { "16/B37\(String(format: "%05X", $0))" },
    ]

    private static func day(offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: 1_600_000_000 + TimeInterval(offset) * 86_400))
    }

    private static let unicode = ["Ærø", "Straße", "Ελληνικά", "日本語", "עברית", "العربية", "emoji 🚀✨", "Ünïcödé"]

    struct Document {
        var label: String
        var json: String
        var body: String
        var hexBytes: String
    }

    /// JSON documents from tiny to `largeValueKB`, with deep nesting and wide arrays.
    static func documents(largeValueKB: Int) -> [Document] {
        let deep = (0..<64).reduce(#""leaf""#) { inner, level in #"{"level\#(level)": \#(inner)}"# }
        let wide = "[" + (0..<5_000).map { #"{"i": \#($0), "s": "v\#($0)"}"# }.joined(separator: ",") + "]"
        let targetBytes = largeValueKB * 1024
        let item = #"{"sku": "A-000001", "name": "Løbehjul 漢字 🚀", "qty": 1, "price": 12.5}"#
        let large = "[" + Array(repeating: item, count: max(1, targetBytes / (item.utf8.count + 1))).joined(separator: ",") + "]"
        return [
            Document(label: "empty object", json: "{}", body: "", hexBytes: "\\x"),
            Document(label: "64 levels deep", json: deep, body: "deep", hexBytes: "\\x00ff"),
            Document(label: "5000 array items", json: wide, body: String(repeating: "w", count: 10_000), hexBytes: "\\x" + String(repeating: "ab", count: 4_096)),
            Document(label: "\(largeValueKB) KB", json: large, body: String(repeating: "Ærø 漢字 🚀 ", count: targetBytes / 20),
                     hexBytes: "\\x" + String(repeating: "5a", count: targetBytes)),
        ]
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
