#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INFRA_DIR="${ROOT_DIR}/infra"
LEDGER_DIR="${ROOT_DIR}/core-ledger"

# Config
export LEDGER_HTTP_ADDR="${LEDGER_HTTP_ADDR:-:8080}"
export LEDGER_DB_DSN="${LEDGER_DB_DSN:-postgres://ledger:ledger@localhost:55432/ledger?sslmode=disable}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need curl
need jq
need go

echo "[1/6] Starting infra (docker compose)"
cd "$INFRA_DIR"
# Ensure .env exists
if [ ! -f .env ]; then
  cp .env.example .env
fi

# If containers already exist, just ensure up
make up >/dev/null

echo "[2/6] Starting core-ledger server"
cd "$LEDGER_DIR"

# Start server in background
go run ./cmd/server >/tmp/core-ledger.log 2>&1 &
SERVER_PID=$!
cleanup() {
  echo
  echo "[cleanup] stopping core-ledger (pid=$SERVER_PID)"
  kill "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for health
for i in {1..40}; do
  if curl -fsS "http://localhost:8080/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

echo "[3/6] Creating accounts"
ALICE=$(curl -sS -X POST http://localhost:8080/v1/accounts \
  -H 'Content-Type: application/json' \
  -H 'X-Correlation-Id: e2e-1' \
  -d '{"label":"Alice","currency":"EUR"}' | jq -r .account_id)

BOB=$(curl -sS -X POST http://localhost:8080/v1/accounts \
  -H 'Content-Type: application/json' \
  -H 'X-Correlation-Id: e2e-1' \
  -d '{"label":"Bob","currency":"EUR"}' | jq -r .account_id)

SYS=$(curl -sS -X POST http://localhost:8080/v1/accounts \
  -H 'Content-Type: application/json' \
  -H 'X-Correlation-Id: e2e-1' \
  -d '{"label":"SYSTEM","currency":"EUR"}' | jq -r .account_id)

echo "  Alice=$ALICE"
echo "  Bob=$BOB"
echo "  System=$SYS"

echo "[4/6] Mint 10000 cents to Alice"
MINT_KEY="idem-mint-$(date +%s)"
curl -sS -X POST http://localhost:8080/v1/transfers \
  -H 'Content-Type: application/json' \
  -d "{
    \"from_account_id\":\"$SYS\",
    \"to_account_id\":\"$ALICE\",
    \"amount_cents\":10000,
    \"currency\":\"EUR\",
    \"external_ref\":\"mint-$MINT_KEY\",
    \"idempotency_key\":\"$MINT_KEY\",
    \"correlation_id\":\"e2e-1\"
  }" | jq -e .tx_id >/dev/null

echo "[5/6] Transfer 2500 cents Alice -> Bob"
PMT_KEY="idem-pmt-$(date +%s)"
curl -sS -X POST http://localhost:8080/v1/transfers \
  -H 'Content-Type: application/json' \
  -d "{
    \"from_account_id\":\"$ALICE\",
    \"to_account_id\":\"$BOB\",
    \"amount_cents\":2500,
    \"currency\":\"EUR\",
    \"external_ref\":\"pmt-$PMT_KEY\",
    \"idempotency_key\":\"$PMT_KEY\",
    \"correlation_id\":\"e2e-1\"
  }" | jq -e .tx_id >/dev/null

echo "[6/6] Checking balances"
BAL_A=$(curl -sS "http://localhost:8080/v1/accounts/$ALICE/balance" | jq -r .balance_cents)
BAL_B=$(curl -sS "http://localhost:8080/v1/accounts/$BOB/balance" | jq -r .balance_cents)

echo "  Alice balance_cents=$BAL_A (expected 7500)"
echo "  Bob   balance_cents=$BAL_B (expected 2500)"

if [ "$BAL_A" != "7500" ] || [ "$BAL_B" != "2500" ]; then
  echo "E2E FAILED"
  echo "core-ledger log: /tmp/core-ledger.log"
  exit 1
fi

echo "E2E OK"
