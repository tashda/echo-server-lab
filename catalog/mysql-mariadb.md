# MySQL and MariaDB coverage catalogue

**Driver correction.** Echo does not use Vapor's `mysql-nio` directly any more: `Echo.xcodeproj` depends on
the first-party **`mysql-wire`** package (products `MySQLKit`/`MySQLWire`, branch `dev`, commit `5c060b5`),
which wraps `mysql-nio` 1.9.1 and exposes namespaced clients (`admin`, `security`, `routines`, `views`,
`triggers`, `events`, `bulk`, `serverConfig`, …). Paths in the **Typed API** column are relative to
`mysql-wire/Sources/MySQLKit/`. The brief's "MySQL uses mysql-nio" should be read as "mysql-wire over
mysql-nio"; `.planning/MYSQL_SQLITE_ANALYSIS.md` predates that package.

What `mysql-wire` can create today: users and roles (`Security/MySQLSecurityClient+Mutation.swift`),
grants, views, routines, triggers, events, components, rows (`Execution/MySQLBulkOperationClient.swift:insert`)
and global variables. It has **no typed API for databases, tables, columns, indexes or constraints**
(`Constraints/MySQLConstraintClient.swift` is empty; `Indexes/MySQLIndexClient.swift` only drops). Its
`Admin/MySQLAdminClient+DDL.swift:executeDDL(_:)` takes raw SQL and is therefore not usable by packs. Nothing
in the package mentions MariaDB, so every MariaDB row also depends on GM-20.

Facts: official images `mysql:8.0` (EOL April 2026), `mysql:8.4` (LTS), `mysql:9.x` (Innovation; check the
latest tag), `mariadb:10.6`, `10.11`, `11.4`, `11.8` (LTS) and rolling `12.x` (check). Enterprise-only MySQL
features (audit log, firewall, data masking, thread pool, TDE with Oracle keyrings) are not in community images.

---

> **Built so far (2026-10-01).** Engines `mysql` (8.0, 8.4, 9) and `mariadb` (10.6, 10.11, 11.4, 11.8),
> all content through mysql-wire. Packs: `database`, `column-types` (every type incl. unsigned, BIT,
> ENUM/SET, JSON, all geometry, VECTOR on MySQL 9 / MariaDB 11.8, MariaDB INET4/INET6/UUID),
> `programmability` (view, function, procedure, triggers, event), `indexes-constraints` (unique,
> composite DESC, prefix, FULLTEXT, SPATIAL, invisible; FK, CHECK, unique), `security` (roles, users,
> grants, locked account), `sample` (Sakila, world, Chinook). Setups: TLS (required/optional/strict and
> bad certificates), `source-replica` (GTID), fault proxy, explained captures. Not yet: MariaDB
> sequences and system-versioned tables, partitioning, client-certificate accounts, Galera/Group
> Replication.

