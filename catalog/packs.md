# Content packs and example recipes

A **pack** creates one coherent slice of the catalogue through a driver's typed API and ships a **check**
that reads the result back through the same driver's typed metadata API (never by comparing SQL text). A
**setting** changes how the container starts (environment, `mssql.conf`, `postgresql.conf`, `pg_hba.conf`,
`my.cnf`, certificates); it is not a pack because no driver call is involved. A **base** is an engine image and
version. A **recipe** = base + settings + packs with parameters.

Conventions for every pack:

- Name `engine.area[.detail]` (`mssql.agent`, `pg.types.ranges`). Parameters have defaults so a recipe can
  list a pack by name alone.
- Every pack takes `database` (default: a database named after the pack, created by the pack) and
  `nameStyle` (`plain` | `edge`; `edge` applies the names from `*.edge.names` to everything it creates).
- "Min version" is the lowest server version the pack supports; items above that are skipped with a
  recorded reason, and the check knows which ones.
- **Readiness** counts catalogue items the pack covers that an existing typed API can create now
  (API/SETTING/READY rows) against all its items, and names the driver gaps that block the rest
  ([driver-gaps.md](driver-gaps.md)). A pack can ship when its ready items are useful on their own; blocked
  items are added when the gap closes.
- Live packs (`*.workload`) do not seed the image: they run while the suite runs and hold sessions, locks and
  transactions open, then release them when the lab tears the server down.

---

## SQL Server

### Bases and settings

| Name | What | Notes |
|---|---|---|
| `base.mssql-2017`, `-2019`, `-2022`, `-2025` | `mcr.microsoft.com/mssql/server:<v>-latest` (pin a CU tag per lab release) | amd64 |
| `base.mssql-2017-fts` etc. | same + `mssql-server-fts` layer | needed by `mssql.fulltext` |
| `base.mssql-2019-polybase`, `-2022-polybase` | same + `mssql-server-polybase`; 2025: msodbcsql18 for ODBC BYOD | needed by `mssql.polybase` |
| `base.mssql-win` | Windows Server VM with 2008 R2 – 2016 named instances | from `sqlserver-nio/testlab/README.md` |
| `settings.mssql.agent` | `MSSQL_AGENT_ENABLED=true` | default on in recipes that use Agent |
| `settings.mssql.collation` | `MSSQL_COLLATION=<name>` (default `SQL_Latin1_General_CP1_CI_AS`) | |
| `settings.mssql.edition` | `MSSQL_PID=Developer\|Express\|Standard\|Enterprise` (default Developer) | |
| `settings.mssql.tls` | certificate + key mounted, `network.forceencryption`, `network.forcestrict` (2025) | `mssql.conf` must be writable |
| `settings.mssql.memory` | `MSSQL_MEMORY_LIMIT_MB` (default 2048) | |
| `settings.mssql.network` | `MSSQL_TCP_PORT` | |
| `settings.mssql.hadr` | `MSSQL_ENABLE_HADR=1` | for `mssql.alwayson` |
| `settings.mssql.msdtc` | `MSSQL_RPC_PORT`, `MSSQL_DTC_TCP_PORT` | |
| `settings.mssql.kerberos` | keytab + `network.privilegedadaccount`, Samba AD DC sidecar | |
| `settings.mssql.smtp` | Mailpit sidecar reachable as `smtp` | for `mssql.dbmail` |

### Packs

