# PostgreSQL coverage catalogue

Driver: `postgres-wire` (product `PostgresKit`), checked at commit `62b899c`.
Paths in the **Typed API** column are relative to `postgres-wire/Sources/PostgresKit/`.
Column meanings, status words and feasibility words are defined in [README.md](README.md).

Facts this catalogue relies on:

- Official `postgres` Docker images (Debian and Alpine, amd64) exist for 13–18. PostgreSQL 13 reached end of life in November 2025; 19 is due around now (check release status before adding `base.pg-19`).
- The official Debian image ships all **contrib** modules (`pg_trgm`, `hstore`, `citext`, `ltree`, `postgres_fdw`, `pgcrypto`, `pg_stat_statements`, …). It does **not** ship PostGIS, pgvector, pg_cron, pgAgent, PL/Python, PL/Perl, PL/Tcl, TimescaleDB, or non-contrib FDWs: those need a custom image layer (PGDG apt packages `postgresql-<v>-postgis-3`, `-pgvector`, `-cron`, `pgagent`, `postgresql-plpython3-<v>`, `postgresql-plperl-<v>`) or the vendor images (`postgis/postgis`, `pgvector/pgvector`).
- Libraries that must be preloaded (`pg_stat_statements`, `pg_cron`, `auto_explain`, `pgaudit`) are a start-time SETTING (`shared_preload_libraries`), not something a pack can do.
- The driver builds most DDL from strings it quotes with `quoteIdentifier`; several create APIs have no `schema:` parameter and quote a dotted name as one identifier (GP-01). Column data types are passed as strings (`Schema/PostgresColumnDefinition.swift:dataType`), so any type name, including extension types, can be used: those rows are marked API.

---