## 1. Data types

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes (edge values worth seeding) |
|---|---|---|---|---|---|---|---|
| MY-DT-01 | `TINYINT`/`SMALLINT`/`MEDIUMINT`/`INT`/`BIGINT`, signed and `UNSIGNED` | all | tables (column) | GAP GM-02 (rows: `Execution/MySQLBulkOperationClient.swift:insert(rows: [[MySQLData]])`) | Linux container | my.types.all | `BIGINT UNSIGNED` 18446744073709551615 (> Int64.max) |
| MY-DT-02 | `BOOL`/`BOOLEAN` alias, `TINYINT(1)` display width (deprecated), `ZEROFILL` (deprecated) | all | tables (column) | GAP GM-02 | Linux container | my.types.all | clients guessing boolean from `TINYINT(1)` |
| MY-DT-03 | `DECIMAL(65,30)`, `NUMERIC` | all | tables (column) | GAP GM-02, GM-08 | Linux container | my.types.all | 65 digits |
| MY-DT-04 | `FLOAT`, `DOUBLE`, `FLOAT(p)` | all | tables (column) | GAP GM-02 | Linux container | my.types.all | no NaN/Inf storage |
| MY-DT-05 | `BIT(1..64)` | all | tables (column) | GAP GM-02, GM-08 | Linux container | my.types.all | b'1010', 64-bit all ones |
| MY-DT-06 | `DATE`, `DATETIME(0..6)`, `TIMESTAMP(0..6)`, `TIME(0..6)`, `YEAR` | all | tables (column) | GAP GM-02, GM-08 | Linux container | my.types.all | zero dates `0000-00-00` (non-strict `sql_mode`), `TIME` -838:59:59 and 838:59:59, `TIMESTAMP` 2038-01-19 03:14:07 limit, session time zone conversion |
| MY-DT-07 | `CHAR`, `VARCHAR` up to 65,535-byte row limit, `BINARY`, `VARBINARY` | all | tables (column) | GAP GM-02 | Linux container | my.types.all | `utf8mb4` 4-byte chars shrink max VARCHAR |
| MY-DT-08 | `TINYTEXT`/`TEXT`/`MEDIUMTEXT`/`LONGTEXT`, `TINYBLOB`/`BLOB`/`MEDIUMBLOB`/`LONGBLOB` | all | tables (column) | GAP GM-02 | Linux container | my.types.all | 10 MB value needs `max_allowed_packet` SETTING ≥ 16 MB |
| MY-DT-09 | `ENUM`, `SET` | all | tables (column) | GAP GM-02, GM-08 | Linux container | my.types.all | empty-string enum error value (index 0), SET with 64 members |
| MY-DT-10 | `JSON` (MySQL binary JSON) | MySQL 5.7.8+ | tables (column) | GAP GM-02 | Linux container | my.types.json | 10 MB document, duplicate keys (last wins), big numbers |
| MY-DT-11 | `JSON` on MariaDB (alias of `LONGTEXT` + `JSON_VALID` check) | MariaDB 10.2.7+ | tables (column) | GAP GM-02, GM-20 | Linux container | mariadb.types | Echo must not assume a binary JSON type id |
| MY-DT-12 | Spatial: `GEOMETRY`, `POINT`, `LINESTRING`, `POLYGON`, `MULTI*`, `GEOMETRYCOLLECTION`, column `SRID` attribute (8.0) | all (SRID 8.0+) | tables (column) | GAP GM-02, GM-08 | Linux container | my.types.spatial | axis order for SRID 4326 (lat-long in MySQL 8), empty geometry collections |
| MY-DT-13 | `VECTOR(n)` | MySQL 9.0+, MariaDB 11.7+ | tables (column) | GAP GM-02, GM-08 | Linux container | my.types.vector | |
| MY-DT-14 | MariaDB `UUID` (10.7+), `INET4` (10.10+), `INET6` (10.5+) | MariaDB | tables (column) | GAP GM-02, GM-20 | Linux container | mariadb.types | |
| MY-DT-15 | Character sets and collations per column (`utf8mb4_0900_ai_ci`, `utf8mb4_bin`, `utf8mb3`, `latin1_swedish_ci`, `binary`, MariaDB `utf8mb4_uca1400_ai_ci`) | varies | tables (column) | GAP GM-02 | Linux container | my.config.charsets | same text stored under latin1 and utf8mb4 |
| MY-DT-16 | `AUTO_INCREMENT` (and starting value, gaps, `auto_increment_increment`) | all | tables (column) | GAP GM-02 | Linux container | my.schema.core | |
| MY-DT-17 | Generated columns `VIRTUAL`/`STORED` | MySQL 5.7+, MariaDB 5.2+ (`PERSISTENT`) | tables (column) | GAP GM-02 | Linux container | my.schema.core | |
| MY-DT-18 | Invisible columns | MySQL 8.0.23+, MariaDB 10.3+ | tables (column) | GAP GM-02 | Linux container | my.schema.core | `SELECT *` hides them |
| MY-DT-19 | Default expressions (`DEFAULT (UUID())`, `CURRENT_TIMESTAMP ON UPDATE`) | 8.0.13+ (expressions) | tables (column) | GAP GM-02 | Linux container | my.schema.core | |

