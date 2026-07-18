#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p views
    cat > views/samples.lua <<'EOF'
return {
  name = "samples",
  title = "All samples",
  sql = "SELECT id FROM sqlite_master WHERE type = 'table' LIMIT 5;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
}

teardown() {
    cleanup_test_env
}

@test "view list shows an unapproved view" {
    run "$BIN" view list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "samples" ]]
    [[ "$output" =~ "not approved" ]]
}

@test "view approve marks a view approved" {
    "$BIN" view approve samples
    run "$BIN" view show samples
    [[ "$output" =~ "status: approved" ]]
}

@test "view revoke unapproves a previously approved view" {
    "$BIN" view approve samples
    "$BIN" view revoke samples
    run "$BIN" view show samples
    [[ "$output" =~ "status: not approved" ]]
}

@test "editing an approved view's sql requires re-approval" {
    "$BIN" view approve samples
    cat > views/samples.lua <<'EOF'
return {
  name = "samples",
  title = "All samples",
  sql = "SELECT id FROM sqlite_master WHERE type = 'table' LIMIT 10;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    run "$BIN" view show samples
    [[ "$output" =~ "NOT APPROVED" ]]
}

@test "view add rejects sql with a stacked statement" {
    mkdir -p views
    cat > views/evil.lua <<'EOF'
return {
  name = "evil",
  title = "Evil",
  sql = "SELECT id FROM sqlite_master; DROP TABLE entity_field;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    run "$BIN" view show evil
    [[ "$output" =~ "Error" ]]
}
