-- Thin adapter over Luam's sqlite-backed database module.
--
-- Kept deliberately small and isolated: v0 runs on SQLite because that's
-- what Luam actually ships a binding for (see doc/architecture.md,
-- "SQLite now, Postgres later"). Nothing above this file should call
-- sqlite3/database directly -- when a Postgres adapter is written, only
-- this file needs to change.

database = require("database")

db = {}

function db.query(db_path, query, ...)
    return database.local_query(db_path, query, ...)
end

function db.exec(db_path, statement, ...)
    return database.local_update(db_path, statement, ...)
end

-- database.get_tables/get_columns go through a different sqlite binding
-- entry point (sqlite.rows(db, query), a db-level convenience call) than
-- local_query's sqlite.prepare + stmt.rows/nrows -- and that path returns
-- no rows even when the query is correct (confirmed: entity_field/entity
-- tables are visibly populated via sqlite3 directly, but database.get_tables
-- reports none). Reimplemented here against the local_query path, which
-- is the one actually verified working throughout this codebase.

function db.get_tables(db_path)
    rows = db.query(db_path, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%';")
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
    rows = db.query(db_path, "PRAGMA table_info(" .. table_name .. ");")
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
    rows = db.query(db_path, string.format(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = %s;", db.quote(table_name)
    ))
    return rows != nil
end

-- Quotes a value as a SQLite string literal, escaping embedded quotes.
-- Uses database.escape_sqlite rather than re-implementing the same
-- one-line gsub -- that function was already there, just not exported.
function db.quote(value)
    return "'" .. database.escape_sqlite(value) .. "'"
end

-- Renders `value` as a safe SQL literal: NULL for nil, a quoted string
-- otherwise. Numbers/booleans are stringified and quoted too, which is
-- harmless for SQLite's dynamic typing and keeps callers from needing
-- two code paths.
function db.literal(value)
    if value == nil then
        return "NULL"
    end
    return db.quote(value)
end

return db
