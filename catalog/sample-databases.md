# Sample databases

Well-known sample databases give Echo realistic schemas and data that nobody on the team designed. Nothing
here has been downloaded; sizes come from the publishers' release metadata (GitHub API for the GitHub
releases, the publishers' pages otherwise) as of 2026-09-30. "check" marks what could not be confirmed.

## Loading policy

The pack rule says content is created only through the drivers' typed APIs. Samples fall into three groups:

1. **Native backups restored by a typed API.** SQL Server `.bak` files are restored with
   `sqlserver-nio` `Client/SQLServerBackupRestoreClient.swift:listBackupFiles(diskPath:)` (RESTORE
   FILELISTONLY, to learn the logical names) and `restore(options: SQLServerRestoreOptions)` with
   `relocateFiles` pointing at `/var/opt/mssql/data`. Detached data files are attached with
   `Client/SQLServerAdministrationClient+Database.swift:attachDatabase(name:files:)`. Getting the file into the
   container (download cache on the lab host, then a volume mount or `docker cp`) is the lab's job, not the
   driver's; `sqlserver-nio/Sources/SQLServerKitTesting/SQLServerDockerManager.swift:loadAdventureWorks` shows
   the same flow done with raw SQL, which the pack replaces with the typed calls. **These comply with the rule.**
   Restores need a server version ≥ the backup's version, and the lab should set the compatibility level
   afterwards only if a recipe asks (`alterDatabaseOption(.compatibilityLevel)`).
2. **SQL scripts or dumps** (Northwind, pubs, Chinook, pagila, dvdrental, airlines, sakila, employees, world).
   Loading them means executing someone else's SQL, which is exactly what the rule forbids. Options for the
   owner:
   - **(A) Typed ports (recommended for small samples).** Re-express the schema as a pack in Swift and load
     the data from a bundled data file (CSV/JSON) through typed inserts or bulk APIs. Chinook even publishes
     `ChinookData.json`. Northwind, pubs, Chinook, menagerie, world, sakila and dvdrental are small enough.
   - **(B) A driver "dump loader" API** (GP-23, GM-17, GS-38): the driver parses the dump format and executes
     it. It keeps the rule's letter, not its purpose (the driver would still run foreign SQL).
   - **(C) Exempt samples** and restore them at image build with the engine's own tools (`psql`,
     `pg_restore`, `mysql`, MySQL Shell `util.loadDump`), recorded as "not driver-created" in the coverage
     report. Probably the only practical choice for multi-GB samples (airlines 2y, employees, Stack Overflow).
3. **Ready-made SQLite files.** The file is the fixture; nothing is executed.

## SQL Server

