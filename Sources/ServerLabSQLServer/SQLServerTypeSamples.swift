import Foundation
import SQLServerKit

/// One column of the column-types pack: its type and the values seeded into it.
struct SQLServerTypeSample: Sendable {
    let column: String
    let type: SQLDataType
    let minimum: SQLServerLiteralValue
    let maximum: SQLServerLiteralValue
    let generated: @Sendable (Int) -> SQLServerLiteralValue
    /// First SQL Server version with the type.
    var since = 2017
    /// False for types the server fills itself (rowversion).
    var isInsertable = true
}

enum SQLServerTypeSamples {
    static func samples(forVersion version: Int) -> [SQLServerTypeSample] {
        all.filter { version >= $0.since }
    }

    private static let all: [SQLServerTypeSample] = numbers + dates + text + binary + other + spatialAndNewer

    private static let numbers: [SQLServerTypeSample] = [
        .init(column: "BitCol", type: .bit, minimum: .bool(false), maximum: .bool(true), generated: { .bool($0 % 2 == 0) }),
        .init(column: "TinyIntCol", type: .tinyint, minimum: .int(0), maximum: .int(255), generated: { .int($0 % 256) }),
        .init(column: "SmallIntCol", type: .smallint, minimum: .int(-32_768), maximum: .int(32_767), generated: { .int($0 * 7 % 32_767) }),
        .init(column: "IntCol", type: .int, minimum: .int(Int(Int32.min)), maximum: .int(Int(Int32.max)), generated: { .int($0 * 104_729) }),
        .init(column: "BigIntCol", type: .bigint, minimum: .int64(.min), maximum: .int64(.max), generated: { .int64(Int64($0) * 9_999_999_967) }),
        .init(column: "DecimalCol", type: .decimal(precision: 38, scale: 10),
              minimum: .decimal("-9999999999999999999999999999.9999999999"),
              maximum: .decimal("9999999999999999999999999999.9999999999"),
              generated: { .decimal("\($0).\(String(format: "%010d", $0 * 7919 % 10_000_000_000))") }),
        .init(column: "NumericCol", type: .numeric(precision: 18, scale: 4),
              minimum: .decimal("-99999999999999.9999"), maximum: .decimal("99999999999999.9999"),
              generated: { .decimal("\($0 * 13).\(String(format: "%04d", $0 % 10_000))") }),
        .init(column: "MoneyCol", type: .money, minimum: .decimal("-922337203685477.5808"), maximum: .decimal("922337203685477.5807"),
              generated: { .decimal("\($0 * 101).\(String(format: "%02d", $0 % 100))") }),
        .init(column: "SmallMoneyCol", type: .smallmoney, minimum: .decimal("-214748.3648"), maximum: .decimal("214748.3647"),
              generated: { .decimal("\($0 % 214_748).25") }),
        .init(column: "FloatCol", type: .float(mantissa: 53), minimum: .double(-1.79e308), maximum: .double(1.79e308),
              generated: { .double(Double($0) * 3.141592653589793) }),
        .init(column: "RealCol", type: .real, minimum: .double(-3.40e38), maximum: .double(3.40e38),
              generated: { .double(Double($0) / 7) }),
    ]

