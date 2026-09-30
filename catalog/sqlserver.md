# SQL Server coverage catalogue

Driver: `sqlserver-nio` (product `SQLServerKit`), checked at commit `49e4820`.
Paths in the **Typed API** column are relative to `sqlserver-nio/Sources/SQLServerKit/`.
Column meanings, status words and feasibility words are defined in [README.md](README.md).

Container facts this catalogue relies on (from the local `sql-docs` clone,
`docs/linux/sql-server-linux-editions-and-components-2017/2019/2022/2025.md` and
`docs/linux/sql-server-linux-ssis-known-issues.md`):

- Official Linux images exist for **2017, 2019, 2022, 2025** (`mcr.microsoft.com/mssql/server:<v>-latest`). 2008 R2 to 2016 need the Windows VM that `sqlserver-nio/testlab/README.md` already plans.
- Not on Linux in any version: merge replication, FILESTREAM and FileTable, CLR `EXTERNAL_ACCESS`/`UNSAFE`, `xp_cmdshell` and other system extended procedures, Buffer Pool Extension, database mirroring, linked servers to anything other than SQL Server, distributed queries with third-party providers, **SQL Agent alerts**, Agent subsystems CmdExec/PowerShell/Queue Reader/SSIS/SSAS/SSRS, Managed Backup, EKM (before 2022 CU12), Windows auth for linked servers and AG endpoints, SSAS, SSRS, Browser. 2017 also lacks the Log Reader Agent (transactional replication publishing arrived later on Linux) and PolyBase.
- 2022 on Linux: no Always Encrypted with secure enclaves, no TLS 1.3. 2025 on Linux: no enclaves; SSIS is not available at all.
- SSIS on Linux (2017–2022) has **no SSIS catalog (SSISDB)** and no Agent scheduling of packages.
- Full-Text Search needs the `mssql-server-fts` package (custom image layer). PolyBase needs `mssql-server-polybase` (2019/2022) or, from 2025, ODBC "bring your own driver" (custom image layer).
- Edition matters: the images default to Developer (all Enterprise features). `MSSQL_PID=Express/Standard` removes Resource Governor, online index ops, full AGs, snapshots (Express), Service Broker (Express, Web), TDE (Express, Web).

---