## 1. Data types

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes (edge values worth seeding) |
|---|---|---|---|---|---|---|---|
| PG-DT-01 | `smallint`, `integer`, `bigint` | all | tables (column) | API `Schema/TableOperations.swift:createTable` + `Schema/PostgresColumnDefinition.swift:integer/bigInt`; rows `Execution/DataManipulation.swift:insert(values: [[PostgresInsertValue]])` | Linux container | pg.types.core | min/max of each; `Int16`/`Int32` binds missing (GP-19) |
| PG-DT-02 | `smallserial`, `serial`, `bigserial` | all | tables (column) | API `PostgresColumnDefinition.serial/bigSerial` | Linux container | pg.types.core | owned sequence appears under Sequences |
| PG-DT-03 | Identity columns (`GENERATED ALWAYS/BY DEFAULT AS IDENTITY`, custom sequence options) | 10+ | tables (column) | GAP GP-02 | Linux container | pg.schema.core | |
| PG-DT-04 | `numeric(p,s)` / unconstrained `numeric` | all | tables (column) | PARTIAL GP-19 (column `PostgresColumnDefinition.decimal`; no Decimal bind, value via `.sql` literal is raw) | Linux container | pg.types.core | NaN, `Infinity`/`-Infinity` (14+), 1000-digit value, negative scale (15+) |
| PG-DT-05 | `real`, `double precision` | all | tables (column) | API `PostgresColumnDefinition.real/double`; bind `Double` | Linux container | pg.types.core | NaN, Infinity, -0, denormals |
| PG-DT-06 | `money` | all | tables (column) | PARTIAL GP-19 | Linux container | pg.types.core | locale-dependent output (`lc_monetary`) |
| PG-DT-07 | `char(n)`, `varchar(n)`, `text`, `"char"`, `name` | all | tables (column) | API `PostgresColumnDefinition.char/varchar/text` | Linux container | pg.types.core | NUL is rejected; 10 MB text (TOAST), 1 GB limit not seeded |
| PG-DT-08 | `bytea` | all | tables (column) | API `PostgresColumnDefinition.bytea`; bind `Data` | Linux container | pg.types.core | hex vs escape output (`bytea_output`), 10 MB value |
| PG-DT-09 | `boolean` | all | tables (column) | API `PostgresColumnDefinition.boolean`; bind `Bool` | Linux container | pg.types.core | |
| PG-DT-10 | `date` | all | tables (column) | API `PostgresColumnDefinition.date`; bind `Date` | Linux container | pg.types.core | `infinity`, `-infinity`, 4713 BC, 5874897 AD (Swift `Date` cannot hold these: GP-19) |
| PG-DT-11 | `time`, `timetz` | all | tables (column) | PARTIAL GP-19 | Linux container | pg.types.core | 24:00:00, offsets ±15:59 |
| PG-DT-12 | `timestamp`, `timestamptz` (precision 0–6) | all | tables (column) | API `PostgresColumnDefinition.timestamp/timestampWithTimeZone`; bind `Date` | Linux container | pg.types.core | infinity, BC dates, DST gap times, session `TimeZone` changes |
| PG-DT-13 | `interval` (fields, precision) | all | tables (column) | PARTIAL GP-19 | Linux container | pg.types.core | mixed months/days/µs, negative, `infinity` (17+), `IntervalStyle` variants |
| PG-DT-14 | `uuid` | all | tables (column) | API `PostgresColumnDefinition.uuid`; bind `UUID` | Linux container | pg.types.core | `uuidv7()` default (18+) |
| PG-DT-15 | `inet`, `cidr`, `macaddr`, `macaddr8` | all (macaddr8 10+) | tables (column) | API `PostgresColumnDefinition.inet/cidr/macaddr`; binds `Types/IPAddress.swift`, `Types/MACAddress.swift` | Linux container | pg.types.core | IPv6 with zone, /0, /128 |
| PG-DT-16 | `bit(n)`, `bit varying(n)` | all | tables (column) | PARTIAL GP-19 | Linux container | pg.types.core | 0-length varbit, 10,000 bits |
| PG-DT-17 | Geometric: `point`, `line`, `lseg`, `box`, `path` (open/closed), `polygon`, `circle` | all | tables (column) | PARTIAL GP-19 | Linux container | pg.types.core | |
| PG-DT-18 | `tsvector`, `tsquery` | all | tables (column) | PARTIAL GP-19 | Linux container | pg.fts | positions and weights |
| PG-DT-19 | `xml` | all | tables (column) | PARTIAL GP-19 (value only as text with implicit cast: check) | Linux container | pg.types.core | content vs document (`xmloption`) |
| PG-DT-20 | `json` | all | tables (column) | API `PostgresColumnDefinition.json` (value as `String` bind: check the driver sends it with a json OID or unknown) | Linux container | pg.types.json | duplicate keys preserved, key order preserved, 10 MB doc |
| PG-DT-21 | `jsonb` | 9.4+ | tables (column) | API `PostgresColumnDefinition.jsonb` | Linux container | pg.types.json | deep nesting (depth limit), numbers beyond double precision, `\u0000` rejected |
| PG-DT-22 | `jsonpath` | 12+ | tables (column) | PARTIAL GP-19 | Linux container | pg.types.json | |
| PG-DT-23 | Arrays: 1-D, multi-dimensional, non-1 lower bound (`'[0:2]={1,2,3}'`), NULL elements, empty `{}`, arrays of enum/composite/domain/range/jsonb | all | tables (column) | PARTIAL GP-19 (column `PostgresColumnDefinition.array(elementType:)`; `Array: PostgresEncodable` only for `Encodable` elements, no multi-dim or bounds) | Linux container | pg.types.arrays | array of 100,000 elements |
| PG-DT-24 | Built-in ranges `int4range`, `int8range`, `numrange`, `tsrange`, `tstzrange`, `daterange` | 9.2+ | tables (column) | PARTIAL GP-19 | Linux container | pg.types.ranges | empty, (,) unbounded, inclusive/exclusive, canonicalised discrete ranges |
| PG-DT-25 | Multiranges (`int4multirange`, …) | 14+ | tables (column) | PARTIAL GP-19 | Linux container | pg.types.ranges | |
| PG-DT-26 | User range type (+ its auto multirange) | 9.2+ (multirange 14+) | types | API `Schema/AdvancedTypeOperations.swift:createRangeType` | Linux container | pg.types.ranges | subtype `float8` with subtype_diff |
| PG-DT-27 | Enum type (values added later, renamed value, value with space/Unicode) | 8.3+ | types | API `Schema/TypeOperations.swift:createEnum/addEnumValue/renameEnumValue` | Linux container | pg.types.user | enum with 1,000 labels; `ADD VALUE BEFORE` |
| PG-DT-28 | Domain (NOT NULL, CHECK, default, domain over array/composite) | all | types | API `Schema/AdvancedTypeOperations.swift:createDomain/alterDomainAddConstraint` | Linux container | pg.types.user | NOT VALID domain constraint |
| PG-DT-29 | Composite type (nested composite, composite with array attribute) | all | types | API `Schema/AdvancedTypeOperations.swift:createCompositeType` | Linux container | pg.types.user | table row type used as column type |
| PG-DT-30 | Typed table (`CREATE TABLE … OF type`) | all | tables | GAP GP-03 | Linux container | pg.types.user | |
| PG-DT-31 | Object identifier types (`oid`, `regclass`, `regproc`, `regtype`, `regnamespace`, `regrole`, `regcollation` 13+) | all | tables (column) | API (type string) | Linux container | pg.types.core | regclass of a dropped table |
| PG-DT-32 | `pg_lsn`, `pg_snapshot`, `txid_snapshot`, `xid`, `xid8` (13+), `tid` | varies | tables (column) | API (type string) | Linux container | pg.types.core | |
| PG-DT-33 | Generated columns `STORED` | 12+ | tables (column) | GAP GP-02 | Linux container | pg.schema.core | |
| PG-DT-34 | Generated columns `VIRTUAL` | 18+ | tables (column) | GAP GP-02 | Linux container | pg.schema.core | |
| PG-DT-35 | Column collation: libc `C`, `en_US.utf8`, ICU `und-x-icu`, ICU non-deterministic case-insensitive collation, `builtin` `C.UTF-8`/`PG_UNICODE_FAST` (17+/18+) | varies | tables (column) | PARTIAL GP-02 (collation objects: `Schema/CollationOperations.swift:createCollation`; column `COLLATE` missing) | Linux container (Alpine images use musl: prefer Debian for libc collations) | pg.config.collations | `LIKE` fails on non-deterministic collations before 18 |
| PG-DT-36 | Column compression `lz4`/`pglz`, `STORAGE` settings | 14+ | tables (column) | PARTIAL GP-02 (`Schema/TableOperations.swift:alterColumnStorage` exists; compression missing) | Linux container | pg.schema.core | |
| PG-DT-37 | `citext`, `hstore`, `ltree`, `cube`, `isn` types, `seg`, `lo` | contrib | tables (column) | API `Maintenance/DatabaseMaintenance.swift:createExtension` + type string; values PARTIAL GP-19 | Linux container | pg.ext.contrib | hstore with NULL values, ltree 65,535 labels |
| PG-DT-38 | PostGIS `geometry`, `geography` (all subtypes, Z/M, SRIDs), `raster`, `box2d` | PostGIS 3.x | tables (column) | API `createExtension("postgis")` + type string; values PARTIAL GP-19 | needs custom image layer (or `postgis/postgis`) | pg.ext.postgis | invalid polygons, EMPTY, 1 M-vertex linestring, SRID 4326/3857/27700 |
| PG-DT-39 | pgvector `vector(n)`, `halfvec` (0.7+), `sparsevec` (0.7+), `bit` for binary quantisation | pgvector 0.5+ | tables (column) | API `createExtension("vector")` + type string; values PARTIAL GP-19 | needs custom image layer (or `pgvector/pgvector`) | pg.ext.pgvector | dimension 16,000 max, NaN rejected |