## 2. Schema objects

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| MY-SO-01 | Database / schema with default charset and collation, encryption default, read-only schema (8.0.22+) | all | databases | GAP GM-01 | Linux container | my.schema.core | |
| MY-SO-02 | Table engines: InnoDB, MyISAM, MEMORY, ARCHIVE, CSV, BLACKHOLE, MERGE, FEDERATED (off by default) | all | tables | GAP GM-02 | Linux container | my.schema.engines | |
| MY-SO-03 | MariaDB engines: Aria, MyRocks, Spider, CONNECT, ColumnStore, S3, Sequence | MariaDB | tables | GAP GM-02, GM-15 | needs custom image layer (plugins) | mariadb.engines | |
| MY-SO-04 | Row formats (DYNAMIC, COMPRESSED, REDUNDANT, COMPACT), page compression, table comment, `AUTO_INCREMENT=n` | all | tables | GAP GM-02 | Linux container | my.schema.core | |
| MY-SO-05 | Primary key, unique, composite keys | all | tables | GAP GM-05 | Linux container | my.schema.core | |
| MY-SO-06 | Foreign keys (InnoDB; cascade/set null/restrict; self-reference; FK checks disabled data) | all | tables | GAP GM-05 | Linux container | my.schema.core | orphaned rows inserted with `foreign_key_checks=0` |
| MY-SO-07 | CHECK constraints (enforced, `NOT ENFORCED`) | MySQL 8.0.16+, MariaDB 10.2+ | tables | GAP GM-05 | Linux container | my.schema.core | |
| MY-SO-08 | Indexes: BTREE, HASH (MEMORY), prefix length, descending (8.0), invisible (8.0 / MariaDB 10.6 `IGNORED`) | varies | tables | GAP GM-04 | Linux container | my.schema.core | |
| MY-SO-09 | Functional (expression) indexes, multi-valued indexes on JSON arrays | 8.0.13+ / 8.0.17+ | tables | GAP GM-04 | Linux container | my.types.json | |
| MY-SO-10 | FULLTEXT indexes (InnoDB, MyISAM, `ngram` parser for CJK) | 5.6+ (InnoDB) | tables | GAP GM-04 | Linux container | my.fulltext | |
| MY-SO-11 | SPATIAL indexes | all | tables | GAP GM-04 | Linux container | my.types.spatial | NOT NULL + SRID required in 8.0 |
| MY-SO-12 | Partitioning: RANGE, RANGE COLUMNS, LIST, LIST COLUMNS, HASH, LINEAR HASH, KEY, subpartitions | all (InnoDB native 5.7+) | tables | GAP GM-03 | Linux container | my.partitioning | 8,192 partitions max |
| MY-SO-13 | Views (MERGE/TEMPTABLE algorithm, `SQL SECURITY DEFINER/INVOKER`, `WITH CHECK OPTION`, definer that no longer exists) | all | views | PARTIAL GM-18 (`Views/MySQLViewClient.swift:createView(schema:name:definitionSQL:replace:)`) | Linux container | my.schema.core | view with a missing definer user |
| MY-SO-14 | General tablespaces, file-per-table off, undo tablespaces | 5.7+ / 8.0.14+ | none — Echo does not show it yet | GAP GM-09 | Linux container | my.storage | |
| MY-SO-15 | Temporary tables | all | tables (session only) | GAP GM-02 | Linux container | my.workload | |
| MY-SO-16 | Histograms (`ANALYZE TABLE … UPDATE HISTOGRAM`) | MySQL 8.0+ | none | GAP GM-23 (`Maintenance/MySQLMaintenanceClient.swift:analyzeTable` without histogram options: check) | Linux container | my.schema.core | |
| MY-SO-17 | Spatial reference systems (`CREATE SPATIAL REFERENCE SYSTEM`) | MySQL 8.0+ | none | GAP GM-13 | Linux container | my.types.spatial | |
| MY-SO-18 | MariaDB sequences (`CREATE SEQUENCE`, `NEXTVAL`) | MariaDB 10.3+ | none — Echo does not show it yet | GAP GM-07 | Linux container | mariadb.sequences | sequence used as column default |
| MY-SO-19 | MariaDB system-versioned tables (`WITH SYSTEM VERSIONING`, history partitions, `AS OF` data) | MariaDB 10.3.4+ | tables | GAP GM-06 | Linux container | mariadb.system-versioning | history rows need updates over time |
| MY-SO-20 | MariaDB application-time periods and bitemporal tables, `WITHOUT OVERLAPS` | MariaDB 10.4+/10.5+ | tables | GAP GM-06 | Linux container | mariadb.system-versioning | |