    private static let dates: [SQLServerTypeSample] = [
        .init(column: "DateCol", type: .date, minimum: .string("0001-01-01"), maximum: .string("9999-12-31"),
              generated: { .string(date(dayOffset: $0)) }),
        .init(column: "DateTimeCol", type: .datetime, minimum: .string("1753-01-01T00:00:00"), maximum: .string("9999-12-31T23:59:59.997"),
              generated: { .string("\(date(dayOffset: $0))T12:34:56.123") }),
        .init(column: "DateTime2Col", type: .datetime2(precision: 7),
              minimum: .string("0001-01-01T00:00:00.0000000"), maximum: .string("9999-12-31T23:59:59.9999999"),
              generated: { .string("\(date(dayOffset: $0))T08:15:30.1234567") }),
        .init(column: "SmallDateTimeCol", type: .smalldatetime,
              minimum: .string("1900-01-01T00:00:00"), maximum: .string("2079-06-06T23:59:00"),
              generated: { .string("\(date(dayOffset: $0))T17:45:00") }),
        .init(column: "TimeCol", type: .time(precision: 7), minimum: .string("00:00:00.0000000"), maximum: .string("23:59:59.9999999"),
              generated: { .string(String(format: "%02d:%02d:%02d.%07d", $0 % 24, $0 % 60, ($0 * 7) % 60, $0 % 10_000_000)) }),
        .init(column: "DateTimeOffsetCol", type: .datetimeoffset(precision: 7),
              minimum: .string("0001-01-01T14:00:00.0000000+14:00"), maximum: .string("9999-12-31T09:59:59.9999999-14:00"),
              generated: { .string("\(date(dayOffset: $0))T09:00:00.0000000\(offsets[$0 % offsets.count])") }),
    ]

    private static let text: [SQLServerTypeSample] = [
        .init(column: "CharCol", type: .char(length: 10), minimum: .string(""), maximum: .string("abcdefghij"),
              generated: { .string("c\($0)") }),
        .init(column: "VarCharCol", type: .varchar(length: .length(255)), minimum: .string(""), maximum: .string(String(repeating: "x", count: 255)),
              generated: { .string("row \($0)") }),
        .init(column: "VarCharMaxCol", type: .varchar(length: .max), minimum: .string(""), maximum: .string(String(repeating: "v", count: 9_000)),
              generated: { .string(String(repeating: "m", count: $0 % 50)) }),
        .init(column: "TextCol", type: .text, minimum: .string(""), maximum: .string(String(repeating: "t", count: 9_000)),
              generated: { .string("legacy text \($0)") }),
        .init(column: "NCharCol", type: .nchar(length: 10), minimum: .nString(""), maximum: .nString("ÆØÅæøå漢字🚀"),
              generated: { .nString(unicodeSamples[$0 % unicodeSamples.count]) }),
        .init(column: "NVarCharCol", type: .nvarchar(length: .length(255)), minimum: .nString(""), maximum: .nString(String(repeating: "Ω", count: 255)),
              generated: { .nString("\(unicodeSamples[$0 % unicodeSamples.count]) \($0)") }),
        .init(column: "NVarCharMaxCol", type: .nvarchar(length: .max), minimum: .nString(""), maximum: .nString(String(repeating: "漢", count: 5_000)),
              generated: { .nString(String(repeating: "ü", count: $0 % 80)) }),
        .init(column: "NTextCol", type: .ntext, minimum: .nString(""), maximum: .nString(String(repeating: "ñ", count: 5_000)),
              generated: { .nString("legacy ntext \($0) ☃") }),
    ]

    private static let binary: [SQLServerTypeSample] = [
        .init(column: "BinaryCol", type: .binary(length: 16), minimum: .bytes([UInt8](repeating: 0, count: 16)),
              maximum: .bytes([UInt8](repeating: 0xFF, count: 16)), generated: { .bytes(bytes(seed: $0, count: 16)) }),
        .init(column: "VarBinaryCol", type: .varbinary(length: .length(255)), minimum: .bytes([0]),
              maximum: .bytes([UInt8](repeating: 0xAB, count: 255)), generated: { .bytes(bytes(seed: $0, count: $0 % 64 + 1)) }),
        .init(column: "VarBinaryMaxCol", type: .varbinary(length: .max), minimum: .bytes([0]),
              maximum: .bytes(bytes(seed: 1, count: 9_000)), generated: { .bytes(bytes(seed: $0, count: $0 % 200 + 1)) }),
        .init(column: "ImageCol", type: .image, minimum: .bytes([0]),
              maximum: .bytes(bytes(seed: 2, count: 9_000)), generated: { .bytes(bytes(seed: $0, count: 32)) }),
    ]