## 2. Schema objects

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| PG-SO-01 | Database (owner, template, encoding, locale, ICU locale, locale provider, tablespace, connection limit) | all (ICU provider 15+, builtin 17+) | databases | API `Schema/DatabaseOperations.swift:createDatabase` | Linux container | pg.schema.core | `icuRules` 16+ |
| PG-SO-02 | Schema (owner, empty, many) | all | none — check: Echo groups objects by schema inside a database | API `Schema/DatabaseOperations.swift:createSchema` | Linux container | pg.schema.core | schema named `public` dropped; `pg_temp_N` visible |
| PG-SO-03 | Table in non-public schema | all | tables | PARTIAL GP-01 (`createTable` has no `schema:`) | Linux container | pg.schema.core | the most common gap: every pack needs it |
| PG-SO-04 | Temporary table, `UNLOGGED` table | all | tables | PARTIAL GP-03 (`createTable(temporary:)` exists; `UNLOGGED` missing) | Linux container | pg.schema.core | temp table only visible to its session |
| PG-SO-05 | Table with storage parameters (fillfactor, autovacuum_*, toast.*), tablespace, `USING` access method | all (table AM 12+) | tables | PARTIAL GP-03 (`alterTableSetParameter`, `alterTableSetTablespace` after create) | Linux container | pg.schema.core | |
| PG-SO-06 | Primary key, composite PK, unique, `UNIQUE NULLS NOT DISTINCT` (15+) | all | tables | API `Schema/ConstraintOperations.swift:addPrimaryKey/addCompositePrimaryKey/addUniqueConstraint`; NULLS NOT DISTINCT via `createAdvancedIndex(nullsDistinct:)` | Linux container | pg.schema.core | |
| PG-SO-07 | Check constraint, `NOT VALID` check, validated later | all | tables | API `addCheckConstraint/addCheckConstraintNotValid/validateConstraint` | Linux container | pg.schema.core | |
| PG-SO-08 | Foreign keys (actions, self-reference, composite, `DEFERRABLE INITIALLY DEFERRED`, `MATCH FULL`, `NOT VALID`, cross-schema) | all | tables | PARTIAL GP-17 (`Schema/ConstraintOperations.swift:addForeignKey/addCompositeForeignKey`; no deferrable/match/schema) | Linux container | pg.schema.core | FK referencing a partitioned table (12+) |
| PG-SO-09 | Exclusion constraint (gist, `&&` on ranges) | 9.0+ | tables | API `Schema/ConstraintOperations.swift:addExclusionConstraint` | Linux container | pg.types.ranges | needs `btree_gist` for scalar equality |
| PG-SO-10 | Temporal constraints `PRIMARY KEY … WITHOUT OVERLAPS`, `FOREIGN KEY … PERIOD` | 18+ | tables | GAP GP-18 | Linux container | pg.schema.temporal | |
| PG-SO-11 | Named NOT NULL constraints, `NOT NULL NOT VALID` | 18+ | tables | GAP GP-02 | Linux container | pg.schema.core | |
| PG-SO-12 | B-tree index (unique, multi-column, DESC NULLS FIRST, partial) | all | tables | API `Schema/IndexOperations.swift:createAdvancedIndex(columns:[PostgresIndexColumn], whereClause:)` | Linux container | pg.schema.core | |
| PG-SO-13 | Hash, GiST, GIN, BRIN indexes | all | tables | API `createAdvancedIndex(indexType:)` (`Schema/PostgresIndexTypes.swift:PostgresIndexType`) | Linux container | pg.schema.core | BRIN on append-only timestamp table |
| PG-SO-14 | SP-GiST index | all | tables | GAP GP-05 | Linux container | pg.schema.core | on `inet`, `point`, text prefix |
| PG-SO-15 | Expression index, `INCLUDE` columns (11+), operator class (`gin_trgm_ops`, `jsonb_path_ops`, `text_pattern_ops`), index collation, `CONCURRENTLY` | all | tables | GAP GP-05 | Linux container | pg.schema.core | invalid index from a failed `CREATE INDEX CONCURRENTLY` (see PG-ST-09) |
| PG-SO-16 | Extension index methods: pgvector `hnsw`/`ivfflat`, `bloom`, `rum` | varies | tables | GAP GP-05 | needs custom image layer (pgvector, rum); bloom is contrib | pg.ext.pgvector | |
| PG-SO-17 | Extended statistics (`CREATE STATISTICS` ndistinct, dependencies, mcv 12+, expressions 14+) | 10+ | none — Echo does not show it yet | GAP GP-06 | Linux container | pg.schema.core | |
| PG-SO-18 | View (updatable, `WITH CHECK OPTION`, `security_barrier`, `security_invoker` 15+, recursive view) | all | views | PARTIAL GP-01 (`Schema/ViewOperations.swift:createView(name:query:temporary:orReplace:)`; no schema, no options) | Linux container | pg.schema.core | view depending on a view in another schema |
| PG-SO-19 | Materialized view (populated, `WITH NO DATA`, indexed, refreshed concurrently) | 9.3+ | materializedViews | PARTIAL GP-01, GP-03 (`Schema/ViewOperations.swift:createMaterializedView/refreshMaterializedView`) | Linux container | pg.schema.core | unpopulated MV errors on select |
| PG-SO-20 | Sequence (start, increment negative, min/max, cycle, cache, `AS smallint`, owned by column, at max value) | all | sequences | PARTIAL GP-01 (`Schema/SequenceOperations.swift:createSequence/setval`; no schema, `OWNED BY` check) | Linux container | pg.schema.core | unlogged sequence (15+) |
| PG-SO-21 | Table inheritance (parent, children, multiple inheritance, `ONLY`) | all | tables | API `Schema/InheritanceOperations.swift:addInheritance` | Linux container | pg.partitioning | |
| PG-SO-22 | Declarative partitioning: RANGE, LIST, HASH, DEFAULT partition, sub-partitions, 1,000 partitions | 10+ (HASH/DEFAULT 11+) | tables | API `Schema/PartitionOperations.swift:createPartitionedTable/createPartition(bound:)/attachPartition/detachPartition` | Linux container | pg.partitioning | detach `CONCURRENTLY` (14+), `SPLIT/MERGE PARTITION` (check: reverted from 17) |
| PG-SO-23 | Foreign table | 9.1+ | tables (check: Echo lists foreign tables) | API `Schema/ForeignDataOperations.swift:createForeignTable` | Linux container | pg.fdw | |
| PG-SO-24 | Foreign-data wrapper, foreign server, user mapping | all | none — Echo does not show it yet | API `createForeignDataWrapper/createForeignServer/createUserMapping` | Linux container | pg.fdw | |
| PG-SO-25 | `IMPORT FOREIGN SCHEMA` | 9.5+ | tables | GAP GP-21 | Linux container | pg.fdw | |
| PG-SO-26 | Comments on every object kind (table, column, view, function, type, schema, database, role, index, constraint, trigger, extension, sequence) | all | all | API `Schema/CommentOperations.swift:add*Comment`, `Schema/DatabaseOperations.swift:addDatabaseComment`, `Security/RoleManagement.swift:setRoleComment` | Linux container | pg.schema.core | multi-line and Unicode comments |
| PG-SO-27 | Collations (libc, ICU, non-deterministic) | 10+ (non-deterministic 12+) | none — Echo does not show it yet | API `Schema/CollationOperations.swift:createCollation` | Linux container | pg.config.collations | collation version mismatch warning (`alterCollationRefreshVersion`) |
| PG-SO-28 | Tablespaces (default, custom location, empty) | all | tablespaces / tablespace | API `Schema/TablespaceOperations.swift:createTablespace` | Linux container (harness creates the directory owned by `postgres`) | pg.tablespaces | tablespace whose directory is missing (harness) |
| PG-SO-29 | Text search configuration, dictionaries (simple, snowball, synonym, thesaurus, ispell) | all | none — Echo does not show it yet | API `Schema/FTSOperations.swift:createTextSearchConfiguration/createTextSearchDictionary/alterTextSearchConfigurationMapping` | Linux container (synonym/thesaurus files need an image layer) | pg.fts | |
| PG-SO-30 | Text search parser / template | all | none | N/A (needs C code) | needs custom image layer | — | out of scope |
| PG-SO-31 | Large objects (`lo_create`, `lo_import`) | all | none — Echo does not show it yet | GAP GP-07 | Linux container | pg.types.core | orphaned large objects (`vacuumlo`) |
| PG-SO-32 | Rules (`DO INSTEAD` on view, `DO ALSO`) | all | none — Echo does not show it yet | API `Schema/RuleOperations.swift:createRule` | Linux container | pg.programmability | |
| PG-SO-33 | Casts (with function, binary-coercible, implicit) | all | none — Echo does not show it yet | API `Schema/MiscOperations.swift:createCast` | Linux container | pg.programmability | |
| PG-SO-34 | Operators | all | none — Echo does not show it yet | API `Schema/MiscOperations.swift:createOperator` | Linux container | pg.programmability | |
| PG-SO-35 | Operator classes and families, access methods, conversions, transforms | all | none | GAP GP-09 | Linux container (index AMs in C need a layer) | pg.programmability | |
| PG-SO-36 | Security labels | all | none | GAP GP-08 | needs custom image layer (label provider such as `sepgsql` or `anon`) | pg.security.labels | |
| PG-SO-37 | Event triggers (`ddl_command_start/end`, `sql_drop`, `table_rewrite`, `login` 17+, disabled) | 9.3+ | none — check: not under Triggers | API `Schema/EventTriggerOperations.swift:createEventTrigger/alterEventTriggerEnable` | Linux container | pg.programmability | a `login` event trigger that raises locks everyone out: bind to a test role |

