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

@test "searching for the same document twice reuses its note (no duplicate) and promotes it to tier 1" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor
    search_for_bioreactor

    run "$BIN" knowledge stats
    # Still exactly one note -- ensure_note_for_document is idempotent,
    # not a second note per search.
    [[ "$output" =~ "notes=1 retrievals=2" ]]

    # 2 retrievals crosses the tier-0->1 promotion threshold.
    run "$BIN" knowledge list 1
    [[ "$output" =~ "Bioreactor Notes" ]]
    [[ "$output" =~ "retrievals=2" ]]
}

@test "platform knowledge show prints a note's full detail" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    run "$BIN" knowledge show 1
    [[ "$output" =~ "title: Bioreactor Notes" ]]
    [[ "$output" =~ "tier: 0" ]]
    [[ "$output" =~ "source: document #1" ]]
    [[ "$output" =~ "cleaning steps for the bioreactor procedure" ]]
}

@test "platform knowledge promote manually overrides a note's tier" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps for the bioreactor procedure"
    search_for_bioreactor

    run "$BIN" knowledge promote 1 2
    [[ "$output" =~ "Note #1 set to tier 2" ]]

    run "$BIN" knowledge list 2
    [[ "$output" =~ "Bioreactor Notes" ]]
    run "$BIN" knowledge list 0
    [[ ! "$output" =~ "Bioreactor Notes" ]]
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
