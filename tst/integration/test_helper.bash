# tst/integration/test_helper.bash
# Shared setup for bats CLI/CGI integration tests -- each test gets a
# fresh scratch directory (never the repo root, to avoid colliding with
# a developer's own .store/ store) and the real, built binary.

resolve_bin() {
    if [ -x "$PROJECT_ROOT/bin/platform" ]; then
        BIN="$PROJECT_ROOT/bin/platform"
    else
        BIN="platform"
    fi
}

setup_test_env() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    resolve_bin
    export TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

cleanup_test_env() {
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_DIR"
}

# Creates a user (via the real `user add` CLI command, bcrypt hash and
# all) and logs them in through a real CGI POST to /login -- not a
# shortcut env-var stub. Echoes "<session_cookie> <csrf_token>"
# (space-separated; both values are plain hex/dot-delimited, so a
# space is a safe separator) for the caller to capture with `read`.
login_test_user() {
    local login="$1"
    local cap="$2"
    "$BIN" user add "$login" "testpass123" "$cap" >/dev/null

    local raw
    raw=$(printf 'login=%s&password=testpass123' "$login" | \
        GATEWAY_INTERFACE="CGI/1.1" REQUEST_METHOD="POST" PATH_INFO="/login" QUERY_STRING="" "$BIN")

    local session_cookie csrf_token
    session_cookie=$(printf '%s' "$raw" | grep -o 'Set-Cookie: session=[^;[:space:]]*' | head -1 | sed 's/^Set-Cookie: session=//')
    csrf_token=$(printf '%s' "$raw" | grep -o 'Set-Cookie: csrf=[^;[:space:]]*' | head -1 | sed 's/^Set-Cookie: csrf=//')

    echo "${session_cookie} ${csrf_token}"
}

# Runs the binary in real CGI mode -- the same GATEWAY_INTERFACE
# env-var trigger a real web server's CGI/FastCGI invocation would use
# (see main.lua's main()), not the CLI dispatch. Attaches a real,
# previously-logged-in session (TEST_SESSION_COOKIE/TEST_CSRF_TOKEN,
# baseline "i" capability -- see login_test_user, called from each
# bats file's own setup()).
run_cgi() {
    local path_info="$1"
    local query_string="${2:-}"
    local method="${3:-GET}"
    GATEWAY_INTERFACE="CGI/1.1" \
    REQUEST_METHOD="$method" \
    PATH_INFO="$path_info" \
    QUERY_STRING="$query_string" \
    HTTP_COOKIE="session=${TEST_SESSION_COOKIE}; csrf=${TEST_CSRF_TOKEN}" \
    HTTP_X_CSRF_TOKEN="${TEST_CSRF_TOKEN}" \
    run "$BIN"
}

# Same as run_cgi, but authenticated as a "is" (Setup+Admin) capability
# user -- for routes gated above the baseline "i" capability (/sql).
run_cgi_admin() {
    local path_info="$1"
    local query_string="${2:-}"
    local method="${3:-GET}"
    GATEWAY_INTERFACE="CGI/1.1" \
    REQUEST_METHOD="$method" \
    PATH_INFO="$path_info" \
    QUERY_STRING="$query_string" \
    HTTP_COOKIE="session=${ADMIN_SESSION_COOKIE}; csrf=${ADMIN_CSRF_TOKEN}" \
    HTTP_X_CSRF_TOKEN="${ADMIN_CSRF_TOKEN}" \
    run "$BIN"
}