## 3. Programmability

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| PG-PR-01 | SQL function (IMMUTABLE/STABLE/VOLATILE, STRICT, SECURITY DEFINER, cost/rows) | all | functions | PARTIAL GP-01 (`Schema/RoutineOperations.swift:createFunction`; no schema, no PARALLEL, no `SET` clause) | Linux container | pg.programmability | SQL-standard body `BEGIN ATOMIC` (14+) |
| PG-PR-02 | PL/pgSQL function (RAISE NOTICE/WARNING/EXCEPTION, returns TABLE, SETOF, OUT params, VARIADIC, polymorphic `anyelement`/`anycompatible`) | all | functions | API `createFunction(language: .plpgsql)` (OUT/INOUT via `PostgresFunctionParameter.mode`) | Linux container | pg.programmability | overloaded functions with the same name |
| PG-PR-03 | Procedure (`CREATE PROCEDURE`, transaction control inside, INOUT, OUT 14+) | 11+ | procedures | GAP GP-04 | Linux container | pg.programmability | |
| PG-PR-04 | Functions in PL/Python, PL/Perl, PL/Tcl, PL/v8 | all | functions | PARTIAL GP-14 (`PostgresFunctionLanguage.plpython = "PLPYTHONU"` names the removed Python 2 language; plv8 missing) | needs custom image layer | pg.pl-languages | |
| PG-PR-05 | Window/aggregate functions: user aggregate (sfunc/stype/initcond), ordered-set, moving-aggregate, parallel combine | all | functions (check: aggregates listed) | PARTIAL GP-22 (`Schema/MiscOperations.swift:createAggregate` basic form only) | Linux container | pg.programmability | |
| PG-PR-06 | Row triggers BEFORE/AFTER, statement triggers, `WHEN` condition, `INSTEAD OF` on view, `TRUNCATE` trigger, disabled trigger, constraint trigger | all | triggers | API `Schema/TriggerOperations.swift:createTrigger` (`constraint:`, `forEach:`, `when:`), `Schema/TableOperations.swift:alterTableTrigger` | Linux container | pg.programmability | |
| PG-PR-07 | Triggers with transition tables (`REFERENCING NEW TABLE`), deferrable constraint triggers, triggers on partitioned tables | 10+ (partitioned 11+/13+ BEFORE) | triggers | GAP GP-24 | Linux container | pg.programmability | |
| PG-PR-08 | Row-level security: enable/force, permissive and restrictive policies per command, policies on roles | 9.5+ | none — Echo does not show it yet | API `Security/PolicyManagement.swift:enableRowLevelSecurity/forceRowLevelSecurity/createPolicy(permissive:)` | Linux container | pg.security | |
| PG-PR-09 | Prepared (two-phase) transactions left open | all (needs `max_prepared_transactions > 0` SETTING) | pgPreparedTransactions | GAP GP-15 (`Schema/MiscOperations.swift:commitPrepared/rollbackPrepared` exist; `PREPARE TRANSACTION` does not) | Linux container | pg.workload | |
| PG-PR-10 | LISTEN/NOTIFY channels in use | all | none | API `Connection/PostgresClient+Namespaces.swift:PostgresNotifierClient.notify` | Linux container | pg.workload | |
| PG-PR-11 | Advisory locks held | all | pgLocks | API `Execution/LockManagement.swift:acquireAdvisoryLock` | Linux container | pg.workload | |
| PG-PR-12 | pg_cron jobs (every minute, `cron.schedule_in_database`, failed runs, job run details) | pg_cron 1.x, PG 13+ | none — Echo does not show it yet | GAP GP-11 (`createExtension("pg_cron")` exists) | needs custom image layer + SETTING `shared_preload_libraries=pg_cron`, `cron.database_name` | pg.cron | |
| PG-PR-13 | pgAgent jobs, steps, schedules, exceptions | pgAgent 4.x | none — Echo does not show it yet | GAP GP-12 | needs custom image layer (pgagent daemon in the container or a sidecar) | pg.pgagent | pgAdmin's scheduler; Echo's pgAgent support is planned (PGADMIN4_POSTGRES_GAP.md Phase 6) |

