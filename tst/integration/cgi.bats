#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    mkdir -p schemas views

    cat > schemas/person.lua <<'EOF'
return {
  name = "person",
  fields = {
    {name = "full_name", type = "text", required = true, display = true},
  },
}
EOF
    cat > schemas/experiment.lua <<'EOF'
return {
  name = "experiment",
  fields = {
    {name = "title", type = "text", required = true, display = true},
    {name = "owner", type = "reference", required = false, entity_type = "person"},
  },
}
EOF
    cat > schemas/sample.lua <<'EOF'
return {
  name = "sample",
  fields = {
    {name = "lot_number", type = "text", required = true},
    {name = "experiment", type = "reference", required = false, entity_type = "experiment"},
  },
}
EOF
    "$BIN" schema add schemas/person.lua
    "$BIN" schema add schemas/experiment.lua
    "$BIN" schema add schemas/sample.lua

    "$BIN" entity create person full_name="Dr. Cohen"
    "$BIN" entity create experiment title="Contamination trial" owner=1
    "$BIN" entity create sample lot_number="LOT-42" experiment=2

    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "testuser" "i")
    export TEST_SESSION_COOKIE TEST_CSRF_TOKEN
    read ADMIN_SESSION_COOKIE ADMIN_CSRF_TOKEN < <(login_test_user "testadmin" "is")
    export ADMIN_SESSION_COOKIE ADMIN_CSRF_TOKEN
}

teardown() {
    cleanup_test_env
}

@test "/ renders the entity-relation diagram with a node per type and an edge for each reference field" {
    run_cgi "/" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "fossci-diagram-node\" data-entity-type=\"person\"" ]]
    [[ "$output" =~ "fossci-diagram-node\" data-entity-type=\"experiment\"" ]]
    [[ "$output" =~ "fossci-diagram-node\" data-entity-type=\"sample\"" ]]
    [[ "$output" =~ "fossci-diagram-edge\" data-from=\"experiment\" data-to=\"person\"" ]]
    [[ "$output" =~ "fossci-diagram-edge\" data-from=\"sample\" data-to=\"experiment\"" ]]
}

@test "/ sorts entity types by row count descending, alphabetical tiebreak, with data-count for the hide-empty toggle" {
    "$BIN" entity create person full_name="Dr. Amare"
    "$BIN" entity create person full_name="Dr. Beadle"
    # person now has 3 rows (1 from setup + 2 here); experiment and
    # sample each still have 1 -- person must sort first, then
    # experiment before sample (alphabetical tiebreak on equal counts).
    run_cgi "/" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ 'data-count="3"><a href="browse?type=person"' ]]
    before_experiment="${output%%'type=experiment"'*}"
    [[ "$before_experiment" == *'type=person"'* ]]
    before_sample="${output%%'type=sample"'*}"
    [[ "$before_sample" == *'type=experiment"'* ]]
}

@test "/register renders the registration form for a real entity type" {
    run_cgi "/register" "type=sample"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Register sample" ]]
}

@test "/browse lists an entity type's rows" {
    run_cgi "/browse" "type=sample"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOT-42" ]]
}

@test "/browse and /detail links are plain relative paths, not tied to any particular mount point" {
    # Regression: several links here used to carry a leftover
    # "fossci/" path segment from an old mount-point convention this
    # app no longer uses -- broken under any real deployment, since
    # there's no route at "fossci/browse" etc. Every link/action/src
    # this app renders for its own pages must be a plain relative
    # reference (or none at all), so it resolves correctly no matter
    # what path prefix a web server mounts this app under.
    run_cgi "/browse" "type=sample"
    [[ "$output" =~ 'href="detail?type=sample' ]]
    [[ ! "$output" =~ "fossci/detail" ]]
    [[ ! "$output" =~ "fossci/browse" ]]

    run_cgi "/detail" "type=sample&entity_id=3"
    [[ "$output" =~ 'href="browse?type=sample"' ]]
    [[ ! "$output" =~ "fossci/browse" ]]
}

@test "/browse rejects a 'type' shaped like a stacked-SQL-statement injection" {
    run_cgi "/browse" "type=sample%3B+DROP+TABLE+sample%3B--"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "400 Bad Request" ]]
    # the entity table must survive -- confirm sample is still queryable
    run_cgi "/browse" "type=sample"
    [[ "$output" =~ "LOT-42" ]]
}

@test "/browse rejects a 'type' shaped like a path-traversal payload" {
    run_cgi "/browse" "type=..%2F..%2Fetc%2Fpasswd"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "400 Bad Request" ]]
}

