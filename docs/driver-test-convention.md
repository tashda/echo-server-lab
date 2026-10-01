# How our drivers' tests find a database server

sqlserver-nio, postgres-wire and mysql-wire are open-source packages. Anyone should be able to
run their tests with nothing but Docker, so the tests must not depend on echo-server-lab. All
three use the same convention, and the lab is only one way of meeting it.

## The rule

A test that needs a server reads **one URL variable**. When the variable is not set, the test is
skipped and the skip message names the variable. When `<ENGINE>_TEST_REQUIRED=1` is set, a missing
variable fails the test instead, so CI cannot pass by skipping.

| Variable | What it points at |
|---|---|
| `SQLSERVER_TEST_URL`, `POSTGRES_TEST_URL`, `MYSQL_TEST_URL` | a plain server (MariaDB uses `MYSQL_`) |
| `<ENGINE>_TEST_TLS_URL` | a server that requires TLS; the URL carries the mode and CA |
| `<ENGINE>_TEST_KERBEROS_URL` | Kerberos logins; `krb5Config` names the Kerberos settings file |
| `POSTGRES_TEST_STANDBY_URL`, `MYSQL_TEST_REPLICA_URL` | the second server of a primary/standby pair |
| `SQLSERVER_TEST_AG_URLS` | availability-group replicas, primary first, comma-separated |
| `<ENGINE>_TEST_PROXY_URL`, `<ENGINE>_TEST_PROXY_CONTROL` | the server through a Toxiproxy, and the proxy's HTTP API |

Nothing else: no `USE_DOCKER`, no `.env` files read by the tests, no host/port/user/password
variables, and no Docker or `sqlcmd` calls from test code.

## URL forms

User and password are percent-encoded. The query keys are the ones the engine's own clients use.

```
sqlserver://sa:pass@localhost:1433/master?encrypt=mandatory&trustServerCertificate=true
sqlserver://sa:pass@host:1433/master?encrypt=strict&trustServerCertificate=false&caFile=/path/ca.pem
postgres://postgres:pass@localhost:5432/postgres?sslmode=disable
postgres://postgres:pass@host:5432/postgres?sslmode=verify-full&sslrootcert=/ca.pem&sslcert=/c.pem&sslkey=/k.pem
mysql://root:pass@localhost:3306/?ssl-mode=PREFERRED
mysql://root:pass@host:3306/?ssl-mode=VERIFY_IDENTITY&ssl-ca=/ca.pem&ssl-cert=/c.pem&ssl-key=/k.pem
postgres://alice%40LAB.TEST@host:5432/postgres?sslmode=disable&authentication=kerberos&serviceHost=pg.lab.test&krb5Config=/krb5.conf
```

The URL's path names the database to connect to first. Tests create the databases and objects
they need through the driver's typed APIs and remove them afterwards; they do not depend on
sample databases unless the test says which one and skips without it.

## In each package

1. **`<Kit>Testing`** (the package's existing test-support library) has the parser and a trait:
   - `TestServer.url(_ variable: String = "<ENGINE>_TEST_URL") -> TestServer?` parses the URL into
     the package's own configuration type.
   - `@Suite(.testServer)` or `@Suite(.testServer("POSTGRES_TEST_TLS_URL"))` skips or fails as
     above, and gives the test `TestServer.current`.
   - Unit tests for the parser: each form above, percent-encoded passwords, a missing variable,
     and `_TEST_REQUIRED`.
2. **`TESTING.md`** (and a short section in `README.md`) says how to run the tests:
   ```bash
   docker run -d --name sqlserver-test -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='Your_password1' -p 1433:1433 mcr.microsoft.com/mssql/server:2022-latest
   SQLSERVER_TEST_URL='sqlserver://sa:Your_password1@localhost:1433/master?trustServerCertificate=true' swift test
   ```
   It lists every variable, which tests use it, and how to get such a server with plain Docker
   where that is practical (TLS, a standby). Setups that need more (Kerberos, availability groups)
   say that they are optional and are skipped without their variable.
3. **CI** (`.github/workflows/test.yml`) runs unit tests on every push, and integration tests
   against GitHub `services:` containers for each supported server version, with
   `<ENGINE>_TEST_URL` and `<ENGINE>_TEST_REQUIRED=1` set.
4. Old ways are removed in the same change: Docker managers in test code, fixture shell scripts,
   per-package lab folders, `.env` reading, and the old variable names. Tests that only ran in one
   of those set-ups move onto a URL variable or are deleted with a note in the commit.

## With echo-server-lab

The lab sets the same variables for every server it starts, so a maintainer with access runs the
whole matrix (every version, TLS, Kerberos, availability groups, faults) without the package
knowing about the lab:

```bash
swift run --package-path ../echo-server-lab serverlab run --recipe pg-17-tls-required -- swift test
eval "$(swift run --package-path ../echo-server-lab serverlab up mssql-2022-ag --env)"
```

`serverlab run` removes its servers when the command ends; after `serverlab up`, run
`serverlab down "$SERVERLAB_CONTAINER"`.
