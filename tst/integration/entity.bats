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
