import Foundation
import MySQLKit
import MySQLWire
import ServerLabKit

/// One column per MySQL/MariaDB type, with its smallest and largest values and a way to make more.
struct MySQLTypeSample: Sendable {
    var column: String
    var type: String
    var minimum: MySQLInsertValue
    var maximum: MySQLInsertValue
    var generated: @Sendable (Int) -> MySQLInsertValue

    static func text(_ value: String) -> MySQLInsertValue { .data(MySQLData(string: value)) }

    static func samples(engine: EngineKind, version: String) -> [MySQLTypeSample] {
        let mariaDB = engine == .mariadb
        // "10.10" is newer than "10.6": compare numbers part by part.
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        func atLeast(_ major: Int, _ minor: Int = 0) -> Bool {
            (parts.first ?? 0, parts.count > 1 ? parts[1] : 0) >= (major, minor)
        }
        func number(_ column: String, _ type: String, _ low: String, _ high: String) -> MySQLTypeSample {
            // Generated values fit every numeric type (TINYINT tops out at 127).
            MySQLTypeSample(column: column, type: type, minimum: text(low), maximum: text(high), generated: { text("\($0 % 100)") })
        }
        func string(_ column: String, _ type: String, _ high: String, generated: @escaping @Sendable (Int) -> String = { "row \($0)" }) -> MySQLTypeSample {
            MySQLTypeSample(column: column, type: type, minimum: text(""), maximum: text(high), generated: { text(generated($0)) })
        }
        func geometry(_ column: String, _ type: String, _ low: String, _ high: String) -> MySQLTypeSample {
            MySQLTypeSample(column: column, type: type, minimum: .geometry(wkt: low), maximum: .geometry(wkt: high),
                            generated: { .geometry(wkt: "POINT(\($0) \($0))".replacingOccurrences(of: "POINT", with: type == "POINT" || type == "GEOMETRY" ? "POINT" : "POINT")) })
        }
        let nines65 = String(repeating: "9", count: 35) + "." + String(repeating: "9", count: 30)
        var samples: [MySQLTypeSample] = [
            number("tinyint_col", "TINYINT", "-128", "127"),
            number("tinyint_unsigned_col", "TINYINT UNSIGNED", "0", "255"),
            number("smallint_col", "SMALLINT", "-32768", "32767"),
            number("smallint_unsigned_col", "SMALLINT UNSIGNED", "0", "65535"),
            number("mediumint_col", "MEDIUMINT", "-8388608", "8388607"),
            number("mediumint_unsigned_col", "MEDIUMINT UNSIGNED", "0", "16777215"),
            number("int_col", "INT", "-2147483648", "2147483647"),
            number("int_unsigned_col", "INT UNSIGNED", "0", "4294967295"),
            number("bigint_col", "BIGINT", "-9223372036854775808", "9223372036854775807"),
            number("bigint_unsigned_col", "BIGINT UNSIGNED", "0", "18446744073709551615"),
            MySQLTypeSample(column: "bool_col", type: "BOOLEAN", minimum: text("0"), maximum: text("1"), generated: { text("\($0 % 2)") }),
            number("decimal_col", "DECIMAL(65,30)", "-" + nines65, nines65),
            number("money_col", "DECIMAL(19,4)", "-922337203685477.5808", "922337203685477.5807"),
            number("float_col", "FLOAT", "-3.40282e38", "3.40282e38"),
            number("double_col", "DOUBLE", "-1.7976931348623157e308", "1.7976931348623157e308"),
            MySQLTypeSample(column: "bit1_col", type: "BIT(1)", minimum: .bits(0), maximum: .bits(1), generated: { .bits(UInt64($0 % 2)) }),
            MySQLTypeSample(column: "bit64_col", type: "BIT(64)", minimum: .bits(0), maximum: .bits(.max), generated: { .bits(UInt64($0)) }),
            MySQLTypeSample(column: "date_col", type: "DATE", minimum: text("1000-01-01"), maximum: text("9999-12-31"),
                            generated: { text(String(format: "2024-%02d-%02d", $0 % 12 + 1, $0 % 28 + 1)) }),
            MySQLTypeSample(column: "time_col", type: "TIME(6)", minimum: text("-838:59:59.000000"), maximum: text("838:59:59.000000"),
                            generated: { text(String(format: "%02d:%02d:%02d.%06d", $0 % 24, $0 % 60, $0 % 60, $0)) }),
            MySQLTypeSample(column: "datetime_col", type: "DATETIME(6)", minimum: text("1000-01-01 00:00:00.000000"),
                            maximum: text("9999-12-31 23:59:59.999999"), generated: { text(String(format: "2024-01-01 %02d:00:00.%06d", $0 % 24, $0)) }),
            MySQLTypeSample(column: "timestamp_col", type: "TIMESTAMP(6) NULL", minimum: text("1970-01-01 00:00:01.000000"),
                            maximum: text("2038-01-19 03:14:07.999999"), generated: { text(String(format: "2020-06-01 %02d:30:00.000001", $0 % 24)) }),
            MySQLTypeSample(column: "year_col", type: "YEAR", minimum: text("1901"), maximum: text("2155"), generated: { text("\(1901 + $0 % 255)") }),
            string("char_col", "CHAR(10)", String(repeating: "Z", count: 10)),
            string("varchar_col", "VARCHAR(255)", String(repeating: "Ω", count: 255)),
            MySQLTypeSample(column: "binary_col", type: "BINARY(16)", minimum: text(String(repeating: "\u{0}", count: 16)),
                            maximum: text(String(repeating: "\u{7F}", count: 16)), generated: { text(String(format: "%016d", $0)) }),
            string("varbinary_col", "VARBINARY(255)", String(repeating: "\u{7F}", count: 255)),
            string("tinytext_col", "TINYTEXT", String(repeating: "t", count: 255)),
            string("text_col", "TEXT", String(repeating: "Text ", count: 13_000)),
            string("mediumtext_col", "MEDIUMTEXT", String(repeating: "Medium ", count: 20_000)),
            string("longtext_col", "LONGTEXT", String(repeating: "Long ", count: 60_000)),
            string("tinyblob_col", "TINYBLOB", String(repeating: "b", count: 255)),
            string("blob_col", "BLOB", String(repeating: "B", count: 65_535)),
            string("mediumblob_col", "MEDIUMBLOB", String(repeating: "M", count: 100_000)),
            string("longblob_col", "LONGBLOB", String(repeating: "L", count: 200_000)),
            MySQLTypeSample(column: "enum_col", type: "ENUM('small','medium','large')", minimum: text("small"), maximum: text("large"),
                            generated: { text(["small", "medium", "large"][$0 % 3]) }),
            MySQLTypeSample(column: "set_col", type: "SET('red','green','blue')", minimum: text(""), maximum: text("red,green,blue"),
                            generated: { text(["red", "green", "blue", "red,blue"][$0 % 4]) }),
            MySQLTypeSample(column: "json_col", type: "JSON", minimum: mariaDB ? text("{}") : .json("{}"),
                            maximum: mariaDB ? text(#"{"a":[1,2,{"b":null}],"s":"é","n":1.5e10}"#) : .json(#"{"a":[1,2,{"b":null}],"s":"é","n":1.5e10}"#),
                            generated: { mariaDB ? text("{\"row\":\($0)}") : .json("{\"row\":\($0)}") }),
            geometry("geometry_col", "GEOMETRY", "POINT(0 0)", "POLYGON((0 0,10 0,10 10,0 10,0 0))"),
            geometry("point_col", "POINT", "POINT(-180 -90)", "POINT(180 90)"),
            geometry("linestring_col", "LINESTRING", "LINESTRING(0 0,1 1)", "LINESTRING(0 0,1 1,2 2,3 3)"),
            geometry("polygon_col", "POLYGON", "POLYGON((0 0,1 0,1 1,0 0))", "POLYGON((0 0,10 0,10 10,0 10,0 0),(2 2,3 2,3 3,2 2))"),
            geometry("multipoint_col", "MULTIPOINT", "MULTIPOINT((0 0))", "MULTIPOINT((0 0),(1 1),(2 2))"),
            geometry("multilinestring_col", "MULTILINESTRING", "MULTILINESTRING((0 0,1 1))", "MULTILINESTRING((0 0,1 1),(2 2,3 3))"),
            geometry("multipolygon_col", "MULTIPOLYGON", "MULTIPOLYGON(((0 0,1 0,1 1,0 0)))", "MULTIPOLYGON(((0 0,1 0,1 1,0 0)),((5 5,6 5,6 6,5 5)))"),
            geometry("geometrycollection_col", "GEOMETRYCOLLECTION", "GEOMETRYCOLLECTION(POINT(0 0))",
                     "GEOMETRYCOLLECTION(POINT(0 0),LINESTRING(0 0,1 1))"),
        ]
        // The generated geometry for typed columns must match the column's type.
        for index in samples.indices where samples[index].type != "GEOMETRY" && samples[index].type != "POINT" && samples[index].column.hasSuffix("_col")
            && ["LINESTRING", "POLYGON", "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION"].contains(samples[index].type) {
            let maximum = samples[index].maximum
            samples[index].generated = { _ in maximum }
        }
        if (!mariaDB && atLeast(9)) || (mariaDB && atLeast(11, 8)) {
            samples.append(MySQLTypeSample(column: "vector_col", type: "VECTOR(3)", minimum: .vector([0, 0, 0], mariaDB: mariaDB),
                                           maximum: .vector([1.5, -2, 3.25], mariaDB: mariaDB),
                                           generated: { .vector([Float($0), 1, -1], mariaDB: mariaDB) }))
        }
        if mariaDB {
            samples.append(MySQLTypeSample(column: "inet6_col", type: "INET6", minimum: text("::"), maximum: text("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"),
                                           generated: { text("2001:db8::\($0)") }))
            if atLeast(10, 10) {
                samples.append(MySQLTypeSample(column: "inet4_col", type: "INET4", minimum: text("0.0.0.0"), maximum: text("255.255.255.255"),
                                               generated: { text("10.0.0.\($0 % 256)") }))
            }
            if atLeast(10, 7) { samples.append(MySQLTypeSample(column: "uuid_col", type: "UUID", minimum: text("00000000-0000-0000-0000-000000000000"),
                                           maximum: text("ffffffff-ffff-ffff-ffff-ffffffffffff"), generated: { _ in text(UUID().uuidString) })) }
        }
        return samples
    }
}
