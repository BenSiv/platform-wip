#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
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

@test "user add creates a login that can authenticate" {
    "$BIN" user add alice secret123 i
    run "$BIN" user list
    [[ "$output" =~ "alice" ]]
    [[ "$output" =~ "cap=i" ]]
}

@test "login with the correct password succeeds and issues session + csrf cookies" {
    "$BIN" user add alice secret123 i
    run raw_login alice secret123
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /" ]]
    [[ "$output" =~ "Set-Cookie: session=alice." ]]
    [[ "$output" =~ "HttpOnly" ]]
    [[ "$output" =~ "Set-Cookie: csrf=" ]]
}

@test "login with the wrong password is rejected without revealing whether the login exists" {
    "$BIN" user add alice secret123 i
    run raw_login alice wrongpass
    [[ "$output" =~ "401 Unauthorized" ]]
    [[ "$output" =~ "Invalid login or password" ]]

    run raw_login nosuchuser whatever
    [[ "$output" =~ "401 Unauthorized" ]]
    [[ "$output" =~ "Invalid login or password" ]]
}

@test "an archived user can no longer log in" {
    "$BIN" user add alice secret123 i
    "$BIN" user archive alice
    run raw_login alice secret123
    [[ "$output" =~ "401 Unauthorized" ]]
}

@test "a request with no session cookie is redirected to /login" {
    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" run "$BIN"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login" ]]
}

@test "a request with a tampered session cookie is redirected to /login" {
    "$BIN" user add alice secret123 i
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}tampered" run "$BIN"
    [[ "$output" =~ "302 Found" ]]
    [[ "$output" =~ "Location: /login" ]]
}

@test "a valid session cookie grants access, and logout clears it" {
    "$BIN" user add alice secret123 i
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/logout" QUERY_STRING="" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "Location: /login" ]]
    [[ "$output" =~ "Set-Cookie: session=; Path=/; Max-Age=0" ]]
    [[ "$output" =~ "Set-Cookie: csrf=; Path=/; Max-Age=0" ]]
}

@test "a capability change takes effect on the very next request, not only after the session expires" {
    "$BIN" user add alice secret123 ""
    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')

    mkdir -p schemas
    cat > schemas/widget.lua <<'EOF'
return {
  name = "widget",
  fields = { {name = "label", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/widget.lua

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/browse" QUERY_STRING="type=widget" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "403 Forbidden" ]]

    "$BIN" user capabilities alice i

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="GET" PATH_INFO="/browse" QUERY_STRING="type=widget" \
        HTTP_COOKIE="session=${session}" run "$BIN"
    [[ "$output" =~ "200 OK" ]]
}

@test "a mutating POST without the matching CSRF header is rejected" {
    "$BIN" user add alice secret123 i
    mkdir -p schemas
    cat > schemas/widget.lua <<'EOF'
return {
  name = "widget",
  fields = { {name = "label", type = "text", required = true} },
}
EOF
    "$BIN" schema add schemas/widget.lua
    "$BIN" entity create widget label=Test1

    raw=$(raw_login alice secret123)
    session=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;]*' | sed 's/Set-Cookie: session=//')
    csrf=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;]*' | sed 's/Set-Cookie: csrf=//')

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/archive" QUERY_STRING="type=widget&entity_id=1" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" run "$BIN"
    [[ "$output" =~ "403 Forbidden" ]]
    [[ "$output" =~ "CSRF check failed" ]]

    GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/api/archive" QUERY_STRING="type=widget&entity_id=1" \
        HTTP_COOKIE="session=${session}; csrf=${csrf}" HTTP_X_CSRF_TOKEN="${csrf}" run "$BIN"
    [[ "$output" =~ '"success":true' ]]
}