| Pack | Creates | Parameters (defaults) | Depends on | Min version | Check verifies | Readiness |
|---|---|---|---|---|---|---|
| `mssql.schema.core` | database, schemas, tables with every constraint kind, identity/computed/rowguid columns, indexes (unique, filtered, included), views, indexed views, table types, synonyms, sequences, alias types, statistics, comments | `tables: 20`, `schemas: ["dbo","sales","hr"]`, `rowsPerTable: 100` | — | 2017 | `metadata.listTables/listColumns/listIndexes/listForeignKeys/listSynonyms/listSequences` match the manifest | 18/22 — GS-09, GS-10, GS-11, GS-14 |
| `mssql.types.all` | one table per type family + one "every type" table, each with min/max/NULL/edge rows | `rowsPerEdge: 1`, `includeDeprecated: false` | — | 2017 | column types, lengths, precisions; round-trip of every seeded value through `query` | 23/28 — GS-01, GS-02 |
| `mssql.types.legacy` | `text`/`ntext`/`image`, rules/defaults, numbered procs | — | — | 2017 | as above | 3/5 — GS-18, GS-33 |
| `mssql.types.spatial-hier` | geography, geometry, hierarchyid tables + spatial indexes | `shapes: all` | — | 2017 | spatial columns and SRIDs; index type | 0/4 — GS-01, GS-02, GS-15 |
| `mssql.types.xml-json` | xml (untyped, typed), XML indexes, `json`/`vector` (2025) | `docSizeKB: 10240` | — | 2017 (json/vector 2025) | column types, XML schema collection, index kinds | 1/6 — GS-01, GS-02, GS-12, GS-15 |
| `mssql.storage` | filegroups, files, partition functions/schemes/tables, compression, columnstore | `partitions: 12`, `columnstoreRows: 1_100_000` | `mssql.schema.core` | 2017 | filegroups, partition counts, rowgroup states | 6/10 — GS-03, GS-15, GS-22 |
| `mssql.temporal` | system-versioned tables with history rows | `historyVersions: 5` | — | 2017 | `temporal.listSystemVersionedTables`, history row counts | 1/2 — GS-05 |
| `mssql.inmemory` | memory-optimized filegroup, tables, hash indexes, table types, native procs | `durability: schemaAndData` | — | 2017 | `temporal.listMemoryOptimizedTables` | 0/4 — GS-04, GS-18 |
| `mssql.graph` | node/edge tables, edge constraints, MATCH-able data | `nodes: 100` | — | 2017 (edge constraints 2019) | graph flags in table metadata (check: metadata exposes `is_node/is_edge`) | 0/1 — GS-07 |
| `mssql.ledger` | updatable and append-only ledger tables | — | — | 2022 | ledger flags | 0/1 — GS-06 |
| `mssql.programmability` | procedures (multi-result, messages, TVP, encrypted), scalar/inline/multi-statement functions, DML/INSTEAD OF/DDL/server/LOGON triggers | `procedures: 20`, `logonTriggerLogin: "lab_logon_blocked"` | `mssql.schema.core` | 2017 | `metadata.listProcedures/listFunctions/listTriggers`, `triggers.listServerTriggers`, definitions readable (except encrypted) | 9/10 — GS-18 |
| `mssql.clr` | SAFE assembly with type, function, aggregate, procedure, trigger | `assembly: bundled`, `clrStrictSecurity: trusted-assembly` | `settings.mssql` `clr enabled` via `serverConfig.setConfiguration` | 2017 | assemblies and CLR objects listed | 0/2 — GS-13 |
| `mssql.agent` | jobs (T-SQL steps, flows, owners, categories), every schedule kind, operators, notifications, history (one success, one failure, one running) | `jobs: 20`, `schedules: all`, `runOnce: true` | `settings.mssql.agent` | 2017 | `agent.listJobsDetailed/listJobSchedules/listJobHistory/listOperators` | 7/7 ready |
| `mssql.agent.scale` | many jobs with long history | `jobs: 1000`, `historyRows: 50_000` | `mssql.agent` | 2017 | counts | ready |
| `mssql.dbmail` | profiles, accounts, links, grants, sent/failed/unsent mail | `smtpHost: "smtp"` | `settings.mssql.smtp` | 2017 | `databaseMail.listProfiles/listAccounts/mailQueue/eventLog` | ready |
| `mssql.linked-servers` | loopback linked server, linked server to a second container, broken linked server, login mappings | `target: "peer"` | second container | 2017 | `linkedServers.list`, `test` results | 0/1 — GS-28 |
| `mssql.security.server` | SQL logins with every option, server roles, credentials, server permissions, server audit + specs | `logins: 10` | — | 2017 | `serverSecurity.listLogins/listServerRoles/listCredentials/listAllServerPermissions`, `audit.listServerAudits` | 6/7 — GS-16 |
| `mssql.security.database` | users of every type, roles, app roles, schemas, permissions, RLS, masking, classification | `users: 10` | `mssql.security.server` | 2017 | `security.listUsers/listRoles/listPermissionsDetailed/listSecurityPolicies/listMaskedColumns` | 7/8 — GS-24 |
| `mssql.security.encryption` | master key, certificates, keys, TDE, Always Encrypted keys + column | `tde: true` | `mssql.security.database` | 2017 | `security.listCertificates/listAsymmetricKeys`, `alwaysEncrypted.listColumnMasterKeys`, encryption state | 1/6 — GS-03, GS-16 |
| `mssql.security.ad` | Windows logins and users from the lab domain | `domain: "LAB.ECHODB.DEV"` | `settings.mssql.kerberos` | 2017 | login types | ready once AD sidecar exists |
| `mssql.lowpriv` | a set of low-privilege logins with their mapped users | `profiles: [connectOnly, readerOnly, noViewDefinition, agentReader]` | `mssql.schema.core`, `mssql.agent` | 2017 | effective permissions (`security.listEffectivePermissions`) per login | ready |
| `mssql.broker` | broker-enabled database, message types, contracts, queues with activation, services, routes, bindings, queued messages | `messages: 10_000` | `mssql.security.encryption` for bindings | 2017 | `serviceBroker.list*` | 1/4 — GS-19, GS-40 |
| `mssql.cdc-ct` | Change Tracking and CDC on tables, with changes | `tables: 3` | `settings.mssql.agent`, `mssql.schema.core` | 2017 | `changeTracking.listCDCTables/listChangeTrackingTables` | ready |
| `mssql.fulltext` | catalogs, full-text indexes (populated), stoplists | `languages: [1033, 1031, 1041]` | `base.*-fts` | 2017 | `fullText.listCatalogs/listIndexes` | 1/2 — GS-21 |
| `mssql.replication` | distributor, publication, articles, subscription on a peer | `type: transactional` | second container, Agent | 2019 (check 2017 CU18) | `replication.listPublications/listSubscriptions/agentStatus` | ready |
| `mssql.alwayson` | endpoints, AG with `CLUSTER_TYPE=NONE`, 3 replicas, databases | `replicas: 3`, `contained: false` | `settings.mssql.hadr`, 3 containers | 2017 | `availabilityGroups.listGroups/listReplicas/listDatabases` | 0/4 — GS-19, GS-20 |
| `mssql.logshipping` | primary/secondary with backup/copy/restore jobs | — | 2 containers, shared volume, Agent | 2017 | `admin.fetchLogShippingConfig` | 0/1 — GS-25 |
| `mssql.polybase` | external data source (SQL Server peer / MinIO S3), file format, external table, database-scoped credential | `source: peer` | `base.*-polybase` | 2019 | `polyBase.list*` | 1/2 — GS-17 |
| `mssql.xevents-trace` | XE sessions (running/stopped, targets), server-side trace | — | — | 2017 | `extendedEvents.listSessions` | ready |
| `mssql.resource-governor` | pools, groups, classifier, reconfigured | — | Developer/Enterprise PID | 2017 | `resourceGovernor.fetchConfiguration` | ready |
| `mssql.policy` | conditions and policies | — | — | 2017 | `policy.listPolicies/listConditions` | 0/1 — GS-23 |
| `mssql.querystore` | Query Store on, captured queries, forced plan, plan guide, hints | `queries: 50` | `mssql.schema.core` | 2017 (hints 2022) | `queryStore.topQueries`, forced plan present | 1/3 — GS-32, GS-39 |
| `mssql.config.server` | `sp_configure` values, default paths, trace flags | `options: {…}` | — | 2017 | `serverConfig.listConfigurations` | 2/3 — GS-27 |
| `mssql.config.database` | databases at every compat level and recovery model, RCSI/SI/ADR, scoped configs, containment | `compatLevels: all` | — | 2017 | `admin.fetchDatabaseProperties` | 5/6 — GS-36 |
| `mssql.config.collations` | databases and columns in CS, BIN2, UTF-8, Japanese, Turkish collations | — | — | 2017 (UTF-8 2019) | collation names | ready |
| `mssql.states` | offline, read-only, single-user (held), restricted, emergency, restoring, standby, auto-closed, snapshot, detached/attached, disabled index | `states: all` | `mssql.backups` | 2017 | `admin.getDatabaseProperties` per database | **built** as `database-states` (recipes `mssql-<v>-database-states`); snapshot, held single-user and disabled index not yet |
| `mssql.states.damaged` | suspect / recovery-pending database | — | harness step | 2017 | state name | harness |
| `mssql.backups` | backup history of every kind, backup devices | — | — | 2017 | `backupRestore.getBackupHistory` | 1/2 — GS-26 |
| `mssql.edge.names` | the same small schema under hostile names at every level | `sets: [unicode, spaces, brackets, quotes, reserved, maxLength, caseOnly]` | — | 2017 | names round-trip exactly | ready (check escaping per API) |
| `mssql.edge.scale` | 1,024-column table, 30,000 sparse columns, 5,000 tables, 200 databases, 10 MB values, 1 M rows | `tables: 5000`, `rows: 1_000_000` | — | 2017 | counts, sizes | 4/6 — GS-08, GS-29 |
| `mssql.edge.nulls` | NULL-heavy tables in every type | `nullRatio: 0.9` | `mssql.types.all` | 2017 | NULL counts | ready |
| `mssql.edge.empty` | empty database, empty tables | — | — | 2017 | counts are zero | ready |
| `mssql.edge.dependencies` | 20-level dependency chain, deferred-name procs, cross-database references | `depth: 20` | `mssql.schema.core` | 2017 | `metadata.objectDependencies` | ready |
| `mssql.extended-properties` | properties at every level | — | `mssql.schema.core` | 2017 | `extendedProperties.list*` | ready |
| `mssql.cms` | CMS groups and registered servers | — | — | 2017 | `cms.listGroups/listServers` | ready |
| `mssql.extensibility` | external languages/libraries, ML Services | — | image layer | 2019 | — | 0/2 — GS-31 |
| `mssql.workload` (live) | sessions, blocking chain, long query, open transaction, deadlock, missing-index queries, failed logins, global temp table | `sessions: 20`, `blockingDepth: 3` | any schema pack | 2017 | `activity.snapshot` shows blocking; `tuning.listMissingIndexRecommendations` non-empty | ready |
| `mssql.sample.*` | restore/attach of AdventureWorks (OLTP/LT/DW), WWI, Stack Overflow; typed ports of Northwind, pubs, Chinook | `edition: 2022` | — | per backup | object counts per sample | restores ready; ports GS-38 |
| `mssql.win.*` | Windows-only items (FILESTREAM, CmdExec/PowerShell steps, alerts, SSIS catalog, mirroring, merge replication, non-SQL linked servers, enclaves) | — | `base.mssql-win` | 2008 R2 | as per item | mixed — GS-01, GS-03, GS-34, GS-35 |