## 1. Data types

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes (edge values worth seeding) |
|---|---|---|---|---|---|---|---|
| SS-DT-01 | `bit` | all | tables (column) | API `Model/SQLDataType.swift:SQLDataType.bit`; rows `Client/SQLServerAdministrationClient+CRUD.swift:insertRows` | Linux container | mssql.types.all | 0, 1, NULL; string 'true'/'false' conversion |
| SS-DT-02 | `tinyint` | all | tables (column) | API `SQLDataType.tinyint` | Linux container | mssql.types.all | 0, 255 (unsigned!), NULL |
| SS-DT-03 | `smallint` | all | tables (column) | API `SQLDataType.smallint` | Linux container | mssql.types.all | -32768, 32767 |
| SS-DT-04 | `int` | all | tables (column) | API `SQLDataType.int` | Linux container | mssql.types.all | -2147483648, 2147483647 |
| SS-DT-05 | `bigint` | all | tables (column) | API `SQLDataType.bigint`; value `Model/SQLServerLiteralValue.swift:.int64` | Linux container | mssql.types.all | Int64.min/max; values above 2^53 (JS/Double precision loss in grids) |
| SS-DT-06 | `decimal(p,s)` / `numeric(p,s)` | all | tables (column) | API `SQLDataType.decimal/.numeric`; value `.decimal(String)` | Linux container | mssql.types.all | p=1..38; (38,0) max, (38,38) tiny fractions, negative zero, trailing zeros kept |
| SS-DT-07 | `money` | all | tables (column) | API `SQLDataType.money` | Linux container | mssql.types.all | ±922337203685477.5807 (4 dp); value only as `.decimal` string |
| SS-DT-08 | `smallmoney` | all | tables (column) | API `SQLDataType.smallmoney` | Linux container | mssql.types.all | ±214748.3647 |
| SS-DT-09 | `float(n)` (53) | all | tables (column) | API `SQLDataType.float(mantissa:)` | Linux container | mssql.types.all | ±1.79E+308, 2.23E-308, -0.0; SQL Server rejects NaN/Inf, so none seeded |
| SS-DT-10 | `real` / `float(24)` | all | tables (column) | API `SQLDataType.real` | Linux container | mssql.types.all | ±3.40E+38, 1.18E-38 |
| SS-DT-11 | `date` | all | tables (column) | API `SQLDataType.date`; value `.date(Date)` | Linux container | mssql.types.all | 0001-01-01, 9999-12-31, 1582 Gregorian gap |
| SS-DT-12 | `time(0..7)` | all | tables (column) | PARTIAL GS-02 (column API `SQLDataType.time(precision:)`; no typed time value, `.string` works by implicit conversion) | Linux container | mssql.types.all | 00:00:00, 23:59:59.9999999 for each precision |
| SS-DT-13 | `datetime` | all | tables (column) | API `SQLDataType.datetime` | Linux container | mssql.types.all | 1753-01-01, 9999-12-31 23:59:59.997 (1/300 s rounding) |
| SS-DT-14 | `datetime2(0..7)` | all | tables (column) | PARTIAL GS-02 (column API `SQLDataType.datetime2(precision:)`; `.date(Date)` loses 100 ns precision) | Linux container | mssql.types.all | 0001-01-01 00:00:00, 9999-12-31 23:59:59.9999999 |
| SS-DT-15 | `smalldatetime` | all | tables (column) | API `SQLDataType.smalldatetime` | Linux container | mssql.types.all | 1900-01-01, 2079-06-06 23:59 |
| SS-DT-16 | `datetimeoffset(0..7)` | all | tables (column) | PARTIAL GS-02 (column API `SQLDataType.datetimeoffset(precision:)`; offsets only via `.string`) | Linux container | mssql.types.all | offsets -14:00 and +14:00, +05:45, same instant in two offsets |
| SS-DT-17 | `char(n)` | all | tables (column) | API `SQLDataType.char(length:)` | Linux container | mssql.types.all | n=1, n=8000, trailing-space padding, code page chars under Latin1 collation |
| SS-DT-18 | `varchar(n)` | all | tables (column) | API `SQLDataType.varchar(length: .length)` | Linux container | mssql.types.all | n=8000, empty string vs NULL |
| SS-DT-19 | `varchar(max)` | all | tables (column) | API `SQLDataType.varchar(length: .max)` | Linux container | mssql.types.all | 10 MB value, 2 GB limit not seeded; off-row LOB |
| SS-DT-20 | `text` (deprecated) | all | tables (column) | API `SQLDataType.text` | Linux container | mssql.types.legacy | legacy LOB, TEXTPTR; not allowed in some contexts |
| SS-DT-21 | `nchar(n)` | all | tables (column) | API `SQLDataType.nchar(length:)` | Linux container | mssql.types.all | n=4000; supplementary characters (emoji) under non-SC collation count as 2 |
| SS-DT-22 | `nvarchar(n)` | all | tables (column) | API `SQLDataType.nvarchar(length: .length)`; value `.nString` | Linux container | mssql.types.all | n=4000, RTL text, combining marks, zero-width joiner, NUL char U+0000 |
| SS-DT-23 | `nvarchar(max)` | all | tables (column) | API `SQLDataType.nvarchar(length: .max)` | Linux container | mssql.types.all | **10 MB** value (PLP chunking), 1 char, 4001 chars (just over in-row limit) |
| SS-DT-24 | `ntext` (deprecated) | all | tables (column) | API `SQLDataType.ntext` | Linux container | mssql.types.legacy | |
| SS-DT-25 | `binary(n)` | all | tables (column) | API `SQLDataType.binary(length:)`; value `.bytes` | Linux container | mssql.types.all | n=8000, all-zero, 0xFF.. |
| SS-DT-26 | `varbinary(n)` / `varbinary(max)` | all | tables (column) | API `SQLDataType.varbinary(length:)` | Linux container | mssql.types.all | empty 0x, 10 MB blob, PNG header bytes (for image preview) |
| SS-DT-27 | `image` (deprecated) | all | tables (column) | API `SQLDataType.image` | Linux container | mssql.types.legacy | |
| SS-DT-28 | `uniqueidentifier` | all | tables (column) | API `SQLDataType.uniqueidentifier`; value `.uuid` | Linux container | mssql.types.all | byte-order quirk (mixed-endian), NEWSEQUENTIALID() default, all-zero GUID |
| SS-DT-29 | `rowversion` / `timestamp` | all | tables (column) | GAP GS-01 | Linux container | mssql.types.all | auto-filled; one per table; must be excluded from inserts |
| SS-DT-30 | `sql_variant` | all | tables (column) | PARTIAL GS-02 (column API `SQLDataType.sql_variant`; base type of each value not controllable) | Linux container | mssql.types.all | one row per base type (int, nvarchar, datetime2, decimal, binary, uniqueidentifier) |
| SS-DT-31 | `xml` (untyped) | all | tables (column) | API `SQLDataType.xml` (values via `.nString`) | Linux container | mssql.types.xml-json | 10 MB document, namespaces, CDATA, encoding declaration |
| SS-DT-32 | `xml` typed by schema collection (CONTENT/DOCUMENT) | all | tables (column) | GAP GS-01, GS-12 | Linux container | mssql.types.xml-json | |
| SS-DT-33 | `hierarchyid` | 2008+ | tables (column) | GAP GS-01, GS-02 (workaround `.userDefined(name:"hierarchyid")` + `.raw` not allowed) | Linux container | mssql.types.spatial-hier | root '/', deep path '/1/2/3/.../', GetDescendant values |
| SS-DT-34 | `geography` | 2008+ | tables (column) | GAP GS-01, GS-02 | Linux container | mssql.types.spatial-hier | point, linestring, polygon (ring orientation!), multi*, geometrycollection, FULLGLOBE, curves (CIRCULARSTRING), SRID 4326/4269, empty |
| SS-DT-35 | `geometry` | 2008+ | tables (column) | GAP GS-01, GS-02 | Linux container | mssql.types.spatial-hier | invalid polygon (self-intersecting), SRID 0, 3D Z/M values |
| SS-DT-36 | `json` (native) | 2025 | tables (column) | GAP GS-01, GS-02 | Linux container | mssql.types.xml-json | nested 100 levels, large arrays, unicode escapes; check: TDS type encoding in driver |
| SS-DT-37 | `vector(n)` | 2025 | tables (column) | GAP GS-01, GS-02 | Linux container | mssql.types.xml-json | dimension 1 and 1998, float32 precision; check: preview-feature flag needed on 2025 |
| SS-DT-38 | `sysname` | all | tables (column) | API `SQLDataType.userDefined(name:"sysname")` | Linux container | mssql.types.all | nvarchar(128) NOT NULL alias |
| SS-DT-39 | Alias (user-defined) data type | all | types — none: Echo's SQL Server tree has no Types folder | GAP GS-11 | Linux container | mssql.schema.core | alias with NOT NULL, alias of decimal(38,10) |
| SS-DT-40 | User-defined table type (TVP) | 2008+ | types — none: not in SQL Server tree | API `Client/SQLServerTypeClient.swift:createUserDefinedTableType` | Linux container | mssql.schema.core | with PK, unique, check, default, identity |
| SS-DT-41 | Memory-optimized table type | 2014+ | none — Echo does not show it yet | GAP GS-04 | Linux container | mssql.inmemory | requires MEMORY_OPTIMIZED_DATA filegroup |
| SS-DT-42 | CLR user-defined type | 2005+ | none — Echo does not show it yet | GAP GS-13 | Linux container (SAFE only) | mssql.clr | needs a compiled assembly shipped with the pack; `clr enabled` + `clr strict security` handling |
| SS-DT-43 | Identity column (int/bigint/decimal seeds) | all | tables (column) | API `StandardColumn.identity(seed:increment:)` | Linux container | mssql.schema.core | negative seed, increment -1, bigint seed near max, gaps after rollback |
| SS-DT-44 | Computed column (persisted and non-persisted) | all | tables (column) | API `SQLServerColumnDefinition.ColumnType.computed(expression:persisted:)`; `Client/SQLServerAdministrationClient+Column.swift:addComputedColumn` | Linux container | mssql.schema.core | non-deterministic expression (GETDATE), indexed persisted column |
| SS-DT-45 | Sparse columns | 2008+ | tables (column) | API `StandardColumn.isSparse` | Linux container | mssql.edge.scale | 30,000 sparse columns per table |
| SS-DT-46 | Sparse column set (`xml COLUMN_SET FOR ALL_SPARSE_COLUMNS`) | 2008+ | tables (column) | GAP GS-08 | Linux container | mssql.edge.scale | `SELECT *` returns the set, not the columns |
| SS-DT-47 | `ROWGUIDCOL` | all | tables (column) | API `StandardColumn.isRowGuidCol` | Linux container | mssql.schema.core | |
| SS-DT-48 | `varbinary(max) FILESTREAM` | 2008+ | tables (column) | GAP GS-01 (and GS-03 FILESTREAM_ON) | Windows VM | mssql.win.filestream | FILESTREAM/FileTable unsupported on Linux |
| SS-DT-49 | Column collation (CS, AS, BIN2, _SC, UTF-8 `_UTF8`) | UTF-8: 2019+ | tables (column) | API `StandardColumn.collation` | Linux container | mssql.config.collations | `Latin1_General_100_CI_AS_SC_UTF8` varchar with emoji; `Japanese_XJIS_140_CS_AS` |
| SS-DT-50 | Default constraint (named, expression) | all | tables (column) | API `Client/SQLServerConstraintClient+Other.swift:addDefaultConstraint`; `StandardColumn.defaultValue` | Linux container | mssql.schema.core | default with function call, default on sparse |
| SS-DT-51 | Masked column (dynamic data masking) | 2016+ | tables (column) | API `Client/SQLServerSecurityClient+Masking.swift:addMask` | Linux container | mssql.security.database | each `MaskFunction`: default, email, random, partial, datetime (2022) |
| SS-DT-52 | Always Encrypted column (deterministic / randomized) | 2016+ | tables (column) | GAP GS-03 (no `ENCRYPTED WITH` in column definition); keys: `Client/SQLServerAlwaysEncryptedClient.swift:createColumnMasterKey/createColumnEncryptionKey` | Linux container (no enclaves) | mssql.security.encryption | inserting data needs client-side AE encryption in the driver: check whether sqlserver-nio can encrypt parameters |
| SS-DT-53 | `cursor`, `table` variable types | all | none (not persistable) | N/A (not persistable) | — | — | only parameters/variables; covered by procedures in mssql.programmability |