## 4. Server-level

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| PG-SV-01 | Extensions from contrib: `pg_trgm`, `hstore`, `citext`, `ltree`, `cube`, `earthdistance`, `fuzzystrmatch`, `unaccent`, `pgcrypto`, `uuid-ossp`, `tablefunc`, `intarray`, `isn`, `seg`, `btree_gin`, `btree_gist`, `bloom`, `pg_buffercache`, `pg_prewarm`, `pageinspect`, `amcheck`, `pgstattuple`, `tsm_system_rows`, `dblink`, `postgres_fdw`, `file_fdw`, `lo`, `pg_walinspect` (15+), `pg_surgery` (14+) | per version | extensions | API `Maintenance/DatabaseMaintenance.swift:createExtension(schema:version:cascade:)` | Linux container | pg.ext.contrib | extension in a non-default schema; extension at an older version then `updateExtension` |
| PG-SV-02 | `pg_stat_statements` populated | all | extensions / pgQueries | API `createExtension` + SETTING `shared_preload_libraries` | Linux container | pg.ext.contrib + pg.workload | |
| PG-SV-03 | PostGIS (+ `postgis_topology`, `postgis_raster`, `postgis_tiger_geocoder`, `address_standardizer`) | PostGIS 3.x per PG version | extensions | API `createExtension` | needs custom image layer | pg.ext.postgis | spatial_ref_sys has 8,500 rows |
| PG-SV-04 | pgvector | 0.5+ | extensions | API `createExtension("vector")` | needs custom image layer | pg.ext.pgvector | |
| PG-SV-05 | Other popular extensions: TimescaleDB, Citus, pg_partman, pgaudit, pg_hint_plan, hypopg, orafce, pg_repack, pgrouting, h3 | varies | extensions | API `createExtension` | needs custom image layer (several need preload SETTING) | pg.ext.thirdparty | pick per need; licences differ (Timescale TSL for some features) |
| PG-SV-06 | Procedural languages installed (`plpgsql` default; plpython3u, plperl/plperlu, pltcl) | all | extensions | API `createExtension("plpython3u")` or `Schema/MiscOperations.swift:createLanguage` | needs custom image layer | pg.pl-languages | |
| PG-SV-07 | Logical replication publication: `FOR ALL TABLES`, table list, operations subset | 10+ | none — pgReplication tool | API `Schema/ReplicationOperations.swift:createPublication(forAllTables:tables:operations:)` | Linux container + SETTING `wal_level=logical` | pg.replication | |
| PG-SV-08 | Publication `FOR TABLES IN SCHEMA`, row filters, column lists, `publish_via_partition_root`, `publish_generated_columns` (18+) | 13+/15+/18+ | none | GAP GP-10 | Linux container | pg.replication | |
| PG-SV-09 | Subscription (enabled, disabled, copy_data off, streaming, two-phase, failover 17+) on a second server | 10+ | none — pgReplication tool | PARTIAL GP-10 (`createSubscription` basic options) | Linux container (2) | pg.replication | subscription with broken connection string |
| PG-SV-10 | Replication slots (logical with `pgoutput`/`test_decoding`, physical, inactive slot holding WAL) | 9.4+ | pgReplication / pgWAL | GAP GP-10 | Linux container | pg.replication | |
| PG-SV-11 | Physical streaming replica (hot standby, `pg_stat_replication` rows) | all | pgReplication | HARNESS (`pg_basebackup` into the second container) | Linux container (2) | pg.replica | the standby is read-only: every Explorer create action must fail cleanly |
| PG-SV-12 | Server configuration changed with `ALTER SYSTEM`, pending-restart parameters | all | pgConfiguration | GAP GP-16 (`Execution/ServerConfiguration.swift:set` is session-level) | Linux container | pg.config.server | parameter with `pending_restart = true` |
| PG-SV-13 | Activity: many sessions, idle in transaction, blocking chain, long-running query, waiting on advisory lock, autovacuum worker | all | pgSessions / pgLocks / pgOperations | API `Execution/TransactionManagement.swift:beginTransaction`, `Execution/LockManagement.swift:lock/acquireAdvisoryLock` | Linux container | pg.workload | live pack (holds sessions) |
| PG-SV-14 | Database statistics, I/O statistics (`pg_stat_io` 16+), WAL stats, background writer / checkpointer | varies | pgDatabaseStatistics / pgIOStatistics / pgWAL / pgBackgroundWriter | API (workload through CRUD + `Maintenance/DatabaseMaintenance.swift:vacuum/analyze`) | Linux container | pg.workload | stats reset on restart |
| PG-SV-15 | Progress views (VACUUM, CREATE INDEX, COPY, ANALYZE, basebackup) visible in Operations | 9.6+ (COPY 14+) | pgOperations | API `vacuum` on a large table + GP-05 concurrent index | Linux container | pg.workload | |
| PG-SV-16 | pg_dump / pg_dumpall availability for Back Up Server / Back Up Globals / PSQL Console tools | all | backUpServer / backUpGlobals / psqlConsole | N/A (client tools on the Mac; any server works) | Linux container | — | tool nodes need only a reachable server |
| PG-SV-17 | Maintenance targets: bloated table, table needing vacuum, index needing reindex | all | maintenance | API (CRUD churn) | Linux container | pg.workload | |

