-- Real login/session auth, replacing cgi.lua's Phase 0
-- AUTH_USER/AUTH_CAPABILITIES/AUTH_NONCE env-var stub.
--
-- Password storage: bcrypt (require("bcrypt"), luam/lib/bcrypt/bcrypt.c).
-- Session cookies: stateless, not server-side session rows -- the
-- cookie itself is "<login>.<expiry_unix>.<hmac_hex>", verified with
-- require("hmac").sha256 keyed by a per-store secret generated once at
-- init (config.session_secret_path) and never transmitted. Capabilities
-- are deliberately NOT embedded in the cookie: they're looked up fresh
-- from the user table on every request, so a capability change or
-- archive takes effect on the user's very next request rather than
-- only after their session cookie expires.
-- CSRF: a separate, unsigned random token, double-submitted (cookie +
-- request field/header must match) -- doesn't need HMAC signing since
-- it's only ever compared to itself, not decoded or trusted alone.

db = require("db")
paths = require("paths")
bcrypt = require("bcrypt")
hmac = require("hmac")

auth = {}

SESSION_TTL_SECONDS = 60 * 60 * 24 * 7 -- 7 days

auth.SCHEMA = """
-- VARCHAR(255), not TEXT -- MariaDB/InnoDB refuses a bare TEXT column
-- as a key without an explicit length; see ledger.lua's own SCHEMA
-- comment for the full reasoning.
CREATE TABLE IF NOT EXISTS user (
    login VARCHAR(255) PRIMARY KEY,
    password_hash TEXT NOT NULL,
    cap TEXT NOT NULL DEFAULT '',
    created_at TEXT DEFAULT (%s),
    archived_at TEXT
);
"""

function auth.init_schema(db_path)
    return db.exec(db_path, string.format(auth.SCHEMA, db.now_expr(db_path)))
end

-- A per-store HMAC secret, generated once from /dev/urandom and never
-- rotated automatically (rotating it invalidates every outstanding
-- session cookie, so that's an explicit operator action, not implicit
-- request-time behavior).
function auth.ensure_session_secret(root)
    config = require("config")
    path = config.session_secret_path(root)
    if paths.file_exists(path) then
        return true
    end

    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return nil, "cannot open /dev/urandom"
    end
    raw = io.read(urandom, 32)
    io.close(urandom)
    if raw == nil or string.len(raw) != 32 then
        return nil, "short read from /dev/urandom"
    end

    secret = hex_encode(raw)
    file = io.open(path, "w")
    if file == nil then
        return nil, "cannot create session secret file: " .. path
    end
    io.write(file, secret)
    io.close(file)
    return true
end

function auth.session_secret(root)
    config = require("config")
    path = config.session_secret_path(root)
    file = io.open(path, "r")
    if file == nil then
        return nil, "no session secret at " .. path .. " -- run 'platform init' first"
    end
    secret = io.read(file, "*all")
    io.close(file)
    return secret
end

function hex_encode(bytes)
    hex = {}
    for i = 1, string.len(bytes) do
        table.insert(hex, string.format("%02x", string.byte(bytes, i)))
    end
    return table.concat(hex)
end

function random_hex_token(num_bytes)
    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return nil, "cannot open /dev/urandom"
    end
    raw = io.read(urandom, num_bytes)
    io.close(urandom)
    if raw == nil or string.len(raw) != num_bytes then
        return nil, "short read from /dev/urandom"
    end
    return hex_encode(raw)
end

-- Not a full constant-time comparison across arbitrary lengths (Lua's
-- string library gives no cheaper primitive), but both inputs here are
-- always fixed-length hex digests/tokens, so length itself leaks
-- nothing an attacker doesn't already know.
function constant_time_equal(a, b)
    if string.len(a) != string.len(b) then
        return false
    end
    diff = 0
    for i = 1, string.len(a) do
        if string.byte(a, i) != string.byte(b, i) then
            diff = diff + 1
        end
    end
    return diff == 0