## 3. Programmability

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| MY-PR-01 | Stored procedures (IN/OUT/INOUT, multiple result sets, SIGNAL, cursors, handlers) | all | procedures | PARTIAL GM-10 (`Routines/MySQLRoutineClient.swift:createRoutine(schema:name:kind:parametersSQL:returnsSQL:…)`; parameters are raw SQL fragments) | Linux container | my.programmability | |
| MY-PR-02 | Stored functions (DETERMINISTIC, `READS SQL DATA`, `log_bin_trust_function_creators` needed when binlog on) | all | functions | PARTIAL GM-10 (`createRoutine(kind: .function)`) | Linux container | my.programmability | |
| MY-PR-03 | Triggers BEFORE/AFTER INSERT/UPDATE/DELETE, several triggers per event with `FOLLOWS`/`PRECEDES` | all (multiple 5.7.2+) | triggers | PARTIAL GM-19 (`Triggers/MySQLTriggerClient.swift:createTrigger(schema:name:timing:event:table:…)`) | Linux container | my.programmability | |
| MY-PR-04 | Events (one-time `AT`, recurring `EVERY … STARTS … ENDS`, disabled, `ON COMPLETION PRESERVE`, `DISABLE ON SLAVE`) | 5.1+ | none — MySQL tree has no Events folder | PARTIAL GM-11 (`Events/MySQLEventClient.swift:createEvent(schema:name:scheduleSQL:bodySQL:…)`; schedule is raw SQL) | Linux container + event scheduler ON (`ServerConfig/MySQLServerConfigClient.swift:setGlobalVariable("event_scheduler","ON")`) | my.events | Echo gap: events are listed in `.planning/MYSQL_SQLITE_ANALYSIS.md` M10 |
| MY-PR-05 | Loadable functions (UDF `CREATE FUNCTION … SONAME`) | all | functions | GAP GM-15 | needs custom image layer (shared object) | my.plugins | |
| MY-PR-06 | MariaDB packages (`sql_mode=ORACLE`, `CREATE PACKAGE`) | MariaDB 10.3+ | none | GAP GM-20 | Linux container | mariadb.oracle-mode | |
| MY-PR-07 | Stored routine definer missing, `SQL SECURITY INVOKER` | all | procedures | PARTIAL GM-10 | Linux container | my.security | |

## 4. Server-level

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| MY-SV-01 | Event scheduler on/off | 5.1+ | serverProperties | API `ServerConfig/MySQLServerConfigClient.swift:setGlobalVariable` | Linux container | my.events | |
| MY-SV-02 | Global variables persisted (`SET PERSIST`) and read-only variables set at start | 8.0+ | serverProperties | PARTIAL GM-21 (`setGlobalVariable` is non-persisted); start-time variables are a SETTING (`my.cnf`) | Linux container | my.config.server | |
| MY-SV-03 | Binary log on/off, GTID mode, row/statement/mixed format | all | serverProperties | SETTING | Linux container | settings.my.binlog | MySQL 8 has binlog on by default |
| MY-SV-04 | Source/replica replication (GTID, lag, stopped replica, broken replica) | all | activityMonitor (check) | GAP GM-16 (status only: `Replication/MySQLReplicationClient+Status.swift:replicaStatus`) | Linux container (2) | my.replication | |
| MY-SV-05 | Group Replication / InnoDB Cluster, Galera (MariaDB) | 5.7.17+ / MariaDB | none | GAP GM-16 | Linux container (3) | my.replication.group | memory heavy |
| MY-SV-06 | General log / slow log to TABLE, error log | all | none — `ErrorLog/MySQLErrorLogClient.swift:readTableLog` reads them | SETTING (`log_output=TABLE`) + API `setGlobalVariable` | Linux container | my.logs | |
| MY-SV-07 | Performance Schema and `sys` schema populated (statements, waits, memory, locks) | 5.7+ | activityMonitor | API (workload through `insert`/queries) | Linux container | my.workload | |
| MY-SV-08 | Activity: many sessions, long query, metadata lock wait, row lock wait, deadlock in `SHOW ENGINE INNODB STATUS` | all | activityMonitor | API `Execution/MySQLTransaction.swift:begin`, `Session/MySQLSessionClient+Locks.swift:acquireNamedLock` | Linux container | my.workload | live pack |
| MY-SV-09 | Maintenance targets: fragmented table, crashed MyISAM table (REPAIR), table needing ANALYZE | all | maintenance | API `Maintenance/MySQLMaintenanceClient.swift:optimizeTable/repairTable/checkTable`; crash needs harness file damage | Linux container | my.states | |
| MY-SV-10 | Components (`validate_password`, `query_attributes`) and plugins (`server_audit` MariaDB, `auth_socket`, `clone`) | 8.0+ components | none | PARTIAL GM-15 (`Admin/MySQLAdminClient+Components.swift:installComponent`; `INSTALL PLUGIN` missing) | Linux container | my.plugins | |
| MY-SV-11 | Clone plugin, Enterprise backup | 8.0.17+ | none | GAP GM-15 | Linux container (2) | my.replication | |
| MY-SV-12 | Time zone tables loaded (named time zones) | all | none | HARNESS (`mysql_tzinfo_to_sql` at image build; it emits SQL, so owner decision) | Linux container | settings.my.tz | `CONVERT_TZ` returns NULL without them |
| MY-SV-13 | Resource groups | MySQL 8.0+ | none | GAP GM-22 | Linux container (needs `CAP_SYS_NICE`: check in Docker) | my.config.server | |
| MY-SV-14 | Keyring and InnoDB encryption at rest (table, redo, undo, binlog) | 8.0+ (component keyring_file 8.0.24+) | none — `Security/MySQLSecurityClient+Enterprise.swift:encryptedTables` lists them | GAP GM-02 (`ENCRYPTION='Y'`) + SETTING (keyring component config) | Linux container | my.security.encryption | |
| MY-SV-15 | Enterprise audit log, firewall, data masking, thread pool | MySQL Enterprise | none — listing APIs exist in `Security/MySQLSecurityClient+Enterprise.swift` | N/A (Enterprise only) | cloud (HeatWave) or licensed image | my.enterprise | |

