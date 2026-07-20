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

return db
