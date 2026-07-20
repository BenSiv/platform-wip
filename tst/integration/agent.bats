#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add alice secret123 i
    "$BIN" user add bob bobpass123 i

    raw=$(printf 'login=alice&password=secret123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    SESSION=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    CSRF=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    COOKIE="session=${SESSION}; csrf=${CSRF}"

    raw_bob=$(printf 'login=bob&password=bobpass123' | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")
    BOB_SESSION=$(printf '%s' "$raw_bob" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    BOB_CSRF=$(printf '%s' "$raw_bob" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    BOB_COOKIE="session=${BOB_SESSION}; csrf=${BOB_CSRF}"
}

teardown() {
    cleanup_test_env
}

# The Location header's value carries a trailing \r (CRLF line ending)
# that a naive extraction misses -- a real bug caught manually while
# verifying this feature -- so every extraction here strips it.
extract_query_param() {
    local response="$1"
    local param="$2"
    printf '%s' "$response" | grep -o "${param}=[^ ]*" | sed "s/${param}=//" | tr -d '\r'
}

raw_get() {
    local path_info="$1"
    local query_string="$2"
    local cookie="$3"
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="$path_info" QUERY_STRING="$query_string" \
        HTTP_COOKIE="$cookie" "$BIN"
}

raw_post() {
    local path_info="$1"
    local body="$2"
    local cookie="$3"
    local test_responses="$4"
    local compaction_threshold="${5:-}"
    printf '%s' "$body" | AGENT_PROVIDER=test AGENT_TEST_RESPONSES="$test_responses" \
        AGENT_COMPACTION_THRESHOLD="$compaction_threshold" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="$path_info" QUERY_STRING="" \
        HTTP_COOKIE="$cookie" "$BIN"
}

start_chat() {
    local cookie="$1"
    local csrf="$2"
    local title="$3"
    raw_post "/chat-start" "csrf_token=${csrf}&title=${title}" "$cookie" ""
}

@test "GET /chat with no sessions shows the empty state" {
    run raw_get "/chat" "" "$COOKIE"
    [[ "$output" =~ "200 OK" ]]
    [[ "$output" =~ "No chats yet" ]]
}

@test "chat-start creates a session owned by the logged-in user" {
    run start_chat "$COOKIE" "$CSRF" "First+chat"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: chat?session_id=" ]]
}

@test "chat session list shows the session's start timestamp next to its title" {
    start_chat "$COOKIE" "$CSRF" "Timestamped+chat"

    run raw_get "/chat" "" "$COOKIE"
    [[ "$output" =~ "Timestamped chat" ]]
    [[ "$output" =~ "fossci-chat-session-started" ]]
}

@test "chat-message with a plain <done> reply records both turns and returns the message" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=What+is+2%2B2%3F" "$COOKIE" $'<done>2+2 is 4.</done>'
    [[ "$output" =~ "302 Found" ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "What is 2+2?" ]]
    [[ "$output" =~ "2+2 is 4." ]]
}

@test "a session with no explicit title gets one generated from its first real message" {
    resp=$(start_chat "$COOKIE" "$CSRF" "")
    session_id=$(extract_query_param "$resp" "session_id")

    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=What+is+the+boiling+point+of+water%3F" "$COOKIE" $'<done>100 degrees C.</done>'
    [[ "$output" =~ "302 Found" ]]

    run raw_get "/chat" "" "$COOKIE"
    [[ "$output" =~ "What is the boiling point of water?" ]]
    [[ ! "$output" =~ "Untitled chat" ]]
}

@test "current-user/current-page annotations reach the model but are stripped from the human-facing transcript" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    # Simulates exactly what the widget's own JS prepends -- a raw form
    # POST bypasses the JS, so this locks in the *server-side* strip
    # behavior (agent.display_content) independently of the browser.
    # Built already form-urlencoded (%0A for newline, + for space)
    # rather than encoding a shell string with real newlines, which sed
    # can't do reliably line-by-line.
    encoded_message="%5BCurrent+user:+alice%5D%0A%5BCurrent+page:+home+%22Home%22%5D%0A%0Awhat+page+am+I+on%3F"
    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=${encoded_message}" "$COOKIE" $'<done>You are on the Home page.</done>'
    [[ "$output" =~ "302 Found" ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "what page am I on?" ]]
    # Not a bare substring check -- the widget's own JS source
    # legitimately contains the literal text "Current user: " on every
    # page (it's the code that builds the prefix), so this checks for
    # the specific leaked-into-a-message-bubble shape instead.
    [[ ! "$output" =~ "Current user: alice]" ]]
    [[ ! "$output" =~ 'Current page: home' ]]
}

@test "a non-destructive tool call (document.search) executes automatically within the same turn" {
    "$BIN" entity create document title="Bioreactor Notes" content="cleaning steps"
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>document</tool>\n<method>search</method>\n<args>\nquery=bioreactor\n</args>\1<done>Found it.</done>'
    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=find+bioreactor+pages" "$COOKIE" "$scripted"
    [[ "$output" =~ "302 Found" ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "Tool result" ]]
    [[ "$output" =~ "Bioreactor Notes" ]]
    [[ "$output" =~ "Found it." ]]

    # Auto-executed and done -- no pending approval left behind.
    [[ ! "$output" =~ "wants to run" ]]

    # The document.search tool routes through knowledge.search_and_log:
    # every search is logged, and the retrieved document gets its
    # tier-0 knowledge_note created lazily (see knowledge.bats for the
    # full tiering/review coverage).
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT query_text, hit_count FROM knowledge_retrieval;"
    [[ "$output" =~ "bioreactor|1" ]]
    run sqlite3 "$TEST_DIR/.store/store.db" "SELECT COUNT(*) FROM knowledge_note;"
    [ "$output" -eq 1 ]
}

@test "a destructive tool call (document.create) pauses for approval instead of executing" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>document</tool>\n<method>create</method>\n<args>\ntitle=New Page\ncontent=hello\n</args>'
    run raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+page" "$COOKIE" "$scripted"
    [[ "$output" =~ "302 Found" ]]

    run "$BIN" entity list document
    [[ "$output" == "" ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "wants to run" ]]
    [[ "$output" =~ "document.create" ]]
    [[ "$output" =~ "Approve" ]]
    [[ "$output" =~ "Deny" ]]
}

