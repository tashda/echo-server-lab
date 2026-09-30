# echo-server-lab

On-demand database servers for testing Echo and its drivers. A test asks for a
**recipe** ("SQL Server 2017, Agent on, every column type, 20 scheduled jobs");
the lab starts a fresh copy of that server, hands back host, port and login,
and removes it when the suite ends. Nothing runs when nothing is being tested.

## Pieces

| Piece | What it is |
|---|---|
| **Base images** | Official images per engine and version (SQL Server 2017–2025, PostgreSQL 13–18, MySQL, MariaDB), plus small Dockerfiles where a feature is missing (full-text, PostGIS, pgvector). |
| **Settings** | Start-time configuration: Agent, collation, memory, TLS certificates, `mssql.conf`, `postgresql.conf`, `my.cnf`. |
| **Packs** | Content: every column type, programmability objects, Agent jobs and schedules, linked servers, security objects, edge cases. Each pack has a manifest (engine, minimum version, parameters, dependencies) and a check of what it must have created. |
| **Recipes** | JSON: engine + version + settings + packs with parameters. The unit a test, the CLI or Echo Labs asks for. |

## Rules

- **Packs create content only through our drivers' typed APIs** (`sqlserver-nio`,
  `postgres-wire`). There are no `.sql` fallbacks. When a driver cannot create
  something, or creates it wrongly, the fix goes into the driver, and the pack
  waits for it.
- **Every suite gets a fresh server.** A recipe is built once into a seeded image
  (tagged with a hash of the recipe and pack versions); each suite starts its own
  copy from that image in seconds and it is deleted afterwards. Containers carry
  an expiry label so anything a crashed run leaves behind is removed.
- **Docker is the source of truth.** Containers and images are labelled
  `dev.echodb.lab.*`; there is no daemon. The lab speaks the Docker Engine API to
  local sockets (OrbStack, Colima, Docker Desktop) and to remote hosts over SSH.
- **A memory budget per host.** Requests wait for room instead of overloading it.

## Hosts

| Host | Use |
|---|---|
| `testlab` (192.168.1.153, Proxmox VM 103) | Default. Debian 13, Docker Engine, 14 GB. Reached as `ssh://testlab`. |
| Local OrbStack | Offline work on the Mac. |

## Consumers

- **Tests:** Swift Testing trait, `@Suite(.server("mssql-2017-agent-jobs"))`.
- **CLI:** `serverlab up <recipe>` prints connection details (`--env` for
  `NIO_LAB_*`, `--echo` for Echo's automation config); `serverlab coverage`.
- **Echo Labs:** a Servers section for recipes, running servers, logs and
  coverage against the Explorer blueprints.

## Using it

```bash
swift run serverlab recipes                         # what can be asked for
swift run serverlab build mssql-2022-agent-jobs     # build (or reuse) the seeded image
eval "$(swift run serverlab up pg-17-column-types --env)"   # a fresh server, SERVERLAB_* set
swift run serverlab ps                              # lab containers and reserved memory
swift run serverlab down <container> | --all
```

In a test (`ServerLabTesting`):

```swift
@Suite(.server("mssql-2022-agent-jobs"))
struct JobTests {
    @Test func listsJobs() async throws {
        let server = try #require(LabServer.current)   // host, port, username, password
    }
}
```

The password comes from `SERVERLAB_PASSWORD`, else `TESTLAB_PASSWORD` in
`~/.echo-testlab/credentials.env`. `SERVERLAB_HOST=local` uses Docker on the Mac
instead of `testlab`. The integration tests run with `SERVERLAB_INTEGRATION=1`.

## Layout

| Path | What |
|---|---|
| `Sources/ServerLabKit` | Recipes, Docker, seeded images, server lifetimes, memory budget. No driver. |
| `Sources/ServerLabSQLServer`, `ServerLabPostgres` | Engines and packs, through the drivers only. |
| `Sources/ServerLabCatalog` | The standard lab and the shipped recipes (`Recipes/*.json`). |
| `Sources/ServerLabTesting` | The `.server(...)` trait. |
| `Sources/serverlab` | The command-line tool. |
| `catalog/` | Everything each engine has, what creates it, what the drivers still lack. |

## Status

Engines: SQL Server 2017–2025, PostgreSQL 13–18. Packs: `database`,
`column-types`, `programmability`, `indexes-constraints` and `security` (both engines),
`partitioning` (both), `agent-jobs`, `temporal`, `linked-servers` (SQL Server),
`extensions` (PostgreSQL), and `sample` (both): AdventureWorks, AdventureWorksLT,
AdventureWorksDW, WideWorldImporters, Northwind, pubs (SQL Server; not yet built, testlab lacked
memory); Chinook (PostgreSQL 13+) and pagila (PostgreSQL 18, pgvector image), built and checked.

Sample files live on testlab in `/opt/serverlab/samples` (downloaded from their sources and
checked against `LabSamples`), mirrored in the `samples-v1` release of this repo.
Built and checked on SQL Server 2017, 2022, 2025 and PostgreSQL 13, 17, 18. The next packs and the
driver work they need are listed in `catalog/packs.md` and `catalog/driver-gaps.md`.