## 5. Security

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| MY-SE-01 | Users with host patterns (`'%'`, `'localhost'`, `'10.%'`, `''@'%'` anonymous), same name on two hosts | all | none — Echo has no MySQL security tree yet | API `Security/MySQLSecurityClient+Mutation.swift:createUser(username:host:password:authenticationPlugin:)` | Linux container | my.security | anonymous user breaking host matching |
| MY-SE-02 | Authentication plugins: `caching_sha2_password` (8.0 default), `mysql_native_password` (off by default in 8.4, removed in 9.0), `sha256_password`, `auth_socket`; MariaDB `ed25519`, `unix_socket`, `parsec` (11.6+) | varies | none | API `createUser(authenticationPlugin:)`; MariaDB plugins also GM-20 | Linux container | my.security.auth | checks the driver's handshake paths (RSA key exchange without TLS) |
| MY-SE-03 | Account options: `REQUIRE SSL/X509/SUBJECT`, `PASSWORD EXPIRE`, `FAILED_LOGIN_ATTEMPTS/PASSWORD_LOCK_TIME` (8.0.19+), password history, `ACCOUNT LOCK`, comments/attributes | varies | none | PARTIAL GM-14 (`lockUser/unlockUser`, `Security/MySQLSecurityClient+Administration.swift:setAccountLimits` exist) | Linux container | my.security | |
| MY-SE-04 | Roles, default roles, mandatory roles, role graphs | MySQL 8.0+, MariaDB 10.0.5+ | none | API `createRole/grantRole/setDefaultRole` | Linux container | my.security | |
| MY-SE-05 | Privileges: global, database, table, column, routine, proxy, dynamic (8.0: `BACKUP_ADMIN`, `SYSTEM_VARIABLES_ADMIN`), partial revokes (8.0.16+) | varies | none | PARTIAL GM-14 (`grant(_ privilege:on object:to:host:withGrantOption:)` takes the privilege and object as strings; column and proxy grants: check) | Linux container | my.security | |
| MY-SE-06 | Low-privilege account: `USAGE` only; SELECT on one table; no `PROCESS` (Activity Monitor), no `performance_schema` access | all | every folder | API (SE-01, SE-05) | Linux container | my.lowpriv | |
| MY-SE-07 | TLS: required transport (`require_secure_transport`), own CA, TLS 1.2 only, expired certificate | all | none (connection) | SETTING | Linux container | settings.my.tls | |