@test "/api/preview rejects a 'type' shaped like a SQL-injection payload" {
    run_cgi "/api/preview" "type=sample%3B+DROP+TABLE+sample%3B--&entity_id=1"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "400 Bad Request" ]]
}

@test "/api/preview resolves a reference field to the referenced entity's name, not its raw id" {
    # Reported live 2026-07-18: the hover-popover preview showed a
    # sample's "experiment"/"container"-style reference fields as raw
    # foreign-key ids, not the referenced entity's name -- confirmed the
    # link text itself (render_reference_value) already resolved fine,
    # this was isolated to handle_preview's own field_lines loop, which
    # never reference-resolved anything.
    run_cgi "/api/preview" "type=experiment&entity_id=2"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Dr. Cohen" ]]
}

@test "/sql query textarea overrides Fossil's base 95% textarea max-width" {
    # Reported live: the query textarea measured visibly narrower than
    # the prompt-input+button row above it -- traced to Fossil's own
    # base CSS (src/default.css: "textarea { max-width: 95%; }"), which
    # otherwise wins with nothing overriding it here.
    run_cgi_admin "/sql" ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "fossci-sql-input" ]]
    [[ "$output" =~ "max-width: 100%" ]]
}

@test "/sql resolves a reference column on the FROM table" {
    # /sql requires Setup or Admin capability (not just baseline "i").
    run_cgi_admin "/sql" "q=SELECT+id%2C+lot_number%2C+experiment+FROM+sample%3B"
    [ "$status" -eq 0 ]
    # experiment=2 should render as a resolved link/label, not the bare id "2"
    [[ "$output" =~ "Contamination trial" ]]
}

@test "/sql resolves a reference column on a JOINed table, not just FROM (regression: view.guess_tables)" {
    # Before the join-aware fix, this reference column (experiment.owner)
    # would silently fall back to displaying the raw id "1" instead of a
    # resolved link, since the old heuristic only ever looked at the FROM
    # table (sample), not the joined one (experiment).
    query='SELECT+s.id%2C+e.owner+FROM+sample+s+JOIN+experiment+e+ON+s.experiment+%3D+e.id%3B'
    run_cgi_admin "/sql" "q=${query}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Dr. Cohen" ]]
}

@test "/view renders a canned view's rows" {
    cat > views/samples.lua <<'EOF'
return {
  name = "samples",
  title = "All samples",
  sql = "SELECT id, lot_number FROM sample;",
  columns = {
    {name = "id", label = "ID"},
    {name = "lot_number", label = "Lot"},
  },
}
EOF
    "$BIN" view approve samples

    run_cgi "/view" "view_name=samples"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOT-42" ]]
    # No entity_type declared on this view -- no register link expected.
    [[ ! "$output" =~ "Register new" ]]
}

@test "/view shows a Register new link when the view declares entity_type" {
    cat > views/samples_with_type.lua <<'EOF'
return {
  name = "samples_with_type",
  title = "All samples",
  entity_type = "sample",
  sql = "SELECT id, lot_number FROM sample;",
  columns = {
    {name = "id", label = "ID"},
    {name = "lot_number", label = "Lot"},
  },
}
EOF
    "$BIN" view approve samples_with_type

    run_cgi "/view" "view_name=samples_with_type"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Register new" ]]
    [[ "$output" =~ 'href="register?type=sample"' ]]
}

@test "/view refuses to run an unapproved view" {
    cat > views/unapproved.lua <<'EOF'
return {
  name = "unapproved",
  title = "Unapproved",
  sql = "SELECT id FROM sample;",
  columns = {
    {name = "id", label = "ID"},
  },
}
EOF
    run_cgi "/view" "view_name=unapproved"
    [[ "$output" =~ "not approved" ]]
}

@test "/api/archive excludes an entity from /browse but keeps it reachable via /detail" {
    run_cgi "/api/archive" "type=sample&entity_id=3" "POST"
    [ "$status" -eq 0 ]
    [[ "$output" =~ '"success":true' ]]

    run_cgi "/browse" "type=sample"
    [[ ! "$output" =~ "LOT-42" ]]

    run_cgi "/detail" "type=sample&entity_id=3"
    [[ "$output" =~ "LOT-42" ]]
}

@test "/api/unarchive restores an entity to /browse" {
    run_cgi "/api/archive" "type=sample&entity_id=3" "POST"
    run_cgi "/api/unarchive" "type=sample&entity_id=3" "POST"
    [[ "$output" =~ '"success":true' ]]

    run_cgi "/browse" "type=sample"
    [[ "$output" =~ "LOT-42" ]]
}