## 2. Schema objects

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SS-SO-01 | Database (default options) | all | databases | API `Client/SQLServerAdministrationClient+Database.swift:createDatabase(name:options:)` | Linux container | mssql.schema.core | |
| SS-SO-02 | Schema with owner | all | schemas / schema | API `Client/SQLServerSecurityClient+Schemas.swift:createSchema(name:authorization:)` | Linux container | mssql.schema.core | schema owned by a role, schema named like a reserved word |
| SS-SO-03 | Heap table | all | tables | API `Client/SQLServerConnection+Administration.swift:createTable(name:columns:schema:database:)` | Linux container | mssql.schema.core | admin variant `Client/SQLServerAdministrationClient+Table.swift:createTable` has no `schema:` (GS-30) |
| SS-SO-04 | Table with clustered PK | all | tables | API `StandardColumn.isPrimaryKey`; `Client/SQLServerConstraintClient+Other.swift:addPrimaryKey` | Linux container | mssql.schema.core | composite PK, nonclustered PK + clustered index elsewhere |
| SS-SO-05 | Unique constraint | all | tables | API `Client/SQLServerConstraintClient+Other.swift:addUniqueConstraint` | Linux container | mssql.schema.core | unique on nullable column (one NULL only) |
| SS-SO-06 | Check constraint (enabled, disabled, NOCHECK/untrusted) | all | tables | API `Client/SQLServerConstraintClient+Check.swift:addCheckConstraint`; `Client/SQLServerConstraintClient+Information.swift:disableConstraint` | Linux container | mssql.schema.core | untrusted constraint (`is_not_trusted = 1`) |
| SS-SO-07 | Foreign key (cascade/set null/set default/no action, self-reference, composite, cross-schema, disabled) | all | tables | API `Client/SQLServerConstraintClient+ForeignKey.swift:addForeignKey` | Linux container | mssql.schema.core | circular FKs between two tables; FK to unique constraint rather than PK |
| SS-SO-08 | Nonclustered index (unique, descending, included columns) | all | tables | API `Client/SQLServerIndexClient.swift:createIndex/createUniqueIndex` (`IndexColumn.isIncluded`) | Linux container | mssql.schema.core | 16-key-column limit, 1,023 included columns |
| SS-SO-09 | Filtered index | 2008+ | tables | API `createIndex(filter:)` | Linux container | mssql.schema.core | filter `WHERE col IS NOT NULL` |
| SS-SO-10 | Index options (fill factor, pad, compression, filegroup, partition scheme) | all | tables | API `Client/SQLServerIndexTypes.swift:IndexOptions` | Linux container | mssql.storage | ONLINE requires Enterprise/Developer |
| SS-SO-11 | Clustered index on heap | all | tables | API `Client/SQLServerIndexClient.swift:createClusteredIndex` | Linux container | mssql.schema.core | |
| SS-SO-12 | Disabled index | all | tables | API `Client/SQLServerIndexClient+Management.swift:disableIndex` | Linux container | mssql.states | disabled clustered index makes table unreadable |
| SS-SO-13 | Clustered columnstore index | 2014+ | tables | API `Client/SQLServerIndexClient.swift:createColumnstoreIndex(clustered:true)` | Linux container | mssql.storage | delta store vs compressed rowgroups (seed >1,048,576 rows for a compressed rowgroup) |
| SS-SO-14 | Nonclustered columnstore (incl. filtered, ordered 2022, archive compression) | 2012+ (filtered 2016, ordered 2022) | tables | PARTIAL GS-15 (plain NCCI via `createColumnstoreIndex(clustered:false)`) | Linux container | mssql.storage | |
| SS-SO-15 | XML index (primary, secondary PATH/VALUE/PROPERTY, selective) | all | tables | GAP GS-15 | Linux container | mssql.types.xml-json | needs clustered PK |
| SS-SO-16 | Spatial index (geometry grid, geography auto grid) | 2008+ | tables | GAP GS-15 | Linux container | mssql.types.spatial-hier | geometry needs BOUNDING_BOX |
| SS-SO-17 | JSON index / vector index | 2025 | tables | GAP GS-15 | Linux container | mssql.types.xml-json | check: both previews in 2025 |
| SS-SO-18 | Hash index (memory-optimized) | 2014+ | tables | GAP GS-04 | Linux container | mssql.inmemory | BUCKET_COUNT too small / too large |
| SS-SO-19 | Statistics (user-created, filtered, incremental, NORECOMPUTE) | all | none — Echo does not show it yet | GAP GS-14 | Linux container | mssql.schema.core | auto-created `_WA_Sys_` stats appear after queries (workload pack) |
| SS-SO-20 | View | all | views | API `Client/SQLServerViewClient.swift:createView` | Linux container | mssql.schema.core | view over view over view (dependency chain), view with `SCHEMABINDING`, `CHECK OPTION`, `WITH ENCRYPTION` (check options exist) |
| SS-SO-21 | Indexed view | all | views | API `Client/SQLServerViewClient.swift:createIndexedView` | Linux container | mssql.schema.core | |
| SS-SO-22 | Partitioned view (UNION ALL with check constraints) | all | views | API `createView` + `addCheckConstraint` | Linux container | mssql.storage | distributed partitioned view needs linked servers |
| SS-SO-23 | Synonym (table, view, proc, function, cross-database, via linked server, broken target) | 2005+ | synonyms | GAP GS-10 | Linux container | mssql.schema.core | dangling synonym (target dropped) |
| SS-SO-24 | Sequence (int/bigint/decimal, cycle, cache, negative increment) | 2012+ | none — SQL Server tree has no Sequences folder | GAP GS-09 | Linux container | mssql.schema.core | sequence at max with CYCLE; used as column default |
| SS-SO-25 | Filegroup (plus read-only filegroup, default filegroup) | all | none — Echo does not show it yet | API `Client/SQLServerAdministrationClient+Filegroups.swift:createFilegroup/alterFilegroupReadOnly/setDefaultFilegroup` | Linux container | mssql.storage | |
| SS-SO-26 | Additional data/log files | all | none — shown in Database Properties | API `Client/SQLServerAdministrationClient+Database.swift:addDatabaseFile/addDatabaseLogFile` | Linux container | mssql.storage | file with fixed growth vs percent, max size |
| SS-SO-27 | Partition function (RANGE LEFT/RIGHT on int, date, datetime2, char) | 2005+ (all editions from 2016 SP1) | none — Echo does not show it yet | PARTIAL GS-22 (`Client/SQLServerConnection+Administration.swift:createPartitionFunction`, boundary values are raw strings) | Linux container | mssql.storage | 15,000 partitions max; empty partitions |
| SS-SO-28 | Partition scheme (per-partition filegroups) | 2005+ | none — Echo does not show it yet | PARTIAL GS-22 (`createPartitionScheme` supports `ALL TO` one filegroup only) | Linux container | mssql.storage | |
| SS-SO-29 | Partitioned table and aligned index | 2005+ | tables | API `Client/SQLServerConnection+Administration.swift:createPartitionedTable`; index via `IndexOptions.partitionScheme` | Linux container | mssql.storage | |
| SS-SO-30 | Data compression ROW/PAGE on table | 2008+ | tables | PARTIAL GS-03 (index compression via `IndexOptions.dataCompression`; heap compression missing) | Linux container | mssql.storage | |
| SS-SO-31 | System-versioned temporal table (default names) | 2016+ | tables | API `Client/SQLServerConnection+Administration.swift:createSystemVersionedTable`; `Client/SQLServerTemporalClient.swift:addPeriodColumnsAndEnableVersioning` | Linux container | mssql.temporal | |
| SS-SO-32 | Temporal table with custom period names, `HIDDEN` period columns, existing history table, retention period | 2016+ (retention 2017+) | tables | PARTIAL GS-05 | Linux container | mssql.temporal | history rows need updates over time; seed with `SYSTEM_VERSIONING = OFF` then back on |
| SS-SO-33 | Memory-optimized table (SCHEMA_AND_DATA, SCHEMA_ONLY) | 2014+ | tables | GAP GS-04 (filegroup exists: `Client/SQLServerAdministrationClient+Filegroups.swift:createMemoryOptimizedFilegroup`) | Linux container | mssql.inmemory | Express limit 352 MB |
| SS-SO-34 | Graph node and edge tables, edge constraints | 2017+ (edge constraints 2019+) | tables | GAP GS-07 | Linux container | mssql.graph | `$node_id`, `$from_id` pseudo-columns in grid |
| SS-SO-35 | Ledger tables (updatable, append-only), ledger database | 2022+ | tables | GAP GS-06 | Linux container | mssql.ledger | ledger history views; dropped ledger tables |
| SS-SO-36 | External table / data source / file format (PolyBase) | 2019+ Linux (2017 no) | externalTables / externalDataSources / externalFileFormats / externalObject | API `Client/SQLServerPolyBaseClient.swift:createExternalDataSource/createExternalFileFormat/createExternalTable` | needs custom image layer (`mssql-server-polybase`; 2025 ODBC BYOD) + second SQL Server or MinIO container | mssql.polybase | check: which data source types work on each Linux version |
| SS-SO-37 | Extended properties (table, column, view, proc, function, index, constraint, schema, user, parameter) | all | none — shown in table structure editor | API `Client/SQLServerExtendedPropertiesClient.swift:add/upsert` | Linux container | mssql.extended-properties | `MS_Description` with 7,500-char value, property on a parameter |
| SS-SO-38 | Table and column comments via `MS_Description` | all | tables | API `Client/SQLServerAdministrationClient+Table.swift:addTableComment/addColumnComment` | Linux container | mssql.schema.core | |
| SS-SO-39 | Database snapshot | 2005+ (Enterprise/Developer; Standard 2016 SP1+) | databaseSnapshots / databaseSnapshot | API `Client/SQLServerAdministrationClient+Snapshots.swift:createSnapshot` | Linux container | mssql.states | snapshot of a database with two data files |
| SS-SO-40 | Legacy rules and defaults (`CREATE RULE`, `CREATE DEFAULT`, `sp_bindrule`) | all (deprecated) | none — Echo does not show it yet | GAP GS-33 | Linux container | mssql.types.legacy | |
| SS-SO-41 | FILESTREAM filegroup / FileTable | 2008+/2012+ | none | GAP GS-03 | Windows VM | mssql.win.filestream | unsupported on Linux |
| SS-SO-42 | Data classification labels (`ADD SENSITIVITY CLASSIFICATION`) | 2019+ | none — shown as dots on result headers | GAP GS-24 | Linux container | mssql.security.database | Echo decodes the classification TDS token; this is its only fixture |

