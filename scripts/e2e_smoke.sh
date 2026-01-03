#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/infra"
LEDGER_DIR="${ROOT_DIR}/core-ledger"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need curl
need jq
need go

LOG_FILE="/tmp/core-ledger.log"

# Config
unset LEDGER_DB_DSN
export LEDGER_HTTP_ADDR="${LEDGER_HTTP_ADDR:-:8080}"
LEDGER_URL="${LEDGER_URL:-http://localhost:8080}"

get_env_var() {
  local file="$1" key="$2"
  if [ ! -f "$file" ]; then
    echo ""
    return 0
  fi
  # supports KEY=value with optional spaces (simple)
  grep -E "^[[:space:]]*${key}=" "$file" | tail -n1 | cut -d= -f2- | tr -d '\r'
}

fail() {
  echo "E2E FAILED: $*" >&2
  echo "---- ${LOG_FILE} (tail) ----" >&2
  tail -n 200 "${LOG_FILE}" 2>/dev/null || true
  exit 1
}

echo "[1/6] Starting infra (docker compose)"
cd "$INFRA_DIR"

# Ensure .env exists (bootstrap_env.sh should also do this, but keep safe)
if [ ! -f .env ]; then
  cp .env.example .env
fi

# Start infra (must have run bootstrap in infra make up)
make up >/dev/null

# Read the actual Postgres port chosen by bootstrap_env.sh
ENV_FILE="${INFRA_DIR}/.env"
PGPORT="$(get_env_var "$ENV_FILE" "POSTGRES_PORT")"
if [ -z "$PGPORT" ]; then
  fail "POSTGRES_PORT missing from ${ENV_FILE} (bootstrap_env.sh did not write it)"
fi

export LEDGER_DB_DSN="postgres://ledger:ledger@localhost:${PGPORT}/ledger?sslmode=disable"

echo "  Using POSTGRES_PORT=$PGPORT"
echo "  Using LEDGER_DB_DSN=$LEDGER_DB_DSN"

echo "[2/6] Starting core-ledger server"
cd "$LEDGER_DIR"

: > "${LOG_FILE}"

# Pass env explicitly to remove any ambiguity
LEDGER_DB_DSN="$LEDGER_DB_DSN" LEDGER_HTTP_ADDR="$LEDGER_HTTP_ADDR" \
  go run ./cmd/server >"${LOG_FILE}" 2>&1 &
SERVER_PID=$!

cleanup() {
  echo
  echo "[cleanup] stopping core-ledger (pid=$SERVER_PID)"
  kill "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for health and fail fast if process dies
for i in {1..120}; do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    fail "core-ledger process exited early"
  fi
  if curl -fsS "${LEDGER_URL}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! curl -fsS "${LEDGER_URL}/healthz" >/dev/null 2>&1; then
  fail "core-ledger did not become healthy at ${LEDGER_URL}/healthz"
fi

create_account() {
  local label="$1"
  local resp
  resp="$(curl -sS -X POST "${LEDGER_URL}/v1/accounts" \
    -H 'Content-Type: application/json' \
    -H 'X-Correlation-Id: e2e-1' \
    -d "{\"label\":\"${label}\",\"currency\":\"EUR\"}")"

  local id
  id="$(echo "$resp" | jq -r '.account_id // empty' 2>/dev/null || true)"
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    echo "Create account failed for label=$label. Response:" >&2
    echo "$resp" >&2
    fail "account creation returned no account_id"
  fi
  echo "$id"
}

echo "[3/6] Creating accounts"
ALICE="$(create_account "Alice")"
BOB="$(create_account "Bob")"
SYS="$(create_account "SYSTEM")"

echo "  Alice=$ALICE"
echo "  Bob=$BOB"
echo "  System=$SYS"

echo "[4/6] Mint 10000 cents to Alice"
MINT_KEY="idem-mint-$(date +%s)"
curl -sS -X POST "${LEDGER_URL}/v1/transfers" \
  -H 'Content-Type: application/json' \
  -d "{
    \"from_account_id\":\"$SYS\",
    \"to_account_id\":\"$ALICE\",
    \"amount_cents\":10000,
    \"currency\":\"EUR\",
    \"external_ref\":\"mint-$MINT_KEY\",
    \"idempotency_key\":\"$MINT_KEY\",
    \"correlation_id\":\"e2e-1\"
  }" | jq -e .tx_id >/dev/null || fail "mint failed"

echo "[5/6] Transfer 2500 cents Alice -> Bob"
PMT_KEY="idem-pmt-$(date +%s)"
curl -sS -X POST "${LEDGER_URL}/v1/transfers" \
  -H 'Content-Type: application/json' \
  -d "{
    \"from_account_id\":\"$ALICE\",
    \"to_account_id\":\"$BOB\",
    \"amount_cents\":2500,
    \"currency\":\"EUR\",
    \"external_ref\":\"pmt-$PMT_KEY\",
    \"idempotency_key\":\"$PMT_KEY\",
    \"correlation_id\":\"e2e-1\"
  }" | jq -e .tx_id >/dev/null || fail "transfer failed"

echo "[6/6] Checking balances"
BAL_A="$(curl -sS "${LEDGER_URL}/v1/accounts/$ALICE/balance" | jq -r .balance_cents)"
BAL_B="$(curl -sS "${LEDGER_URL}/v1/accounts/$BOB/balance" | jq -r .balance_cents)"

echo "  Alice balance_cents=$BAL_A (expected 7500)"
echo "  Bob   balance_cents=$BAL_B (expected 2500)"

if [ "$BAL_A" != "7500" ] || [ "$BAL_B" != "2500" ]; then
  fail "unexpected balances"
fi

echo "E2E OK"
