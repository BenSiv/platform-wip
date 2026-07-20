#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
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
    "$BIN" schema add schemas/reagent.lua
}

teardown() {
    cleanup_test_env
}

@test "entity create succeeds with all required fields" {
    run "$BIN" entity create reagent lot_number=LOT-1 concentration=5
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Created reagent #1" ]]
}

@test "entity create fails when a required field is missing" {
    run "$BIN" entity create reagent lot_number=LOT-1
    [[ "$output" =~ "required field is missing" ]]
}

@test "concurrent entity creates never collide on entity_id or leave one NULL (task #77)" {
    # ledger.append_create used to re-derive entity_id via SELECT
    # MAX(event_id) -- not connection-scoped the way last_insert_rowid()
    # is, so two simultaneous creates could both read the same MAX and
    # collide on one entity_id while the other's row kept entity_id NULL
    # forever. The bug itself is established by that direct reasoning
    # (see ledger.lua's own comment), not by this test: unsynchronized
    # process-level concurrency turned out to not reliably reproduce the
    # actual failure even at 150 parallel processes across several
    # tries against the unfixed code -- SQLite's own write-lock queue
    # plus per-process overhead apparently keeps the exploitable window
    # too narrow to hit by scheduling luck alone. This test instead
    # stands as an ongoing invariant check under real concurrent load
    # (every create gets a NULL-free, unique entity_id), which the fix
    # must satisfy regardless of whether the old bug can be reliably
    # forced to fail here.
    pids=()
    for i in $(seq 1 15); do
        "$BIN" entity create reagent lot_number="LOT-$i" concentration="$i" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    null_count=$(sqlite3 .store/store.db "SELECT COUNT(*) FROM entity_event WHERE event_type = 'create' AND entity_id IS NULL;")
    [ "$null_count" -eq 0 ]

    total_creates=$(sqlite3 .store/store.db "SELECT COUNT(*) FROM entity_event WHERE event_type = 'create';")
    distinct_entity_ids=$(sqlite3 .store/store.db "SELECT COUNT(DISTINCT entity_id) FROM entity_event WHERE event_type = 'create';")
    [ "$total_creates" -eq 15 ]
    [ "$distinct_entity_ids" -eq 15 ]
}

@test "entity list shows a created entity's id" {
    "$BIN" entity create reagent lot_number=LOT-1 concentration=5
    # entity list only prints "#<id>" per entity, not field values --
    # entity show/detail pages are where field values render.
    run "$BIN" entity list reagent
    [ "$status" -eq 0 ]
    [[ "$output" =~ "#1" ]]
}

@test "entity update changes a field value" {
    "$BIN" entity create reagent lot_number=LOT-1 concentration=5
    run "$BIN" entity update reagent 1 concentration=10
    [ "$status" -eq 0 ]

    run "$BIN" entity show reagent 1
    [[ "$output" =~ "10" ]]
}

@test "ledger records full history for an entity" {
    "$BIN" entity create reagent lot_number=LOT-1 concentration=5
    "$BIN" entity update reagent 1 concentration=10

    run "$BIN" ledger history 1
    [ "$status" -eq 0 ]
    # Both the create and the update should show up in the event history.
    [[ "$output" =~ "create" ]]
    [[ "$output" =~ "update" ]]
}

@test "entity archive excludes an entity from the default list but keeps it fully reachable" {
    "$BIN" entity create reagent lot_number=LOT-1 concentration=5
    "$BIN" entity create reagent lot_number=LOT-2 concentration=7

    run "$BIN" entity archive reagent 1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Archived reagent #1" ]]

    run "$BIN" entity list reagent
    [[ ! "$output" =~ "#1" ]]
    [[ "$output" =~ "#2" ]]

    # Never deleted -- still reachable directly, and with --include-archived.
    run "$BIN" entity show reagent 1
    [[ "$output" =~ "LOT-1" ]]
    run "$BIN" entity list reagent --include-archived
    [[ "$output" =~ "#1" ]]

    # Archiving is an additive ledger event, not a rewrite of history --
    # the original create event must still be there alongside it.
    run "$BIN" ledger history 1
    [[ "$output" =~ "create" ]]
    [[ "$output" =~ "archive" ]]
}

@test "entity unarchive restores an entity to the default list" {
    "$BIN" entity create reagent lot_number=LOT-1 concentration=5
    "$BIN" entity archive reagent 1

    run "$BIN" entity unarchive reagent 1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Unarchived reagent #1" ]]

    run "$BIN" entity list reagent
    [[ "$output" =~ "#1" ]]
}