## 6. Configuration and versions

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| MY-CF-01 | MySQL 5.7 | 5.7 (EOL 2023-10) | — | SETTING (`mysql:5.7`, amd64 only) | Linux container | base.mysql-5.7 | still common in the field |
| MY-CF-02 | MySQL 8.0 | 8.0 (EOL 2026-04) | — | SETTING | Linux container | base.mysql-8.0 | |
| MY-CF-03 | MySQL 8.4 LTS | 8.4 | — | SETTING | Linux container | base.mysql-8.4 | |
| MY-CF-04 | MySQL 9.x Innovation | 9.x (check latest) | — | SETTING | Linux container | base.mysql-9 | `VECTOR`, JavaScript stored programs (Enterprise) |
| MY-CF-05 | MariaDB 10.6, 10.11, 11.4, 11.8 LTS; 12.x rolling | varies | — | SETTING (`mariadb:<v>`) | Linux container | base.mariadb-<v> | 10.6 EOL 2026-07 (check) |
| MY-CF-06 | Percona Server for MySQL | 8.0/8.4 | — | SETTING | Linux container | base.percona | optional |
| MY-CF-07 | `lower_case_table_names` = 0 / 1 (fixed at initialisation on 8.0+) | all | databases | SETTING (initialisation option) | Linux container | settings.my.lctn | mixed-case table names on a case-sensitive server |
| MY-CF-08 | `sql_mode` variants: strict (default), non-strict with zero dates, `ANSI_QUOTES`, `NO_BACKSLASH_ESCAPES`, `ONLY_FULL_GROUP_BY` off, `PIPES_AS_CONCAT` | all | — | SETTING or API `Session/MySQLSessionClient+Variables.swift:setSQLMode` (session) / `setGlobalVariable` | Linux container | my.config.sqlmode | Echo's quoting must respect ANSI_QUOTES |
| MY-CF-09 | Server charset/collation (`utf8mb4_0900_ai_ci`, `latin1`, MariaDB `utf8mb4_uca1400_ai_ci` default 11.5+? check) | all | — | SETTING | Linux container | my.config.charsets | |
| MY-CF-10 | `max_allowed_packet`, `innodb_page_size` (4K/8K/16K/32K/64K at init) | all | — | SETTING | Linux container | settings.my.limits | 64K page changes max row size |
| MY-CF-11 | Cloud: RDS/Aurora MySQL, Azure Flexible, PlanetScale (Vitess), TiDB | — | — | SETTING | cloud | base.mysql-cloud | |

## 7. States and edge cases

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| MY-ST-01 | Read-only server (`super_read_only`), read-only schema (8.0.22+) | 5.7+ | databases | API `setGlobalVariable("super_read_only","ON")`; schema option GM-01 | Linux container | my.states | |
| MY-ST-02 | Names: Unicode, spaces, backticks inside names, reserved words, 64-char limit, names differing by case, dots, names ending in space (rejected) | all | every folder | GAP GM-02 (tables); API for routines/views/triggers (check: `escapedIdentifier` doubles backticks) | Linux container | my.edge.names | |
| MY-ST-03 | 4,096-column limit (InnoDB 1,017 columns), 65,535-byte row limit, 10 MB LONGTEXT/LONGBLOB | all | tables | GAP GM-02 | Linux container | my.edge.scale | |
| MY-ST-04 | 10,000 tables; 500 databases | all | tables | GAP GM-01, GM-02 | Linux container | my.edge.scale | `information_schema` slowness |
| MY-ST-05 | 1 million rows | all | tables | PARTIAL GM-12 (`insert(chunkSize:)` multi-row INSERT; LOAD DATA via `loadDataCommand` builds a CLI command) | Linux container | my.edge.scale | |
| MY-ST-06 | NULL-heavy data, zero dates, invalid UTF-8 in latin1 columns, `NaN` impossible | all | tables | GAP GM-02 | Linux container | my.edge.nulls | |
| MY-ST-07 | Views and routines whose definer is missing; views over dropped tables (invalid view) | all | views | PARTIAL GM-18 | Linux container | my.states | |
| MY-ST-08 | Crashed MyISAM table, corrupt InnoDB page (needs harness) | all | tables | HARNESS (damage files) | Linux container (harness) | my.states.damaged | |

## 8. Sample databases

See [sample-databases.md](sample-databases.md).

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| MY-SA-01 | sakila | 5.x+ (spatial column + FULLTEXT) | databases | GAP GM-17 (SQL scripts with DELIMITER) | Linux container | my.sample.sakila | |
| MY-SA-02 | employees (datacharmer/test_db) | all | databases | GAP GM-17 | Linux container | my.sample.employees | ~4 M rows, 167 MB of data |
| MY-SA-03 | world | all | databases | GAP GM-17 | Linux container | my.sample.world | |
| MY-SA-04 | airportdb | 8.0+ (MySQL Shell dump) | databases | GAP GM-17 (needs `util.loadDump`, i.e. MySQL Shell) | Linux container | my.sample.airportdb | 625 MB download, ~2 GB |
| MY-SA-05 | menagerie | all | databases | GAP GM-17 (tiny: port to a typed pack) | Linux container | my.sample.menagerie | |
| MY-SA-06 | Chinook | all | databases | GAP GM-17 — or typed pack from `ChinookData.json` once GM-01/GM-02 exist | Linux container | my.sample.chinook | |