## 5. Security

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| PG-SE-01 | Login roles: plain, superuser, CREATEDB, CREATEROLE, REPLICATION, BYPASSRLS, connection limit, `VALID UNTIL` past (expired), NOINHERIT | all | loginRoles / login | API `Security/RoleManagement.swift:createRole(password:superuser:createDatabase:createRole:login:inherit:replication:bypassRLS:connectionLimit:validUntil:)` | Linux container | pg.security | role name with uppercase and spaces |
| PG-SE-02 | Group roles (NOLOGIN), nested membership, `ADMIN OPTION`, `INHERIT`/`SET` options (16+) | all (16+ options) | groupRoles / login | PARTIAL GP-20 (`Security/PrivilegeManagement.swift:grantRole`; 16+ membership options missing) | Linux container | pg.security | |
| PG-SE-03 | Predefined roles membership (`pg_read_all_data` 14+, `pg_monitor`, `pg_signal_backend`, `pg_maintain` 17+) | varies | groupRoles | API `grantRole` | Linux container | pg.security | |
| PG-SE-04 | Password stored as SCRAM-SHA-256 vs MD5 (MD5 deprecated in 18) | 10+ | loginRoles | PARTIAL GP-25 (`Security/PostgresPasswordHashing.swift:passwordClause` always hashes SCRAM) | Linux container | pg.security | pairs with `pg_hba` auth method SETTING |
| PG-SE-05 | Table privileges GRANT/REVOKE with grant option | all | tables | PARTIAL GP-01 (`Security/PrivilegeManagement.swift:grantPrivileges(onTable:)` unqualified) | Linux container | pg.security | |
| PG-SE-06 | Column privileges, sequence/function/type/FDW/server/language/large object/tablespace privileges, `GRANT SET ON PARAMETER` (15+) | all | tables / functions | GAP GP-20 | Linux container | pg.security | |
| PG-SE-07 | Schema and database privileges, `ALL TABLES IN SCHEMA` | all | databases | API `grantSchemaPrivileges/grantDatabasePrivileges/grantAllTablesPrivileges` | Linux container | pg.security | `public` schema CREATE revoked (15+ default) |
| PG-SE-08 | Default privileges (`ALTER DEFAULT PRIVILEGES`) | 9.0+ | none — Echo does not show it yet | API `Security/PrivilegeManagement.swift:alterDefaultPrivileges` | Linux container | pg.security | |
| PG-SE-09 | Object ownership by different roles, `REASSIGN OWNED`, `DROP OWNED` | all | all | API `alterTableOwner/alterViewOwner/…`, `Security/RoleManagement.swift:reassignOwned` | Linux container | pg.security | |
| PG-SE-10 | Low-privilege login: CONNECT only; no access to `pg_stat_activity` details; no schema USAGE; `pg_read_all_data` only | all | every folder | API (SE-01, SE-05..07) | Linux container | pg.lowpriv | Explorer must degrade gracefully |
| PG-SE-11 | Authentication methods: `scram-sha-256`, `md5`, `password`, `trust`, `cert` (client certificates), `reject` for one database, `ldap` | all | none (connection) | SETTING (`pg_hba.conf` mounted at start) | Linux container (ldap needs an LDAP sidecar) | settings.pg.auth | |
| PG-SE-12 | TLS: own CA, `ssl_min_protocol_version`, `sslmode=verify-full` mismatch, expired certificate, direct SSL negotiation (17+ `sslnegotiation=direct`) | all | none (connection) | SETTING (`ssl=on`, certificates) | Linux container | settings.pg.tls | reuse `sqlserver-nio/testlab/certs` CA layout |
| PG-SE-13 | GSSAPI / Kerberos | all | none | SETTING | Linux container + KDC sidecar | settings.pg.kerberos | |
| PG-SE-14 | Cloud IAM auth (AWS RDS token) | — | none | API `Security/PostgresAWSRDSAuthToken.swift:generate` (client side) | cloud | settings.pg.rds | |

