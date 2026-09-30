# Coverage catalogue

What `echo-server-lab` must be able to put on a server so that every part of Echo can be tested against
real content: every data type, object kind, server-level feature, configuration, state, edge case and
well-known sample database, for SQL Server, PostgreSQL, MySQL/MariaDB and SQLite. For each item it records
whether our driver can create it with a typed API today, and where it can run.

Written 2026-09-30 against: Echo `7f768259` (Explorer blueprints and `ExplorerNodeKind`), `sqlserver-nio`
`49e4820`, `postgres-wire` `62b899c`, `mysql-wire` `5c060b5`, `sqlite-nio` 1.12.10 (SQLite 3.53.4), and the
local Microsoft `sql-docs` clone.

## Files

| File | Contents |
|---|---|
| [sqlserver.md](sqlserver.md) | SQL Server items |
| [postgresql.md](postgresql.md) | PostgreSQL items |
| [mysql-mariadb.md](mysql-mariadb.md) | MySQL and MariaDB items (and the correction that Echo uses `mysql-wire`, not bare `mysql-nio`) |
| [sqlite.md](sqlite.md) | SQLite items |
| [packs.md](packs.md) | proposed packs per engine (what, parameters, dependencies, minimum version, check, readiness) and example recipes |
| [driver-gaps.md](driver-gaps.md) | every typed API the packs need that a driver lacks, with proposed Swift signatures, ranked by items unblocked; Explorer node-kind coverage |
| [sample-databases.md](sample-databases.md) | sample databases: source, licence, size, how they load, and the loading policy question |

## How an engine file is organised

Sections in the same order for every engine: **Data types**, **Schema objects**, **Programmability**,
**Server-level**, **Security**, **Configuration and versions**, **States and edge cases**, **Sample
databases** (SQLite folds some sections together because it has no server). Every item is one table row
with a stable ID (`SS-DT-23`, `PG-SO-03`, `MY-SE-02`, `SL-CF-01`); IDs are never reused, so packs, checks
and gap entries can refer to them.

## Columns