### Example recipes (SQL Server)

| Recipe | Base | Settings | Packs (parameters) | Used for |
|---|---|---|---|---|
| `mssql-2017-agent-jobs` | 2017 | agent | `mssql.agent`(jobs: 20), `mssql.lowpriv` | Agent tree, Job Queue, permissions on msdb |
| `mssql-2022-everything-ready` | 2022 | agent, smtp | every pack whose readiness is "ready" | nightly broad regression |
| `mssql-2019-types` | 2019 | — | `mssql.types.all`, `mssql.edge.nulls`, `mssql.config.collations` | result grid decoding, cell formatting |
| `mssql-2025-types-new` | 2025 | — | `mssql.types.all`, `mssql.types.xml-json` | json/vector once GS-01/02 land |
| `mssql-2022-security` | 2022 | — | `mssql.security.server`, `mssql.security.database`, `mssql.security.encryption`, `mssql.lowpriv` | Security folders, editors |
| `mssql-2022-states` | 2022 | — | `mssql.states`, `mssql.schema.core` | Explorer behaviour for non-online databases |
| `mssql-2022-cs-collation` | 2022 | collation=`Latin1_General_CS_AS` | `mssql.schema.core`(nameStyle: edge), `mssql.edge.names` | case-sensitive identifier handling |
| `mssql-2019-broker-cdc` | 2019 | agent | `mssql.broker`, `mssql.cdc-ct` | Service Broker tree, CDC |
| `mssql-2022-scale` | 2022 | memory=4096 | `mssql.edge.scale`(tables: 5000), `mssql.agent.scale` | Explorer and grid performance |
| `mssql-2022-adventureworks` | 2022 | agent | `mssql.sample.adventureworks`, `mssql.sample.adventureworks-dw`, `mssql.sample.wwi` | realistic demos, autocomplete |
| `mssql-2022-tls-strict` | 2025 | tls(forcestrict) | `mssql.schema.core` | TDS 8.0 connection paths |
| `mssql-2022-replication-pair` | 2022 ×2 | agent | `mssql.replication`, `mssql.linked-servers` | multi-server features |

