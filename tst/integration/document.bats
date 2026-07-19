#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add alice secret123 i

    raw=$(printf 'login=alice&password=secret123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    SESSION=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    CSRF=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    COOKIE="session=${SESSION}; csrf=${CSRF}"
}

teardown() {
    cleanup_test_env
}

save_document() {
    local body="$1"
    printf '%s' "$body" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/document-save" QUERY_STRING="" \
        HTTP_COOKIE="$COOKIE" "$BIN"
}

get_route() {
    local path_info="$1"
    local query_string="$2"
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$path_info" QUERY_STRING="$query_string" \
        HTTP_COOKIE="$COOKIE" "$BIN"
}

# Piping straight into `run "$BIN"` doesn't carry stdin through bats'
# `run` correctly (same issue auth.bats' raw_admin_action works around)
# -- runs the binary directly, letting the caller wrap the *function
# call* in `run` instead.
raw_document_preview() {
    local body="$1"
    local csrf_header="$2"
    printf '%s' "$body" | GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/document-preview" \
        QUERY_STRING="" HTTP_COOKIE="$COOKIE" HTTP_X_CSRF_TOKEN="$csrf_header" "$BIN"
}

@test "document-save creates a root page and redirects to it" {
    run save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=Welcome."
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: document?entity_id=1" ]]

    run "$BIN" entity show document 1
    [[ "$output" =~ "Home" ]]
}

@test "document-save without the matching CSRF token is rejected" {
    run save_document "csrf_token=wrong&title=Home&parent_id=&content=x"
    [[ "$output" =~ "403 Forbidden" ]]

    run "$BIN" entity list document
    [[ "$output" == "" ]]
}

@test "documents nest under a parent, and /documents renders the tree in order" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=1&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Setup&parent_id=2&content=" >/dev/null

    run get_route "/documents" ""
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ 'href="document?entity_id=1">Home' ]]
    # Setup's <li> must be nested inside Guides' <details>, which is
    # nested inside Home's -- not just present anywhere on the page.
    # Collapsible <details>/<summary> nodes now, not a flat always-
    # expanded <ul><li> -- see html.lua's render_document_tree_level.
    [[ "$output" =~ 'Home</a></summary><ul><li><details><summary><a href="document?entity_id=2">Guides</a></summary><ul><li class="fossci-tree-leaf"><a href="document?entity_id=3">Setup' ]]
}

@test "/document shows breadcrumbs from root to self" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=1&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Setup&parent_id=2&content=" >/dev/null

    run get_route "/document" "entity_id=3"
    [[ "$output" =~ 'href="document?entity_id=1">Home</a> / <a href="document?entity_id=2">Guides</a> / Setup' ]]
}

@test "a [[title]] link resolves to a real page and renders as a link; an unknown one renders as a dangling marker" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=1&content=Back+to+%5B%5BHome%5D%5D+and+%5B%5BNowhere%5D%5D." >/dev/null

    run get_route "/document" "entity_id=2"
    [[ "$output" =~ 'Back to <a href="document?entity_id=1">Home</a>' ]]
    [[ "$output" =~ '<em>Nowhere</em> <em>(not created yet)</em>' ]]
}

@test "a resolved link creates a backlink shown on the target page" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=&content=Back+to+%5B%5BHome%5D%5D." >/dev/null

    run get_route "/document" "entity_id=1"
    [[ "$output" =~ "Linked from" ]]
    [[ "$output" =~ 'href="document?entity_id=2">Guides' ]]
}

@test "editing a document updates it in place instead of creating a duplicate" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=Original." >/dev/null

    run save_document "csrf_token=${CSRF}&entity_id=1&title=Home+Base&parent_id=&content=Renamed."
    [[ "$output" =~ "Location: document?entity_id=1" ]]

    run "$BIN" entity list document
    [[ "$output" =~ "#1" ]]
    [[ ! "$output" =~ "#2" ]]

    run "$BIN" ledger history 1
    [[ "$output" =~ "create" ]]
    [[ "$output" =~ "update" ]]
    [[ "$output" =~ "Home Base" ]]
}

@test "moving a page underneath its own descendant is rejected with a clear error, not silently applied" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null
    save_document "csrf_token=${CSRF}&title=Guides&parent_id=1&content=" >/dev/null

    run save_document "csrf_token=${CSRF}&entity_id=1&title=Home&parent_id=2&content="
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Can" ]]
    [[ "$output" =~ "own sub-page" ]]

    run "$BIN" entity show document 1
    [[ ! "$output" =~ "parent_id             2" ]]
}

@test "api/document-preview renders Markdown, and requires the CSRF header" {
    body='{"content": "# Title\n\nSome **bold** text."}'

    run raw_document_preview "$body" "wrong"
    [[ "$output" =~ "403 Forbidden" ]]

    run raw_document_preview "$body" "$CSRF"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "<h1>Title</h1>" ]]
    [[ "$output" =~ "<strong>bold</strong>" ]]
}

@test "archiving a document (via the generic /api/archive route) removes it from the /documents tree" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=" >/dev/null

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/archive" QUERY_STRING="type=document&entity_id=1" \
        HTTP_COOKIE="$COOKIE" HTTP_X_CSRF_TOKEN="$CSRF" run "$BIN"
    [[ "$output" =~ '"success":true' ]]

    run get_route "/documents" ""
    [[ "$output" =~ "No pages yet" ]]
}

@test "document reindex-embeddings CLI populates cached embeddings, explicitly not on every save" {
    save_document "csrf_token=${CSRF}&title=Home&parent_id=&content=hello" >/dev/null

    run "$BIN" entity list document
    # Saving a page never computes an embedding as a side effect --
    # only the explicit reindex command does (see document.lua's own
    # comment on why: it's a real, avoidable API cost per save).
    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db 'SELECT COUNT(*) FROM document_embedding;'"
    [ "$output" = "0" ]

    AGENT_PROVIDER=test run "$BIN" document reindex-embeddings
    [[ "$output" =~ "Reindexed 1 page(s), 0 failed" ]]

    run bash -c "cd '$TEST_DIR' && sqlite3 .store/store.db 'SELECT COUNT(*) FROM document_embedding;'"
    [ "$output" = "1" ]
}