@test "approving a pending action executes it, attributes it to the real user, and resumes the loop" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>document</tool>\n<method>create</method>\n<args>\ntitle=New Page\ncontent=hello\n</args>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+page" "$COOKIE" "$scripted" >/dev/null

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)

    run raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" $'<done>Created it.</done>'
    [[ "$output" =~ "302 Found" ]]

    run "$BIN" entity show document 1
    [[ "$output" =~ "New Page" ]]
    [[ "$output" =~ created_by[[:space:]]+alice ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ ! "$output" =~ "wants to run" ]]
    [[ "$output" =~ "Created it." ]]
}

@test "denying a pending action never executes it, and records the denial" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>document</tool>\n<method>create</method>\n<args>\ntitle=Denied Page\ncontent=hello\n</args>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+page" "$COOKIE" "$scripted" >/dev/null

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)

    run raw_post "/chat-deny" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" $'<done>Understood.</done>'
    [[ "$output" =~ "302 Found" ]]

    run "$BIN" entity list document
    [[ "$output" == "" ]]

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "denied" ]]
}

write_task_schema() {
    mkdir -p schemas
    cat > schemas/task.lua <<'EOF'
return {
  name = "task",
  fields = {
    {name = "title", type = "text", required = true},
    {name = "status", type = "select", required = true, values = {"open", "done"}},
  },
}
EOF
    "$BIN" schema add schemas/task.lua >/dev/null
}

@test "entity.list_types lists every registered entity type" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>entity</tool>\n<method>list_types</method>\n<args>\n</args>\1<done>Listed.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=what+entity+types+exist" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "document" ]]
    [[ "$output" =~ "task" ]]
}

@test "entity.fields lists a type's field names and types, for discovery before create/update" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>entity</tool>\n<method>fields</method>\n<args>\nentity_type=task\n</args>\1<done>Listed.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=what+fields+does+task+have" "$COOKIE" "$scripted" >/dev/null

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "title (text, required)" ]]
    [[ "$output" =~ "status (select, required)" ]]
}

@test "entity.list and entity.get read real rows (non-destructive, auto-executes)" {
    write_task_schema
    "$BIN" entity create task title="Ship it" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>entity</tool>\n<method>list</method>\n<args>\nentity_type=task\n</args>\1<done>Found tasks.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=list+tasks" "$COOKIE" "$scripted" >/dev/null
    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "Ship it" ]]
    [[ ! "$output" =~ "wants to run" ]]

    scripted2=$'<tool>entity</tool>\n<method>get</method>\n<args>\nentity_type=task\nentity_id=1\n</args>\1<done>Here it is.</done>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=show+task+1" "$COOKIE" "$scripted2" >/dev/null
    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "status=open" ]]
}

@test "entity.create is destructive: pauses for approval, then really creates the row once approved" {
    write_task_schema
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>entity</tool>\n<method>create</method>\n<args>\nentity_type=task\ntitle=New task\nstatus=open\n</args>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=create+a+task" "$COOKIE" "$scripted" >/dev/null

    run "$BIN" entity list task
    [[ "$output" == "" ]]

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    [[ "$page_html" =~ "wants to run" ]]
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)

    run raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" $'<done>Created it.</done>'
    [[ "$output" =~ "302 Found" ]]

    run "$BIN" entity show task 1
    [[ "$output" =~ "New task" ]]
    [[ "$output" =~ created_by[[:space:]]+alice ]]
}