---

## PostgreSQL

### Bases and settings

| Name | What | Notes |
|---|---|---|
| `base.pg-13` … `base.pg-18` | `postgres:<v>` (Debian) | contrib included |
| `base.pg-<v>-postgis` | + `postgresql-<v>-postgis-3` (or `postgis/postgis:<v>-3.x`) | |
| `base.pg-<v>-vector` | + `postgresql-<v>-pgvector` | |
| `base.pg-<v>-cron` | + `postgresql-<v>-cron` | needs `settings.pg.preload` |
| `base.pg-<v>-pgagent` | + `pgagent` and a supervisor for the daemon | |
| `base.pg-<v>-pl` | + `postgresql-plpython3-<v>`, `postgresql-plperl-<v>`, `postgresql-pltcl-<v>` | |
| `base.pg-<v>-full` | all of the above | for "everything" recipes |
| `settings.pg.preload` | `shared_preload_libraries` (default `pg_stat_statements`) | |
| `settings.pg.logical` | `wal_level=logical`, `max_replication_slots`, `max_wal_senders` | |
| `settings.pg.prepared` | `max_prepared_transactions=10` | |
| `settings.pg.auth` | `pg_hba.conf` preset (`scram`, `md5`, `trust`, `cert`, `mixed`) | |
| `settings.pg.tls` | `ssl=on`, certificates, `ssl_min_protocol_version` | |
| `settings.pg.locale` | `POSTGRES_INITDB_ARGS` (`--locale-provider=icu --icu-locale=…`, `--encoding`) | cluster-wide defaults |
| `settings.pg.network` | port, `listen_addresses` | |
| `settings.pg.kerberos` | KDC sidecar, keytab | |

### Packs

