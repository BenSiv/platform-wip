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

raw_post() {
    local path_info="$1"
    local body="$2"
    local cookie="$3"
    local test_responses="$4"
    printf '%s' "$body" | AGENT_PROVIDER=test AGENT_TEST_RESPONSES="$test_responses" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="$path_info" QUERY_STRING="" \
        HTTP_COOKIE="$cookie" "$BIN"
}

raw_get() {
    local path_info="$1"
    local query_string="$2"
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$path_info" QUERY_STRING="$query_string" \
        HTTP_COOKIE="$COOKIE" "$BIN"
}

extract_query_param() {
    local response="$1"
    local param="$2"
    printf '%s' "$response" | grep -o "${param}=[^ ]*" | sed "s/${param}=//" | tr -d '\r'
}

start_chat() {
    raw_post "/chat-start" "csrf_token=${CSRF}&title=Chat" "$COOKIE" ""
}

search_for_bioreactor() {
    resp=$(start_chat)
    session_id=$(extract_query_param "$resp" "session_id")
    scripted=$'<tool>document</tool>\n<method>search</method>\n<args>\nquery=bioreactor\n</args>\1<done>Found it.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=find+bioreactor+pages" "$COOKIE" "$scripted" >/dev/null
}

@test "platform knowledge stats shows all zeros on a fresh store" {
    run "$BIN" knowledge stats
    [[ "$output" =~ "tier0=0 tier1=0 tier2=0 tier3=0" ]]
    [[ "$output" =~ "notes=0 retrievals=0 reviewed=0 sessions=0" ]]
}

@test "document.search's tool result grounds the agent in real content, not just a title" {
    # Found live: document.search itself already fetched full content
    # for scoring, but the agent tool wrapper around it used to throw
    # that away and return only "#id title" -- the model could find
    # which pages might be relevant but never actually read one before
    # answering. Excerpted (not the full page verbatim) so a search
    # matching several long pages doesn't balloon every turn's prompt.
    long_content=$(python3 -c "print('The bioreactor procedure needs careful monitoring. ' * 40)")
    "$BIN" entity create document title="Bioreactor SOP" content="$long_content"
    search_for_bioreactor

    tool_result=$(sqlite3 .store/store.db "SELECT content FROM agent_message WHERE role='tool_result' ORDER BY id DESC LIMIT 1;")
    [[ "$tool_result" =~ "Bioreactor SOP" ]]
    [[ "$tool_result" =~ "careful monitoring" ]]
    # Truncated, not the full ~2000-char body verbatim.
    [[ "$tool_result" =~ "..." ]]
    [ "${#tool_result}" -lt 1400 ]
}

@test "a chat search creates a tier-0 note, logs the retrieval, and runs review" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    run "$BIN" knowledge stats
    [[ "$output" =~ "tier0=1 tier1=0 tier2=0 tier3=0" ]]
    [[ "$output" =~ "notes=1 retrievals=1 reviewed=1 sessions=1" ]]

    run "$BIN" knowledge list 0
    [[ "$output" =~ "Bioreactor Notes" ]]
    [[ "$output" =~ "heat=1.15" ]]
}

@test "searching for the same document twice reuses its own row (no duplicate) and promotes it to tier 1" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor
    search_for_bioreactor

    run "$BIN" knowledge stats
    # Still exactly one pool document -- a retrieved document accrues
    # heat/tier directly on itself (task #106), never a second row per
    # search.
    [[ "$output" =~ "notes=1 retrievals=2" ]]

    # 2 retrievals crosses the tier-0->1 promotion threshold.
    run "$BIN" knowledge list 1
    [[ "$output" =~ "Bioreactor Notes" ]]
    [[ "$output" =~ "retrievals=2" ]]
}

@test "platform knowledge show prints a document's full pool detail" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    run "$BIN" knowledge show 1
    [[ "$output" =~ "title: Bioreactor Notes" ]]
    [[ "$output" =~ "tier: 0" ]]
    # A real, user-authored page retrieved directly has no source_type
    # (task #106) -- it isn't "sourced from" anything, it simply IS the
    # document; only agent-derived content (reasoning notes, future
    # distilled notes) prints a "source:" line.
    [[ ! "$output" =~ "source:" ]]
    [[ "$output" =~ "cleaning steps for the bioreactor procedure" ]]
}

