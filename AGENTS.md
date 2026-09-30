# echo-server-lab: agent guide

Disposable database servers for tests. Read `README.md` first. `CLAUDE.md` is an identical copy of
this file; change both together.

## Rules

- **Nothing runs always.** Start a server for the work, remove it afterwards. `swift run serverlab ps`
  must show no containers of yours when you finish.
- **Content only through our drivers' typed APIs** (sqlserver-nio, postgres-wire). No `.sql` files,
  no `sqlcmd`/`psql`. If a driver cannot create something, or creates it wrong, fix the driver first.
- **Never print the lab password.** It comes from `SERVERLAB_PASSWORD` or
  `~/.echo-testlab/credentials.env`.
- **Data is deterministic.** No random values in packs; the same recipe must give the same server.

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
4. **The driver is missing an API or has a bug:** fix it in the driver repo on `dev`, with a test,
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
