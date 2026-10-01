# SQLite coverage catalogue

Driver: Vapor's **`sqlite-nio`** (Echo pins 1.12.10). It is not a first-party package and has **no typed DDL or
DML API**: everything goes through `SQLiteConnection.query(_:_:)` with SQL text and `SQLiteData` binds.
Under the owner's rule every SQLite item is therefore a **GAP** until a typed layer exists (GL-00). SQLite
needs no server: a recipe produces a database **file** that Echo opens, so the feasibility column says
**file** for almost everything.

The SQLite library compiled into `sqlite-nio` (read from its checkout in Echo's DerivedData: `SQLITE_VERSION
"3.53.4"`, `Package.swift` defines) has `SQLITE_ENABLE_FTS5`, `SQLITE_ENABLE_RTREE`,
`SQLITE_ENABLE_DBSTAT_VTAB`, `SQLITE_ENABLE_SESSION`, and **`SQLITE_OMIT_LOAD_EXTENSION`**. So FTS3/FTS4,
Geopoly, `sqlite_stat4`, and every loadable extension (SpatiaLite, sqlite-vec, sqlean) are unavailable to Echo
today; files that use them can still be opened but those tables fail to read (a useful edge case). JSON
functions are built in since 3.38; JSONB since 3.45. Math functions depend on
`SQLITE_ENABLE_MATH_FUNCTIONS`, which is not in the define list (check).

Echo's SQLite tree shows Databases (main and attached), Tables, Views and a Maintenance tool.

---

> **Built so far (2026-10-01).** Fixture files through sqlite-nio (`LabSQLite`, `serverlab sqlite`):
> `all-types` (every declared type and affinity, extremes, a STRICT table), `programmability` (FKs,
> CHECK, generated columns, AUTOINCREMENT, WITHOUT ROWID, partial/expression/descending indexes, view,
> triggers, FTS5, R*Tree when compiled in), `chinook`. Not yet: attached databases, WAL vs rollback
> journal files, encrypted (SQLCipher) files, very large files.

## 1. Data types

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes (edge values worth seeding) |
|---|---|---|---|---|---|---|---|
| SL-DT-01 | Storage classes NULL, INTEGER, REAL, TEXT, BLOB in one untyped column | all | tables (column) | GAP GL-01, GL-07 | file | lite.types | mixed types in one column; Echo's grid must not assume one type per column |
| SL-DT-02 | Type affinity from declared names (`VARCHAR(10)`, `DATETIME`, `BOOLEAN`, `NUMERIC`, `DECIMAL(10,2)`, `DOUBLE`, `FLOATING POINT` → INTEGER affinity quirk, no type) | all | tables (column) | GAP GL-01 | file | lite.types | `'00123'` in NUMERIC column becomes 123 |
| SL-DT-03 | 64-bit integers: -9223372036854775808, 9223372036854775807, overflow to REAL | all | tables (column) | GAP GL-07 | file | lite.types | |
| SL-DT-04 | REAL edge values: ±1.7976931348623157e308, -0.0, NaN (stored as NULL), Infinity (`9e999`) | all | tables (column) | GAP GL-07 | file | lite.types | |
| SL-DT-05 | Dates as TEXT ISO-8601, REAL Julian day, INTEGER Unix epoch (and `unixepoch()` 3.38+) | all | tables (column) | GAP GL-07 | file | lite.types | Echo date detection heuristics |
| SL-DT-06 | Booleans as 0/1 and `TRUE`/`FALSE` keywords (3.23+) | 3.23+ | tables (column) | GAP GL-07 | file | lite.types | |
| SL-DT-07 | TEXT: 10 MB value, embedded NUL, invalid UTF-8 bytes stored as TEXT, emoji | all | tables (column) | GAP GL-07 | file | lite.edge.scale | |
| SL-DT-08 | BLOB: empty, 10 MB, PNG/JPEG bytes, zeroblob | all | tables (column) | GAP GL-07 | file | lite.types | |
| SL-DT-09 | JSON as TEXT; JSONB as BLOB (3.45+) | 3.38+/3.45+ | tables (column) | GAP GL-07 | file | lite.json | JSONB blobs look like binary to a naive viewer |
| SL-DT-10 | STRICT table types `INT`, `INTEGER`, `REAL`, `TEXT`, `BLOB`, `ANY` | 3.37+ | tables (column) | GAP GL-01 | file | lite.schema.core | file with STRICT tables cannot be opened by SQLite < 3.37 |
| SL-DT-11 | Generated columns VIRTUAL and STORED | 3.31+ | tables (column) | GAP GL-01 | file | lite.schema.core | |
| SL-DT-12 | Column collations `BINARY`, `NOCASE`, `RTRIM`; unknown collation (from another app) | all | tables (column) | GAP GL-01 | file | lite.schema.core | a file declaring a custom collation Echo doesn't register: queries error |
| SL-DT-13 | UTF-16le / UTF-16be database encoding | all | databases | GAP GL-06 | file | lite.config | set before first table |

## 2. Schema objects

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SL-SO-01 | Rowid table; `INTEGER PRIMARY KEY` rowid alias; `AUTOINCREMENT` with `sqlite_sequence` | all | tables | GAP GL-01 | file | lite.schema.core | `INT PRIMARY KEY` is not an alias (edge) |
| SL-SO-02 | `WITHOUT ROWID` table | 3.8.2+ | tables | GAP GL-01 | file | lite.schema.core | |
| SL-SO-03 | `STRICT` table, `STRICT, WITHOUT ROWID` | 3.37+ | tables | GAP GL-01 | file | lite.schema.core | |
| SL-SO-04 | Constraints: PRIMARY KEY (composite), UNIQUE, CHECK, NOT NULL, DEFAULT expressions, conflict clauses (`ON CONFLICT REPLACE/IGNORE`) | all | tables | GAP GL-01 | file | lite.schema.core | |
| SL-SO-05 | Foreign keys (actions, deferrable, violations present with `foreign_keys=OFF`) | all | tables | GAP GL-01, GL-06 | file | lite.schema.core | `PRAGMA foreign_key_check` finds rows |
| SL-SO-06 | Indexes: unique, multi-column, DESC, COLLATE, partial (3.8+), expression (3.9+) | all | none — check: indexes shown in table structure | GAP GL-02 | file | lite.schema.core | |
| SL-SO-07 | Views (including view over attached database, broken view over dropped table) | all | views | GAP GL-03 | file | lite.schema.core | |
| SL-SO-08 | Triggers BEFORE/AFTER/INSTEAD OF (on view), `UPDATE OF`, `WHEN`, recursive triggers | all | none — Echo does not show triggers in the SQLite tree | GAP GL-03 | file | lite.schema.core | |
| SL-SO-09 | Temporary tables, views and triggers (`temp` schema) | all | databases (`temp`) | GAP GL-03 | file (live connection only) | lite.workload | vanish when the connection closes |
| SL-SO-10 | FTS5 virtual table (unicode61, porter, trigram 3.34+, `ascii`), external-content and contentless tables, shadow tables (`_data`, `_idx`, `_content`, `_docsize`, `_config`) | 3.9+ | tables | GAP GL-04 | file | lite.fts5 | shadow tables must not clutter the tree |
| SL-SO-11 | FTS3/FTS4 virtual table | all | tables | GAP GL-04, GL-08 (not compiled into sqlite-nio) | file (produced by another SQLite build) | lite.fts-legacy | reading one in Echo errors today: good error fixture |
| SL-SO-12 | R*Tree (`rtree`, `rtree_i32`, auxiliary columns 3.24+) | 3.8.5+ | tables | GAP GL-04 | file | lite.rtree | shadow tables `_node`, `_parent`, `_rowid` |
| SL-SO-13 | Geopoly | 3.25+ | tables | GAP GL-04, GL-08 (not compiled) | file (other build) | lite.rtree | |
| SL-SO-14 | Table-valued functions: `json_each`, `json_tree`, `dbstat`, `pragma_*` | 3.9+ | none (queries) | N/A (query-time only) | file | lite.json | |
| SL-SO-15 | `sqlite_stat1` after `ANALYZE`; `sqlite_stat4` | all (stat4 compile flag) | tables (system) | GAP GL-09 (stat4 also GL-08) | file | lite.schema.core | |
| SL-SO-16 | Attached databases (`main`, `temp`, two attached files, attached `:memory:`, same table name in two databases) | all | databases | GAP GL-05 | file (several files) | lite.attached | default limit 10 attached databases |
| SL-SO-17 | Tables created by other tools: Core Data store (`Z_PRIMARYKEY`, `ZENTITY`), Android `android_metadata`, Firefox `places.sqlite` (WAL), SpatiaLite metadata tables, SQLCipher-encrypted file | all | tables | GAP GL-00 (fixtures are external files, not pack-created) | file | lite.foreign-files | an encrypted file must produce a clear "not a database" error |

## 3. Configuration, states and edge cases

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SL-CF-01 | Journal modes DELETE, TRUNCATE, PERSIST, MEMORY, WAL (with `-wal`/`-shm` files present), OFF | all (WAL 3.7+) | databases | GAP GL-06 | file | lite.config | WAL file with uncheckpointed frames |
| SL-CF-02 | Page size 512–65536, `auto_vacuum` NONE/FULL/INCREMENTAL, `user_version`, `application_id`, `secure_delete` | all | databases | GAP GL-06 | file | lite.config | |
| SL-CF-03 | Read-only file (permissions), file on read-only volume, `immutable=1` URI | all | databases | HARNESS (file mode) | file | lite.states | |
| SL-CF-04 | Locked database (another process holds a write transaction or an exclusive lock) | all | databases | GAP GL-07 (needs a live second connection) | file + live helper process | lite.workload | `SQLITE_BUSY` handling |
| SL-CF-05 | Hot journal left behind (`-journal` after a crash) | all | databases | HARNESS (kill a writer mid-transaction) | file | lite.states.damaged | |
| SL-CF-06 | Corrupt file (bad page, truncated file), non-SQLite file with `.sqlite` extension, empty 0-byte file | all | databases | HARNESS (write bytes) | file | lite.states.damaged | `PRAGMA integrity_check` output |
| SL-CF-07 | Names: Unicode, spaces, `"`, `[`, `` ` `` quoting styles, reserved words, `sqlite_` prefix (reserved), names differing only by case (SQLite is case-insensitive for ASCII) | all | tables / views | GAP GL-01 | file | lite.edge.names | |
| SL-CF-08 | 2,000-column table (default `SQLITE_MAX_COLUMN`), 10,000 tables, 1 GB file, 1 million rows | all | tables | GAP GL-01, GL-07 | file | lite.edge.scale | |
| SL-CF-09 | NULL-heavy data | all | tables | GAP GL-07 | file | lite.edge.nulls | |
| SL-CF-10 | Empty database (no tables), in-memory database | all | databases | GAP GL-00 | file | lite.edge.empty | |
| SL-CF-11 | Files written by older SQLite (legacy file format 1, schema format 1–4) and by newer SQLite with features unknown to Echo's bundled version | all | databases | HARNESS (files made by other SQLite builds) | file | lite.foreign-files | |
| SL-CF-12 | Loadable extensions (SpatiaLite geometry blobs, sqlite-vec vectors) | — | tables | GAP GL-08 (`SQLITE_OMIT_LOAD_EXTENSION`) | file (other build) | lite.foreign-files | |

## 4. Sample databases

See [sample-databases.md](sample-databases.md).

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SL-SA-01 | Chinook (`Chinook_Sqlite.sqlite`) | all | databases | READY (the published file is the fixture; or a typed pack from `ChinookData.json` after GL-00) | file | lite.sample.chinook | 1 MB |
| SL-SA-02 | Northwind (jpwhite3/northwind-SQLite3) | all | databases | READY (published file) | file | lite.sample.northwind | |
| SL-SA-03 | Sakila (bradleygrant/sakila-sqlite3) | all | databases | READY (published file) | file | lite.sample.sakila | |