| Pack | Creates | Parameters (defaults) | Depends on | Min version | Check verifies | Readiness |
|---|---|---|---|---|---|---|
| `pg.schema.core` | database, schemas, tables in several schemas, every constraint kind, identity/generated columns, every index method, views, MVs, sequences, statistics, comments | `schemas: ["public","sales","hr"]`, `tables: 20` | — | 13 | `metadata` table/column/index/constraint introspection matches manifest | 7/22 — GP-01, GP-02, GP-03, GP-05, GP-06, GP-17 |
| `pg.schema.temporal` | `WITHOUT OVERLAPS` keys, `PERIOD` foreign keys | — | `pg.types.ranges` | 18 | constraint definitions | 0/1 — GP-18 |
| `pg.types.core` | one table per type family + every-type table with edge rows | `rowsPerEdge: 1` | — | 13 | column types and value round-trip | 12/20 — GP-07, GP-19 |
| `pg.types.json` | json/jsonb/jsonpath columns, GIN indexes | `docSizeKB: 10240` | — | 13 | types, index opclasses | 2/3 — GP-19 |
| `pg.types.arrays` | 1-D, multi-dim, bounded, NULL-element arrays of many element types | `maxElements: 100_000` | `pg.types.user` | 13 | `array_ndims`, bounds | 0/1 — GP-19 |
| `pg.types.ranges` | built-in ranges and multiranges, custom range, exclusion constraints | — | — | 13 (multirange 14) | range types, constraint | 2/4 — GP-19 |
| `pg.types.user` | enums, domains, composites, typed tables | `enumLabels: 20` | — | 13 | `metadata` type introspection | 3/4 — GP-03 |
| `pg.partitioning` | range/list/hash/default partitions, sub-partitions, inheritance trees | `partitions: 12` | — | 13 | partition tree | ready |
| `pg.programmability` | SQL/plpgsql functions, procedures, triggers (all kinds), event triggers, rules, aggregates, operators, casts | `functions: 20` | `pg.schema.core` | 13 | routines, triggers, event triggers listed | 6/11 — GP-01, GP-04, GP-09, GP-22, GP-24 |
| `pg.pl-languages` | plpython3u/plperl/pltcl functions | — | `base.pg-<v>-pl` | 13 | languages installed | 1/2 — GP-14 |
| `pg.ext.contrib` | every contrib extension that `CREATE EXTENSION` accepts, in its own schema where sensible, with sample data | `extensions: all` | `settings.pg.preload` for pg_stat_statements | 13 | `metadata` extension list + versions | ready |
| `pg.ext.postgis` | PostGIS extensions, geometry/geography/raster tables, spatial indexes | `srids: [4326, 3857]` | `base.pg-<v>-postgis` | 13 | geometry columns | ready |
| `pg.ext.pgvector` | vector/halfvec/sparsevec columns, hnsw/ivfflat indexes | `dims: 1536` | `base.pg-<v>-vector` | 13 | column types; index methods | 2/3 — GP-05 |
| `pg.ext.thirdparty` | TimescaleDB hypertables, pg_partman sets, etc. (opt-in list) | `extensions: []` | image layer | per extension | extension present | ready per extension |
| `pg.fts` | text search configurations, dictionaries, tsvector columns, GIN indexes | — | — | 13 | configurations listed | 1/2 — GP-19 |
| `pg.fdw` | postgres_fdw to a peer (or loopback), file_fdw, user mappings, foreign tables, imported schema | `peer: "peer"` | second container optional | 13 | foreign servers/tables | 2/3 — GP-21 |
| `pg.replication` | publications of every shape, slots, subscription on a peer | — | `settings.pg.logical`, second container | 13 (row filters 15) | `pg_publication*`, `pg_subscription` via replication introspection | 1/4 — GP-10 |
| `pg.replica` | hot-standby replica (harness `pg_basebackup`) | — | second container | 13 | `pg_stat_replication` row | harness |
| `pg.cron` | pg_cron jobs, run history | `jobs: 10` | `base.pg-<v>-cron`, `settings.pg.preload` | 13 | `cron.job` rows | 0/1 — GP-11 |
| `pg.pgagent` | pgAgent jobs, steps, schedules | `jobs: 10` | `base.pg-<v>-pgagent` | 13 | `pgagent.pga_job` rows | 0/1 — GP-12 |
| `pg.security` | login/group roles with every attribute, memberships, grants at every level, default privileges, RLS policies, ownership spread | `roles: 10` | `pg.schema.core` | 13 | role attributes, ACLs, policies | 7/11 — GP-01, GP-20, GP-25 |
| `pg.security.labels` | security labels | — | label-provider image | 13 | labels | 0/1 — GP-08 |
| `pg.lowpriv` | connect-only, read-only, no-USAGE, `pg_read_all_data` logins | — | `pg.schema.core` | 13 | effective privileges per login | ready |
| `pg.tablespaces` | extra tablespaces with objects | `count: 2` | harness mkdir | 13 | tablespace list | ready |
| `pg.config.collations` | libc/ICU/builtin/non-deterministic collations and columns using them | — | — | 13 (builtin 17) | collations | 2/3 — GP-02 |
| `pg.config.encodings` | databases in UTF8, LATIN1, SQL_ASCII, EUC_JP | — | — | 13 | `pg_database.encoding` | ready |
| `pg.config.session` | per-database/per-role `DateStyle`, `IntervalStyle`, `TimeZone`, `bytea_output` | — | — | 13 | `pg_db_role_setting` | ready |
| `pg.config.server` | `ALTER SYSTEM` values, pending-restart parameter | — | — | 13 | `pg_settings` | 0/1 — GP-16 |
| `pg.states` | no-connection, limit-0, template, read-only-default databases; invalid index; unpopulated MV; sequence at max | — | `pg.schema.core` | 13 | per state | 4/5 — GP-05 |
| `pg.states.damaged` | invalid database | — | harness | 15.4 | `datconnlimit = -2` | harness |
| `pg.edge.names` | hostile names at every level, dropped-column tables | `sets: all` | — | 13 | names round-trip | ready |
| `pg.edge.scale` | 1,600-column table, 10,000 tables, 1,000 partitions, 10 MB values, 1 M rows | `tables: 10000`, `rows: 1_000_000` | — | 13 | counts | 2/3 — GP-13 |
| `pg.edge.nulls` | NULL-heavy data in every type | `nullRatio: 0.9` | `pg.types.core` | 13 | NULL counts | ready |
| `pg.edge.empty` | nothing (fresh cluster) | — | — | 13 | only default databases | ready |
| `pg.workload` (live) | sessions, idle-in-transaction, blocking, advisory locks, LISTEN/NOTIFY, prepared transactions, vacuum/index progress, pg_stat_statements traffic | `sessions: 20` | `settings.pg.prepared`, `settings.pg.preload` | 13 | `activity.snapshot` shows each | 7/8 — GP-15 |
| `pg.sample.*` | pagila, dvdrental, Chinook, airlines, Northwind, AdventureWorks, Neon set, Stack Overflow | `variant` per sample | — | per sample | object/row counts | GP-23 (owner decision) |