@test "entity.update is destructive: pauses for approval, then really updates the row once approved" {
    write_task_schema
    "$BIN" entity create task title="Old title" status=open >/dev/null
    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    scripted=$'<tool>entity</tool>\n<method>update</method>\n<args>\nentity_type=task\nentity_id=1\nstatus=done\n</args>'
    raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=mark+task+1+done" "$COOKIE" "$scripted" >/dev/null

    run "$BIN" entity show task 1
    [[ "$output" =~ status[[:space:]]+open ]]

    page_html=$(raw_get "/chat" "session_id=${session_id}" "$COOKIE")
    pending_id=$(printf '%s' "$page_html" | grep -o 'pending_id" value="[0-9]*"' | grep -o '[0-9]*' | head -1)

    raw_post "/chat-approve" "csrf_token=${CSRF}&pending_id=${pending_id}&session_id=${session_id}" "$COOKIE" $'<done>Done.</done>' >/dev/null

    run "$BIN" entity show task 1
    [[ "$output" =~ status[[:space:]]+done ]]
}

@test "one user cannot see, message, or approve/deny another user's session" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Alice private chat")
    session_id=$(extract_query_param "$resp" "session_id")

    run raw_get "/chat" "session_id=${session_id}" "$BOB_COOKIE"
    [[ "$output" =~ "404 Not Found" ]]

    run raw_post "/chat-message" "csrf_token=${BOB_CSRF}&session_id=${session_id}&message=hi" "$BOB_COOKIE" ""
    [[ "$output" =~ "404 Not Found" ]]
}

@test "chat-start/chat-message/chat-approve/chat-deny all require the matching CSRF token" {
    run raw_post "/chat-start" "csrf_token=wrong&title=x" "$COOKIE" ""
    [[ "$output" =~ "403 Forbidden" ]]

    resp=$(start_chat "$COOKIE" "$CSRF" "Chat")
    session_id=$(extract_query_param "$resp" "session_id")

    run raw_post "/chat-message" "csrf_token=wrong&session_id=${session_id}&message=hi" "$COOKIE" ""
    [[ "$output" =~ "403 Forbidden" ]]
}

@test "compaction marks old turns out of context (dimmed) but never deletes them" {
    resp=$(start_chat "$COOKIE" "$CSRF" "Long chat")
    session_id=$(extract_query_param "$resp" "session_id")

    for i in 1 2 3 4 5 6; do
        raw_post "/chat-message" "csrf_token=${CSRF}&session_id=${session_id}&message=message+number+${i}+with+extra+padding+text" \
            "$COOKIE" $'<done>ok</done>' "30" >/dev/null
    done

    run raw_get "/chat" "session_id=${session_id}" "$COOKIE"
    [[ "$output" =~ "fossci-chat-out-of-context" ]]
    [[ "$output" =~ "Compacted summary" ]]

    # Nothing deleted -- the full transcript is still all there.
    [[ "$output" =~ "message number 1" ]]
}

# --- Real Vertex AI end-to-end confirmation ---
#
# Deliberately NOT hardcoding a project id here (that would bake a
# specific customer's GCP project into this generic platform's own test
# suite) -- reads VERTEX_PROJECT from whatever's already in the
# environment, same as the app itself does, and skips if it's unset or
# gcloud has no usable credentials. Kept to a couple of small, cheap
# calls -- the turn-loop mechanics are already fully covered above
# against the deterministic test provider; this only needs to confirm
# the real Vertex AI wiring itself still works.

@test "real Vertex AI: agent_provider_vertex.generate returns a real model response" {
    if [ -z "${VERTEX_PROJECT:-}" ]; then
        skip "VERTEX_PROJECT not set in this environment"
    fi
    if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        skip "no usable gcloud application-default credentials"
    fi

    cat > "${TEST_DIR}/vertex_check.lua" <<EOF
package.path = "${PROJECT_ROOT}/src/?.lua;" .. package.path
agent_provider = require("agent_provider")
result, err = agent_provider.generate("gemini-2.5-flash", "Reply in exactly one word, uppercase.", "What sound does a cow make?")
print("RESULT:", result, "ERR:", err)
EOF
    if [ -z "${LUAM_DIR:-}" ]; then
        LUAM_DIR=$(cd "${PROJECT_ROOT}/../luam" && pwd)
    fi
    run env LUA_PATH="${PROJECT_ROOT}/src/?.lua;${LUAM_DIR}/lib/?.lua;${LUAM_DIR}/lib/?/init.lua;;" \
        LUA_CPATH="${LUAM_DIR}/bin/?.so;${LUAM_DIR}/lib/lfs/?.so;;" \
        "${LUAM_DIR}/bin/luam" "${TEST_DIR}/vertex_check.lua"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ERR:	nil" ]]
    [[ ! "$output" =~ "RESULT:	nil" ]]
}