## 6. Configuration and versions

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| PG-CF-01 | PostgreSQL 13 | 13 (EOL 2025-11) | — | SETTING (`postgres:13`) | Linux container | base.pg-13 | no multirange changes after 14 |
| PG-CF-02 | PostgreSQL 14 | 14 | — | SETTING | Linux container | base.pg-14 | |
| PG-CF-03 | PostgreSQL 15 | 15 | — | SETTING | Linux container | base.pg-15 | `public` schema permissions change, MERGE |
| PG-CF-04 | PostgreSQL 16 | 16 | — | SETTING | Linux container | base.pg-16 | `pg_stat_io`, role membership options |
| PG-CF-05 | PostgreSQL 17 | 17 | — | SETTING | Linux container | base.pg-17 | builtin locale provider, `pg_maintain`, login event trigger |
| PG-CF-06 | PostgreSQL 18 | 18 | — | SETTING | Linux container | base.pg-18 | virtual generated columns, temporal constraints, uuidv7, OAuth, MD5 deprecation, async I/O |
| PG-CF-07 | PostgreSQL 19 | 19 (check) | — | SETTING | Linux container | base.pg-19 | add once GA |
| PG-CF-08 | PostgreSQL 9.6–12 (legacy servers still in the field) | 9.6–12 | — | SETTING (official images still published but unsupported) | Linux container | base.pg-legacy | driver behaviour on old catalogs (`relhasoids`, no `pg_stat_progress_*`) |
| PG-CF-09 | Server encodings UTF8, LATIN1, SQL_ASCII, EUC_JP; per-database encoding | all | databases | API `createDatabase(encoding:lcCollate:lcCtype:template:"template0")` | Linux container | pg.config.encodings | SQL_ASCII database with invalid UTF-8 bytes stored |
| PG-CF-10 | Locale providers libc / ICU / builtin; cluster default case-insensitive ICU collation not allowed (deterministic only) | 15+/17+ | databases | API `createDatabase(localeProvider:icuLocale:)` | Linux container | pg.config.collations | |
| PG-CF-11 | Session settings: `DateStyle`, `IntervalStyle`, `TimeZone`, `bytea_output`, `extra_float_digits`, `search_path` with Unicode schema | all | none | API `Schema/DatabaseOperations.swift:alterDatabaseSet` / `Security/RoleManagement.swift:alterRoleSet` | Linux container | pg.config.session | Echo's formatting must survive non-ISO DateStyle |
| PG-CF-12 | Database-level states: `ALLOW_CONNECTIONS false`, `CONNECTION LIMIT 0`, `IS_TEMPLATE`, `default_transaction_read_only` | all | databases | API `alterDatabaseAllowConnections/alterDatabaseConnectionLimit/alterDatabaseIsTemplate/alterDatabaseSet` | Linux container | pg.states | |
| PG-CF-13 | Non-default port, Unix socket only, `listen_addresses`, IPv6, many databases on one cluster | all | — | SETTING | Linux container | settings.pg.network | |
| PG-CF-14 | Managed services (RDS, Aurora, Azure Flexible, Cloud SQL, Neon, Supabase) | — | — | SETTING | cloud | base.pg-cloud | restricted superuser, custom predefined roles |
| PG-CF-15 | Compatible forks (e.g. Supabase image, YugabyteDB, CockroachDB wire compatibility) | — | — | SETTING | Linux container | base.pg-compat | check: scope decision for the owner |