### Example recipes (PostgreSQL)

| Recipe | Base | Settings | Packs | Used for |
|---|---|---|---|---|
| `pg-18-json-everything` | 18 | — | `pg.types.json`, `pg.types.arrays`, `pg.edge.scale`(tables: 50) | JSON viewer, large documents |
| `pg-13-oldest-supported` | 13 | — | `pg.schema.core`, `pg.types.core`, `pg.programmability` | catalog differences on the oldest version |
| `pg-17-types-all` | 17 | locale ICU | `pg.types.core`, `pg.types.ranges`, `pg.types.user`, `pg.edge.nulls` | cell decoding |
| `pg-18-gis-vector` | 18-full | preload | `pg.ext.postgis`, `pg.ext.pgvector`, `pg.ext.contrib` | extension types in grid, Extensions folder |
| `pg-16-security` | 16 | auth=scram | `pg.security`, `pg.lowpriv` | Login/Group Roles, privileges |
| `pg-17-replication-pair` | 17 ×2 | logical | `pg.replication`, `pg.fdw` | Replication page, FDW |
| `pg-15-partitioning` | 15 | — | `pg.partitioning`, `pg.edge.scale`(partitions: 1000) | partition trees |
| `pg-18-activity` | 18 | preload, prepared | `pg.schema.core`, `pg.workload` | every Activity page |
| `pg-16-cron-agent` | 16-full | preload(pg_cron) | `pg.cron`, `pg.pgagent` | scheduler support (future Echo work) |
| `pg-18-samples` | 18 | — | `pg.sample.pagila`, `pg.sample.chinook`, `pg.sample.airlines`(variant: 3m) | demos |
| `pg-14-latin1-edge` | 14 | encoding LATIN1 | `pg.config.encodings`, `pg.edge.names` | encoding conversions |
| `pg-18-standby` | 18 ×2 | — | `pg.schema.core`, `pg.replica` | read-only server behaviour |

---

## MySQL and MariaDB

### Bases and settings

| Name | What |
|---|---|
| `base.mysql-5.7`, `-8.0`, `-8.4`, `-9` | `mysql:<v>` |
| `base.mariadb-10.6`, `-10.11`, `-11.4`, `-11.8`, `-12` | `mariadb:<v>` |
| `settings.my.lctn` | `--lower-case-table-names=0\|1` at initialisation |
| `settings.my.sqlmode` | `sql_mode` preset (`strict`, `legacy-zero-dates`, `ansi`) |
| `settings.my.charset` | `character-set-server`, `collation-server` |
| `settings.my.binlog` | `log_bin`, `binlog_format`, `gtid_mode` |
| `settings.my.limits` | `max_allowed_packet=64M`, `innodb_page_size` |
| `settings.my.tls` | certificates, `require_secure_transport` |
| `settings.my.auth` | 8.4: `mysql_native_password=ON` to allow legacy accounts |
| `settings.my.tz` | time zone tables loaded at image build (owner decision: the loader emits SQL) |

### Packs

