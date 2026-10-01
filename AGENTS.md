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

`testlab` has 20 GB of RAM and 4 vCPUs. The lab lets its servers use at most **18 GB together**,
and that budget also counts what every other container on the host uses (sqlserver-nio's
`nio-lab-*` fixtures share `testlab`).

| Server | Memory each | At most at once on an otherwise empty host |
|---|---|---|
| SQL Server (any version) | 3 GB (`mssql-*-wideworldimporters`: 4 GB) | 6 |
| PostgreSQL | 1 GB | 18 |
| Mixed | add them up | e.g. 4 SQL Server + 6 PostgreSQL |

A builder (making a seeded image) counts like a server while it runs.

**Before you start servers**, run `swift run serverlab ps`. Its last line says how much of the
budget is taken (`Reserved 9031 of 18432 MB on testlab`). If what you need does not fit:

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
   - **By hand:** `serverlab up <recipe>` prints host, port and user. Remove yours with `serverlab down
     <server>` or `serverlab down --all` (only `--owner cli`'s, the default); never `--everyone` while
     other agents work.
   - **Test targets that already link the drivers (Echo's `EchoTests`):** import `ServerLabClient`
     instead of `ServerLabTesting`. Same `.server(...)` and `LabServer.current`, through the
     `serverlab` tool (`SERVERLAB_CLI`, else the lab checkout's release build, built once if missing).
4. **Check what went over the wire:** `.server("recipe", capture: true)` records the server's
   traffic; `LabWire.current.messages()` returns it decoded by Wireshark (TDS and PostgreSQL message
   kinds, SQL text, direction), with `roundTrips(containing:)` and `containsPlaintext(_:)`. By hand:
   `serverlab up <recipe> --capture`, then `serverlab wire <server>` or `serverlab pcap <server>`
   (opens in Wireshark). Capture and decoding run on the lab host; nothing to install. SQL Server
   traffic is encrypted when the client asks for TLS; connect with encryption off to read it.
5. **Restarts, failover and replicas:** every server keeps a fixed host port for its life, so it
   can be stopped and started without the address changing. Recipes with a `topology` setting are
   several containers ("parts") on a private network, each with its own port: `pg-<v>-primary-standby`
   has `primary` and `standby` (a hot standby streaming through a replication slot);
   `pg-<v>-publisher-subscriber` is logical replication of `labdata.replicated_items`; MySQL/MariaDB
   `*-source-replica` have `primary` and a GTID `replica`.
   `LabServer.parts`, `server.endpoint(of: "standby")`, and `server.stop(part:)`,
   `server.start(part:)` (returns once it takes logins) and `server.promote()` in tests; by hand
   `serverlab stop|start <server> [--part standby]` and `serverlab promote <server>`. `--env` adds
   `SERVERLAB_STANDBY_PORT` etc. Restarting the main part restarts a capture (a new recording).
6. **TLS and certificate checks:** recipes with a `tls` setting (`*-tls-required`, `-optional`,
   `mssql-2025-tls-strict` for TDS 8, `pg-17-tls-strict` for TLS 1.3 only,
   `pg-17-tls-client-certificate`, and `-expired-certificate`, `-wrong-host`, `-self-signed`) present
   a certificate from this machine's lab CA (`~/.echo-testlab/ca/lab-ca.pem`, made once) naming the
   lab host, its IP and `primary`/`standby`. `server.tls` has the mode, the certificate kind, `caPath`
   and for client-certificate servers the admin user's certificate and key; `--env` sets
   `SERVERLAB_TLS_*`. MySQL/MariaDB: `mysql-*-tls-required`, `-tls-optional`, `-tls-strict` (TLS 1.3)
   and the bad-certificate variants on 8.4. Verify against `caPath`; with `capture: true`, `containsPlaintext` shows the
   traffic really is encrypted.
7. **Network faults:** `.server("recipe", faults: true)` (or `serverlab up <recipe> --faults`) puts
   a Toxiproxy part `proxy` in front of any server. Connect to `server.endpoint(of: "proxy")`, then
   `server.addFault(.latency(milliseconds: 400))`, `.bandwidth`, `.timeout` (0 = silent hang),
   `.resetPeer`, `.slowClose`, `.limitData`, `.slicer` (downstream by default, `direction: .upstream`),
   `clearFaults()`, and `cutConnections()` / `restoreConnections()` for a network cut. By hand:
   `serverlab fault <server> latency 400 | cut | restore | clear`. For a server crash or restart use
   `stop(part:)` / `start(part:)` instead.
8. **Kerberos / Active Directory:** `*-kerberos` recipes (`mssql-2019/2022/2025-kerberos`,
   `pg-16/17/18-kerberos`, `-kerberos-tls-required`) join the lab domain `LAB.TEST`: one shared Samba
   DC (`serverlab-domain`, KDC on the lab host's port 19088) that starts with the first Kerberos
   server and goes with the last. Each server gets its own service account and host name
   (`server.kerberos.serviceHost`, e.g. `sql-1a2b3c4d.lab.test`; `*.lab.test` resolves to the lab
   host through Pi-hole). The domain user is `labuser@LAB.TEST` with the lab password; SQL Server
   has a Windows login `LAB\labuser`, PostgreSQL a `gss` rule and role `labuser`. Connect to
   `serviceHost` (not the IP), inside
   `server.kerberos!.withTicket(password: server.password) { … }` (`credentials: .password` when the
   driver logs in with the password itself). It sets `KRB5_CONFIG` (`~/.echo-testlab/krb5.conf`) and
   a ticket cache of its own, and makes Kerberos logins take turns: GSS state is per process.
9. **Availability groups:** `mssql-2019/2022/2025-availability-group` (primary + readable
   `secondary`) and `mssql-2022-availability-group-3` (`secondary`, `secondary2`): Always On group
   `LabAG`, CLUSTER_TYPE NONE, certificate-authenticated endpoints on 5022, LabData seeded
   automatically. Read from `endpoint(of: "secondary")`; `server.promote(part: "secondary")` fails
   over (the others step down, the target forces the failover) and returns once its databases take
   connections.
10. **What went over the wire, field by field (TDS, PostgreSQL, MySQL):** the `TDSSpec` module (MS-TDS reference and a
    decoder) explains every captured SQL Server message: `LabWire.current.explainedMessages()` in
    tests, `serverlab explain <server>` by hand; `.specProblems` / the last line list every byte the
    decoder could not match to MS-TDS (empty means the traffic matches the spec). sqlserver-nio
    always encrypts, so its traffic reads only as TLS until it has TLS key logging; `serverlab
    sqlcmd <server> "<sql>"` (`ServerLab.runMicrosoftClient`) sends through Microsoft's sqlcmd with
    only the login encrypted, as a readable reference. The `tds-mcp` MCP server
    (`swift run tds-mcp`, stdio) is this module plus `explain_capture` and `check_capture`; it
    replaces the old TypeScript tds-mcp repo. Fix the spec in `Sources/TDSSpec/Resources/spec`
    and say where the fix came from (MS-TDS section and date, or a capture).
    PostgreSQL captures decode the same way (`PostgresProtocol` module: startup, SSL/GSS requests,
    authentication with passwords and SCRAM proofs never shown, simple and extended queries,
    DataRow values in text or binary by type OID, COPY, notifications); postgres-wire can connect
    with `sslMode: .disable`, so its own traffic is readable.
    MySQL and MariaDB captures decode too (`MySQLProtocol`: handshake, login and auth switching, every
    COM_ command, OK/ERR/EOF, result sets in text and binary, prepared statements, MariaDB's metadata
    caching). mysql-wire encrypts and cannot log in to MySQL without TLS, so `serverlab mysql <server>
    "<sql>"` (`ServerLab.runMySQLClient`) sends through the image's own client without TLS.

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
   Read the driver's own `AGENTS.md`.

**The lab provides every way of testing everything** (owner, 2026-09-30): not only content but
every server setup a driver or Echo can meet: TLS in every mode, TDS 8 strict, Kerberos, client
certificates, failover pairs and availability groups, network faults. Each driver agent stays
responsible for its driver working with them; the lab is responsible for offering the servers. When
a test needs a setup the lab lacks, add it here (a recipe, a server part, a setting), not a private
fixture in the driver.
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