    private static let other: [SQLServerTypeSample] = [
        .init(column: "UniqueIdentifierCol", type: .uniqueidentifier,
              minimum: .uuid(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))),
              maximum: .uuid(UUID(uuid: (255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255))),
              generated: { .uuid(uuid(seed: $0)) }),
        .init(column: "SqlVariantCol", type: .sql_variant, minimum: .variant(.int(0)), maximum: .variant(.nString("variant text")),
              generated: { $0 % 3 == 0 ? .variant(.int($0)) : $0 % 3 == 1 ? .variant(.nString("variant \($0)")) : .variant(.decimal("\($0).5")) }),
        .init(column: "XmlCol", type: .xml, minimum: .nString("<empty/>"),
              maximum: .nString("<order id=\"1\"><line sku=\"A-1\" qty=\"2\">Løbehjul</line><line sku=\"B-2\" qty=\"1\"/></order>"),
              generated: { .nString("<row n=\"\($0)\"><v>\($0 * 3)</v></row>") }),
    ]

    private static let spatialAndNewer: [SQLServerTypeSample] = [
        .init(column: "RowVersionCol", type: .rowversion, minimum: .null, maximum: .null, generated: { _ in .null }, isInsertable: false),
        .init(column: "HierarchyIdCol", type: .hierarchyid, minimum: .hierarchyID("/"), maximum: .hierarchyID("/1/2/3/4/5/6/7/8/"),
              generated: { .hierarchyID("/\($0 % 10 + 1)/\($0 % 7 + 1)/") }),
        .init(column: "GeometryCol", type: .geometry, minimum: .geometry(wellKnownText: "POINT EMPTY", srid: 0),
              maximum: .geometry(wellKnownText: "POLYGON ((0 0, 0 10, 10 10, 10 0, 0 0))", srid: 0),
              generated: { .geometry(wellKnownText: "LINESTRING (0 0, \($0) \($0 * 2))", srid: 0) }),
        .init(column: "GeographyCol", type: .geography, minimum: .geography(wellKnownText: "POINT (-179.9 -89.9)", srid: 4326),
              maximum: .geography(wellKnownText: "POINT (179.9 89.9)", srid: 4326),
              generated: { .geography(wellKnownText: "POINT (\(Double($0 % 360) - 179.5) \(Double($0 % 180) - 89.5))", srid: 4326) }),
        .init(column: "JsonCol", type: .json, minimum: .nString("{}"),
              maximum: .nString(#"{"nested": {"array": [1, "two", 3.0, true, null], "unicode": "Ærø 漢字 🚀"}}"#),
              generated: { .nString(#"{"n": \#($0), "even": \#($0 % 2 == 0)}"#) }, since: 2025),
        .init(column: "VectorCol", type: .vector(dimensions: 3), minimum: .string("[-1, -1, -1]"), maximum: .string("[1, 1, 1]"),
              generated: { .string("[\(Double($0) / 100), 0.5, -0.25]") }, since: 2025),
    ]

    private static let unicodeSamples = ["Ærø", "Straße", "Ελληνικά", "日本語", "עברית", "العربية", "emoji 🚀✨", "Ünïcödé"]
    private static let offsets = ["+00:00", "+01:00", "-05:00", "+05:30", "+14:00", "-12:00"]

    private static func date(dayOffset: Int) -> String {
        let day = Date(timeIntervalSince1970: 1_600_000_000 + TimeInterval(dayOffset) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    private static func bytes(seed: Int, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: ($0 &+ seed) &* 131) }
    }

    private static func uuid(seed: Int) -> UUID {
        let hex = String(format: "%08X-0000-4000-8000-%012X", seed, seed &* 2_654_435_761 & 0xFFFF_FFFF_FFFF)
        return UUID(uuidString: hex) ?? UUID()
    }
}