| Pack | Creates | Parameters (defaults) | Depends on | Min version | Check verifies | Readiness |
|---|---|---|---|---|---|---|
| `my.schema.core` | databases with charsets, tables, keys, FKs, checks, generated/invisible columns, indexes, views, histograms | `tables: 20` | — | 5.7 | `metadata` table/column/index lists | 0/12 — GM-01, GM-02, GM-04, GM-05, GM-18, GM-23 |
| `my.schema.engines` | one table per engine | `engines: [InnoDB, MyISAM, MEMORY, ARCHIVE, CSV, BLACKHOLE]` | `my.schema.core` | 5.7 | engine per table | 0/1 — GM-02 |
| `my.types.all` | every numeric/date/string/binary/enum/set type with edge rows | — | `my.schema.core` | 5.7 | column types, round-trip | 0/9 — GM-02, GM-08 |
| `my.types.json` | JSON columns, functional and multi-valued indexes | — | — | 5.7 (indexes 8.0.17) | types, indexes | 0/2 — GM-02, GM-04 |
| `my.types.spatial` | spatial columns with SRIDs, spatial indexes, custom SRS | — | — | 5.7 (SRID 8.0) | SRIDs | 0/3 — GM-02, GM-04, GM-08, GM-13 |
| `my.types.vector` | VECTOR columns | — | — | MySQL 9.0 / MariaDB 11.7 | types | 0/1 — GM-02, GM-08 |
| `my.partitioning` | every partitioning kind | `partitions: 12` | `my.schema.core` | 5.7 | `information_schema.partitions` via metadata | 0/1 — GM-03 |
| `my.fulltext` | FULLTEXT indexes incl. ngram | — | `my.schema.core` | 5.7 | index types | 0/1 — GM-04 |
| `my.storage` | general tablespaces | — | — | 8.0 | tablespaces | 0/1 — GM-09 |
| `my.programmability` | procedures, functions, triggers (ordered) | `routines: 20` | `my.schema.core` | 5.7 | `metadata` routines/triggers | 0/3 — GM-10, GM-19 |
| `my.events` | event scheduler on, one-time/recurring/disabled events | `events: 10` | — | 5.7 | `metadata` events | 1/2 — GM-11 |
| `my.security` | users on several hosts, roles, grants at every level, locked/expired accounts, proxies | `users: 10` | — | 5.7 (roles 8.0) | `security.listUsers/showGrants/listRoles` | 2/5 — GM-10, GM-14 |
| `my.security.auth` | one account per auth plugin | `plugins: [caching_sha2_password, mysql_native_password, sha256_password]` | `settings.my.auth` on 8.4 | 5.7 | plugin per account | ready |
| `my.security.encryption` | encrypted tables with keyring component | — | keyring setting | 8.0 | `security.encryptedTables` | 0/1 — GM-02 |
| `my.lowpriv` | USAGE-only, single-table, no-PROCESS accounts | — | `my.schema.core` | 5.7 | grants | ready (tables need GM-02) |
| `my.plugins` | components and plugins, loadable functions | — | image layer for UDFs | 8.0 | installed components | 0/2 — GM-15 |
| `my.replication` | source/replica pair, clone | — | `settings.my.binlog`, 2 containers | 5.7 | `replication.replicaStatus` | 0/2 — GM-15, GM-16 |
| `my.replication.group` | Group Replication / Galera | — | 3 containers | 8.0 / MariaDB | members | 0/1 — GM-16 |
| `my.logs` | general/slow log to tables with entries | — | — | 5.7 | `errorLog.readTableLog` | ready |
| `my.config.charsets` | databases/columns in many charsets | — | — | 5.7 | charsets | 1/2 — GM-02 |
| `my.config.sqlmode` | global `sql_mode` variants | `mode: strict` | — | 5.7 | variable value | ready |
| `my.config.server` | persisted variables, resource groups | — | — | 8.0 | variables | 0/2 — GM-21, GM-22 |
| `my.states` | super_read_only, broken views/definers, crashed-table repair | — | — | 5.7 | per state | 2/3 — GM-18 |
| `my.edge.names` / `.scale` / `.nulls` | as for the other engines | — | — | 5.7 | names, counts | 0 — GM-01, GM-02, GM-12 |
| `my.workload` (live) | sessions, lock waits, metadata locks, deadlock, performance_schema traffic | `sessions: 20` | any schema pack | 5.7 | `activity` snapshot | 2/3 — GM-02 |
| `mariadb.types` | UUID, INET4, INET6, JSON alias | — | — | MariaDB 10.10 | types | 0/2 — GM-02, GM-20 |
| `mariadb.sequences` | sequences, sequence defaults | — | — | MariaDB 10.3 | sequences | 0/1 — GM-07 |
| `mariadb.system-versioning` | system-versioned, application-time, bitemporal tables with history | — | — | MariaDB 10.4 | table options | 0/2 — GM-06 |
| `mariadb.engines` | Aria, MyRocks, Spider, CONNECT | — | plugins | MariaDB 10.6 | engines | 0/1 — GM-02, GM-15 |
| `mariadb.oracle-mode` | packages under `sql_mode=ORACLE` | — | — | MariaDB 10.3 | packages | 0/1 — GM-20 |
| `my.sample.*` | sakila, employees, world, airportdb, menagerie, Chinook | — | — | per sample | counts | GM-17 (owner decision) |

### Example recipes (MySQL / MariaDB)

