#!/usr/bin/env bash
set -euo pipefail

VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: ./bld/build.sh [options]

Options:
  -v, --verbose   Print full build command output
  -h, --help      Show this help
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage." >&2
            exit 1
            ;;
    esac
done

run_cmd() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        "$@"
    else
        "$@" >>"$BUILD_LOG" 2>&1
    fi
}

on_error() {
    if [[ "$VERBOSE" -eq 0 ]]; then
        echo "Build failed. Re-run with --verbose for full output." >&2
        echo "Last build log lines:" >&2
        tail -n 40 "$BUILD_LOG" >&2 || true
    fi
}

# Create temp dir
TMPDIR=$(mktemp -d)
BUILD_LOG=$(mktemp)
trap on_error ERR
trap 'rm -rf "$TMPDIR" "$BUILD_LOG"' EXIT

# Change to project root (one level up from bld/)
cd "$(dirname "$0")/.."

# Determine absolute paths (allow env override, default to sibling checkout)
if [ -z "${LUAM_DIR:-}" ]; then
    LUAM_DIR=$(cd ../luam && pwd)
fi
LUAM_BIN="$LUAM_DIR/bin/luam"
STATIC_TOOL="$LUAM_DIR/lib/static/init.lua"
LUAM_LIB="$LUAM_DIR/obj/liblua.a"

if [ ! -f "$LUAM_LIB" ]; then
    echo "Error: $LUAM_LIB not found. Set LUAM_DIR to a built luam checkout." >&2
    exit 1
fi

# Entry point filename -- placeholder "main.lua" until the project has
# a real name (see doc/backend-migration-plan.md in the fossci repo).
# Rename this + the ENTRY var below together when that's decided.
ENTRY="main.lua"
ENTRY_STEM="${ENTRY%.lua}"
BIN_NAME="platform"

echo "Preparing build"
# Copy this project's sources
run_cmd cp -R src/* "$TMPDIR"/

# Copy luam standard libraries
run_cmd cp "$LUAM_DIR/lib/"*.lua "$TMPDIR"/
run_cmd cp "$LUAM_DIR/lib/dkjson/init.lua" "$TMPDIR/dkjson.lua"

# Remove static.lua (tool) to prevent it from being compiled into the binary source list inadvertently
run_cmd rm -f "$TMPDIR"/static.lua

# Build
pushd "$TMPDIR" >/dev/null

# Construct file list; entry point must be first (main entry point)
FILES="$ENTRY $(find . -type f -name '*.lua' | grep -v "^\./${ENTRY}$" | sed 's|^\./||' | tr '\n' ' ')"

echo "Files to bundle: $FILES"
echo "Generating C source"
run_cmd env CC="" "$LUAM_BIN" "$STATIC_TOOL" \
    $FILES \
    "$LUAM_LIB" \
    -I "$LUAM_DIR/src" \
    -lm -ldl -lreadline -lpthread

# Inject lsqlite3, lfs, bcrypt, and hmac preload -- same reasoning as
# fossci's own build.sh for the first two (schemas/views/templates are
# plain Luam table files, no YAML/JSON parser needed; lfs is a native C
# extension that must be compiled and preload-injected rather than
# copied as a .lua file). bcrypt (luam/lib/bcrypt/bcrypt.c) and hmac
# (luam/lib/hmac/hmac.c) live in luam itself, not this project --
# generically useful bindings (any Luam project needing password
# hashing or HMAC signing can require("bcrypt")/require("hmac")),
# added there rather than duplicated per-project, matching how
# sqlite3/lfs already work. bcrypt is a thin wrapper over the
# platform's own crypt_gensalt/crypt_r bcrypt support
# (glibc/libxcrypt); hmac is a thin wrapper over OpenSSL libcrypto's
# HMAC-SHA256 -- neither is a vendored implementation, see each file's
# own header comment.
run_cmd sed -i '/luaL_openlibs(L);/a \
  int luaopen_sqlite3(lua_State *L); \
  int luaopen_lfs(lua_State *L); \
  int luaopen_bcrypt(lua_State *L); \
  int luaopen_hmac(lua_State *L); \
  lua_getglobal(L, "package"); \
  lua_getfield(L, -1, "preload"); \
  lua_pushcfunction(L, luaopen_sqlite3); \
  lua_setfield(L, -2, "sqlite3"); \
  lua_pushcfunction(L, luaopen_lfs); \
  lua_setfield(L, -2, "lfs"); \
  lua_pushcfunction(L, luaopen_bcrypt); \
  lua_setfield(L, -2, "bcrypt"); \
  lua_pushcfunction(L, luaopen_hmac); \
  lua_setfield(L, -2, "hmac"); \
  lua_pop(L, 2);' "${ENTRY_STEM}.static.c"

# Compile lsqlite3
run_cmd cc -c -O2 -I"$LUAM_DIR/src" "$LUAM_DIR/lib/sqlite/lsqlite3.c" -o lsqlite3.o

# Compile lfs
run_cmd cc -c -O2 -I"$LUAM_DIR/src" "$LUAM_DIR/lib/lfs/src/lfs.c" -o lfs.o

# Compile bcrypt binding
run_cmd cc -c -O2 -I"$LUAM_DIR/src" "$LUAM_DIR/lib/bcrypt/bcrypt.c" -o lbcrypt.o

# Compile hmac binding
run_cmd cc -c -O2 -I"$LUAM_DIR/src" "$LUAM_DIR/lib/hmac/hmac.c" -o lhmac.o

# Compile binary
run_cmd cc -Os "${ENTRY_STEM}.static.c" lsqlite3.o lfs.o lbcrypt.o lhmac.o "$LUAM_LIB" \
    -I "$LUAM_DIR/src" \
    -lm -ldl -lreadline -lpthread -lsqlite3 -lcrypt -lcrypto \
    -Wl,--export-dynamic \
    -o "$BIN_NAME"

popd >/dev/null

# bin/ holds only final binaries
run_cmd mkdir -p bin
run_cmd mv "$TMPDIR/$BIN_NAME" bin/
echo "Build complete. Binary in bin/$BIN_NAME"
if [[ "$VERBOSE" -eq 1 ]]; then
    ls -lh "bin/$BIN_NAME"
fi