| Sample | Engine versions | Source | Licence | Download size | How it loads | Catalogue items covered |
|---|---|---|---|---|---|---|
| AdventureWorks2012/2014/2016/2017/2019/2022/2025 (OLTP) | backup version or newer; Linux images 2017+ | https://github.com/Microsoft/sql-server-samples/releases/tag/adventureworks | MIT (`sql-server-samples/license.txt`) | 44.9 / 44.6 / 46.5 / 48.0 / 199.1 / 200.1 / 47.9 MB | `.bak` → typed restore | SS-SA-01; schemas, FKs, views, procs, functions, triggers, XML (typed XML schema collections), hierarchyid, geography, alias types, extended properties, full-text (needs FTS layer) |
| AdventureWorks2016_EXT (OLTP) | 2016+ | same | MIT | 125.0 MB | typed restore | adds in-memory, temporal, columnstore, JSON, RLS, masking, Always Encrypted demos (check exact list) |
| AdventureWorksLT2012–2025 | backup version or newer | same | MIT | 13.4 / 13.3 / 7.1 / 7.1 / 8.1 / 8.1 / 1.7 MB | typed restore | SS-SA-02; small schema for quick recipes |
| AdventureWorksDW2012–2025 | backup version or newer | same | MIT | 21.8 / 21.4 / 21.4 / 22.4 / 97.1 / 97.1 / 24.1 MB | typed restore | SS-SA-03; star schema, larger fact tables |
| AdventureWorksDW2016_EXT | 2016+ | same | MIT | 883.3 MB | typed restore | clustered columnstore at volume |
| AdventureWorks OLTP/DW install scripts | any | same (`AdventureWorks-oltp-install-script.zip` 16.7 MB, DW 16.0 MB) | MIT | 16.7 / 16.0 MB | scripts + CSV: not used (backups exist) | — |
| WideWorldImporters Full / Standard | 2016+ (Full uses memory-optimized tables: Developer/Enterprise) | https://github.com/Microsoft/sql-server-samples/releases/tag/wide-world-importers-v1.0 | MIT | 121.2 / 121.1 MB `.bak` (`.bacpac` 58.5 / 58.2 MB) | typed restore of `.bak` | SS-SA-04; temporal, in-memory, RLS, JSON, columnstore, partitioning, sequences, synonyms (check), Service Broker (check) |
| WideWorldImportersDW Full / Standard | 2016+ | same | MIT | 47.7 / 51.4 MB | typed restore | SS-SA-04; columnstore, partitioning |
| Northwind, pubs | any | https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/northwind-pubs (`instnwnd.sql`, `instpubs.sql`) | MIT | < 1 MB each (check) | SQL scripts: policy option A (typed port) | SS-SA-05; `pubs` has alias types, `text`/`image` columns, legacy rules/defaults (check) |
| Stack Overflow Mini (2009 subset) | 2008+ (check) | https://github.com/BrentOzarULTD/Stack-Overflow-Database/releases/download/20230114/StackOverflowMini.bak | CC BY-SA 4.0 (attribute Stack Exchange) | ≈1 GB (≈1.5 GB restored) | typed restore | SS-SA-06; large tables, performance recipes |
| StackOverflow2010 | 2008+ | https://downloads.brentozar.com/StackOverflow2010.7z | CC BY-SA 4.0 | ≈1 GB 7z (≈10 GB) | 7z holds database files (check: `.mdf`/`.ldf`) → typed `attachDatabase`; unpacking is the lab's job | SS-SA-06 |
| StackOverflow2013 / 2024-04 | 2008+ / 2016+ | https://www.brentozar.com/archive/2015/10/how-to-download-the-stack-overflow-database-via-bittorrent/ | CC BY-SA 4.0 | 10 GB (≈50 GB) / 31 GB torrent (≈202 GB) | attach | too large for the default 14 GB host; out of scope |
| Chinook | any | https://github.com/lerocha/chinook-database/releases (v1.4.5: `Chinook_SqlServer.sql` 587 KB, `ChinookData.json` 1.8 MB) | MIT | 0.6 MB | option A from `ChinookData.json` | SS-SA-07; same data across all four engines |

## PostgreSQL

| Sample | Engine versions | Source | Licence | Download size | How it loads | Catalogue items covered |
|---|---|---|---|---|---|---|
| pagila | 13+ (check per release) | https://github.com/devrimgunduz/pagila | MIT-style permission notice in `LICENSE.txt` (GitHub reports NOASSERTION: check) | a few MB of SQL (repository 67 MB incl. JSONB variant data) | plain SQL + COPY: option A/B/C | PG-SA-01; partitioned tables, domains, enums, full-text (`tsvector`), triggers, views, functions, JSONB variant |
| dvdrental | 9.x+ | https://neon.com/postgresqltutorial/dvdrental.zip | not stated (check) | small (check) | `pg_restore` tar archive: option A (typed port) or C | PG-SA-02; 15 tables, 7 views, 8 functions, 1 trigger, 1 domain, 13 sequences |
| Chinook | any | https://github.com/lerocha/chinook-database/releases (`Chinook_PostgreSql.sql` 586 KB, serial/identity variants) | MIT | 0.6 MB | option A from `ChinookData.json` | PG-SA-03 |
| Airlines demo (Postgres Pro), 2025 edition | 15+ | https://postgrespro.com/community/demodb (`demo-20250901-3m/6m/1y/2y.sql.gz`) | MIT | 133 MB / 276 MB / 558 MB / 1,137 MB gz (≈1.3 / 2.7 / 5.4 / 11 GB) | option C (too large for A) | PG-SA-04; bookings schema, timestamptz-heavy data, `jsonb`, generated data at scale |
| Airlines demo, 2017 edition (small/medium/big) | 9.6+ | https://edu.postgrespro.com (check current URLs) | check | ≈21 MB small (check) | option C | PG-SA-04 (older variant) |
| Northwind (pthom) | any | https://github.com/pthom/northwind_psql | NOASSERTION on GitHub (data from Microsoft's MIT Northwind) | < 1 MB | option A | PG-SA-05 |
| AdventureWorks for Postgres | any | https://github.com/lorint/AdventureWorks-for-Postgres | MIT (scripts); data from Microsoft's MIT CSVs | CSVs from the Microsoft install-script zip (16.7 MB) + scripts | option A (CSV → typed COPY once GP-13 exists) | PG-SA-06; many schemas, views |
| Stack Overflow (2024-04) | 18 dump | torrent from brentozar.com (page above) | CC BY-SA 4.0 | 24 GB torrent (≈110 GB) | option C | PG-SA-07; out of scope for the default host |
| Neon sample set (employees, lego, netflix, titanic, wikipedia, chinook, pagila, periodic table, …) | any | https://github.com/neondatabase/postgres-sample-dbs | MIT | varies (repository 141 MB) | option A for the small ones | PG-SA-08 |