@test "platform knowledge promote manually overrides a document's tier" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    run "$BIN" knowledge promote 1 2
    [[ "$output" =~ "Document #1 set to tier 2" ]]

    run "$BIN" knowledge list 2
    [[ "$output" =~ "Bioreactor Notes" ]]
    run "$BIN" knowledge list 0
    [[ ! "$output" =~ "Bioreactor Notes" ]]
}

@test "spreading activation reinforces a retrieved document's linked neighbors, not just the exact hit" {
    # Real [[title]] links (task #106 follow-up, ACT-R "spreading
    # activation") -- only document.create_page/sync_links populates
    # document_link, so this goes through the real /document-save
    # route rather than the `entity create` CLI shortcut every other
    # test in this file uses.
    # The link target must exist BEFORE the linking page is saved --
    # document.sync_links resolves "[[title]]" against documents that
    # exist at save time and is never retroactively re-run when a
    # dangling link's target later appears.
    raw_post "/document-save" "csrf_token=${CSRF}&title=Cleaning+Checklist&parent_id=&content=Checklist+content+here." "$COOKIE" "" >/dev/null
    raw_post "/document-save" "csrf_token=${CSRF}&title=Bioreactor+SOP&parent_id=&content=Steps+for+the+bioreactor.+See+%5B%5BCleaning+Checklist%5D%5D+for+details." "$COOKIE" "" >/dev/null

    resp=$(start_chat)
    session_id=$(extract_query_param "$resp" "session_id")
    scripted=$'<tool>document</tool>\n<method>search</method>\n<args>\nquery=bioreactor\n</args>\1<done>Found it.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=find+bioreactor+pages" "$COOKIE" "$scripted" >/dev/null

    # The linked neighbor ("Cleaning Checklist") never matched the query
    # directly, so its retrieval_count stays 0 -- but it should still
    # get a heat bump above the 1.0 default via spreading activation.
    run sqlite3 .store/store.db "SELECT retrieval_count FROM document WHERE title = 'Cleaning Checklist';"
    [ "$output" -eq 0 ]
    run sqlite3 .store/store.db "SELECT heat > 1.0 FROM document WHERE title = 'Cleaning Checklist';"
    [ "$output" -eq 1 ]
}

@test "the agent's knowledge.stats tool reports the same numbers as the CLI" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    resp=$(start_chat)
    session_id=$(extract_query_param "$resp" "session_id")
    scripted=$'<tool>knowledge</tool>\n<method>stats</method>\n<args>\n</args>\1<done>Here you go.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=summarize+the+knowledge+pool" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}"
    [[ "$output" =~ "notes=1" ]]
    [[ "$output" =~ "retrievals=1" ]]
}

@test "/knowledge renders the landing page for a Setup/Admin user" {
    "$BIN" user add carol carolpass123 isa
    raw_carol=$(printf 'login=carol&password=carolpass123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    carol_session=$(printf '%s' "$raw_carol" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    carol_csrf=$(printf '%s' "$raw_carol" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')

    run bash -c "GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/knowledge QUERY_STRING= HTTP_COOKIE='session=${carol_session}; csrf=${carol_csrf}' '$BIN'"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "Knowledge Pool" ]]
    [[ "$output" =~ "Tier 0: Raw Intake" ]]
    [[ "$output" =~ "Tier 3: Atomic Records" ]]
}

@test "/knowledge is forbidden for a plain (non Setup/Admin) user" {
    run raw_get "/knowledge" ""
    [[ "$output" =~ "403 Forbidden" ]]
}

@test "the icon rail no longer has a dedicated Chats entry; System links to Knowledge Pool instead" {
    "$BIN" user add carol carolpass123 isa
    raw_carol=$(printf 'login=carol&password=carolpass123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    carol_session=$(printf '%s' "$raw_carol" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    carol_csrf=$(printf '%s' "$raw_carol" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')

    run bash -c "GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/ QUERY_STRING= HTTP_COOKIE='session=${carol_session}; csrf=${carol_csrf}' '$BIN'"
    [[ ! "$output" =~ 'title="Chats"' ]]

    run bash -c "GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET PATH_INFO=/system QUERY_STRING= HTTP_COOKIE='session=${carol_session}; csrf=${carol_csrf}' '$BIN'"
    [[ "$output" =~ 'href="knowledge"' ]]
    [[ "$output" =~ "Knowledge Pool" ]]
}
