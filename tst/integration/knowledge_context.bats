#!/usr/bin/env bats
# task #87: full prompt/reasoning/token persistence and chat evaluation.
# Note materialization/agent-driven review (originally covered here too)
# were removed under task #106 -- knowledge_note no longer exists as a
# separate table to materialize out of; every pool record already is a
# real document.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    "$BIN" user add admin secret123 ia
    "$BIN" user add alice secret123 i
}

teardown() {
    cleanup_test_env
}

raw_login() {
    local login="$1"
    local password="$2"
    printf 'login=%s&password=%s' "$login" "$password" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN"
}

session_for() {
    local login="$1" password="$2"
    local raw session csrf
    raw=$(raw_login "$login" "$password")
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')
    echo "${session} ${csrf}"
}

start_chat() {
    local session="$1" csrf="$2" title="$3"
    printf 'csrf_token=%s&title=%s' "$csrf" "$title" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-start" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" AGENT_PROVIDER=test "$BIN" \
        | grep -o 'session_id=[a-f0-9]*' | head -1 | sed 's/session_id=//'
}

send_message() {
    local session="$1" csrf="$2" chat_session_id="$3" message="$4" scripted="$5"
    printf 'csrf_token=%s&session_id=%s&message=%s' "$csrf" "$chat_session_id" "$message" | \
        AGENT_PROVIDER=test AGENT_TEST_RESPONSES="$scripted" \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" "$BIN"
}

@test "a real chat turn persists the exact prompt and real token counts in knowledge_context" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hello" "" > /dev/null

    run sqlite3 .store/store.db "SELECT session_id, model_id, prompt_tokens, completion_tokens FROM knowledge_context;"
    [[ "$output" =~ "$chat_session" ]]
    [[ "$output" =~ "gemini-2.5-flash" ]]
    # Real (estimated-under-test-provider) counts, not nil/empty.
    [[ ! "$output" =~ "||" ]]
}

@test "a real chat turn records a knowledge_chat_eval row classified as 'final'" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hello" "<done>A clean final answer.</done>" > /dev/null

    run sqlite3 .store/store.db "SELECT session_id, provider, reply_kind, quality_status FROM knowledge_chat_eval;"
    [[ "$output" =~ "$chat_session" ]]
    [[ "$output" =~ "test|final|ok" ]]
}

@test "a reply leaking visible reasoning creates a linked reasoning document under the Knowledge Pool folder" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hi" "<think>internal reasoning</think>" > /dev/null

    run sqlite3 .store/store.db "SELECT tier, source_type FROM document WHERE source_type='reasoning';"
    [[ "$output" =~ "0|reasoning" ]]

    run sqlite3 .store/store.db "SELECT reply_kind, reasoning_status FROM knowledge_chat_eval ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "reasoning-visible|visible" ]]

    run sqlite3 .store/store.db "SELECT context.reasoning_document_id FROM knowledge_context context ORDER BY context.id DESC LIMIT 1;"
    [[ "$output" != "" ]]

    # Lands under the Knowledge Pool folder, not at the top level.
    run sqlite3 .store/store.db "SELECT d.title FROM document d JOIN document parent ON parent.id = d.parent_id WHERE d.source_type = 'reasoning' AND parent.title = 'Knowledge Pool';"
    [[ "$output" =~ "Chat reasoning" ]]
}

@test "a provider failure still records knowledge_context/knowledge_chat_eval as an error, never reaching a real model call" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    printf 'csrf_token=%s&session_id=%s&message=hi' "$csrf" "$chat_session" | \
        AGENT_PROVIDER=nonexistent-provider \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/chat-message" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" "$BIN" > /dev/null

    run sqlite3 .store/store.db "SELECT reply_kind, quality_status FROM knowledge_chat_eval ORDER BY id DESC LIMIT 1;"
    [[ "$output" =~ "error|error" ]]
}

@test "chat feedback is recorded for the owning user and rejected for anyone else" {
    read session csrf < <(session_for admin secret123)
    chat_session=$(start_chat "$session" "$csrf" "Test")
    send_message "$session" "$csrf" "$chat_session" "hi" "" > /dev/null
    message_id=$(sqlite3 .store/store.db "SELECT id FROM agent_message WHERE role='assistant' ORDER BY id DESC LIMIT 1;")

    output=$(printf '{"message_id":%s,"feedback":"up"}' "$message_id" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/chat-widget-feedback" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" HTTP_X_CSRF_TOKEN="${csrf}" AGENT_PROVIDER=test "$BIN")
    [[ "$output" =~ '"ok":true' ]]
    run sqlite3 .store/store.db "SELECT user_feedback FROM knowledge_chat_eval WHERE message_id = ${message_id};"
    [[ "$output" == "up" ]]

    read alice_session alice_csrf < <(session_for alice secret123)
    output=$(printf '{"message_id":%s,"feedback":"down"}' "$message_id" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/chat-widget-feedback" QUERY_STRING="" \
        HTTP_COOKIE="session=${alice_session}; csrf=${alice_csrf}" HTTP_X_CSRF_TOKEN="${alice_csrf}" AGENT_PROVIDER=test "$BIN")
    [[ "$output" =~ "404 Not Found" ]]
    run sqlite3 .store/store.db "SELECT user_feedback FROM knowledge_chat_eval WHERE message_id = ${message_id};"
    [[ "$output" == "up" ]]
}
