# Driver gaps

Every typed API the packs need that the drivers do not have yet. Counts are the catalogue rows whose
**Typed API** column names the gap (as GAP or PARTIAL); a gap that is cross-cutting (it affects how every
pack is written rather than one row) says so. Signatures follow each driver's existing style: namespaced
clients on the client (`client.admin`, `client.security`, …), `async throws`, SQL Server calls returning
`[SQLServerStreamMessage]` where the neighbours do, PostgreSQL DDL returning `Int`.

IDs: **GS** = sqlserver-nio, **GP** = postgres-wire, **GM** = mysql-wire, **GL** = SQLite (no first-party
driver yet).

Rules that apply to all gaps:

- The escape hatches that exist today are **not** typed APIs and packs must not use them:
  `SQLServerLiteralValue.raw(String)`, `SQLServerClient.execute/query(_ sql:)`,
  `PostgresInsertValue.sql(String)`, `PostgresClient.simpleQuery`, `PostgresBulkCopy.copyIn(sql:source:)`,
  `MySQLAdminClient.executeDDL(_:)`, `sqlite-nio` `query(_:)`. The lab should enforce this with a lint check
  over pack sources.
- Bodies of routines, views, triggers and policies are SQL by nature (`createStoredProcedure(body:)`,
  `createView(query:)`); passing them as strings is accepted as typed. Everything around the body (names,
  parameters, options, schedules) must be typed.

## Found and fixed while building the lab (2026-09-30)

Fixed in sqlserver-nio `dev`:

| Commit | What |
|---|---|
| `0b55ec6` | **GS-01 partly done.** `SQLDataType` gains `rowversion`, `hierarchyid`, `geometry`, `geography`, `json`, `vector(dimensions:)`. **GS-02 partly done.** `SQLServerLiteralValue` gains `.variant(_:)` (a multi-row INSERT converted a `sql_variant` column's values to one type), `.geometry(wellKnownText:srid:)`, `.geography(wellKnownText:srid:)`, `.hierarchyID(_:)`. Still open: typed `xml` (schema collections) and typed time/datetimeoffset values. |
| `4b6707f` | **Bug:** `listColumns` dropped `hierarchyid`, `geometry` and `geography` columns (inner join on system type 240, which has no row of its own in `sys.types`). Echo's Explorer did not show these columns. |
| `12e317c` | **Bug:** `tableProperties.rowCount` counted each row once per allocation unit, up to 3× for tables with LOB columns. |
| `fa2228d` | **GS-09, GS-10, GS-11 done**, plus inline TVFs: `admin.createSequence`/`dropSequence`, `admin.createSynonym`/`dropSynonym` (`SQLServerObjectName`), `types.createAliasType`, `routines.createInlineTableValuedFunction`. |

| `e8d0893` + `bbc8a37` | **Bug:** `addForeignKey`/`addCheckConstraint` put `WITH NOCHECK` after the constraint (a syntax error); `ForeignKeyOptions.isNotTrusted` emitted `NOT FOR REPLICATION`. Now `WITH NOCHECK` precedes `ADD`, `isNotTrusted` creates the key untrusted, and `notForReplication` is its own option. |

| `d25c627` | `security.createMasterKey`, `createCertificate`, `dropCertificate` (certificate logins had no way to get a certificate). |
| `7744c74` | **Bug:** `addMask` with `.partial` or `.datetime` sent `FUNCTION = 'partial(2, 'XXX', 1)'` (broken quoting); Echo's New Mask sheet hit this. |

| `94f7dda` | Linked servers default to `MSOLEDBSQL` (`SQLNCLI` does not exist on Linux or SQL Server 2022). Echo's New Linked Server sheet still defaults to `SQLNCLI`: an Echo change, to go through Echo Labs. |
| `db19f0f` | **Bug:** `tableProperties` returned nothing for partitioned tables (inner join to `sys.filegroups`). |

Fixed in postgres-wire `dev` (`0718e6b`): grants and policies take `schema:`, column-level grants (`columns:`); **bug:** `grantRole` ignored `inherit:`/`set:`; **bug:** `PUBLIC`/`CURRENT_USER` grantees were quoted as role names.

Fixed in postgres-wire `dev` (`5e30efe`): `createIndex`/`createAdvancedIndex` and primary/foreign/unique/check constraints take `schema:`; `PostgresIndexColumn(expression:)`, `operatorClass`, `include:` (covering indexes) and `PostgresIndexType.spgist`.

Fixed in postgres-wire `dev` (`d631da1`):

- **GP-01 mostly done:** `createTable`, `createView`, `createMaterializedView`, `createFunction`, `createTrigger` (table), `createSequence`, `createEnum` and `bulk.insert` take `schema:`. Still without: `createIndex`, `createAdvancedIndex`, `createTableAs`, grants, `addForeignKey`, `createPolicy`, update/delete.
- `routines.createProcedure` / `dropProcedure` (Echo's PostgreSQL Procedures folder had no source).
- `metadata.exactRowCount(schema:table:)`, `types.typeExists(name:schema:)`.
- **Bug:** `insert` returned the number of result rows (always 0 for a plain INSERT); it returns the inserted count.
- **Bug:** `createEnum(ifNotExists:)` emitted `CREATE TYPE IF NOT EXISTS` (not valid PostgreSQL).
- **Bug:** `PostgresFunctionLanguage.plpython` was `PLPYTHONU` (Python 2); now `PLPYTHON3U`.

Still open, found while building:

- **postgres-wire:** `WireClient` starts `PostgresClient.run()` in a detached task and leases at once, so PostgresNIO logs "run() hasn't been called yet" on the first query. Harmless, but noisy.
- **postgres-wire:** `admin.createDatabase(ifNotExists: true)` emits `CREATE DATABASE IF NOT EXISTS`, which PostgreSQL does not support.
- **postgres-wire:** `routines.createFunction` defaults to `SECURITY DEFINER`; the safe default is `INVOKER`. Changing it could affect callers, so it is left for a decision.
- **sqlserver-nio:** `SQLServerAgentJobBuilder.commit()` is not atomic when Agent refuses a later step; its rollback (`deleteJob`) is refused too, leaving a half-created job. Seen on SQL Server 2017 while Agent starts.
- **sqlserver-nio:** `metadata.fetchAgentStatus()` reports Agent as running on SQL Server 2017 before it accepts job changes.

## Found while adding TLS servers (2026-09-30)

| Driver | Owner | What |
|---|---|---|
| postgres-wire | driver agent | Connecting with `sslCertPath`/`sslKeyPath` (client-certificate login) logs a PostgresNIO warning, "Trying to lease connection from `PostgresClient`, but `PostgresClient.run()` hasn't been called yet". Login works; the warning suggests an unused PostgresNIO client on that path. Repro: `pg-17-tls-client-certificate`, `PostgresClientCertificateTests`. |
| sqlserver-nio | core | A failed certificate check is thrown **and** logged twice at error level ("TDS pipeline error", "Uncaught error: NIOSSLExtraError.failedToValidateHostname"). Repro: `mssql-2022-tls-wrong-host`, `SQLServerWrongHostCertificateTests`. |
| sqlserver-nio | core | Windows login with a password fails over to NTLMv2 when `KRB5CCNAME` names a FILE cache: GSS "Moving credentials between different types not yet supported (from XCTEMP to FILE)". SQL Server on Linux then refuses NTLM ("untrusted domain"). Repro: `mssql-2022-kerberos`, set `KRB5CCNAME=FILE:/tmp/x`, `.windowsIntegrated(username:password:domain:)`. `LabKerberosInfo.withTicket(credentials: .password)` clears `KRB5CCNAME` to avoid it. |
| sqlserver-nio | core | A `serverSPN` connection option (like SqlClient/JDBC `ServerSPN`) so clients can reach a server by IP or alias and still ask for `MSSQLSvc/<name>:<port>`. |
| sqlserver-nio | core | TLS key logging (`SSLKEYLOGFILE`, NIOSSL `keyLogCallback`) so the lab's captures of encrypted TDS can be decrypted in Wireshark. |
| postgres-wire | lab | The same key logging for PostgreSQL. |
| sqlserver-nio | lab | Fixed while building `server-features`: `cms.addGroup`/`addServer` (missing `@server_type` and OUTPUT, bogus `@overwrite`, parent 0), unescaped generated constraint names (`[PK_<table>]`, `[DF_…]`) and dynamic `DROP CONSTRAINT` quoting, database-level CDC (`enableDatabaseCDC`). |
| postgres-wire | lab | Fixed: grants to PUBLIC/CURRENT_USER on databases, schemas, roles and defaults quoted the keyword as a role name. |
| mysql-wire | lab | Logging in to MySQL 8+'s default `caching_sha2_password` without TLS fails ("Access denied … using password: YES"): mysql-nio does not do the RSA public-key exchange (`GET_SERVER_PUBLIC_KEY`) for full authentication. Users of servers without TLS cannot connect. Repro: `mysql-8.4-column-types`, `tlsMode: .disabled`. |
| mysql-wire | lab | Client certificates (MySQL `REQUIRE X509` / `REQUIRE SUBJECT` accounts, MariaDB the same): `MySQLWireConfiguration` cannot present one, so the lab has no `client-certificate` MySQL recipe yet. |
| mysql-wire | lab | Fixed while building the MySQL engine: TLS by IP (SNI), `--ssl-mode` semantics (`MySQLWireTLSMode`), empty metadata on MySQL 8+ (upper-case labels), `CREATE USER … IDENTIFIED BY`, roles and grants without a host (MariaDB). Echo still passes `useTLS:` (verify identity); its "require" mode should map to `.required`. |

## Found while adding login plugins and database states (2026-10-01)

Tests: `MySQLAuthenticationServerTests`, `MariaDBAuthenticationServerTests` (each gap is a
`withKnownIssue`, so closing it fails the test until the expectation moves to "works").

| Driver | Owner | What |
|---|---|---|
| mysql-wire | lab | `sha256_password` accounts cannot log in, with or without TLS ("Unsupported auth plugin name: sha256_password"). Repro: `mysql-8.4-auth-plugins`, account `lab_auth_sha256`. |
| mysql-wire | lab | MariaDB `ed25519` accounts cannot log in ("Unsupported auth plugin name: client_ed25519"). Repro: `mariadb-11.8-auth-plugins`, `lab_auth_ed25519`. |
| mysql-wire | lab | MariaDB 11.6+ `parsec` accounts cannot log in ("Unsupported auth plugin name: parsec"). Repro: `mariadb-11.8-auth-plugins`, `lab_auth_parsec`. |
| mysql-wire | lab | Fixed: `security.listUsers()` failed on MariaDB (its `mysql.user` view has no `account_locked`); it now reads `mysql.global_priv`. Added `installPlugin`, `uninstallPlugin`, `metadata.listPlugins`, and MariaDB's `IDENTIFIED VIA … USING PASSWORD(…)`. |
| postgres-wire | lab | Fixed: server-side prepared statements (`queryPreparedRows`) kept the text row description while asking for binary rows, so every boolean or integer column failed to decode. Also `createDatabase(ifNotExists:)` (PostgreSQL has no IF NOT EXISTS), `createMaterializedView(withData:)`, `PostgresViewDetails.isPopulated`. |
| mysql-wire | lab | Fixed: `serverConfig.globalVariables(named:)` sent `SHOW GLOBAL VARIABLES LIKE ?`, which SHOW does not accept (every named lookup failed); `errorLog.readTableLog(named: "slow_log")` ordered by `event_time`, which the slow log lacks (Echo's slow-log view could not load). |
| sqlserver-nio | lab | Added `admin.setDatabaseOwner(name:login:)` (GS-37). |

## Ranking across drivers

| Rank | Gap | Driver · namespace | Items unblocked |
|---|---|---|---|
| 1 | GM-02 `admin.createTable` + `MySQLDataType` | mysql-wire · admin | 29 |
| 2 | GP-19 `PostgresEncodable` for non-core types | postgres-wire · PostgresWire types | 15 |
| 3 | GL-01 SQLite `createTable` | SQLite · schema | 12 |
| 4 | GL-07 SQLite typed `insert` | SQLite · data | 11 |
| 5 | GS-02 typed `SQLServerLiteralValue` cases | sqlserver-nio · model | 9 |
| 6 | GS-01 `SQLDataType` cases | sqlserver-nio · model | 8 |
| 7 | GP-23 dump loading (owner decision) | postgres-wire · admin | 8 |
| 8 | GP-01 `schema:` on every create API | postgres-wire · all | 7 direct, **cross-cutting** (every pack that uses a non-`public` schema) |
| 9 | GP-02 column definition options | postgres-wire · admin | 6 |
| 10 | GM-08 typed `MySQLData` values | mysql-wire · bulk | 6 |
| 11 | GM-17 dump loading (owner decision) | mysql-wire · admin | 6 |
| 12 | GS-16 key hierarchy (master key, certificates, keys, DEK) | sqlserver-nio · security | 5 direct (+ SV-39, SV-42 encrypted backups, SV-45 indirectly) |
| 13 | GP-05 index options | postgres-wire · indexes | 5 |
| 14 | GS-03 `SQLServerTableDefinition` | sqlserver-nio · admin | 4 (and the carrier type for GS-04..GS-08) |
| 15 | GS-04 memory-optimized objects | sqlserver-nio · admin/types/routines | 4 |
| 16 | GS-15 XML/spatial/columnstore/JSON/vector indexes | sqlserver-nio · indexes | 4 |
| 17 | GP-03 table creation options | postgres-wire · admin | 4 |
| 18 | GM-01 `admin.createDatabase` | mysql-wire · admin | 4 (every MySQL pack needs it) |
| 19 | GM-04 `indexes.createIndex` | mysql-wire · indexes | 4 |
| 20 | GM-15 plugins | mysql-wire · admin | 4 |
| 21 | GM-20 MariaDB dialect support | mysql-wire · all | 4 |
| 22 | GL-04, GL-06, GL-08 | SQLite | 4 each |

Cross-cutting items not counted per row: **GS-30** (database targeting on every sqlserver-nio namespace),
**GP-01** (schema qualification), **GM-01/GM-02** (nothing in MySQL can be seeded without them), **GL-00**
(no SQLite typed layer at all).

---

## sqlserver-nio (`SQLServerKit`)

### Model types

**GS-02 · typed literal values — 9 items** (SS-DT-12, 14, 16, 30, 33, 34, 35, 36, 37)
`Model/SQLServerLiteralValue.swift` has `null, string, nString, int, int64, double, decimal, bool, date, uuid,
bytes, raw`. Seeding time, datetime2, datetimeoffset, spatial, hierarchyid, json, vector and sql_variant with
a chosen base type needs typed cases (the driver already has `Client/SQLServerHierarchyID.swift` and
`Model/SQLServerSpatial.swift` to reuse):

```swift
public enum SQLServerLiteralValue: Sendable {
    // existing cases …
    case time(SQLServerTime)                       // hour, minute, second, nanoseconds, precision 0...7
    case dateTime2(SQLServerDateTime2)             // components + 100 ns ticks + precision
    case dateTimeOffset(SQLServerDateTimeOffset)   // dateTime2 + offset minutes (-840...840)
    case money(Decimal)
    case xml(String)
    case json(String)                              // 2025 native json
    case vector([Float])                           // 2025
    case geography(SQLServerSpatialValue)          // WKT or WKB + SRID
    case geometry(SQLServerSpatialValue)
    case hierarchyID(SQLServerHierarchyID)
    case variant(SQLServerLiteralValue, baseType: SQLDataType)
}
```

**GS-01 · missing `SQLDataType` cases — 8 items** (SS-DT-29, 32, 33, 34, 35, 36, 37, 48)

```swift
public enum SQLDataType: Sendable {
    // existing cases …
    case rowversion
    case hierarchyid
    case geography
    case geometry
    case json                                                    // 2025
    case vector(dimensions: UInt16)                              // 2025
    case typedXML(collection: String, schema: String?, document: Bool)
}
// SQLServerColumnDefinition.StandardColumn
public let isFileStream: Bool   // varbinary(max) FILESTREAM (Windows only)
```

### admin (`SQLServerAdministrationClient`)

**GS-03 · `SQLServerTableDefinition` — 4 items** (SS-DT-48, SS-DT-52, SS-SO-30, SS-SO-41), carrier for GS-04 to GS-08.
Today `createTable(name:columns:)` on admin has no schema, and `SQLServerConnection.createTable` has no
storage options, table-level constraints or column encryption.

```swift
public struct SQLServerTableDefinition: Sendable {
    public var schema: String = "dbo"
    public var name: String
    public var columns: [SQLServerColumnDefinition]
    public var constraints: [SQLServerTableConstraint] = []      // named PK/UNIQUE/CHECK/FK/DEFAULT
    public var storage: SQLServerTableStorage = .default         // .filegroup(String), .partitionScheme(name:column:)
    public var textImageOn: String? = nil
    public var fileStreamOn: String? = nil                       // Windows only
    public var dataCompression: SQLServerDataCompression? = nil  // .row, .page, .columnstoreArchive
    public var memoryOptimized: SQLServerMemoryOptimization? = nil        // GS-04
    public var systemVersioning: SQLServerSystemVersioning? = nil         // GS-05
    public var ledger: SQLServerLedgerKind? = nil                          // GS-06
    public var graphKind: SQLServerGraphKind? = nil                        // GS-07
    public var sparseColumnSet: String? = nil                              // GS-08
}
// column additions: encryptedWith: SQLServerColumnEncryption?, mask: SQLServerSecurityClient.MaskFunction?,
//                   generatedAlways: SQLServerGeneratedAlways?, isHidden: Bool
extension SQLServerAdministrationClient {
    public func createTable(_ definition: SQLServerTableDefinition) async throws -> [SQLServerStreamMessage]
}
```

**GS-04 · memory-optimized objects — 4 items** (SS-DT-41, SS-SO-18, SS-SO-33, SS-PR-11)

```swift
public struct SQLServerMemoryOptimization: Sendable { public var durability: Durability /* .schemaAndData, .schemaOnly */ }
public enum SQLServerIndexKind { case hash(bucketCount: Int), nonclustered, clusteredColumnstore }
extension SQLServerTypeClient {
    public func createUserDefinedTableType(_ definition: UserDefinedTableTypeDefinition, memoryOptimized: Bool) async throws
}
// RoutineOptions: nativeCompilation: Bool, schemaBinding: Bool,
//                 atomic: SQLServerAtomicBlock?(isolation: .snapshot, language: "us_english")
```

**GS-22 · partitioning on the admin namespace — 2 items** (SS-SO-27, SS-SO-28)
The existing functions live on `SQLServerConnection` and take boundary values as `[String]` and one filegroup.

```swift
extension SQLServerAdministrationClient {
    public func createPartitionFunction(name: String, inputType: SQLDataType,
                                        range: SQLServerPartitionRange /* .left, .right */,
                                        boundaries: [SQLServerLiteralValue]) async throws
    public func createPartitionScheme(name: String, function: String,
                                      filegroups: SQLServerPartitionFilegroups /* .all(String), .each([String]) */) async throws
    public func splitPartitionRange(function: String, at: SQLServerLiteralValue, nextUsed: String?) async throws
    public func mergePartitionRange(function: String, at: SQLServerLiteralValue) async throws
}
```

**GS-05 · temporal options — 1 item** (SS-SO-32)
```swift
public struct SQLServerSystemVersioning: Sendable {
    public var periodStart: String, periodEnd: String, hidden: Bool
    public var historyTable: (schema: String, name: String)?
    public var retention: SQLServerRetention?          // .days(Int), .months(Int), .infinite (2017+)
}
```

**GS-06 · ledger — 1 item** (SS-SO-35): `SQLServerLedgerKind { case updatable(historyTable: String?), appendOnly }`; `SQLServerCreateDatabaseOptions.ledger: Bool`.

**GS-07 · graph — 1 item** (SS-SO-34): `SQLServerGraphKind { case node, edge }`;
`SQLServerConstraintClient.addEdgeConstraint(name:edgeTable:schema:connections:[(from: String, to: String)], onDelete: SQLServerForeignKeyAction)`.

**GS-08 · sparse column set — 1 item** (SS-DT-46): `SQLServerTableDefinition.sparseColumnSet: String?`.

**GS-10 · synonyms — 1 item** (SS-SO-23); unblocks the Explorer `synonyms` folder, which has no other source.
```swift
extension SQLServerAdministrationClient {
    public func createSynonym(name: String, schema: String = "dbo",
                              target: SQLServerObjectName /* server?, database?, schema, object */) async throws
    public func dropSynonym(name: String, schema: String = "dbo") async throws
}
```

**GS-09 · sequences — 1 item** (SS-SO-24)
```swift
extension SQLServerAdministrationClient {
    public func createSequence(name: String, schema: String = "dbo", type: SQLDataType = .bigint,
                               start: SQLServerLiteralValue? = nil, increment: Int64 = 1,
                               minValue: SQLServerLiteralValue? = nil, maxValue: SQLServerLiteralValue? = nil,
                               cycle: Bool = false, cache: SQLServerSequenceCache = .default) async throws
}
```

**GS-36 · database options — 1 item** (SS-CF-12): add `SQLServerDatabaseOption.acceleratedDatabaseRecovery(Bool)`, `.optimizedLocking(Bool)`.

**GS-37 · database owner — closed** (SS-ST-11): `admin.setDatabaseOwner(name:login:)` (sqlserver-nio 28f25a4).

**GS-32 · plan guides — 1 item** (SS-PR-15): `admin.createPlanGuide(name: String, statement: String, scope: SQLServerPlanGuideScope /* .sql(params:), .object(schema:name:), .template */, hints: String) async throws`.

**GS-25 · log shipping — 1 item** (SS-SV-31)
```swift
extension SQLServerAdministrationClient {
    public func configureLogShippingPrimary(database: String, backupDirectory: String, backupShare: String,
                                            backupJobSchedule: SQLServerAgentScheduleDefinition) async throws
    public func configureLogShippingSecondary(primaryServer: String, primaryDatabase: String,
                                              copyDirectory: String, restoreMode: SQLServerRestoreRecoveryMode) async throws
}
```

**GS-29 · bulk load over TDS — 1 item** (SS-ST-16, and seeding time of every large pack).
`Client/SQLServerBulkClient.swift:copy` batches `INSERT` statements. Add a TDS BulkLoadBCP (packet type
0x07) path:
```swift
extension SQLServerBulkClient {
    public func load<S: AsyncSequence & Sendable>(into table: String, schema: String = "dbo",
                                                  columns: [String], rows: S,
                                                  options: SQLServerBulkLoadOptions = .init()) async throws -> SQLServerBulkCopySummary
        where S.Element == [SQLServerLiteralValue]
}
```

**GS-30 · database targeting — cross-cutting.** `security`, `indexes`, `constraints`, `fullText`, `types`
clients have no `database:` parameter and run in the pooled connection's current database; only `admin`
has `scoped(to:)`. Add `scoped(to database: String) -> Self` to every per-database namespace (packs work
around it today by opening one client per database).

### types (`SQLServerTypeClient`)

**GS-11 · alias types — 1 item** (SS-DT-39): `createAliasType(name: String, schema: String = "dbo", baseType: SQLDataType, nullable: Bool = true) async throws`.

**GS-12 · XML schema collections — 1 item** (SS-DT-32): `createXMLSchemaCollection(name: String, schema: String = "dbo", xsd: String) async throws`, `addSchemas(to:xsd:)`.

**GS-33 · legacy rules and defaults — 1 item** (SS-SO-40): `createRule(name:schema:expression:)`, `bindRule(_:to column: SQLServerColumnReference)`, `createDefault(name:schema:value:)`, `bindDefault(_:to:)`.

### indexes (`SQLServerIndexClient`)

**GS-15 · index kinds — 4 items** (SS-SO-14, 15, 16, 17)
```swift
extension SQLServerIndexClient {
    public func createXMLIndex(name: String, table: String, column: String, schema: String = "dbo",
                               kind: SQLServerXMLIndexKind /* .primary, .secondary(using: String, for: .path|.value|.property) */) async throws
    public func createSpatialIndex(name: String, table: String, column: String, schema: String = "dbo",
                                   tessellation: SQLServerSpatialTessellation /* .geometryAutoGrid(boundingBox:), .geographyAutoGrid */,
                                   cellsPerObject: Int? = nil) async throws
    public func createColumnstoreIndex(name: String, table: String, clustered: Bool, columns: [String] = [],
                                       schema: String = "dbo", filter: String? = nil, order: [String] = [],
                                       compressionDelayMinutes: Int? = nil, archiveCompression: Bool = false,
                                       dropIfExists: Bool = false) async throws -> [SQLServerStreamMessage]
    public func createJSONIndex(name: String, table: String, column: String, schema: String = "dbo", paths: [String]) async throws   // 2025
    public func createVectorIndex(name: String, table: String, column: String, schema: String = "dbo",
                                  metric: SQLServerVectorMetric, type: SQLServerVectorIndexType = .diskANN) async throws           // 2025
}
```

**GS-14 · statistics — 1 item** (SS-SO-19): `createStatistics(name: String, table: String, schema: String = "dbo", columns: [String], filter: String? = nil, sample: SQLServerStatisticsSample = .default, noRecompute: Bool = false, incremental: Bool = false) async throws`.

### routines / triggers

**GS-18 · routine options — 3 items** (SS-PR-03, SS-PR-11, SS-PR-13)
```swift
public struct RoutineOptions { /* existing */ public var nativeCompilation = false; public var schemaBinding = false
                               public var atomic: SQLServerAtomicBlock? = nil; public var number: Int? = nil }
extension SQLServerRoutineClient { public func setStartupProcedure(name: String, enabled: Bool) async throws }
extension SQLServerTriggerClient { public func setTriggerOrder(name: String, schema: String = "dbo",
                                                               order: SQLServerTriggerOrder /* .first, .last, .none */,
                                                               event: String) async throws }
```

**GS-13 · CLR — 2 items** (SS-DT-42, SS-PR-12)
```swift
extension SQLServerRoutineClient {
    public func createAssembly(name: String, bits: Data, permissionSet: SQLServerAssemblyPermission = .safe) async throws
    public func addTrustedAssembly(hash: Data, description: String) async throws           // clr strict security (2017+)
    public func createCLRProcedure(name: String, schema: String = "dbo", parameters: [ProcedureParameter],
                                   externalName: SQLServerCLRName) async throws
    public func createCLRFunction(name: String, schema: String = "dbo", parameters: [ProcedureParameter],
                                  returns: SQLServerCLRReturn, externalName: SQLServerCLRName) async throws
    public func createCLRAggregate(name: String, schema: String = "dbo", input: SQLDataType, returns: SQLDataType,
                                   externalName: SQLServerCLRName) async throws
    public func createCLRType(name: String, schema: String = "dbo", externalName: SQLServerCLRName) async throws
}
```

**GS-31 · external languages and libraries — 2 items** (SS-PR-17, SS-SV-49): `createExternalLanguage(name: String, content: Data, fileName: String, platform: .linux)`, `createExternalLibrary(name: String, language: String, content: Data)`.

### security / serverSecurity

**GS-16 · key hierarchy — 5 items** (SS-SE-04, 14, 15, 16, 17; indirectly SS-SV-39, SS-SV-42, SS-SV-45)
```swift
extension SQLServerSecurityClient {           // database scoped
    public func createMasterKey(password: String) async throws
    public func createCertificate(_ definition: SQLServerCertificateDefinition) async throws
        // name, subject, startDate, expiryDate, source: .generated / .file(certPath:, privateKeyPath:, decryptionPassword:),
        // encryption: .masterKey / .password(String)
    public func backupCertificate(name: String, toFile: String, privateKey: SQLServerPrivateKeyExport?) async throws
    public func createAsymmetricKey(name: String, algorithm: SQLServerAsymmetricAlgorithm = .rsa2048,
                                    encryption: SQLServerKeyEncryption = .masterKey) async throws
    public func createSymmetricKey(name: String, algorithm: SQLServerSymmetricAlgorithm = .aes256,
                                   encryptedBy: [SQLServerKeyEncryption]) async throws
    public func createDatabaseEncryptionKey(algorithm: SQLServerSymmetricAlgorithm = .aes256,
                                            serverCertificate: String) async throws   // run in the target db
}
```
(`createCertificate` in master serves certificate logins and HADR endpoints.)

**GS-17 · database-scoped credentials — 1 item** (SS-SV-45): `security.createDatabaseScopedCredential(name: String, identity: String, secret: String?) async throws`.

**GS-24 · data classification — 1 item** (SS-SO-42): `security.addSensitivityClassification(schema: String, table: String, column: String, label: String?, informationType: String?, rank: SQLServerSensitivityRank?) async throws`.

**GS-19 · endpoints — 2 items** (SS-SV-25, SS-SV-30)
```swift
extension SQLServerServerSecurityClient {
    public func createEndpoint(_ definition: SQLServerEndpointDefinition) async throws
        // name, port, kind: .databaseMirroring(role: .all, authentication: .certificate(String), encryption: .aes)
        //                    .serviceBroker(authentication:), .tsql
    public func grantConnectOnEndpoint(_ endpoint: String, to login: String) async throws
}
```

### availabilityGroups

**GS-20 · create and join AGs — 3 items** (SS-SV-26, 27, 28)
```swift
extension SQLServerAvailabilityGroupsClient {
    public func createAvailabilityGroup(_ definition: SQLServerAvailabilityGroupDefinition) async throws
        // name, clusterType: .none/.external/.wsfc, contained: Bool (2022), databases,
        // replicas: [replica(serverName, endpointURL, availabilityMode, failoverMode, seedingMode, secondaryAllowConnections)]
    public func join(availabilityGroup: String, clusterType: SQLServerAGClusterType) async throws
    public func grantCreateAnyDatabase(availabilityGroup: String) async throws
    public func createDistributedAvailabilityGroup(name: String, members: [SQLServerDistributedAGMember]) async throws
}
```

### serviceBroker

**GS-40 · broker extras — 2 items** (SS-SV-39, SS-SV-40)
```swift
extension SQLServerServiceBrokerClient {
    public func createRemoteServiceBinding(name: String, toService: String, user: String, anonymous: Bool = false) async throws
    public func createBrokerPriority(name: String, contract: String?, localService: String?, remoteService: String?, level: Int) async throws
    public func createEventNotification(name: String, scope: SQLServerEventNotificationScope, events: [String],
                                        toService: String, brokerInstance: String = "current database") async throws
    public func beginDialog(from: String, to: String, contract: String, encryption: Bool = false) async throws -> UUID
    public func send(on conversation: UUID, messageType: String, body: Data?) async throws
    public func endConversation(_ conversation: UUID, error: (code: Int, description: String)? = nil) async throws
}
```

### fullText, policy, queryStore, serverConfig, linkedServers, agent, backupRestore, ssis

- **GS-21 · stoplists and property lists — 1 item** (SS-SV-37): `fullText.createStoplist(name:source: .empty/.system/.copy(of:))`, `addStopword(_:language:to:)`, `createSearchPropertyList(name:)`, `createIndex(... stoplist:searchPropertyList:)`.
- **GS-23 · policy-based management — 1 item** (SS-SV-21): `policy.createCondition(name: String, facet: String, expression: SQLServerPolicyExpression)`, `policy.createPolicy(name: String, condition: String, evaluationMode: SQLServerPolicyEvaluationMode, targetSet: SQLServerPolicyTargetSet?)`.
- **GS-39 · Query Store hints — 1 item** (SS-PR-16): `queryStore.setQueryHints(queryId: Int64, hints: String)`, `clearQueryHints(queryId:)` (2022+).
- **GS-27 · trace flags — 1 item** (SS-SV-24): `serverConfig.setTraceFlag(_ flag: Int, enabled: Bool, global: Bool = true)`, `listTraceFlags()`.
- **GS-28 · linked server provider and options — 1 item** (SS-SV-15). **Bug on Linux:** `linkedServers.add(provider:)` defaults to `"SQLNCLI"`, which SQL Server on Linux does not have; the SQL Server provider there is `MSOLEDBSQL`. Proposed: `add(name: String, provider: SQLServerLinkedServerProvider = .msoledbsql, dataSource: String, catalog: String? = nil, options: SQLServerLinkedServerOptions = .init(rpcOut: true, dataAccess: true))`, `setOption(_:on:)`.
- **GS-34 · Agent typing and MSX — 1 item** (SS-SV-13) plus quality: `addStep(subsystem:)` takes `String` although `SQLServerAgentJobStep.Subsystem` exists; `createSchedule(freqType: Int, …)` takes raw `sp_add_schedule` codes. Proposed: `createSchedule(_ schedule: SQLServerAgentScheduleDefinition)` with `enum Frequency { once(Date), daily(every: Int), weekly(days: Set<Weekday>, every: Int), monthly(day: Int, every: Int), monthlyRelative(ordinal:, weekday:, every:), onAgentStart, onIdle }` and `subday: .minutes(Int)/.hours(Int)/.seconds(Int)`; `enlistTargetServer(msx:)`, `addTargetServer(_:toJob:)`.
- **GS-26 · backup devices — 1 item** (SS-SV-43): `backupRestore.addBackupDevice(name: String, path: String)`, `dropBackupDevice(name:)`.
- **GS-35 · SSIS catalog — 1 item** (SS-SV-41, Windows VM only): `ssis.createCatalog(password: String)`, `createFolder(name:description:)`, `deployProject(folder:name:ispac: Data)`, `createEnvironment(folder:name:variables:)`.

### Samples

**GS-38 · SQL-script samples — 2 items** (SS-SA-05 Northwind/pubs, SS-SA-07 Chinook). Owner decision, see
[sample-databases.md](sample-databases.md#loading-policy). Recommended: no driver API; port each sample to a
typed pack (schema in Swift, data as bundled JSON/CSV inserted with `bulk`).

---

## postgres-wire (`PostgresKit`)

### PostgresWire types

**GP-19 · `PostgresEncodable` for non-core types — 15 items** (PG-DT-04, 06, 11, 13, 16, 17, 18, 19, 22, 23, 24, 25, 37, 38, 39)
Conformances exist only for `Bool, Data, Date, Double, Int, String, UUID, IPAddress, MACAddress, Array`.

```swift
extension Int16: PostgresEncodable {}; extension Int32: PostgresEncodable {}; extension Float: PostgresEncodable {}
public struct PostgresNumeric: PostgresEncodable { /* Decimal or .nan / .infinity / .negativeInfinity */ }
public enum PostgresDateValue: PostgresEncodable { case date(Date), infinity, negativeInfinity }   // also timestamp(tz)
public struct PostgresTime: PostgresEncodable; public struct PostgresTimeTZ: PostgresEncodable
public struct PostgresInterval: PostgresEncodable { public var months: Int32, days: Int32, microseconds: Int64 }
public struct PostgresRange<Bound: PostgresEncodable>: PostgresEncodable { /* lower, upper, inclusivity, empty */ }
public struct PostgresMultirange<Bound: PostgresEncodable>: PostgresEncodable
public struct PostgresBitString: PostgresEncodable
public struct PostgresJSON: PostgresEncodable; public struct PostgresJSONB: PostgresEncodable   // correct OIDs
public struct PostgresArray<Element: PostgresEncodable>: PostgresEncodable { /* dimensions, lower bounds, NULLs */ }
/// Any type by name, sent as text and resolved server-side (hstore, geometry EWKT, vector, citext, ltree, money, xml, tsvector, geometric types…)
public struct PostgresTypedText: PostgresEncodable { public init(_ text: String, type: String) }
```

### admin (`PostgresAdminClient`)

**GP-23 · dump loading — 8 items** (PG-SA-01..08). Owner decision (see sample-databases.md). If a driver API is
chosen: `admin.restorePlainDump(_ source: some AsyncSequence<Data>, database: String) async throws` that
understands psql plain format (statements, `COPY … FROM stdin` blocks, `\.`), and
`admin.restoreArchive(_ file: URL, database: String, options:)` for custom/tar archives (needs an archive
reader; large effort). Recommended alternative: typed ports for small samples, image-build `pg_restore` for
large ones, flagged as outside the pack rule.

**GP-01 · schema qualification — 7 items, cross-cutting** (PG-SO-03, SO-18, SO-19, SO-20, PR-01, SE-05, ST-04)
`createTable`, `createTableAs`, `createView`, `createMaterializedView`, `createIndex`, `createAdvancedIndex`
(both index and table), `createFunction`, `createTrigger` (table), `createEnum`, `createSequence`,
`insert/update/delete`, `grantPrivileges(onTable:)`, `addForeignKey` (both tables), `createPolicy` pass the
name through `quoteIdentifier`, so `"sales.orders"` becomes one identifier. Add `schema: String? = nil`
everywhere (or accept a `PostgresQualifiedName`), matching the functions that already have it (`dropTable`,
`createDomain`, `createCompositeType`, `createRule`, `createForeignTable`).

**GP-02 · column definition — 6 items** (PG-DT-03, 33, 34, 35, 36, SO-11)
```swift
public struct PostgresColumnDefinition: Sendable {
    // existing …
    public var identity: PostgresIdentity? = nil         // .always(sequenceOptions:), .byDefault(sequenceOptions:)
    public var generated: PostgresGeneratedColumn? = nil // .stored(String), .virtual(String) (18+)
    public var collation: String? = nil
    public var compression: PostgresCompression? = nil   // .pglz, .lz4 (14+)
    public var check: String? = nil
    public var notNullConstraintName: String? = nil      // 18+
}
```

**GP-03 · table options — 4 items** (PG-DT-30, SO-04, SO-05, SO-19)
```swift
func createTable(name: String, schema: String? = nil, columns: [PostgresColumnDefinition],
                 persistence: PostgresTablePersistence = .permanent,   // .temporary, .unlogged
                 ofType: String? = nil, inherits: [String] = [], storageParameters: [String: String] = [:],
                 tablespace: String? = nil, accessMethod: String? = nil, ifNotExists: Bool = false) async throws -> Int
func createMaterializedView(name: String, schema: String? = nil, query: String, withData: Bool = true,
                            tablespace: String? = nil, ifNotExists: Bool = false) async throws -> Int
```

**GP-06 · extended statistics — 1 item** (PG-SO-17): `createStatistics(name: String, schema: String? = nil, table: String, kinds: Set<PostgresStatisticsKind>, targets: [PostgresStatisticsTarget /* .column(String), .expression(String) */]) async throws -> Int`.

**GP-07 · large objects — 1 item** (PG-SO-31): new `client.largeObjects`: `create(_ data: Data) async throws -> UInt32`, `write(oid:offset:data:)`, `unlink(oid:)`.

**GP-08 · security labels — 1 item** (PG-SO-36): `security.setSecurityLabel(provider: String?, on: PostgresObjectReference, label: String?)`.

**GP-09 · operator classes, access methods, conversions, transforms — 1 item** (PG-SO-35): `createOperatorClass`, `createOperatorFamily`, `createAccessMethod(name:type: .index/.table, handler:)`, `createConversion(name:source:destination:function:default:)`, `createTransform(type:language:fromSQL:toSQL:)`.

**GP-21 · IMPORT FOREIGN SCHEMA — 1 item** (PG-SO-25): `importForeignSchema(remoteSchema: String, server: String, into localSchema: String, filter: PostgresImportFilter? /* .limitTo([String]), .except([String]) */, options: [String: String] = [:])`.

**GP-22 · full aggregate definition — 1 item** (PG-PR-05): `createAggregate(_ definition: PostgresAggregateDefinition)` covering `combinefunc`, `serialfunc`, `parallel`, `finalfunc_modify`, ordered-set/hypothetical, moving-aggregate functions.

### indexes (`PostgresIndexClient`)

**GP-05 · index options — 5 items** (PG-SO-14, 15, 16, SV-15, ST-09)
```swift
public enum PostgresIndexType: Sendable { case btree, hash, gist, gin, brin, spgist, custom(String) /* hnsw, ivfflat, bloom, rum */ }
public struct PostgresIndexColumn: Sendable {
    public var target: Target   // .column(String), .expression(String)
    public var opclass: String?; public var collation: String?
    public var order: PostgresIndexOrder?; public var nullsOrder: PostgresIndexNullsOrder?
}
func createAdvancedIndex(name: String, schema: String? = nil, table: String, tableSchema: String? = nil,
                         columns: [PostgresIndexColumn], indexType: PostgresIndexType = .btree,
                         unique: Bool = false, include: [String] = [], whereClause: String? = nil,
                         with storageParameters: [String: String] = [:],   // e.g. m, ef_construction, lists
                         tablespace: String? = nil, nullsDistinct: Bool = true,
                         concurrently: Bool = false, only: Bool = false, ifNotExists: Bool = false) async throws -> Int
```

### routines / triggers

**GP-04 · procedures — 1 item** (PG-PR-03); unblocks Echo's PostgreSQL `procedures` folder.
`routines.createProcedure(name: String, schema: String? = nil, parameters: [PostgresFunctionParameter], body: String, language: PostgresFunctionLanguage = .plpgsql, security: PostgresFunctionSecurity = .invoker, orReplace: Bool = false) async throws -> Int`.

**GP-14 · languages — 1 item** (PG-PR-04). **Bug:** `PostgresFunctionLanguage.plpython = "PLPYTHONU"`
names the Python 2 language, removed from PostgreSQL long ago; the language is `plpython3u`. Proposed cases:
`plpython3u`, `plperl`, `plperlu`, `pltcl`, `pltclu`, `plv8`, `custom(String)` (the enum becomes non-`RawRepresentable`, or add a separate `.named(String)` path).

**GP-24 · trigger options — 1 item** (PG-PR-07): `createTrigger(... schema: String?, referencing: [PostgresTransitionTable] /* .newTable(as:), .oldTable(as:) */, deferrable: PostgresDeferrable?)`.

### constraints (`PostgresConstraintClient`)

**GP-17 · foreign key options — 1 item** (PG-SO-08): `addForeignKey(table:schema:columns:referencesTable:referencesSchema:referencesColumns:constraintName:onDelete:onUpdate:match: PostgresMatchType?, deferrable: PostgresDeferrable? /* .deferrable(initiallyDeferred:), .notDeferrable */, notValid: Bool = false)`.

**GP-18 · temporal constraints (18+) — 1 item** (PG-SO-10): `addPrimaryKey(table:schema:columns:withoutOverlaps: String?)`, `addUniqueConstraint(... withoutOverlaps:)`, `addForeignKey(... period: (column: String, referencesColumn: String)?)`.

### replication (`PostgresReplicationClient`)

**GP-10 · publication, subscription, slots — 3 items** (PG-SV-08, 09, 10)
```swift
public enum PostgresPublicationObject: Sendable {
    case table(name: String, schema: String?, columns: [String]? = nil, rowFilter: String? = nil)  // 15+
    case tablesInSchema(String)                                                                     // 15+
}
func createPublication(name: String, target: PostgresPublicationTarget /* .allTables, .objects([PostgresPublicationObject]) */,
                       operations: Set<PostgresPublicationOperation> = [.insert, .update, .delete, .truncate],
                       publishViaPartitionRoot: Bool = false, publishGeneratedColumns: Bool = false) async throws -> Int
func createSubscription(name: String, connectionString: String, publications: [String],
                        options: PostgresSubscriptionOptions /* enabled, copyData, slotName, streaming, twoPhase, failover, binary, disableOnError, origin */) async throws -> Int
func createReplicationSlot(name: String, kind: PostgresReplicationSlotKind /* .logical(plugin:temporary:twoPhase:failover:), .physical(reserveWAL:) */) async throws
func dropReplicationSlot(name: String) async throws
```

### security (`PostgresSecurityClient`)

**GP-20 · privileges beyond tables — 2 items** (PG-SE-02, PG-SE-06)
```swift
func grant(_ privileges: [PostgresPrivilege], on target: PostgresGrantTarget, to grantee: String, withGrantOption: Bool = false) async throws -> Int
// PostgresGrantTarget: .table(schema:name:columns:), .sequence, .function(schema:name:argumentTypes:), .procedure,
//                      .type, .domain, .foreignDataWrapper, .foreignServer, .language, .largeObject(UInt32),
//                      .tablespace, .parameter(String) (15+)
func grantRole(_ role: String, to member: String, admin: Bool = false, inherit: Bool? = nil, set: Bool? = nil) async throws -> Int  // 16+
```

**GP-25 · password encryption choice — 1 item** (PG-SE-04): `createRole(… passwordEncryption: PostgresPasswordEncryption = .scramSHA256 /* .md5 */)`.

### transactions / serverConfig / bulk

- **GP-15 · prepared transactions — 1 item** (PG-PR-09); unblocks Echo's `pgPreparedTransactions` page: `transactions.prepare(_ transactionID: String)` inside a transaction scope, plus `listPreparedTransactions()`.
- **GP-16 · ALTER SYSTEM — 1 item** (PG-SV-12): `serverConfig.alterSystem(set parameter: String, to value: String)`, `alterSystem(reset:)`, `reloadConfiguration()`.
- **GP-13 · typed COPY — 1 item** (PG-ST-07, and seeding speed everywhere): `bulk.copyIn(into table: String, schema: String? = nil, columns: [String], format: PostgresCopyFormat = .binary, rows: some AsyncSequence<[PostgresInsertValue]>) async throws -> Int`.

### extension schedulers

- **GP-11 · pg_cron — 1 item** (PG-PR-12): new `client.cron`: `schedule(name: String, cron: String, command: String, database: String? = nil) async throws -> Int64`, `unschedule(name:)`, `alterJob(id:active:)`.
- **GP-12 · pgAgent — 1 item** (PG-PR-13): new `client.pgAgent`: `createJob(_ job: PgAgentJobDefinition)` (steps with kind SQL/batch, database, on-error; schedules as minute/hour/weekday/monthday/month masks with start/end; exceptions).

---

## mysql-wire (`MySQLKit`)

**GM-02 · tables and data types — 29 items** (all of MY-DT-01..19, SO-02, 03, 04, 15, SV-14, ST-02, 03, 04, 06, SA-06)
```swift
public indirect enum MySQLDataType: Sendable {
    case tinyint(unsigned: Bool), smallint(unsigned: Bool), mediumint(unsigned: Bool), int(unsigned: Bool), bigint(unsigned: Bool)
    case decimal(precision: Int, scale: Int), float, double, bit(Int)
    case date, datetime(fsp: Int), timestamp(fsp: Int), time(fsp: Int), year
    case char(Int), varchar(Int), binary(Int), varbinary(Int)
    case text(MySQLTextSize), blob(MySQLTextSize)                   // tiny, regular, medium, long
    case enumeration([String]), set([String]), json
    case geometry(MySQLGeometryKind, srid: UInt32?)                 // geometry, point, linestring, polygon, multi*, collection
    case vector(Int)                                                // MySQL 9 / MariaDB 11.7
    case uuid, inet4, inet6                                         // MariaDB
}
public struct MySQLColumnDefinition: Sendable {
    public var name: String; public var type: MySQLDataType; public var nullable = true
    public var defaultValue: MySQLDefault? /* .literal(MySQLData), .expression(String), .currentTimestamp(fsp:) */
    public var onUpdateCurrentTimestamp = false; public var autoIncrement = false; public var invisible = false
    public var generated: MySQLGeneratedColumn? /* .virtual(String), .stored(String) */
    public var charset: String?; public var collation: String?; public var comment: String?
}
public struct MySQLTableDefinition: Sendable {
    public var schema: String; public var name: String; public var columns: [MySQLColumnDefinition]
    public var primaryKey: [String]? = nil; public var indexes: [MySQLIndexDefinition] = []
    public var foreignKeys: [MySQLForeignKey] = []; public var checks: [MySQLCheckConstraint] = []
    public var engine: String = "InnoDB"; public var charset: String?; public var collation: String?
    public var rowFormat: MySQLRowFormat?; public var autoIncrementStart: UInt64?; public var encryption: Bool?
    public var tablespace: String?; public var comment: String?; public var temporary = false
    public var partitioning: MySQLPartitioning? = nil           // GM-03
    public var systemVersioning: MySQLSystemVersioning? = nil   // GM-06 (MariaDB)
}
extension MySQLAdminClient { func createTable(_ definition: MySQLTableDefinition) async throws }
```

**GM-08 · typed values — 6 items** (MY-DT-03, 05, 06, 09, 12, 13): helpers producing correct `MySQLData`
for `DECIMAL` (string), `BIT(n)`, negative/over-24h `TIME`, `YEAR`, geometry (`SRID + WKB`), `VECTOR`, `ENUM`/`SET`.

**GM-17 · dump loading — 6 items** (MY-SA-01..06). Owner decision; `Execution/MySQLBulkOperationClient.swift:loadDataCommand` and `BackupRestore/MySQLBackupRestoreClient.swift:restoreCommand` only build CLI command lines.

**GM-01 · databases — 4 items** (MY-SO-01, ST-01, ST-04, SA-06): `admin.createDatabase(name: String, charset: String? = nil, collation: String? = nil, encryption: Bool? = nil, readOnly: Bool? = nil, ifNotExists: Bool = false)`, `dropDatabase(name:)`.

**GM-04 · indexes — 4 items** (MY-SO-08..11)
```swift
public struct MySQLIndexDefinition: Sendable {
    public var name: String; public var kind: MySQLIndexKind   // .index, .unique, .fulltext(parser: String?), .spatial
    public var parts: [MySQLIndexPart]                         // .column(String, length: Int?, order: .asc/.desc), .expression(String)
    public var using: MySQLIndexMethod?; public var invisible = false; public var comment: String?
}
extension MySQLIndexClient { func createIndex(schema: String, table: String, _ index: MySQLIndexDefinition) async throws }
```

**GM-15 · plugins — 4 items** (MY-SO-03, PR-05, SV-10, SV-11): `admin.installPlugin(name: String, soname: String)`, `uninstallPlugin(name:)`, `createLoadableFunction(name:returns:soname:)`.

**GM-20 · MariaDB support — 4 items** (MY-DT-11, DT-14, PR-06, SE-02): server flavour detection, MariaDB types in metadata decoding, `ed25519`/`parsec` authentication in the wire layer (mysql-nio has neither: check), packages under `sql_mode=ORACLE`. Nothing in `mysql-wire` mentions MariaDB today.

**GM-05 · constraints — 3 items** (MY-SO-05, 06, 07): `constraints.addPrimaryKey(schema:table:columns:)`, `addForeignKey(schema:table:name:columns:referencesSchema:referencesTable:referencesColumns:onDelete:onUpdate:)`, `addUniqueConstraint`, `addCheckConstraint(schema:table:name:expression:enforced:)`.

**GM-10 · typed routine signatures — 3 items** (MY-PR-01, 02, 07): `createRoutine(schema:name:kind:parameters: [MySQLRoutineParameter(mode:name:type: MySQLDataType)], returns: MySQLDataType?, characteristics: MySQLRoutineCharacteristics(deterministic:dataAccess:sqlSecurity:comment:), definer: MySQLAccount?, body:)`.

**GM-06 · MariaDB temporal tables — 2 items** (MY-SO-19, 20): `MySQLSystemVersioning(historyPartitioning:)`, `applicationPeriod(name:start:end:)`, `withoutOverlaps`.

**GM-16 · replication setup — 2 items** (MY-SV-04, 05): `replication.configureReplica(source: MySQLReplicationSource, autoPosition: Bool = true, channel: String? = nil)`, `startReplica(channel:)`, `stopReplica(channel:)`, `startGroupReplication(bootstrap: Bool)`.

**GM-14 · account options and structured grants — 2 items** (MY-SE-03, 05): `createUser(… tls: MySQLTLSRequirement, passwordExpire: MySQLPasswordExpiry?, failedLoginAttempts: Int?, passwordLockTime: MySQLLockTime?, passwordHistory: Int?, comment: String?)`; `grant(_ privileges: [MySQLPrivilege], on: MySQLGrantTarget /* .global, .database, .table, .columns, .routine, .proxy */, to: MySQLAccount, withGrantOption: Bool)`.

**GM-18 · view options — 2 items** (MY-SO-13, ST-07): `createView(schema:name:definitionSQL:replace:algorithm: MySQLViewAlgorithm?, sqlSecurity: MySQLSQLSecurity?, definer: MySQLAccount?, checkOption: MySQLCheckOption?)`.

Single-item gaps: **GM-03** partitioning (`MySQLPartitioning`: range, rangeColumns, list, listColumns, hash(linear:), key, subpartitions) — MY-SO-12; **GM-07** MariaDB sequences (`sequences.createSequence(schema:name:start:increment:min:max:cache:cycle:)`) — MY-SO-18; **GM-09** tablespaces (`admin.createTablespace(name:dataFile:engine:encryption:)`) — MY-SO-14; **GM-11** typed event schedule (`MySQLEventSchedule.at(Date)`, `.every(Int, unit:, starts:, ends:)`) — MY-PR-04; **GM-12** `LOAD DATA LOCAL INFILE` over the protocol (`bulk.loadData(schema:table:columns:rows:)`) — MY-ST-05; **GM-13** `admin.createSpatialReferenceSystem(srid:name:definition:organization:)` — MY-SO-17; **GM-19** trigger order (`order: .follows(String)/.precedes(String)`) — MY-PR-03; **GM-21** `setGlobalVariable(… scope: .persist/.persistOnly)` — MY-SV-02; **GM-22** resource groups — MY-SV-13; **GM-23** histograms (`maintenance.updateHistogram(schema:table:columns:buckets:)`) — MY-SO-16.

---

## SQLite (no first-party driver)

**GL-00 · a typed SQLite layer — decision, cross-cutting.** `sqlite-nio` is Vapor's package and exposes SQL
text only. Options: (a) a first-party package in the style of `mysql-wire` wrapping `sqlite-nio`
(name it something other than `SQLiteKit`, which Vapor's `sqlite-kit` already uses); (b) treat SQLite
fixtures as files produced by any SQLite and exempt them from the pack rule. Recommendation: (a), because
it also fixes GL-08 (own build flags). Unblocks every `lite.*` pack.

| Gap | Items | Proposed API |
|---|---|---|
| **GL-01** tables | 12 (SL-DT-01, 02, 10, 11, 12; SO-01..05; CF-07, 08) | `schema.createTable(_ def: SQLiteTableDefinition)` — columns (declared type or `SQLiteStrictType`, `primaryKey(autoincrement:order:onConflict:)`, `notNull`, `unique`, `check`, `default(.literal/.expression)`, `collate(.binary/.nocase/.rtrim/.named)`, `references`, `generated(.virtual/.stored)`), table constraints, `strict`, `withoutRowID`, `temporary`, `schema` (attached name) |
| **GL-07** rows | 11 (SL-DT-01, 03..09; CF-04, 08, 09) | `data.insert(into:schema:columns:rows: [[SQLiteData]], onConflict:)`, `withTransaction` |
| **GL-04** virtual tables | 4 (SL-SO-10..13) | `virtualTables.createFTS5(name:columns:tokenizer:content:prefix:)`, `createRTree(name:dimensions:integer:auxiliary:)` |
| **GL-06** pragmas | 4 (SL-DT-13, SO-05, CF-01, CF-02) | `pragmas.set(_ pragma: SQLitePragma)` — `.journalMode`, `.pageSize`, `.autoVacuum`, `.encoding`, `.userVersion`, `.applicationID`, `.foreignKeys`, `.secureDelete` |
| **GL-08** build flags | 4 (SL-SO-11, 13, 15, CF-12) | a SQLite build with `SQLITE_ENABLE_FTS3/FTS4`, `SQLITE_ENABLE_GEOPOLY`, `SQLITE_ENABLE_STAT4`, `SQLITE_ENABLE_MATH_FUNCTIONS`, and without `SQLITE_OMIT_LOAD_EXTENSION` (Echo would still need to decide whether to load extensions) |
| **GL-03** views, triggers | 3 (SL-SO-07..09) | `schema.createView(name:schema:select:temporary:)`, `createTrigger(name:timing:event:table:forEachRow:when:body:)` |
| **GL-02** indexes | 1 (SL-SO-06) | `schema.createIndex(name:table:parts:unique:where:)` |
| **GL-05** attach | 1 (SL-SO-16) | `attach(file:as:)`, `detach(_:)` |
| **GL-09** statistics | 1 (SL-SO-15) | `maintenance.analyze(schema:)`, `vacuum(into:)` |

---

## Explorer node kinds and coverage

All 85 cases of `ExplorerNodeKind` (`Echo/Sources/Features/ObjectBrowser/Blueprint/ExplorerNodeKind.swift`)
map to at least one catalogue item, except six pure grouping folders that appear whenever their children
exist: `serverSecurity`, `databaseSecurity`, `serverObjects`, `management`, `activity`, `externalResources`.

Node kinds whose **every** catalogue item is blocked today (no pack can make them appear):

| Node kind | Engine | Blocked by |
|---|---|---|
| `synonyms` | SQL Server | GS-10 |
| `certificateLogins` | SQL Server | GS-16 (certificate creation) |
| `remoteServiceBindings` | SQL Server | GS-40 (+ GS-16) |
| `integrationServices`, `ssisFolder` | SQL Server | Windows VM + GS-35 |
| `procedures` | PostgreSQL | GP-04 (SQL Server/MySQL procedures are fine) |
| `pgPreparedTransactions` | PostgreSQL | GP-15 |
| `policyManagement` (user policies) | SQL Server | GS-23 (built-in system policies still show) |
| `externalDataSources`, `externalTables`, `externalFileFormats`, `externalObject` | SQL Server | not a driver gap: need the PolyBase image layer |
| MySQL `tables` (and anything that selects from a table) | MySQL | GM-02; views, routines, triggers and events can already be created in a database made by the `MYSQL_DATABASE`/`MARIADB_DATABASE` start setting, but trigger packs need a table |
| every SQLite folder | SQLite | GL-00 |

Things the catalogue creates that Echo does not show yet (candidates for Explorer work, listed as "none" in
the node column): SQL Server sequences, types (alias/table/CLR), statistics, filegroups, partition
functions/schemes, full-text catalogs, CDC/CT, endpoints, AGs in the tree, plan guides, database-scoped
credentials; PostgreSQL schemas (check), FDWs/servers/user mappings, publications/subscriptions, event
triggers, policies, rules, casts, operators, collations, text search objects, extended statistics, large
objects, default privileges, pg_cron/pgAgent jobs; MySQL events, users/roles, tablespaces, MariaDB
sequences; SQLite triggers and indexes in the tree.