## MySQL and MariaDB

| Sample | Engine versions | Source | Licence | Download size | How it loads | Catalogue items covered |
|---|---|---|---|---|---|---|
| sakila | MySQL 5.x+ (spatial column, FULLTEXT, triggers, procedures, functions, views) | https://dev.mysql.com/doc/index-other.html | New BSD | 712 KB zip / 715 KB tgz | SQL with `DELIMITER`: option A or C | MY-SA-01; views, routines, triggers, spatial, full-text |
| employees (test_db) | MySQL 5.x+/MariaDB | https://github.com/datacharmer/test_db | CC BY-SA 3.0 | ≈167 MB of data (repository 75 MB) | option C (≈4 M rows) | MY-SA-02; volume, date ranges |
| world | any | https://dev.mysql.com/doc/index-other.html (`world.sql`) | not stated on the setup page (check) | 90 KB | option A | MY-SA-03 |
| airportdb | MySQL 8.0+ (MySQL Shell dump) | https://dev.mysql.com/doc/index-other.html | check | 625.3 MB | option C (`util.loadDump` needs MySQL Shell) | MY-SA-04; ≈2 GB, intended for HeatWave |
| menagerie | any | https://dev.mysql.com/doc/index-other.html | check | 1–3 KB | option A | MY-SA-05 |
| Chinook | any | https://github.com/lerocha/chinook-database/releases (`Chinook_MySql.sql` 602 KB) | MIT | 0.6 MB | option A (after GM-01/GM-02) | MY-SA-06 |

MariaDB has no official sample database of its own; the MySQL samples load on MariaDB (sakila's spatial and
full-text parts: check on each MariaDB version).

## SQLite

| Sample | Engine versions | Source | Licence | Download size | How it loads | Catalogue items covered |
|---|---|---|---|---|---|---|
| Chinook | any | https://github.com/lerocha/chinook-database/releases (`Chinook_Sqlite.sqlite`, `Chinook_Sqlite_AutoIncrementPKs.sqlite`) | MIT | 1.0 MB each | ready file | SL-SA-01 |
| Northwind | any | https://github.com/jpwhite3/northwind-SQLite3 | MIT | ≈20 MB repository (check file size) | ready file | SL-SA-02; larger generated order data |
| Sakila | any | https://github.com/bradleygrant/sakila-sqlite3 | BSD-3-Clause | ≈2.4 MB repository | ready file | SL-SA-03 |

## Also worth considering (not in the catalogue yet)

- **Contoso** (SQL Server, generated by the SQLBI Contoso Data Generator, sizes from 10 K to 100 M orders):
  good for scale recipes; check licence and whether prebuilt `.bak` files are published per size.
- **pgbench** schema (PostgreSQL): four tables that `pgbench -i` generates; trivial to port as a typed pack
  with a `scale` parameter.
- **TPC-H / TPC-DS** data from `dbgen`/`dsdgen`: generated CSV loaded through typed bulk APIs; the TPC EULA
  governs redistribution, so the lab would generate rather than ship data.