## 7. States and edge cases

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| PG-ST-01 | Database not accepting connections / connection limit reached | all | databases | API (PG-CF-12) | Linux container | pg.states | |
| PG-ST-02 | Read-only server (hot standby) | all | databases | HARNESS (PG-SV-11) | Linux container (2) | pg.replica | |
| PG-ST-03 | Invalid database (interrupted `DROP DATABASE`, `datconnlimit = -2`) | 15.4+ | databases | HARNESS (kill a backend mid-drop) | Linux container (harness) | pg.states.damaged | check reproducibility |
| PG-ST-04 | Names: Unicode, spaces, quotes `"`, mixed case (`"MyTable"` vs `mytable`), reserved words, 63-byte limit (truncation), dots, names that look like `schema.table` | all | every folder | API (all create APIs use `quoteIdentifier`; GP-01 limits schema placement) | Linux container | pg.edge.names | 64-byte name silently truncated to 63 |
| PG-ST-05 | 1,600-column table (max), wide rows, 10 MB text/bytea, 1 MB jsonb | all | tables | API `createTable`, `insert` | Linux container | pg.edge.scale | |
| PG-ST-06 | 10,000 tables in one schema; 1,000 schemas; 1,000 partitions | all | tables | API loops | Linux container | pg.edge.scale | |
| PG-ST-07 | 1 million rows | all | tables | PARTIAL GP-13 (`Execution/BulkCopy.swift:copyIn(sql:source:)` takes a raw COPY statement) | Linux container | pg.edge.scale | |
| PG-ST-08 | NULL-heavy data; NULLs in arrays, composites, ranges; empty string vs NULL | all | tables | API | Linux container | pg.edge.nulls | |
| PG-ST-09 | Invalid index (failed `CREATE INDEX CONCURRENTLY`) | all | tables | GAP GP-05 | Linux container | pg.states | |
| PG-ST-10 | Disabled triggers, `NOT VALID` constraints, `NO FORCE` RLS, unpopulated materialized view | all | tables / triggers / materializedViews | API (see PR-06, SO-07, PR-08, SO-19) | Linux container | pg.states | |
| PG-ST-11 | Sequence at max without CYCLE (next call errors) | all | sequences | API `Schema/SequenceOperations.swift:setval` | Linux container | pg.states | |
| PG-ST-12 | Table with dropped columns (attisdropped), table rewritten after ALTER TYPE | all | tables | API `Schema/TableOperations.swift:dropColumn/alterColumnType` | Linux container | pg.edge.names | column numbering gaps in `attnum` |
| PG-ST-13 | Objects owned by a role that cannot log in; function with `SECURITY DEFINER` owned by superuser | all | functions | API | Linux container | pg.security | |
| PG-ST-14 | Empty cluster (only `postgres`, `template0`, `template1`) | all | databases | READY (nothing to create) | Linux container | pg.edge.empty | |

## 8. Sample databases

See [sample-databases.md](sample-databases.md).

| ID | Item | Versions | Echo node kind | Typed API or GAP | Feasibility | Pack | Notes |
|---|---|---|---|---|---|---|---|
| PG-SA-01 | pagila (DVD rental, partitions, full-text, JSONB variant) | 13+ (check each release) | databases | GAP GP-23 (plain SQL + COPY dump) | Linux container | pg.sample.pagila | |
| PG-SA-02 | dvdrental | 9.x+ | databases | GAP GP-23 (pg_restore `.tar` archive; would need an archive reader in the driver) | Linux container | pg.sample.dvdrental | |
| PG-SA-03 | Chinook | all | databases | GAP GP-23 — or typed pack from `ChinookData.json` (API) | Linux container | pg.sample.chinook | |
| PG-SA-04 | Airlines demo (Postgres Pro `demo`), 2025 edition 3m/6m/1y/2y | 15+ (2025 edition) | databases | GAP GP-23 | Linux container | pg.sample.airlines | 1.3–11 GB databases |
| PG-SA-05 | Northwind (pthom/northwind_psql) | all | databases | GAP GP-23 | Linux container | pg.sample.northwind | |
| PG-SA-06 | AdventureWorks for Postgres (lorint) | all | databases | GAP GP-23 (needs the Microsoft CSVs + Ruby conversion script: check) | Linux container | pg.sample.adventureworks | |
| PG-SA-07 | Stack Overflow Postgres dump (2024-04) | 18 (dump format) | databases | GAP GP-23 | Linux container (≈110 GB) | pg.sample.stackoverflow | too large for the default host budget |
| PG-SA-08 | Neon sample set (employees, lego, netflix, titanic, wikipedia, chinook, pagila, periodic table) | all | databases | GAP GP-23 | Linux container | pg.sample.neon | MIT |
