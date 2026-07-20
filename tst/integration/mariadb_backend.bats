#!/usr/bin/env bats

# Covers the MariaDB backend (doc/mariadb-migration.md) end to end via
# the real CLI, mirroring entity.bats'/schema.bats' own SQLite-focused
# coverage. Needs a real, reachable MariaDB server -- not available in
# every dev/CI environment the way SQLite (zero external dependency)
# always is, so every test here is skipped (not failed) if one isn't
# configured, matching luam's own test_mariadb.lua/test_mariadb_
# wrapper.lua skip-not-fail convention. Point MARIADB_TEST_HOST/PORT/
# USER/PASSWORD/DATABASE at a real test server to actually run these.

load test_helper.bash

setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    resolve_bin

    export PLATFORM_DB_BACKEND=mariadb
    export PLATFORM_MARIADB_HOST="${MARIADB_TEST_HOST:-127.0.0.1}"
    export PLATFORM_MARIADB_PORT="${MARIADB_TEST_PORT:-3306}"
    export PLATFORM_MARIADB_USER="${MARIADB_TEST_USER:-platform_test}"
    export PLATFORM_MARIADB_PASSWORD="${MARIADB_TEST_PASSWORD:-platform_test_pw}"
    export PLATFORM_MARIADB_DATABASE="${MARIADB_TEST_DATABASE:-platform_bats_test}"

    if ! command -v mariadb >/dev/null 2>&1; then
        skip "mariadb CLI not available -- skipping MariaDB backend coverage"
    fi

    # Fresh database per test (mirrors mktemp -d's fresh-directory
    # isolation for the SQLite path) -- drop-then-create, not just
    # create, so a test that crashed mid-run doesn't leave stale
    # tables for the next one.
    if ! mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
            -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" \
            -e "DROP DATABASE IF EXISTS $PLATFORM_MARIADB_DATABASE; CREATE DATABASE $PLATFORM_MARIADB_DATABASE;" \
            2>/dev/null; then
        skip "no reachable MariaDB test server at ${PLATFORM_MARIADB_HOST}:${PLATFORM_MARIADB_PORT} -- skipping"
    fi

    export TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    if [ -n "${PLATFORM_MARIADB_DATABASE:-}" ] && command -v mariadb >/dev/null 2>&1; then
        mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
            -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" \
            -e "DROP DATABASE IF EXISTS $PLATFORM_MARIADB_DATABASE;" 2>/dev/null || true
    fi
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_DIR"
}

@test "platform init succeeds against MariaDB and is idempotent" {
    run "$BIN" init
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Initialized store" ]]

    run "$BIN" init
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Already initialized" ]]
}

@test "schema add, entity create/list/update/archive/unarchive all work against MariaDB" {
    "$BIN" init
    mkdir -p schemas
    cat > schemas/reagent.lua <<'EOF'
return {
  name = "reagent",
  fields = {
    {name = "lot_number", type = "text", required = true},
    {name = "concentration", type = "number", required = true},
  },
}
EOF
    run "$BIN" schema add schemas/reagent.lua
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Registered entity type 'reagent'" ]]

    run "$BIN" entity create reagent lot_number=LOT-1 concentration=5
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Created reagent #1" ]]

    "$BIN" entity create reagent lot_number=LOT-2 concentration=10
    "$BIN" entity create reagent lot_number=LOT-3 concentration=15

    run "$BIN" entity list reagent
    [[ "$output" =~ "#1" ]]
    [[ "$output" =~ "#2" ]]
    [[ "$output" =~ "#3" ]]

    run "$BIN" entity update reagent 2 concentration=99
    [ "$status" -eq 0 ]

    run "$BIN" entity archive reagent 3
    [ "$status" -eq 0 ]
    run "$BIN" entity list reagent
    [[ ! "$output" =~ "#3" ]]

    run "$BIN" entity unarchive reagent 3
    [ "$status" -eq 0 ]
    run "$BIN" entity list reagent
    [[ "$output" =~ "#3" ]]

    run "$BIN" ledger history 2
    [[ "$output" =~ "create" ]]
    [[ "$output" =~ "concentration: nil -> 10" ]]
    [[ "$output" =~ "update" ]]
    [[ "$output" =~ "concentration: 10 -> 99" ]]
}

@test "concurrent entity creates never collide on entity_id or leave one NULL against MariaDB (task #77)" {
    "$BIN" init
    mkdir -p schemas
    cat > schemas/reagent.lua <<'EOF'
return {
  name = "reagent",
  fields = {
    {name = "lot_number", type = "text", required = true},
  },
}
EOF
    "$BIN" schema add schemas/reagent.lua

    pids=()
    for i in $(seq 1 15); do
        "$BIN" entity create reagent lot_number="LOT-$i" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    null_count=$(mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
        -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(*) FROM $PLATFORM_MARIADB_DATABASE.entity_event WHERE event_type = 'create' AND entity_id IS NULL;")
    [ "$null_count" -eq 0 ]

    total_creates=$(mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
        -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(*) FROM $PLATFORM_MARIADB_DATABASE.entity_event WHERE event_type = 'create';")
    distinct_entity_ids=$(mariadb -h "$PLATFORM_MARIADB_HOST" -P "$PLATFORM_MARIADB_PORT" \
        -u "$PLATFORM_MARIADB_USER" -p"$PLATFORM_MARIADB_PASSWORD" -N \
        -e "SELECT COUNT(DISTINCT entity_id) FROM $PLATFORM_MARIADB_DATABASE.entity_event WHERE event_type = 'create';")
    [ "$total_creates" -eq 15 ]
    [ "$distinct_entity_ids" -eq 15 ]
}
