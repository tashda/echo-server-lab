# echo-server-lab: agent guide

Disposable database servers for tests. Read `README.md` first. `CLAUDE.md` is an identical copy of
this file; change both together.

## Rules

- **Nothing runs always.** Start a server for the work, remove it afterwards. `swift run serverlab ps`
  must show no containers of yours when you finish. Servers and builders are removed with their
  volumes; on `testlab` the reaper also prunes unused volumes. Never prune on a shared Docker
  (your Mac's OrbStack also runs other agents' fixtures, e.g. sqlserver-nio's `nio-lab-*`).
- **Content only through our drivers' typed APIs** (sqlserver-nio, postgres-wire). No `.sql` files,
  no `sqlcmd`/`psql`. If a driver cannot create something, or creates it wrong, fix the driver first.
- **Never print the lab password.** It comes from `SERVERLAB_PASSWORD` or
  `~/.echo-testlab/credentials.env`.
- **Data is deterministic.** No random values in packs; the same recipe must give the same server.

## Capacity: look before you start

`testlab` has 14 GB of RAM and 4 vCPUs. The lab lets its servers use at most **12 GB together**,
and that budget also counts what every other container on the host uses (sqlserver-nio's
`nio-lab-*` fixtures share `testlab`).

| Server | Memory each | At most at once on an otherwise empty host |
|---|---|---|
| SQL Server (any version) | 3 GB (`mssql-*-wideworldimporters`: 4 GB) | 4 |
| PostgreSQL | 1 GB | 12 |
| Mixed | add them up | e.g. 2 SQL Server + 6 PostgreSQL |

A builder (making a seeded image) counts like a server while it runs.

**Before you start servers**, run `swift run serverlab ps`. Its last line says how much of the
budget is taken (`Reserved 9031 of 12288 MB on testlab`). If what you need does not fit:

- Wait, or use fewer servers at once (one suite at a time instead of many in parallel).
- Never remove containers that are not yours to make room. Lab containers are named
  `serverlab-*`; anything else belongs to another agent or to the owner.
- If the host stays full, tell the owner; do not switch to `SERVERLAB_HOST=local` on your own.

When a server does not fit, `serverlab up` and the `.server(...)` trait wait up to 15 minutes for
room, then fail with "Waited too long for … MB". Anything else that runs containers on `testlab`
must give them a memory limit (`--memory`), or the budget cannot protect the host.

## I need a server for a test

1. `swift run serverlab recipes`: pick one that has what you need. `catalog/` lists every item per
   engine and which pack creates it.
2. Nothing fits? Follow "Adding a scenario" below; do not create ad-hoc containers.
3. Use it:
   - **Swift Testing:** `@Suite(.server("recipe-name"))`, then `try #require(LabServer.current)`.
   - **Driver test suites:** `eval "$(swift run --package-path ../echo-server-lab serverlab up <recipe> --env)"`
     sets `TDS_*` (sqlserver-nio) or `POSTGRES_*` (postgres-wire). Run the tests, then
     `swift run --package-path ../echo-server-lab serverlab down "$SERVERLAB_CONTAINER"`.
   - **By hand:** `serverlab up <recipe>` prints host, port and user.
   - **Test targets that already link the drivers (Echo's `EchoTests`):** import `ServerLabClient`
     instead of `ServerLabTesting`. Same `.server(...)` and `LabServer.current`, through the
     `serverlab` tool (`SERVERLAB_CLI`, else the lab checkout's release build, built once if missing).
4. **Check what went over the wire:** `.server("recipe", capture: true)` records the server's
   traffic; `LabWire.current.messages()` returns it decoded by Wireshark (TDS and PostgreSQL message
   kinds, SQL text, direction), with `roundTrips(containing:)` and `containsPlaintext(_:)`. By hand:
   `serverlab up <recipe> --capture`, then `serverlab wire <server>` or `serverlab pcap <server>`
   (opens in Wireshark). Capture and decoding run on the lab host; nothing to install. SQL Server
   traffic is encrypted when the client asks for TLS; connect with encryption off to read it.

## Adding a scenario

Pick the smallest change that works:

1. **New combination of existing packs or parameters:** add a recipe JSON to
   `Sources/ServerLabCatalog/Recipes/`. The file name equals `name`. Names:
   `<mssql|pg>-<version>-<what>`, e.g. `mssql-2019-agent-jobs-100` or `pg-16-security`.
2. **More content of a kind a pack already makes:** extend that pack and raise its `version`
   (otherwise seeded images are not rebuilt).
3. **A new kind of content:** a new pack.
   - One file per pack in `Sources/ServerLab<Engine>/`, a struct conforming to `ContentPack`:
     `name` (kebab-case), `version`, `summary`, `apply`, `verify`.
   - Parameters with defaults via `parameters.int/string/bool`. Default database `LabData` (SQL
     Server) / `labdata` (PostgreSQL). Put objects in the pack's own schema (`shop`, `sales`,
     `secure`) so packs combine in one recipe.
   - `verify` reads back through the driver and throws `ServerLabError.packCheckFailed` with counts.
   - Gate by version where a feature is newer (see `SQLServerTypeSample.since`).
   - Register it in the engine's `packs` list and add recipes for every supported version.
4. **The driver is missing an API or has a bug:** in sqlserver-nio, lab agents own the typed feature
   APIs (`admin`, `security`, `metadata`, `agent`, `routines`, `types`, `constraints`, masking, …).
   The core belongs to the driver agent: `Sources/SQLServerTDS`, connection open and routing, pool
   and session reset, cancellation and deadlines, errors, streaming, value formatting
   (`SQLServerRow`, `SQLServerCellFormatter`, `SQLServerExactFormat`), `Tests/Fixtures` and
   `.github/workflows`. Never edit those; add the need to `catalog/driver-gaps.md` marked **core**.
   Read the driver's own `AGENTS.md`. Transport and security test servers (TLS, Strict, Toxiproxy,
   availability groups, Kerberos) stay in sqlserver-nio's `Tests/Fixtures`, not here.
   Otherwise fix it in the driver repo on `dev`, with a test,
   run against a lab server (`serverlab up … --env`). Commit, then `git fetch && git rebase
   origin/dev`, then push; never stash staged changes before committing. Then
   `swift package update <driver>` here. Record it in `catalog/driver-gaps.md` under "Found and
   fixed".

Then:

- `swift run serverlab build <recipe>` for the **oldest and newest** version the pack supports.
- Add an integration test in `Tests/ServerLabIntegrationTests` using `.server(...)`; run with
  `SERVERLAB_INTEGRATION=1 swift test --filter ServerLabIntegrationTests`.
- `swift test --filter ServerLabKitTests` (every shipped recipe is validated there).
- Mark the items in `catalog/<engine>.md` as covered by the pack; commit and push `dev`.

## Layout

See the Layout table in `README.md`. Hosts: `testlab` (default, 192.168.1.153, `ssh testlab`,
Docker context `testlab`) or `SERVERLAB_HOST=local`.
