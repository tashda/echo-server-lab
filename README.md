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

## Phase 1

SQL Server 2017–2025 and PostgreSQL 13–18. Packs: all column types,
programmability objects, Agent jobs on schedules.
