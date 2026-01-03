# Reproducible E2E

This project enforces a **deterministic, fully automated end-to-end test**.  
A clean clone must be able to run the full scenario without manual steps.

## Single command

```
make e2e
````

This command is the **only supported entry point** for validation.

## What the E2E does

1. Starts local infrastructure via Docker Compose
2. Selects a free Postgres port dynamically
3. Starts the Go API server with an explicit DSN
4. Applies embedded database migrations
5. Creates test accounts
6. Executes a mint operation
7. Executes a transfer
8. Verifies balances
9. Shuts everything down

Successful execution ends with:

```
E2E OK
```

## Determinism rules

The following rules are **non-negotiable**:

* No fixed Postgres port
  The infra layer selects a free port at runtime.

* No fixed HTTP port
  The E2E script selects a free port for the API server.

* No hardcoded database defaults
  `LEDGER_DB_DSN` is mandatory and must be provided by the E2E script.

* Embedded migrations
  Database schema is embedded in the binary and applied at startup.

* Fail fast
  If the server cannot start, bind a port, or connect to the database, the E2E must fail immediately.

## Environment variables

These are set automatically by the E2E script:

* `LEDGER_DB_DSN`
  Postgres connection string used by the API server.

* `LEDGER_HTTP_ADDR`
  Address and port used by the API server.

Manual overrides are not supported for E2E.

## Common issues

### Port already in use

The E2E script avoids collisions automatically.
If you run the server manually, ensure no conflicting process exists:

```
ss -ltnp | grep ':8080' || true
```

### Docker leftovers

If previous runs left containers or networks behind:

```
docker ps -a --filter "name=cbp-" --format "{{.ID}}" | xargs -r docker rm -f
docker network ls --filter "name=infra_default" -q | xargs -r docker network rm
```

## Scope

This document describes **reproducibility guarantees only**.
Business logic, accounting rules, and API semantics are documented elsewhere.

```

