# Community Bank (master)

This repository orchestrates the platform using Git submodules.

## Components

- infra -> community-bank-infra
- core-ledger -> community-bank-core-ledger

## Clone with submodules

```
git clone --recurse-submodules git@github.com:likme/community-bank.git
```

## Update submodules


```
git submodule update --init --recursive
git submodule update --remote --merge
```

## Local run

```
cd infra
make up
```

In another terminal:

```
cd core-ledger
export LEDGER_DB_DSN="postgres://ledger:ledger@localhost:55432/ledger?sslmode=disable"
go test ./...
go run ./cmd/server
```

## License
AGPL-3.0. See LICENSE.