| Column | Meaning |
|---|---|
| **ID** | `SS` SQL Server, `PG` PostgreSQL, `MY` MySQL/MariaDB, `SL` SQLite; then `DT` data types, `SO` schema objects, `PR` programmability, `SV` server-level, `SE` security, `CF` configuration and versions, `ST` states and edge cases, `SA` sample databases |
| **Item** | the thing to create, with its variants |
| **Versions** | engine versions where it exists ("all" = every version the lab targets: SQL Server 2017+, PostgreSQL 13+, MySQL 5.7+/MariaDB 10.6+, any SQLite 3) |
| **Echo node kind** | the `ExplorerNodeKind` case (from `Echo/Sources/Features/ObjectBrowser/Blueprint/ExplorerNodeKind.swift`) under which Echo shows it, or "none — Echo does not show it yet". "tables (column)" means it appears inside a table |
| **Typed API or GAP** | a status word, then the driver file and symbol (`file:symbol`, relative to the driver's `Sources/<Kit>/` folder) or the gap ID from driver-gaps.md |
| **Feasibility** | where it can run (below) |
| **Pack** | the pack in packs.md that creates it (`settings.*` = a start-time setting, `base.*` = an image) |
| **Notes** | edge values worth seeding, caveats, and "check" where something could not be confirmed |

### Status words (Typed API column)

| Word | Meaning |
|---|---|
| **API** | an existing typed API creates it |
| **PARTIAL** | a typed API exists but lacks an option the item needs; the gap ID says what |
| **GAP** | no typed API; the gap ID points to the proposed one |
| **SETTING** | made by container start configuration (environment, config file, certificates), no driver call |
| **READY** | nothing to create (a published file, or the server's default state) |
| **HARNESS** | the lab must do it outside any driver (damage a file, kill a process, `pg_basebackup`); no driver API should exist |
| **N/A** | not creatable or out of scope (not persistable, different protocol, Enterprise-only) |

### Feasibility words

| Word | Meaning |
|---|---|
| **Linux container** | official amd64 image on the Docker host; "(2)" or "(3)" = that many containers; "+ sidecar" = an extra helper container (SMTP, AD, MinIO) |
| **needs custom image layer** | official image plus packages (`mssql-server-fts`, `mssql-server-polybase`, PostGIS, pgvector, pg_cron, pgAgent, PL languages, MariaDB plugins) |
| **Windows VM** | not supported by SQL Server on Linux; needs the planned Windows Server VM (`sqlserver-nio/testlab/README.md`) |
| **cloud** | needs a managed service (Azure SQL, Entra ID, RDS, MySQL HeatWave) |
| **file** | SQLite: a database file, no server |

## Summary per engine

"Creatable now" = API + SETTING + READY. "Needs a driver API" = GAP + PARTIAL. "Not possible in Linux
containers" = feasibility Windows VM or cloud (this column overlaps the others: an item can have an API and
still need the VM). Custom image layers are possible in containers and are counted separately.

| Engine | Items | Creatable now | …of which in a Linux container / file | Needs a driver API | Harness or N/A | Not possible in Linux containers | Needs custom image layer |
|---|---:|---:|---:|---:|---:|---:|---:|
| SQL Server | 234 | 161 | 149 | 69 | 4 | 16 (14 Windows VM, 2 cloud) | 6 |
| PostgreSQL | 157 | 91 | 83 | 61 | 5 | 2 (cloud) | 12 |
| MySQL / MariaDB | 93 | 23 | 22 | 67 | 3 | 2 (cloud) | 2 |
| SQLite | 45 | 3 | 3 | 37 | 5 | 0 | 0 (all "file") |
| **Total** | **529** | **278** | **257** | **234** | **17** | **20** | **20** |

By status: SQL Server API 146, SETTING 15, PARTIAL 16, GAP 53, HARNESS 1, N/A 3. PostgreSQL API 76,
SETTING 14, READY 1, PARTIAL 29, GAP 32, HARNESS 3, N/A 2. MySQL/MariaDB API 9, SETTING 14, PARTIAL 12,
GAP 55, HARNESS 2, N/A 1. SQLite READY 3, GAP 37, HARNESS 4, N/A 1.

What the numbers say:

- **SQL Server** is in good shape: `sqlserver-nio` already covers Agent, Database Mail, security, Service
  Broker, CDC/CT, audits, XE, Resource Governor, replication, temporal and backups. The biggest holes are
  data types and typed values (GS-01, GS-02), the key hierarchy (GS-16), memory-optimized/graph/ledger tables
  (a richer `SQLServerTableDefinition`, GS-03..GS-08) and AG creation (GS-19, GS-20).
- **PostgreSQL** is held back mostly by two cross-cutting gaps: create APIs cannot target a schema (GP-01)
  and bind values exist only for core Swift types (GP-19). Fixing those two unblocks most of `pg.schema.core`
  and `pg.types.*`.
- **MySQL** cannot seed anything table-shaped: `mysql-wire` has no `createDatabase`, `createTable`,
  `createIndex` or constraint APIs (GM-01, GM-02, GM-04, GM-05). Users, roles, grants, views, routines,
  triggers and events can be created today.
- **SQLite** has no first-party driver; everything waits for a decision on a typed layer (GL-00). Published
  sample files work today.

## Open decisions for the owner

1. **Sample databases distributed as SQL** (Northwind, pubs, Chinook, pagila, dvdrental, airlines, sakila,
   employees, world): typed ports, a driver dump loader, or an explicit exemption. See
   [sample-databases.md](sample-databases.md#loading-policy).
2. **SQLite typed layer** (GL-00): a first-party package over `sqlite-nio`, or exempting file fixtures.
3. **Live packs** (`*.workload`) hold sessions and locks while a suite runs; the lab needs a place for them to
   run (in the test process, or a helper container that the lab starts and stops).
4. **Harness actions** (damaged databases, killed backends, `pg_basebackup`, time zone tables) are outside
   the driver rule by nature; confirm they are acceptable as lab-level steps.

## Explorer coverage

All 85 `ExplorerNodeKind` cases map to at least one item except six pure grouping folders
(`serverSecurity`, `databaseSecurity`, `serverObjects`, `management`, `activity`, `externalResources`),
which appear whenever their children do. Node kinds that no pack can populate yet are listed at the end of
[driver-gaps.md](driver-gaps.md#explorer-node-kinds-and-coverage).
