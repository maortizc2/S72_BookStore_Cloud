#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# File: bootstrap.sh
# Purpose:
#   Initialize the 3 decoupled BookStore Co. databases:
#     1. DB_AUTH_NAME   (Auth Service - customers)
#     2. DB_BOOKS_NAME  (Books Catalog Service - books)
#     3. DB_ORDERS_NAME (Orders Service - orders, order_items)
#   Supports either a shared PostgreSQL/RDS host (creating the 3
#   databases automatically) or 3 distinct RDS hosts.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATABASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/bootstrap.env"

CREATE_ROLES_SQL="${SCRIPT_DIR}/create_roles.sql"
GRANTS_SQL="${SCRIPT_DIR}/grants.sql"

SCHEMA_AUTH_SQL="${DATABASE_DIR}/schema_auth.sql"
SCHEMA_BOOKS_SQL="${DATABASE_DIR}/schema_books.sql"
SCHEMA_ORDERS_SQL="${DATABASE_DIR}/schema_orders.sql"

SEED_AUTH_SQL="${DATABASE_DIR}/seed_auth.sql"
SEED_BOOKS_SQL="${DATABASE_DIR}/seed_books.sql"

log() {
    printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

fail() {
    printf '\nERROR: %s\n' "$1" >&2
    exit 1
}

if [[ -z "${DB_HOST:-}" && -z "${AUTH_DB_HOST:-}" ]]; then
    [[ -f "${ENV_FILE}" ]] \
        || fail "No database configuration was provided. Set the required environment variables or copy bootstrap.env.example to bootstrap.env."
    log "Loading configuration from bootstrap.env"
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
else
    log "Using database configuration from environment variables"
fi

# Host and port defaults (allow per-service host or shared DB_HOST)
: "${DB_HOST:=localhost}"
: "${DB_PORT:=5432}"

: "${AUTH_DB_HOST:=${DB_HOST}}"
: "${AUTH_DB_PORT:=${DB_PORT}}"
: "${AUTH_DB_NAME:=bookstore_auth}"

: "${BOOKS_DB_HOST:=${DB_HOST}}"
: "${BOOKS_DB_PORT:=${DB_PORT}}"
: "${BOOKS_DB_NAME:=bookstore_books}"

: "${ORDERS_DB_HOST:=${DB_HOST}}"
: "${ORDERS_DB_PORT:=${DB_PORT}}"
: "${ORDERS_DB_NAME:=bookstore_orders}"

: "${DB_ADMIN_USER:?DB_ADMIN_USER is required}"
: "${DB_ADMIN_PASSWORD:?DB_ADMIN_PASSWORD is required}"

: "${APP_DB_USER:=bookstore_app}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD is required}"

: "${INGEST_DB_USER:=bookstore_ingest}"
: "${INGEST_DB_PASSWORD:?INGEST_DB_PASSWORD is required}"

: "${PGSSLMODE:=require}"

for secret in "${DB_ADMIN_PASSWORD}" "${APP_DB_PASSWORD}" "${INGEST_DB_PASSWORD}"; do
    [[ "${secret}" != "CHANGE_ME" ]] \
        || fail "Replace all CHANGE_ME password values before running the bootstrap."
done

command -v psql >/dev/null 2>&1 \
    || fail "psql is not installed or is not available in PATH."

export PGUSER="${DB_ADMIN_USER}"
export PGPASSWORD="${DB_ADMIN_PASSWORD}"
export PGSSLMODE="${PGSSLMODE}"

bootstrap_database() {
    local host="$1"
    local port="$2"
    local target_db="$3"
    local schema_file="$4"
    local seed_file="${5:-}"

    log "Bootstrapping database '${target_db}' on ${host}:${port}"

    export PGHOST="${host}"
    export PGPORT="${port}"

    # Connect to default maintenance DB ('postgres') to ensure roles and target_db exist
    export PGDATABASE="postgres"

    psql -X -v ON_ERROR_STOP=1 \
        -v app_user="${APP_DB_USER}" \
        -v app_password="${APP_DB_PASSWORD}" \
        -v ingest_user="${INGEST_DB_USER}" \
        -v ingest_password="${INGEST_DB_PASSWORD}" \
        -f "${CREATE_ROLES_SQL}"

    local db_exists
    db_exists="$(psql -X -tAc "SELECT 1 FROM pg_database WHERE datname = '${target_db}'")"
    if [[ "${db_exists}" != "1" ]]; then
        log "Creating database ${target_db}"
        psql -X -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${target_db}\";"
    else
        log "Database ${target_db} already exists"
    fi

    # Connect to the target database to apply schema, grants, and optional seed
    export PGDATABASE="${target_db}"

    psql -X -v ON_ERROR_STOP=1 -f "${schema_file}"

    psql -X -v ON_ERROR_STOP=1 \
        -v db_name="${target_db}" \
        -v app_user="${APP_DB_USER}" \
        -v ingest_user="${INGEST_DB_USER}" \
        -f "${GRANTS_SQL}"

    if [[ -n "${seed_file}" && -f "${seed_file}" ]]; then
        log "Loading seed data into ${target_db}"
        psql -X -v ON_ERROR_STOP=1 -f "${seed_file}"
    fi
}

bootstrap_database "${AUTH_DB_HOST}" "${AUTH_DB_PORT}" "${AUTH_DB_NAME}" "${SCHEMA_AUTH_SQL}" "${SEED_AUTH_SQL}"
bootstrap_database "${BOOKS_DB_HOST}" "${BOOKS_DB_PORT}" "${BOOKS_DB_NAME}" "${SCHEMA_BOOKS_SQL}" "${SEED_BOOKS_SQL}"
bootstrap_database "${ORDERS_DB_HOST}" "${ORDERS_DB_PORT}" "${ORDERS_DB_NAME}" "${SCHEMA_ORDERS_SQL}" ""

unset PGPASSWORD
log "All 3 BookStore Co. microservice databases (auth, books, orders) bootstrapped successfully!"
