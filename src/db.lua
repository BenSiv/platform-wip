-- Thin adapter over Luam's database module -- now spans two backends
-- (SQLite and MariaDB, see doc/mariadb-migration.md), selected per
-- deployment via config.db_backend(). Every function above this file
-- keeps calling db.query/db.exec/db.quote/db.literal/db.table_exists/
-- db.get_tables/db.get_columns exactly as before -- db_path itself is
-- still a fully opaque value to every one of those ~150 call sites,
-- it's just either a SQLite file path (a string, from config.db_path)
-- or a MariaDB connection descriptor (a table, same function, once a
-- deployment sets PLATFORM_DB_BACKEND=mariadb). Dispatch below is by
-- db_path's own shape (type(db_path) == "table"), not a config lookup
-- from inside this file -- config.lua requiring db.lua back would be
-- circular, and every caller already has db_path in scope regardless.

database = require("database")

db = {}

function is_mariadb(db_path)
    return type(db_path) == "table"
end

function db.query(db_path, query, ...)
    if is_mariadb(db_path) then
        return database.mariadb_query(db_path, query, ...)
    end
    return database.sqlite_query(db_path, query, ...)
end

function db.exec(db_path, statement, ...)
    if is_mariadb(db_path) then
        return database.mariadb_update(db_path, statement, ...)
    end
    return database.sqlite_update(db_path, statement, ...)
end

-- database.get_tables/get_columns go through a different sqlite binding
-- entry point (sqlite.rows(db, query), a db-level convenience call) than
-- sqlite_query's sqlite.prepare + stmt.rows/nrows -- and that path returns
-- no rows even when the query is correct (confirmed: entity_field/entity
-- tables are visibly populated via sqlite3 directly, but database.get_tables
-- reports none). Reimplemented here against the sqlite_query path, which
-- is the one actually verified working throughout this codebase.

function db.get_tables(db_path)
    query = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';"
    if is_mariadb(db_path) then
        query = "SELECT table_name AS name FROM information_schema.tables WHERE table_schema = DATABASE();"
    end
    rows = db.query(db_path, query)
    if rows == nil then
        return {}
    end
    names = {}
    for _, row in ipairs(rows) do
        table.insert(names, row.name)
    end
    return names
end

function db.get_columns(db_path, table_name)
    query = "PRAGMA table_info(" .. table_name .. ");"
    if is_mariadb(db_path) then
        query = string.format(
            "SELECT column_name AS name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = %s ORDER BY ordinal_position;",
            db.quote(table_name)
        )
    end
    rows = db.query(db_path, query)
    if rows == nil then
        return {}
    end
    names = {}
    for _, row in ipairs(rows) do
        table.insert(names, row.name)
    end
    return names
end

function db.table_exists(db_path, table_name)
    query = string.format(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = %s;", db.quote(table_name)
    )
    if is_mariadb(db_path) then
        query = string.format(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = %s;",
            db.quote(table_name)
        )
    end
    rows = db.query(db_path, query)
    return rows != nil
end

-- Quotes a value as a safe SQL string literal: plain quote-doubling,
-- the same escaping platform.sqlite always used, no db_path/backend
-- parameter needed here. Correct for MariaDB too now that every
-- MariaDB connection sets NO_BACKSLASH_ESCAPES (see luam's
-- get_mariadb_connection) -- without that, a value containing a
-- literal backslash-letter sequence (a Windows path, a regex) would
-- silently come back transformed on read, even though quote-doubling
-- alone already safely closes the string boundary either way. Keeping
-- this a pure, backend-agnostic function (rather than threading
-- db_path through it) avoids a ripple through this codebase's ~65
-- other db.quote/db.literal call sites, none of which need to change.
function db.quote(value)
    return "'" .. string.gsub(tostring(value), "'", "''") .. "'"
end

-- Renders `value` as a safe SQL literal: NULL for nil, a quoted string
-- otherwise. Numbers/booleans are stringified and quoted too, which is
-- harmless for either backend's dynamic-enough typing and keeps
-- callers from needing two code paths.
function db.literal(value)
    if value == nil then
        return "NULL"
    end
    return db.quote(value)
end

-- The remaining four helpers below are for MariaDB migration Phase 3
-- (see doc/mariadb-migration.md): every other file's SQLite-dialect
-- DDL/DML tokens (AUTOINCREMENT, datetime('now','localtime'),
-- INSERT OR REPLACE/IGNORE) route through these instead of being
-- hardcoded, so db_path's backend decides the actual SQL text at the
-- one call site that already has db_path in scope -- no change needed
-- to db_path's own threading anywhere else.

-- SQL expression for "the current timestamp", backend-appropriate.
-- Embed directly into a query string via string.format's %s.
function db.now_expr(db_path)
    if is_mariadb(db_path) then
        return "NOW()"
    end
    return "datetime('now', 'localtime')"
end

-- The auto-increment keyword for an `INTEGER PRIMARY KEY <this>` column
-- declaration. Only the keyword differs between engines -- SQLite
-- requires the type name spelled exactly "INTEGER" for its rowid-alias
-- behavior, but MariaDB doesn't care whether it's INTEGER or INT, so
-- the surrounding "INTEGER PRIMARY KEY" text stays the same for both.
function db.autoincrement_keyword(db_path)
    if is_mariadb(db_path) then
        return "AUTO_INCREMENT"
    end
    return "AUTOINCREMENT"
end

-- Upsert-by-replace statement prefix (goes before "<table> (<cols>) VALUES ...").
-- MariaDB's REPLACE INTO needs no "INSERT OR" prefix; semantics match
-- SQLite's INSERT OR REPLACE closely enough for this codebase's usage
-- (no foreign-key constraints exist yet for its delete+insert behavior
-- to disturb).
function db.replace_into(db_path)
    if is_mariadb(db_path) then
        return "REPLACE INTO"
    end
    return "INSERT OR REPLACE INTO"
end

-- Insert-ignoring-conflicts statement prefix (goes before "<table> (<cols>) VALUES ...").
function db.insert_ignore(db_path)
    if is_mariadb(db_path) then
        return "INSERT IGNORE INTO"
    end
    return "INSERT OR IGNORE INTO"
end

-- Column reference for a `CREATE INDEX ... ON table(<this>)` clause,
-- safe to use on a TEXT column of unbounded length. MariaDB/InnoDB
-- refuses a bare TEXT/BLOB column in ANY index (not just a primary
-- key) without an explicit prefix length ("BLOB/TEXT column ... used
-- in key specification without a key length") -- confirmed live. A
-- 255-char prefix is plenty for this codebase's actual indexed TEXT
-- columns (content hashes, external ids). SQLite has no equivalent
-- prefix-length syntax at all (it would be a syntax error there), so
-- this can't be unified into one string the way VARCHAR(255) unified
-- the primary-key case -- has to branch.
function db.text_index_column(db_path, column_name)
    if is_mariadb(db_path) then
        return column_name .. "(255)"
    end
    return column_name
end

return db