| Recipe | Base | Settings | Packs | Used for |
|---|---|---|---|---|
| `mysql-8.4-security` | 8.4 | auth | `my.security`, `my.security.auth`, `my.lowpriv` | account handling, auth plugins (ready today) |
| `mysql-8.0-events` | 8.0 | — | `my.events`, `my.programmability` | events (Echo M10), routines |
| `mysql-8.4-types` | 8.4 | limits | `my.types.all`, `my.types.json`, `my.types.spatial` | grid decoding |
| `mysql-5.7-legacy` | 5.7 | sqlmode=legacy-zero-dates | `my.schema.core`, `my.types.all` | zero dates, old catalogs |
| `mysql-9-vector` | 9 | — | `my.types.vector`, `my.types.json` | newest types |
| `mysql-8.4-lctn1` | 8.4 | lctn=1 | `my.schema.core`(nameStyle: edge) | identifier case handling |
| `mysql-8.4-replica-pair` | 8.4 ×2 | binlog | `my.replication`, `my.workload` | replication status |
| `mysql-8.0-sakila` | 8.0 | — | `my.sample.sakila`, `my.sample.world` | demos |
| `mariadb-11.8-temporal` | MariaDB 11.8 | — | `mariadb.system-versioning`, `mariadb.sequences`, `mariadb.types` | MariaDB-only features |
| `mariadb-10.6-oldest-lts` | MariaDB 10.6 | — | `my.schema.core`, `my.programmability` | MariaDB catalog differences |
| `mysql-8.4-activity` | 8.4 | — | `my.workload`, `my.logs` | Activity Monitor |

---

## SQLite

SQLite recipes produce files, not containers: the lab writes the file on the lab host (or in a scratch
container with a shared volume) and hands Echo its path. All `lite.*` packs wait for GL-00 (a typed SQLite
layer); the sample files are ready as published.

| Pack | Creates | Parameters (defaults) | Depends on | Min version | Check verifies | Readiness |
|---|---|---|---|---|---|---|
| `lite.schema.core` | rowid, WITHOUT ROWID, STRICT, AUTOINCREMENT tables; constraints; FKs; indexes (partial, expression); views; triggers; generated columns; `sqlite_stat1` | `tables: 20` | — | 3.37 (STRICT) | `sqlite_schema` contents | 0/12 — GL-01, GL-02, GL-03, GL-06, GL-08, GL-09 |
| `lite.types` | affinity zoo and edge values | — | — | any | `typeof()` per cell | 0/7 — GL-01, GL-07 |
| `lite.json` | JSON text and JSONB blobs | — | — | 3.45 | `json_valid` | 0/2 — GL-07 |
| `lite.fts5` | FTS5 tables with each tokenizer and content mode | — | — | 3.34 (trigram) | shadow tables exist | 0/1 — GL-04 |
| `lite.fts-legacy` | FTS3/4 tables (built with another SQLite) | — | GL-08 | — | Echo's error path | 0/1 — GL-04, GL-08 |
| `lite.rtree` | R*Tree (+ Geopoly with another build) | — | — | 3.24 | shadow tables | 0/2 — GL-04, GL-08 |
| `lite.attached` | main + two attached files + temp | — | — | any | `PRAGMA database_list` | 0/1 — GL-05 |
| `lite.config` | WAL/journal modes, page sizes, auto-vacuum, UTF-16, user_version | — | — | any | pragmas | 0/3 — GL-06 |
| `lite.states` / `.damaged` | read-only, hot journal, corrupt, zero-byte, not-a-database | — | harness | any | open result | harness |
| `lite.foreign-files` | Core Data, Android, Firefox, SpatiaLite, SQLCipher, old-format files | — | collected fixtures | any | Echo opens or errors cleanly | fixtures (GL-00/GL-08 for generated ones) |
| `lite.edge.names` / `.scale` / `.nulls` / `.empty` | as for the other engines | — | — | any | names, counts | 0 — GL-00, GL-01, GL-07 |
| `lite.workload` (live) | a second process holding a write lock; temp objects | — | — | any | `SQLITE_BUSY` observed | 0/2 — GL-03, GL-07 |
| `lite.sample.*` | Chinook, Northwind, Sakila files | — | — | any | table counts | ready |

### Example recipes (SQLite)

| Recipe | Packs | Used for |
|---|---|---|
| `sqlite-chinook` | `lite.sample.chinook` | smoke test (ready today) |
| `sqlite-samples` | `lite.sample.chinook`, `lite.sample.northwind`, `lite.sample.sakila` | demos (ready today) |
| `sqlite-strict-everything` | `lite.schema.core`, `lite.types` | table structure, affinity display |
| `sqlite-fts-rtree` | `lite.fts5`, `lite.rtree` | virtual tables and shadow tables |
| `sqlite-wal-attached` | `lite.config`(journal: wal), `lite.attached` | multiple databases, WAL files |
| `sqlite-utf16` | `lite.config`(encoding: utf16le), `lite.edge.names` | encoding handling |
| `sqlite-damaged` | `lite.states`, `lite.states.damaged` | error paths |
| `sqlite-foreign` | `lite.foreign-files` | files from other apps |
| `sqlite-scale` | `lite.edge.scale`(tables: 10000, rows: 1_000_000) | performance |
| `sqlite-json` | `lite.json`, `lite.edge.nulls` | JSON/JSONB display |