end

--------------------------------------------------------------------------
-- User management
--------------------------------------------------------------------------

function auth.create_user(db_path, login, password, cap)
    if login == nil or login == "" then
        return nil, "login is required"
    end
    -- Session cookies encode "<login>.<expiry>.<sig>" with "." as the
    -- field separator, so a login containing "." would make its own
    -- cookie unparseable.
    if string.find(login, ".", 1, true) != nil then
        return nil, "login cannot contain '.'"
    end
    if password == nil or password == "" then
        return nil, "password is required"
    end
    if cap == nil then
        cap = ""
    end

    existing = auth.get_user(db_path, login)
    if existing != nil then
        return nil, "user already exists: " .. login
    end

    hash = bcrypt.hash(password, 12)
    db.exec(db_path, string.format(
        "INSERT INTO user (login, password_hash, cap) VALUES (%s, %s, %s);",
        db.quote(login), db.quote(hash), db.quote(cap)
    ))
    return login
end

function auth.get_user(db_path, login)
    rows = db.query(db_path, string.format(
        "SELECT * FROM user WHERE login = %s;", db.quote(login)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function auth.list_users(db_path, include_archived)
    q = "SELECT login, cap, created_at, archived_at FROM user"
    if include_archived != true then
        q = q .. " WHERE archived_at IS NULL"
    end
    q = q .. " ORDER BY login ASC;"
    rows = db.query(db_path, q)
    if rows == nil then
        return {}
    end
    return rows
end

function auth.set_password(db_path, login, password)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    hash = bcrypt.hash(password, 12)
    db.exec(db_path, string.format(
        "UPDATE user SET password_hash = %s WHERE login = %s;", db.quote(hash), db.quote(login)
    ))
    return true
end

function auth.set_capabilities(db_path, login, cap)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    db.exec(db_path, string.format(
        "UPDATE user SET cap = %s WHERE login = %s;", db.quote(cap), db.quote(login)
    ))
    return true
end

-- Archive/unarchive, not delete -- same nullable-timestamp convention
-- as entity.lua's archived_at, so a login can never be silently wiped;
-- an archived user just can no longer authenticate (see auth.login).
function auth.archive_user(db_path, login)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    db.exec(db_path, string.format(
        "UPDATE user SET archived_at = %s WHERE login = %s;", db.now_expr(db_path), db.quote(login)
    ))
    return true
end

function auth.unarchive_user(db_path, login)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "no such user: " .. login
    end
    db.exec(db_path, string.format(
        "UPDATE user SET archived_at = NULL WHERE login = %s;", db.quote(login)
    ))
    return true
end

--------------------------------------------------------------------------
-- Login + session cookies
--------------------------------------------------------------------------

-- auth.login(db_path, login, password) -> cap_string | nil, err_string
function auth.login(db_path, login, password)
    user = auth.get_user(db_path, login)
    if user == nil then
        return nil, "invalid login or password"
    end
    if user.archived_at != nil and user.archived_at != "" then
        return nil, "invalid login or password"
    end
    if not bcrypt.verify(password, user.password_hash) then
        return nil, "invalid login or password"
    end
    return user.cap
end

function cookie_signature(secret, login, expiry)
    return hmac.sha256(secret, login .. "." .. tostring(expiry))
end

-- auth.issue_session_cookie(root, login) -> cookie_value_string | nil, err
function auth.issue_session_cookie(root, login)
    secret, err = auth.session_secret(root)
    if secret == nil then
        return nil, err
    end
    expiry = os.time() + SESSION_TTL_SECONDS
    sig = cookie_signature(secret, login, expiry)
    return login .. "." .. tostring(expiry) .. "." .. sig
end

-- auth.verify_session_cookie(root, cookie_value) -> login_string | nil, err
function auth.verify_session_cookie(root, cookie_value)
    if cookie_value == nil or cookie_value == "" then
        return nil, "no session cookie"
    end
    secret, err = auth.session_secret(root)
    if secret == nil then
        return nil, err
    end

    login, expiry_str, sig = string.match(cookie_value, "^(.-)%.(%d+)%.(%x+)$")
    if login == nil then
        return nil, "malformed session cookie"
    end
    expiry = tonumber(expiry_str)
    if expiry == nil or os.time() > expiry then
        return nil, "expired session"
    end

    expected_sig = cookie_signature(secret, login, expiry)
    if not constant_time_equal(sig, expected_sig) then
        return nil, "invalid session signature"
    end
    return login
end

--------------------------------------------------------------------------
-- CSRF (double-submit cookie)
--------------------------------------------------------------------------

function auth.generate_csrf_token()
    token, err = random_hex_token(24)
    if token == nil then
        return nil, err
    end
    return token
end

-- A fresh per-request CSP nonce (replacing the old AUTH_NONCE env-var
-- stub, which used to relay Fossil's own per-request CSP nonce -- there
-- is no Fossil wrapper providing one anymore). Same shape as a CSRF
-- token but a distinct name since the two are semantically unrelated
-- (one gates inline <script> execution via CSP, the other guards
-- against cross-site form submission).
function auth.generate_nonce()
    nonce, err = random_hex_token(16)
    if nonce == nil then
        return nil, err
    end
    return nonce
end

function auth.verify_csrf(cookie_token, submitted_token)
    if cookie_token == nil or submitted_token == nil then
        return false
    end
    if cookie_token == "" or submitted_token == "" then
        return false
    end
    return constant_time_equal(cookie_token, submitted_token)
end

--------------------------------------------------------------------------
-- CLI: `platform user <add|passwd|capabilities|list|archive|unarchive> ...`
--------------------------------------------------------------------------

function auth.do_user(cmd_args, db_path)
    action = cmd_args[1]

    if action == "add" then
        login = cmd_args[2]
        password = cmd_args[3]
        cap = cmd_args[4]
        if login == nil or password == nil then
            print("Usage: platform user add <login> <password> [cap]")
            return
        end
        ok, err = auth.create_user(db_path, login, password, cap)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Created user " .. login)
        return
    end

    if action == "passwd" then
        login = cmd_args[2]
        password = cmd_args[3]
        if login == nil or password == nil then
            print("Usage: platform user passwd <login> <new_password>")
            return
        end
        ok, err = auth.set_password(db_path, login, password)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Password updated for " .. login)
        return
    end

    if action == "capabilities" then
        login = cmd_args[2]
        cap = cmd_args[3]
        if login == nil or cap == nil then
            print("Usage: platform user capabilities <login> <cap_string>")
            return
        end
        ok, err = auth.set_capabilities(db_path, login, cap)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Capabilities updated for " .. login .. ": " .. cap)
        return
    end

    if action == "list" then
        include_archived = false
        for _, a in ipairs(cmd_args) do
            if a == "--include-archived" then
                include_archived = true
            end
        end
        users = auth.list_users(db_path, include_archived)
        for _, u in ipairs(users) do
            status = "active"
            if u.archived_at != nil and u.archived_at != "" then
                status = "archived"
            end
            print(string.format("%s  cap=%s  %s", u.login, u.cap, status))
        end
        return
    end

    if action == "archive" then
        login = cmd_args[2]
        if login == nil then
            print("Usage: platform user archive <login>")
            return
        end
        ok, err = auth.archive_user(db_path, login)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Archived user " .. login)
        return
    end

    if action == "unarchive" then
        login = cmd_args[2]
        if login == nil then
            print("Usage: platform user unarchive <login>")
            return
        end
        ok, err = auth.unarchive_user(db_path, login)
        if ok == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Unarchived user " .. login)
        return
    end

    print("Usage: platform user <add|passwd|capabilities|list|archive|unarchive> ...")
end

return auth