## 3. Programmability

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SS-PR-01 | Stored procedure (params in/out, defaults, table-valued param, `WITH RECOMPILE`, `EXECUTE AS`, `WITH ENCRYPTION`) | all | procedures | API `Client/SQLServerRoutineClient.swift:createStoredProcedure(name:parameters:body:schema:options:)` | Linux container | mssql.programmability | encrypted procedure: definition must show as unavailable; 2,100 parameters max |
| SS-PR-02 | Procedure returning multiple result sets, messages, RAISERROR, PRINT, return code | all | procedures | API `createStoredProcedure` | Linux container | mssql.programmability | exercises Echo's multi-result and messages tabs |
| SS-PR-03 | Numbered procedures (`proc;2`) | all (deprecated) | procedures | GAP GS-18 | Linux container | mssql.types.legacy | |
| SS-PR-04 | Scalar function | all | functions | API `Client/SQLServerRoutineClient.swift:createFunction` | Linux container | mssql.programmability | inlineable scalar UDF (2019), `SCHEMABINDING` |
| SS-PR-05 | Inline table-valued function | all | functions | API `createTableValuedFunction` | Linux container | mssql.programmability | check: API distinguishes inline vs multi-statement |
| SS-PR-06 | Multi-statement table-valued function | all | functions | API `createTableValuedFunction` | Linux container | mssql.programmability | |
| SS-PR-07 | DML trigger AFTER INSERT/UPDATE/DELETE, disabled trigger, nested | all | triggers | API `Client/SQLServerTriggerClient.swift:createTrigger/disableTrigger` | Linux container | mssql.programmability | trigger order (`sp_settriggerorder`) — GS-18 |
| SS-PR-08 | INSTEAD OF trigger on view | all | triggers | API `createTrigger` | Linux container | mssql.programmability | |
| SS-PR-09 | Database DDL trigger | 2005+ | databaseTriggers / databaseTrigger | API `Client/SQLServerTriggerClient.swift:createDatabaseDDLTrigger` | Linux container | mssql.programmability | disabled DDL trigger |
| SS-PR-10 | Server DDL / LOGON trigger | 2005+ | serverTriggers / serverTrigger | API `Client/SQLServerTriggerClient.swift:createServerTrigger` | Linux container | mssql.programmability | LOGON trigger that rejects a login (careful: lockout; bind to a named test login) |
| SS-PR-11 | Natively compiled procedure / scalar function / trigger | 2014+ (functions, triggers 2016+) | procedures / functions / triggers | GAP GS-04, GS-18 (`RoutineOptions` has no NATIVE_COMPILATION / ATOMIC) | Linux container | mssql.inmemory | |
| SS-PR-12 | CLR procedure, function, aggregate, trigger (SAFE) | 2005+ | procedures / functions / triggers | GAP GS-13 | Linux container (SAFE only) | mssql.clr | EXTERNAL_ACCESS/UNSAFE need Windows VM |
| SS-PR-13 | Procedure with `sp_procoption` startup flag | all | procedures | GAP GS-18 | Linux container | mssql.programmability | |
| SS-PR-14 | Security policy with filter + block predicates (RLS) | 2016+ | none — shown in Security tab | API `Client/SQLServerSecurityClient+RLS.swift:createSecurityPolicy/addSecurityPredicate` | Linux container | mssql.security.database | policy OFF vs ON |
| SS-PR-15 | Plan guide | 2005+ | none — Echo does not show it yet | GAP GS-32 | Linux container | mssql.querystore | |
| SS-PR-16 | Query Store with captured plans, forced plan, hints (2022) | 2016+ (hints 2022) | none — Query Store tool | PARTIAL GS-39 (`Client/SQLServerQueryStoreClient.swift:setEnabled/forcePlan`; no query hints) | Linux container | mssql.querystore | populated only by running the workload pack |
| SS-PR-17 | External language / external library (Language Extensions: Java, C#, Python, R) | 2019+ | none — Echo does not show it yet | GAP GS-31 | needs custom image layer | mssql.extensibility | check: package availability per version |
| SS-PR-18 | Dependency graph (proc → view → table → function → synonym, cross-db) | all | tables/views/procedures | API (combination of routine/view/table APIs) | Linux container | mssql.edge.dependencies | 20-level chain; deferred name resolution (proc referencing a missing table) |

## 4. Server-level

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SS-SV-01 | SQL Server Agent running | 2017+ Linux | agentJobs | SETTING (`MSSQL_AGENT_ENABLED=true`); check `Client/SQLServerAgentOperations+Async.swift:preflightAgentEnvironment` | Linux container | settings.mssql.agent | Agent off is its own recipe (Echo's empty/disabled state) |
| SS-SV-02 | Agent job (enabled, disabled, owner, description, category) | all | agentJobs / agentJob | API `Client/SQLServerAgentOperations+Async.swift:createJob/setJobCategory/enableJob`; builder `Client/SQLServerAgentJobBuilder.swift` | Linux container | mssql.agent | job name with Unicode and brackets; job owned by a disabled login |
| SS-SV-03 | Job steps (T-SQL, on success/failure actions, retry, output file, multi-step flow) | all | agentJob | API `addStep/addTSQLStep/configureStep/setJobStartStep` | Linux container | mssql.agent | `addStep` takes `subsystem: String` (typed enum only in builder: GS-34) |
| SS-SV-04 | Job steps in CmdExec, PowerShell, SSIS, Analysis subsystems | all | agentJob | API (same) | Windows VM | mssql.win.agent | unsupported subsystems on Linux |
| SS-SV-05 | Job steps for replication subsystems (Snapshot, LogReader, Distribution) | all (LogReader not on 2017 Linux) | agentJob | API (created by replication setup) | Linux container (2) | mssql.replication | |
| SS-SV-06 | Schedules: one-time, daily, weekly (multi-day), monthly (day N), monthly relative (2nd Tuesday), every N minutes/hours, on Agent start, on CPU idle, disabled, with end date, expired | all | agentJob / jobQueue | API `Client/SQLServerAgentOperations+Schedules.swift:createSchedule`, `attachSchedule` | Linux container | mssql.agent | freq codes are raw Ints (GS-34 proposes an enum); shared schedule attached to 3 jobs |
| SS-SV-07 | Job history (succeeded, failed, retried, cancelled, running now) | all | jobQueue | API `startJob/stopJob` (history comes from running jobs) | Linux container | mssql.agent | one job that fails deliberately, one long-running (WAITFOR) to show "running" |
| SS-SV-08 | Operators (email, pager schedule, disabled) | all | none — Agent tools | API `Client/SQLServerAgentOperations+Async.swift:createOperator/updateOperator` | Linux container | mssql.agent | |
| SS-SV-09 | Job notifications (email operator on failure) | all | agentJob | API `setJobEmailNotification/addNotification` | Linux container + SMTP sidecar | mssql.agent | |
| SS-SV-10 | Alerts (severity, message id, performance condition) | all | none — Agent tools | API `Client/SQLServerAgentOperations+Async.swift:createAlert` | Windows VM (alerts unsupported on Linux; creation may succeed but never fires: check) | mssql.win.agent | |
| SS-SV-11 | Job categories (custom local, multi-server) | all | agentJob | API `createCategory/renameCategory` | Linux container | mssql.agent | |
| SS-SV-12 | Proxies + credential + subsystem grants + login grants | all | credentials / agentJob | API `createProxy/grantProxyToSubsystem/grantLoginToProxy`; credential `Client/SQLServerServerSecurityClient.swift:createCredential` | Linux container (T-SQL proxies not allowed; only non-T-SQL subsystems use proxies, which are Windows-only) | mssql.win.agent | on Linux proxies can be created but not used: check |
| SS-SV-13 | Multi-server administration (MSX/TSX), target servers | all | none | GAP GS-34 | Windows VM (check: Linux support undocumented) | mssql.win.agent | |
| SS-SV-14 | Database Mail: enabled, profiles (public, private, default), accounts (SMTP, SSL, auth), profile-account links, principal grants, sent/failed/unsent items, event log | 2017 CU+ on Linux | databaseMail | API `Client/SQLServerDatabaseMailClient+Write.swift:enableFeature/createProfile/createAccount/addAccountToProfile/grantProfileAccess/sendTestEmail` | Linux container + SMTP sidecar (e.g. Mailpit) | mssql.dbmail | failed item: account pointing at a closed port; queue with unsent items (mail stopped) |
| SS-SV-15 | Linked server to another SQL Server (SQL login mapping, RPC out, data access) | all | linkedServers / linkedServer | PARTIAL GS-28 (`Client/SQLServerLinkedServersClient.swift:add/addLoginMapping`; default provider `SQLNCLI` is not available on Linux, server options not settable) | Linux container (2) | mssql.linked-servers | loopback linked server to self; broken linked server (target down); synonym over linked server |
| SS-SV-16 | Linked server to non-SQL Server (ODBC, Oracle, Excel) | all | linkedServer | API `add(provider:)` | Windows VM | mssql.win.linked-servers | unsupported on Linux |
| SS-SV-17 | Server audit (file target), server audit specification, database audit specification, audit log with events | 2008+ (all editions 2016 SP1+) | none — shown in Security tab | API `Client/SQLServerAuditClient.swift:createServerAudit/createServerAuditSpecification/createDatabaseAuditSpecification/setAuditState` | Linux container (FILE target only; security/application log targets need Windows) | mssql.security.server | |
| SS-SV-18 | Extended Events sessions (ring buffer, event file, running, stopped, with predicates) | 2008+ | extendedEvents | API `Client/SQLServerExtendedEventsClient.swift:createSession/startSession` | Linux container | mssql.xevents-trace | |
| SS-SV-19 | SQL Trace (server-side trace) | all (deprecated) | sqlProfiler | API `Client/SQLServerProfilerClient.swift:startLiveTrace` | Linux container (check: trace file path on Linux) | mssql.xevents-trace | |
| SS-SV-20 | Resource Governor pools, workload groups, classifier function | 2008+ Enterprise/Developer | resourceGovernor | API `Client/SQLServerResourceGovernorClient.swift:createResourcePool/createWorkloadGroup/setClassifierFunction/reconfigure` | Linux container (Developer/Enterprise PID) | mssql.resource-governor | external resource pools need ML services |
| SS-SV-21 | Policy-Based Management conditions and policies | 2008+ | policyManagement | GAP GS-23 (`Client/SQLServerPolicyClient.swift` only lists/enables/evaluates) | Linux container (check: PBM on Linux) | mssql.policy | system policies exist out of the box (list only) |
| SS-SV-22 | Error log with entries (several cycled logs, Agent log) | all | sqlServerLogs | API `Client/SQLServerErrorLogClient.swift:cycleErrorLog`; entries appear from workload/failed logins | Linux container | mssql.workload | failed login attempts write entries |
| SS-SV-23 | Server configuration options (`sp_configure`: max memory, MAXDOP, cost threshold, backup compression default, contained database authentication, clr enabled, show advanced) | all | serverProperties | API `Client/SQLServerServerConfigurationClient.swift:setConfiguration/setConfigurations` | Linux container | mssql.config.server | |
| SS-SV-24 | Trace flags (global) | all | serverProperties | GAP GS-27 (startup flags are a SETTING: `mssql-conf traceflag`) | Linux container | mssql.config.server | |
| SS-SV-25 | Endpoints (TSQL custom, Service Broker, database mirroring/HADR) | all | none — Echo does not show it yet | GAP GS-19 | Linux container | mssql.alwayson / mssql.broker | |
| SS-SV-26 | Always On availability group, read-scale, `CLUSTER_TYPE = NONE`, listener-less, 3 replicas | 2017+ Linux | none — Echo shows AGs in a dashboard only | GAP GS-20 (existing `Client/SQLServerAvailabilityGroupsClient.swift` only adds databases/listeners/failover on an existing AG) | Linux container (3) + `MSSQL_ENABLE_HADR=1` | mssql.alwayson | read-only routing, synchronous vs asynchronous replicas; certificate endpoint auth |
| SS-SV-27 | Contained availability group | 2022+ | none | GAP GS-20 | Linux container (3) | mssql.alwayson | |
| SS-SV-28 | Distributed availability group | 2016+ | none | GAP GS-20 | Linux container (6) | mssql.alwayson | memory budget heavy |
| SS-SV-29 | Failover cluster instance | all | none | N/A (not a container scenario) | Windows VM (Pacemaker on Linux VMs; not containers) | — | out of scope for containers |
| SS-SV-30 | Database mirroring | 2005–2022 (deprecated) | none | API `Client/SQLServerAdministrationClient+Mirroring.swift:setMirroringPartner` (+ GS-19 endpoints) | Windows VM | mssql.win.mirroring | unsupported on Linux |
| SS-SV-31 | Log shipping (primary, secondary, monitor) | all | none — Database Properties page | GAP GS-25 (only `fetchLogShippingConfig`) | Linux container (2) + shared volume + Agent | mssql.logshipping | |
| SS-SV-32 | Transactional / snapshot replication (distributor, publisher, publication, articles, push/pull subscription) | 2017 CU18+ Linux (check) | none — Replication tool | API `Client/SQLServerReplicationClient+Distribution.swift:configureDistributor/configureDistributionDB/enablePublishing`; `Client/SQLServerReplicationClient.swift:createPublication/addArticle/createSubscription` | Linux container (2) + Agent + shared snapshot folder | mssql.replication | |
| SS-SV-33 | Merge replication | all | none | API partly (`createPublication` type) | Windows VM | mssql.win.replication | unsupported on Linux |
| SS-SV-34 | Change Data Capture on database + tables (capture instances, net changes) | 2008+ (Standard 2016 SP1+) | none — Echo does not show it yet | API `Client/SQLServerChangeTrackingClient.swift:enableCDC` | Linux container + Agent | mssql.cdc-ct | CDC capture job needs Agent; seed changes after enabling |
| SS-SV-35 | Change Tracking on database + tables | 2008+ | none — Echo does not show it yet | API `enableChangeTracking/enableTableChangeTracking` | Linux container | mssql.cdc-ct | retention 1 minute to show cleanup |
| SS-SV-36 | Full-text catalog + full-text index (populated, change tracking auto/manual, multiple languages) | all | none — Echo does not show it yet | API `Client/SQLServerFullTextClient.swift:createCatalog/createIndex/startPopulation` | needs custom image layer (`mssql-server-fts`) | mssql.fulltext | 2025 on Linux changed supported languages/document types |
| SS-SV-37 | Full-text stoplist, search property list, semantic search | 2008+ (semantic 2012+) | none | GAP GS-21 | needs custom image layer (semantic language DB: check on Linux) | mssql.fulltext | |
| SS-SV-38 | Service Broker: message types (validation none/well-formed XML/schema), contracts, queues (activation, disabled, poison), services, routes | 2005+ (not Express/Web) | serviceBroker / messageTypes / contracts / queues / services / routes / brokerObject | API `Client/SQLServerServiceBrokerClient.swift:createMessageType/createContract/createQueue/createService/createRoute/disableQueue`; `alterDatabaseOption(.brokerEnabled)` | Linux container | mssql.broker | |
| SS-SV-39 | Remote service bindings | 2005+ | remoteServiceBindings | GAP GS-40 (list only: `listRemoteServiceBindings`) | Linux container | mssql.broker | needs certificate + user (GS-16) |
| SS-SV-40 | Messages in a queue, open conversations, broker priorities, event notifications | 2005+ (priorities 2008+) | queues | GAP GS-40 | Linux container | mssql.broker | queue with 10,000 messages; conversation in error state |
| SS-SV-41 | Integration Services catalog (SSISDB) with folders, projects, packages, environments, executions | 2012+ | integrationServices / ssisFolder | GAP GS-35 (read-only `Client/SQLServerSSISClient.swift:listFolders`; catalog creation needs CLR/Windows tooling) | Windows VM | mssql.win.ssis | SSISDB unsupported on Linux |
| SS-SV-42 | Backup history (full, differential, log, copy-only, compressed, encrypted, striped, failed verify) | all | none — Backup tools | API `Client/SQLServerBackupRestoreClient.swift:backup(options:)`, `verifyBackup` | Linux container | mssql.backups | encrypted backup needs a certificate (GS-16) |
| SS-SV-43 | Backup devices (`sp_addumpdevice`) | all | none | GAP GS-26 | Linux container | mssql.backups | |
| SS-SV-44 | Server-scoped credentials | all | credentials / credential | API `Client/SQLServerServerSecurityClient.swift:createCredential` | Linux container | mssql.security.server | credential with `SHARED ACCESS SIGNATURE` identity (URL backup) |
| SS-SV-45 | Database-scoped credentials | 2016+ | none — Echo does not show it yet | GAP GS-17 | Linux container | mssql.polybase | needs database master key (GS-16) |
| SS-SV-46 | Central Management Server groups and registered servers | 2008+ | none | API `Client/SQLServerCMSClient.swift:addGroup/addServer` | Linux container | mssql.cms | stored in msdb |
| SS-SV-47 | Activity: sessions, blocking chain (head blocker), long-running query, open transaction, deadlock captured by system_health, waits | all | activityMonitor | API `Client/SQLServerTransactionClient.swift:beginTransaction`, `Client/SQLServerClient+Async.swift:executeOnFreshConnection` for held locks (check: holding a session open across pack runs) | Linux container | mssql.workload | the pack must keep sessions alive while the test runs: it is a "live" pack, not a seed |
| SS-SV-48 | Missing-index and index-usage DMV data | all | tuningAdvisor | API (runs queries through typed metadata/CRUD calls; no creation API needed) | Linux container | mssql.workload | DMVs reset on restart: seeded images lose it; run at start |
| SS-SV-49 | Machine Learning Services (R/Python), external resource pools | 2019, 2022 (removed from 2025 check) | none | GAP GS-31 | needs custom image layer | mssql.extensibility | |
| SS-SV-50 | Analysis Services / Reporting Services | all | none | N/A (different protocols, not TDS) | Windows VM | — | out of scope |
| SS-SV-51 | Distributed transactions (MSDTC) | 2017 CU16+ Linux | none | SETTING (mssql-conf network.rpcport + distributedtransaction.servertcpport) | Linux container (2) | settings.mssql.msdtc | |

## 5. Security

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SS-SE-01 | SQL login (CHECK_POLICY on/off, CHECK_EXPIRATION, MUST_CHANGE, default database, default language, fixed SID) | all | logins / login | API `Client/SQLServerServerSecurityClient.swift:createSqlLogin(name:password:options:)` (`LoginOptions.checkPolicy/checkExpiration/sid/mustChange`) | Linux container | mssql.security.server | login whose default database is offline or dropped |
| SS-SE-02 | Disabled login, locked-out login, login with expired password | all | login | API `enableLogin`; lockout via repeated failed logins in pack | Linux container | mssql.security.server | lockout needs CHECK_POLICY and a policy the container honours (check on Linux) |
| SS-SE-03 | Windows login / Windows group login | all | login | API `createWindowsLogin` | Linux container + Samba AD DC container + keytab (custom image layer) | mssql.security.ad | Windows-only accounts need the VM; AD on Linux via adutil/keytab |
| SS-SE-04 | Certificate-mapped login, asymmetric-key-mapped login | 2005+ | certificateLogins / login | PARTIAL GS-16 (`createCertificateLogin/createAsymmetricKeyLogin` exist; certificate and key creation missing) | Linux container | mssql.security.server | |
| SS-SE-05 | Microsoft Entra ID login | 2022+ | login | API `createExternalLogin` | cloud (Azure Arc not supported in containers) | mssql.cloud.entra | |
| SS-SE-06 | User-defined server role, membership in fixed roles (sysadmin, securityadmin, …), nested server roles | 2012+ | serverRoles / serverRole | API `createServerRole/addMemberToServerRole` | Linux container | mssql.security.server | 2022 new fixed roles `##MS_...##` |
| SS-SE-07 | Server permissions GRANT/DENY/REVOKE (CONTROL SERVER, VIEW SERVER STATE, IMPERSONATE LOGIN, ALTER ANY LOGIN) | all | login | API `Client/SQLServerServerSecurityClient.swift:grant/deny/revoke` | Linux container | mssql.security.server | DENY overriding role GRANT |
| SS-SE-08 | Database users of every type: mapped to login, without login, contained with password, Windows user, mapped to certificate, mapped to asymmetric key | all (contained 2012+) | users / user | API `Client/SQLServerSecurityClient+Users.swift:createUser(name:type:options:)` (`Model/SecurityDomain.swift:DatabaseUserType`) | Linux container (Windows user needs AD) | mssql.security.database | orphaned user (login dropped), user with default schema that doesn't exist |
| SS-SE-09 | Database roles (fixed membership, user-defined, nested, owned by user) | all | databaseRoles / databaseRole | API `Client/SQLServerSecurityClient+Roles.swift:createRole/addUserToRole` | Linux container | mssql.security.database | |
| SS-SE-10 | Application roles | all | applicationRoles / applicationRole | API `Client/SQLServerSecurityClient+Roles.swift:createApplicationRole` | Linux container | mssql.security.database | |
| SS-SE-11 | Object/schema/database permissions GRANT/DENY/REVOKE incl. column-level and WITH GRANT OPTION | all | user / databaseRole | API `Client/SQLServerSecurityClient+Permissions.swift:grantPermission/denyPermission/revokePermission` | Linux container | mssql.security.database | check: column-level permission support |
| SS-SE-12 | Ownership chains, `EXECUTE AS` user, `TRUSTWORTHY` database, cross-database ownership chaining | all | procedures | API `RoutineOptions.executeAs`; `alterDatabaseOption(.trustworthy)` | Linux container | mssql.security.database | |
| SS-SE-13 | Low-privilege login set: only CONNECT; `db_datareader` only; `VIEW DEFINITION` denied; no `VIEW SERVER STATE`; no msdb access (Agent roles SQLAgentReaderRole/UserRole/OperatorRole) | all | login / user | API (combination of SE-01, SE-07, SE-08, SE-11); Agent roles via `addUserToRole` in msdb | Linux container | mssql.lowpriv | every Explorer folder must degrade gracefully for these logins |
| SS-SE-14 | Database master key, service master key backup | all | none — Echo does not show it yet | GAP GS-16 | Linux container | mssql.security.encryption | |
| SS-SE-15 | Certificates (self-signed, from file, expired, with private key) | all | none — shown in Security tab | GAP GS-16 (list only: `Client/SQLServerSecurityClient+Catalogs.swift:listCertificates`) | Linux container | mssql.security.encryption | expired certificate |
| SS-SE-16 | Asymmetric keys, symmetric keys (AES_256, open/closed) | all | none — shown in Security tab | GAP GS-16 | Linux container | mssql.security.encryption | |
| SS-SE-17 | Transparent Data Encryption (encrypted database, encryption in progress) | 2008+ (Standard 2019+) | databases | PARTIAL GS-16 (`alterDatabaseOption(.encryption(true))` exists; DEK and certificate missing) | Linux container | mssql.security.encryption | |
| SS-SE-18 | Always Encrypted column master key + column encryption key metadata | 2016+ | none — shown in Security tab | API `Client/SQLServerAlwaysEncryptedClient.swift:createColumnMasterKey/createColumnEncryptionKey` | Linux container (keys in a certificate store only work on Windows clients; metadata alone works) | mssql.security.encryption | |
| SS-SE-19 | Always Encrypted with secure enclaves | 2019+ | none | GAP (enclaves) | Windows VM (VBS enclaves) | mssql.win.enclaves | unsupported on Linux |
| SS-SE-20 | Contained database authentication | 2012+ | databases | API `createDatabase(options: .init(containment: "PARTIAL"))` + `setConfiguration("contained database authentication", 1)` | Linux container | mssql.config.database | |
| SS-SE-21 | Encrypted connections: TLS with own CA, wrong host, expired, `forceencryption`, TDS 8.0 strict | 2022+ for strict (2025 container tested) | none (connection) | SETTING (mssql.conf `network.tlscert/tlskey/forceencryption/forcestrict`) | Linux container | settings.mssql.tls | certificates already in `sqlserver-nio/testlab/certs` |
| SS-SE-22 | Kerberos authentication | 2017+ Linux | none (connection) | SETTING (keytab) | Linux container + Samba AD DC | settings.mssql.kerberos | planned in `sqlserver-nio/testlab/README.md` |
| SS-SE-23 | NTLM authentication | all | none (connection) | SETTING | Windows VM | settings.mssql.ntlm | |

## 6. Configuration and versions

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SS-CF-01 | SQL Server 2017 (14.x) | 2017 | — | SETTING (image `2017-latest`) | Linux container | base.mssql-2017 | oldest Linux image; CU pin recommended |
| SS-CF-02 | SQL Server 2019 (15.x) | 2019 | — | SETTING | Linux container | base.mssql-2019 | |
| SS-CF-03 | SQL Server 2022 (16.x) | 2022 | — | SETTING | Linux container | base.mssql-2022 | |
| SS-CF-04 | SQL Server 2025 (17.x) | 2025 | — | SETTING | Linux container | base.mssql-2025 | |
| SS-CF-05 | SQL Server 2008 R2, 2012, 2014, 2016 | 2008 R2–2016 | — | SETTING (named instances on the VM) | Windows VM | base.mssql-win | per `sqlserver-nio/testlab/README.md` |
| SS-CF-06 | Azure SQL Database / Managed Instance | cloud | — | SETTING | cloud | base.azure-sql | gateway redirect, Entra tokens |
| SS-CF-07 | Editions: Developer, Express, Standard, Enterprise (Core) | all | — | SETTING (`MSSQL_PID`) | Linux container | settings.mssql.edition | Express: 10 GB limit, no Agent (check: Agent on Express Linux) |
| SS-CF-08 | Server collation: `SQL_Latin1_General_CP1_CI_AS` (default), case-sensitive `Latin1_General_CS_AS`, binary `Latin1_General_BIN2`, `Japanese_CI_AS`, `Turkish_CI_AS` (dotted i), UTF-8 `Latin1_General_100_CI_AS_SC_UTF8` | UTF-8 2019+ | — | SETTING (`MSSQL_COLLATION`) | Linux container | settings.mssql.collation | a CS server makes identifiers case-sensitive in `master`/`tempdb` too |
| SS-CF-09 | Database collation differing from server collation | all | databases | API `SQLServerCreateDatabaseOptions.collation` | Linux container | mssql.config.collations | temp-table collation conflicts |
| SS-CF-10 | Compatibility levels 100–170 on one server | all (2025: 100–170) | databases | API `Client/SQLServerAdministrationClient+Options.swift:alterDatabaseOption(.compatibilityLevel)` | Linux container | mssql.config.database | Echo features gated by compat level (STRING_AGG 140, etc.) |
| SS-CF-11 | Recovery models SIMPLE / FULL / BULK_LOGGED | all | databases | API `alterDatabaseOption(.recoveryModel)` | Linux container | mssql.config.database | FULL with no log backup (log grows) |
| SS-CF-12 | RCSI, snapshot isolation, delayed durability, ADR (2019+), optimized locking (2025) | varies | databases | PARTIAL GS-36 (RCSI/SI/delayed durability via `alterDatabaseOption`; ADR and optimized locking options missing) | Linux container | mssql.config.database | |
| SS-CF-13 | Database-scoped configurations (MAXDOP, LEGACY_CARDINALITY_ESTIMATION, PARAMETER_SNIFFING) | 2016+ | databases | API `Client/SQLServerAdministrationClient+ScopedConfig.swift:alterScopedConfiguration` | Linux container | mssql.config.database | |
| SS-CF-14 | Query Store on/off, read-only, capture modes | 2016+ | databases | API `Client/SQLServerQueryStoreClient.swift:setEnabled/alterOption` | Linux container | mssql.querystore | |
| SS-CF-15 | Database options: AUTO_CLOSE, AUTO_SHRINK, PAGE_VERIFY, ANSI settings, QUOTED_IDENTIFIER off, parameterization FORCED | all | databases | API `alterDatabaseOption` (`Client/SQLServerAdministrationTypes.swift:SQLServerDatabaseOption`) | Linux container | mssql.config.database | QUOTED_IDENTIFIER OFF breaks Echo's bracketless SQL? good edge |
| SS-CF-16 | Memory limit / low memory server | all | — | SETTING (`MSSQL_MEMORY_LIMIT_MB`) | Linux container | settings.mssql.memory | 2 GB minimum |
| SS-CF-17 | Non-default port, IPv6 | all | — | SETTING (`MSSQL_TCP_PORT`) | Linux container | settings.mssql.network | |
| SS-CF-18 | Default data/log/backup paths | all | — | API `Client/SQLServerServerConfigurationClient.swift:setDefaultDataPath/setDefaultLogPath/setDefaultBackupPath` or SETTING | Linux container | mssql.config.server | |

## 7. States and edge cases

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SS-ST-01 | Offline database | all | databases | API `Client/SQLServerAdministrationClient+Database.swift:takeDatabaseOffline` | Linux container | mssql.states | Explorer's `WhenOnline` sections must hide |
| SS-ST-02 | Read-only database | all | databases | API `alterDatabaseOption(.readOnly(true))` | Linux container | mssql.states | |
| SS-ST-03 | Single-user database (held by another session) | all | databases | API `setDatabaseSingleUser` + a live session (SS-SV-47) | Linux container | mssql.states | Echo connecting to it fails; good error path |
| SS-ST-04 | Restricted-user database | all | databases | API `alterDatabaseOption(.userAccess(.restrictedUser))` | Linux container | mssql.states | |
| SS-ST-05 | Emergency mode | all | databases | API `alterDatabaseOption(.databaseState(.emergency))` | Linux container | mssql.states | |
| SS-ST-06 | Restoring database (RESTORE WITH NORECOVERY) | all | databases | API `Client/SQLServerBackupRestoreClient.swift:restore(options:)` (`recoveryMode` norecovery) | Linux container | mssql.states | needs a backup made first (SV-42) |
| SS-ST-07 | Standby / read-only restoring database | all | databases | API `restore(options:)` (`standbyFile`) | Linux container | mssql.states | |
| SS-ST-08 | Suspect / recovery-pending database | all | databases | HARNESS (stop the container, damage or remove a data file) | Linux container (harness step) | mssql.states.damaged | flag the image as "damaged"; no typed API should exist for this |
| SS-ST-09 | AUTO_CLOSE database that is closed | all | databases | API `alterDatabaseOption(.autoClose(true))` | Linux container | mssql.states | |
| SS-ST-10 | Detached database files re-attached; database with missing log (attach rebuild log) | all | databases | API `detachDatabase/attachDatabase/attachDatabaseRebuildLog` | Linux container | mssql.states | |
| SS-ST-11 | Database owned by a dropped / disabled login (`owner_sid` orphan) | all | databases | PARTIAL GS-37 (no `ALTER AUTHORIZATION ON DATABASE`) | Linux container | mssql.states | |
| SS-ST-12 | Names: Unicode (CJK, Arabic RTL, emoji), spaces, leading/trailing spaces, `]` and `[` inside names, `'` and `"`, dots, reserved words (`select`, `table`, `order`), 128-character names, names differing only by case (CS collation), `#`/`@`-prefixed names | all | every object folder | API (every create API escapes with `SQLServerSQL.escapeIdentifier`: check each honours `]]`) | Linux container | mssql.edge.names | apply to databases, schemas, tables, columns, indexes, procs, jobs, logins |
| SS-ST-13 | 1,024-column table (max non-sparse), 30,000-column sparse table, 8,060-byte row, row-overflow | all | tables | API `createTable` | Linux container | mssql.edge.scale | result grid and structure editor performance |
| SS-ST-14 | 5,000 tables in one database; 500 schemas; 200 databases on one server | all | databases / tables | API (loops over create APIs) | Linux container | mssql.edge.scale | seeding time: prefer image snapshot |
| SS-ST-15 | Huge values: 10 MB `nvarchar(max)`, 10 MB `varbinary(max)`, 10 MB xml, 2 MB single-line JSON | all | tables | API `insertRow` (check: `.nString` of 10 MB through batched INSERT literal vs RPC parameters) | Linux container | mssql.edge.scale | |
| SS-ST-16 | 1 million rows in one table; wide rows | all | tables | PARTIAL GS-29 (`Client/SQLServerBulkClient.swift:copy` batches INSERT statements; slow for millions) | Linux container | mssql.edge.scale | build once into the seeded image |
| SS-ST-17 | NULL-heavy data (all-NULL columns, NULL in every type, empty strings vs NULL, NULL PK in unique) | all | tables | API `SQLServerLiteralValue.null` | Linux container | mssql.edge.nulls | |
| SS-ST-18 | Empty database (no user objects), empty tables | all | databases | API `createDatabase` | Linux container | mssql.edge.empty | Explorer empty-state titles |
| SS-ST-19 | Objects in `sys`-lookalike schemas and user objects in `master`/`msdb` | all | tables | API | Linux container | mssql.edge.names | |
| SS-ST-20 | Many Agent jobs (1,000) and long job history | all | agentJobs | API `createJob` loop | Linux container | mssql.agent.scale | |
| SS-ST-21 | Deep dependency chains and circular dependencies | all | views / procedures | API | Linux container | mssql.edge.dependencies | |
| SS-ST-22 | Tempdb objects (global temp tables `##t`) visible during tests | all | tables (tempdb) | API `createTable` in tempdb | Linux container | mssql.workload | lives only while a session holds it |

## 8. Sample databases

See [sample-databases.md](sample-databases.md) for sources, licences and sizes.

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| SS-SA-01 | AdventureWorks OLTP (2012–2025 backups) | restore needs server ≥ backup version | databases | API `Client/SQLServerBackupRestoreClient.swift:listBackupFiles(diskPath:)` (FILELISTONLY) + `restore(options:)` with `relocateFiles` | Linux container | mssql.sample.adventureworks | .bak must be copied into the container by the lab (not a driver job); 2016_EXT uses FILESTREAM? check (EXT variants add in-memory/temporal) |
| SS-SA-02 | AdventureWorksLT | same | databases | API restore | Linux container | mssql.sample.adventureworks-lt | |
| SS-SA-03 | AdventureWorksDW | same | databases | API restore | Linux container | mssql.sample.adventureworks-dw | 2016_EXT DW 883 MB (columnstore) |
| SS-SA-04 | WideWorldImporters (Full/Standard) and WideWorldImportersDW | 2016+ | databases | API restore | Linux container (Full needs memory-optimized support: fine on Developer) | mssql.sample.wwi | exercises temporal, in-memory, RLS, JSON, columnstore, partitioning |
| SS-SA-05 | Northwind, pubs | all | databases | GAP GS-38 (only published as `.sql` scripts; proposal: port to a typed pack with bundled data) | Linux container | mssql.sample.northwind / mssql.sample.pubs | |
| SS-SA-06 | Stack Overflow Mini (.bak, ~1.5 GB) / StackOverflow2010 (7z, ~10 GB expanded) | 2008+ (check per file) | databases | API restore (Mini); API `attachDatabase` (2010 ships as data files in 7z: check) | Linux container | mssql.sample.stackoverflow | large: lab host disk budget |
| SS-SA-07 | Chinook | all | databases | GAP GS-38 (SQL script) — proposal: typed pack from `ChinookData.json` | Linux container | mssql.sample.chinook | same data on every engine: cross-engine comparisons |
