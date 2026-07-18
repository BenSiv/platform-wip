-- Custom SQL-query views: a named, read-only SELECT query rendered as
-- a generic table, defined the same way schemas/extensions are (a
-- Luam table file, version-controlled alongside them). A view has
-- direct database access the same way an extension does, so it goes
-- through the same admin-approval registry -- approving records the
-- exact SQL text at approval time, and if the file is edited
-- afterward, the view is unapproved again until re-approved (same
-- escalation-detection principle as extension.capabilities_equal, just
-- keyed on the query text instead of a capabilities table).

db = require("db")
json = require("dkjson")
paths = require("paths")
lfs = require("lfs")
sandbox = require("sandbox")

view = {}

view.SCHEMA = """
CREATE TABLE IF NOT EXISTS view_approval (
    name TEXT PRIMARY KEY,
    sql_text TEXT NOT NULL,
    approved_by TEXT,
    approved_at TEXT DEFAULT (datetime('now', 'localtime'))
);
"""

function view.init_schema(db_path)
    return db.exec(db_path, view.SCHEMA)
end

function read_file(path)
    file = io.open(path, "r")
    if file == nil then
        return nil
    end
    source = io.read(file, "*all")
    io.close(file)
    return source
end

function view.names(views_dir)
    names = {}
    attr = lfs.attributes(views_dir)
    if attr == nil or attr.mode != "directory" then
        return names
    end
    for dir_name in lfs.dir(views_dir) do
        if dir_name != "." and dir_name != ".." then
            if string.match(dir_name, "%.lua$") != nil then
                name = string.gsub(dir_name, "%.lua$", "")
                table.insert(names, name)
            end
        end
    end
    return names
end

-- Rejects anything but a single, plain SELECT statement: no stacked
-- statements (a ";" anywhere but optionally trailing), and no
-- DDL/DML/pragma/attach keywords, matched on word boundaries (not bare
-- substring search -- fossci's own tables have columns like
-- updated_at/updated_by, which a naive substring check for "update"
-- would wrongly reject).
FORBIDDEN_SQL_WORDS = {
    "insert", "update", "delete", "drop", "alter", "attach", "detach",
    "pragma", "create", "replace", "vacuum", "reindex", "trigger", "exec",
}

function view.is_select_only(sql_text)
    trimmed = string.gsub(sql_text, "^%s+", "")
    trimmed = string.gsub(trimmed, "%s+$", "")
    lowered = string.lower(trimmed)
    if string.find(lowered, "^select") == nil then
        return false
    end

    body = trimmed
    if string.sub(trimmed, -1) == ";" then
        body = string.sub(trimmed, 1, -2)
    end
    if string.find(body, ";") != nil then
        return false
    end

    for _, word in ipairs(FORBIDDEN_SQL_WORDS) do
        if string.find(lowered, "%f[%a]" .. word .. "%f[%A]") != nil then
            return false
        end
    end
    return true
end

-- A view may declare at most one runtime parameter (e.g. scoping a
-- lookup to one experiment's samples), bound through sqlite's own
-- prepared-statement API (view.run below) -- never string-interpolated
-- into the SQL text, so there's no injection surface from the value
-- itself regardless of type. `type` controls the coercion applied
-- before binding, not any kind of SQL-text validation.
PARAM_TYPES = {"integer", "number", "text"}

function is_valid_param_type(t)
    for _, valid in ipairs(PARAM_TYPES) do
        if t == valid then
            return true
        end
    end
    return false
end

function view.validate(def)
    if type(def.name) != "string" or def.name == "" then
        return "view must have a non-empty string 'name'"
    end
    if type(def.sql) != "string" or def.sql == "" then
        return "view '" .. tostring(def.name) .. "' must have a non-empty string 'sql'"
    end
    if view.is_select_only(def.sql) == false then
        return "view '" .. tostring(def.name) .. "': sql must be a single, plain SELECT statement (no ';', no DDL/DML/pragma)"
    end
    if type(def.columns) != "table" or #def.columns == 0 then
        return "view '" .. tostring(def.name) .. "' must have a non-empty 'columns' list"
    end
    for i, col in ipairs(def.columns) do
        if type(col.name) != "string" or col.name == "" then
            return string.format("view '%s' column #%d: missing 'name'", def.name, i)
        end
    end
    if def.param != nil then
        if type(def.param.name) != "string" or def.param.name == "" then
            return "view '" .. tostring(def.name) .. "': param must have a non-empty string 'name'"
        end
        -- "id" and "name" are confirmed to collide with Fossil's own
        -- /ext dispatch parameters (see doc/deployment.md) -- a query
        -- param with either of these names never reaches fossci at
        -- all, so reject them here rather than let an author discover
        -- it as a mysterious 404 later.
        if def.param.name == "id" or def.param.name == "name" then
            return "view '" .. tostring(def.name) .. "': param name can't be 'id' or 'name' -- both collide with Fossil's own /ext dispatch (see doc/deployment.md)"
        end
        if is_valid_param_type(def.param.type) == false then
            return "view '" .. tostring(def.name) .. "': param 'type' must be one of integer/number/text"
        end
    end
    -- Optional: which single entity type this view is primarily about,
    -- if any (a view can join across types, so there isn't always one --
    -- see html.render_view's own comment). Purely a rendering hint for
    -- the "+ Register new" link; not cross-checked against schema.list()
    -- here since view.load/validate has no db_path to check against --
    -- a typo'd name just means a broken register link, not a security
    -- concern (the /register route validates the type itself).
    if def.entity_type != nil and (type(def.entity_type) != "string" or def.entity_type == "") then
        return "view '" .. tostring(def.name) .. "': entity_type must be a non-empty string if present"
    end
    return nil
end

function view.load(views_dir, name)
    path = paths.joinpath(views_dir, name .. ".lua")
    source = read_file(path)
    if source == nil then
        return nil, "cannot open view: " .. path
    end
    ok, result = sandbox.run(source, path, sandbox.data_env())
    if ok == false or type(result) != "table" then
        return nil, "error loading view " .. path .. ": " .. tostring(result)
    end
    err = view.validate(result)
    if err != nil then
        return nil, err
    end
    return result
end

function view.all(views_dir)
    result = {}
    for _, name in ipairs(view.names(views_dir)) do
        def, err = view.load(views_dir, name)
        table.insert(result, {name = name, def = def, err = err})
    end
    return result
end

function view.approved_sql(db_path, name)
    view.init_schema(db_path)
    rows = db.query(db_path, "SELECT sql_text FROM view_approval WHERE name = " .. db.quote(name) .. ";")
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1].sql_text
end

function view.is_approved(db_path, def)
    approved = view.approved_sql(db_path, def.name)
    if approved == nil then
        return false
    end
    return approved == def.sql
end

function view.approve(db_path, def, approved_by)
    view.init_schema(db_path)
    db.exec(db_path, string.format(
        "INSERT OR REPLACE INTO view_approval (name, sql_text, approved_by, approved_at) VALUES (%s, %s, %s, datetime('now', 'localtime'));",
        db.quote(def.name), db.quote(def.sql), db.literal(approved_by)
    ))
end

function view.revoke(db_path, name)
    view.init_schema(db_path)
    db.exec(db_path, "DELETE FROM view_approval WHERE name = " .. db.quote(name) .. ";")
end

-- Runs an approved view's query. `param_value` is required iff the
-- view declares `param` (ignored otherwise). Returns (rows, err) --
-- rows is a list of {column_name = value} tables either way.
function view.run(db_path, def, param_value)
    if view.is_select_only(def.sql) == false then
        return nil, "refusing to run: not a plain SELECT"
    end

    if def.param == nil then
        rows = db.query(db_path, def.sql)
        if rows == nil then
            return {}
        end
        return rows
    end

    return run_parameterized(db_path, def, param_value)
end

-- Real bind-parameter execution -- never string-interpolated into the
-- SQL text, unlike everything else in this file (db.exec/db.query's
-- own %s substitution is fine for identifiers/literals fossci itself
-- builds, but a runtime-supplied filter value needs the real thing).
-- sqlite3 isn't shared as a global across modules in Luam (each
-- require() gets its own reference; see src/db.lua for the same
-- require), so it's pulled in locally here rather than assumed
-- available.
function run_parameterized(db_path, def, param_value)
    bind_value = param_value
    if def.param.type == "integer" or def.param.type == "number" then
        bind_value = tonumber(param_value)
        if bind_value == nil then
            return nil, "parameter '" .. def.param.name .. "' must be a number"
        end
    elseif param_value == nil or param_value == "" then
        return nil, "missing required parameter '" .. def.param.name .. "'"
    end

    sqlite3 = require("sqlite3")
    conn = sqlite3.open(db_path)
    if conn == nil then
        return nil, "cannot open database"
    end

    vm, err = sqlite3.prepare(conn, def.sql)
    if vm == nil then
        sqlite3.close(conn)
        return nil, "invalid sql: " .. tostring(err)
    end
    if sqlite3.stmt.bind_parameter_count(vm) != 1 then
        sqlite3.stmt.finalize(vm)
        sqlite3.close(conn)
        return nil, "view declares a param but sql doesn't have exactly one '?' placeholder"
    end

    bind_rc = sqlite3.stmt.bind(vm, 1, bind_value)
    if bind_rc != 0 then
        sqlite3.stmt.finalize(vm)
        sqlite3.close(conn)
        return nil, "failed to bind parameter"
    end

    rows = {}
    for row in sqlite3.stmt.nrows(vm) do
        table.insert(rows, row)
    end
    sqlite3.stmt.finalize(vm)
    sqlite3.close(conn)
    return rows
end

-- Ad-hoc, unsaved SELECT execution against the entity store -- for
-- one-off exploration, not embeddable/shareable content, so unlike a
-- named view there's nothing to approve (the caller enforcing Setup/
-- Admin capability -- see cgi.lua's /sql route -- already *is* the
-- approval: nobody untrusted can reach this). Still SELECT-only via
-- the same is_select_only guard, and returns column names separately
-- from db.query's rows (which are unordered Lua tables keyed by
-- column name) so results render with real, ordered headers even for
-- an empty result set.
-- Best-effort single-table guess for "which table is this query
-- primarily about" -- used for the "id" self-reference special case in
-- cgi.lua (the queried table's own id column). Still just the first
-- `FROM <table>` match, alias discarded (a result column is looked up
-- by its own name, not by qualified alias.column, so the alias itself
-- is never needed). See guess_tables below for the full table list a
-- query reads from, joins included.
function view.guess_from_table(sql_text)
    table_name = string.match(sql_text, "[Ff][Rr][Oo][Mm]%s+([A-Za-z_][A-Za-z0-9_]*)")
    return table_name
end

-- Best-effort guess of every table a query reads from: the primary
-- FROM table plus any JOINed tables -- INNER/LEFT/RIGHT/OUTER/CROSS
-- JOIN all end in the literal word "JOIN" immediately before the table
-- name, so one case-insensitive match covers every join variant.
-- Still string-matching, not a real SQL parser: comma-joins ("FROM a,
-- b"), subqueries, and CTEs aren't covered, and each table's alias (if
-- any) is discarded -- reference_columns below only needs the real
-- table name to look up entity_field metadata, since a query's result
-- columns are keyed by their own (possibly aliased-away) name, not by
-- qualified alias.column.
function view.guess_tables(sql_text)
    tables = {}
    seen = {}
    from_table = view.guess_from_table(sql_text)
    if from_table != nil then
        table.insert(tables, from_table)
        seen[from_table] = true
    end
    for joined in string.gmatch(sql_text, "[Jj][Oo][Ii][Nn]%s+([A-Za-z_][A-Za-z0-9_]*)") do
        if seen[joined] == nil then
            table.insert(tables, joined)
            seen[joined] = true
        end
    end
    return tables
end

-- {column_name -> ref_entity_type} for a set of tables' reference-type
-- fields, via the same entity_field metadata schema.layout() already
-- exposes (see html.lua's display_field_value) -- used here directly by
-- table name since an ad-hoc query has no schema.layout() call of its
-- own. Accepts either a single table name (back-compat for callers that
-- only ever guessed one table) or a list (see guess_tables) -- merged in
-- list order, first table wins a column-name collision, so a query's
-- primary FROM table takes precedence over a joined table that happens
-- to reuse the same column name.
function view.reference_columns(db_path, table_names)
    columns = {}
    if table_names == nil then
        return columns
    end
    if type(table_names) == "string" then
        table_names = {table_names}
    end
    for _, table_name in ipairs(table_names) do
        rows = db.query(db_path, string.format(
            "SELECT name, ref_entity_type FROM entity_field WHERE entity_type = %s AND type = 'reference';",
            db.quote(table_name)
        ))
        if rows != nil then
            for _, row in ipairs(rows) do
                if columns[row.name] == nil then
                    columns[row.name] = row.ref_entity_type
                end
            end
        end
    end
    return columns
end

function view.run_adhoc(db_path, sql_text)
    if view.is_select_only(sql_text) == false then
        return nil, nil, "refusing to run: not a plain SELECT"
    end

    sqlite3 = require("sqlite3")
    conn = sqlite3.open(db_path)
    if conn == nil then
        return nil, nil, "cannot open database"
    end

    vm, err = sqlite3.prepare(conn, sql_text)
    if vm == nil then
        sqlite3.close(conn)
        return nil, nil, "invalid sql: " .. tostring(err)
    end

    column_names = sqlite3.stmt.get_names(vm)
    rows = {}
    for row in sqlite3.stmt.nrows(vm) do
        table.insert(rows, row)
    end
    sqlite3.stmt.finalize(vm)
    sqlite3.close(conn)
    return column_names, rows
end

-- CLI entry point: `fossci view <list|show|approve|revoke> [args]`
function view.do_view(cmd_args, db_path)
    config = require("config")
    views_dir = config.views_dir()
    action = cmd_args[1]

    if action == "list" then
        for _, entry in ipairs(view.all(views_dir)) do
            if entry.def == nil then
                print(string.format("%-20s ERROR: %s", entry.name, entry.err))
            else
                status = "not approved"
                if view.is_approved(db_path, entry.def) then
                    status = "approved"
                end
                print(string.format("%-20s %-14s %s", entry.name, status, entry.def.sql))
            end
        end
        return
    end

    if action == "show" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: fossci view show <name>")
            return
        end
        def, err = view.load(views_dir, name)
        if def == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("name: " .. def.name)
        print("sql:  " .. def.sql)
        if view.is_approved(db_path, def) then
            print("status: approved")
        elseif view.approved_sql(db_path, name) == nil then
            print("status: not approved")
        else
            print("status: NOT APPROVED -- sql changed since last approval, re-approval required")
        end
        return
    end

    if action == "approve" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: fossci view approve <name>")
            return
        end
        def, err = view.load(views_dir, name)
        if def == nil then
            print("Error: " .. tostring(err))
            return
        end
        view.approve(db_path, def, os.getenv("USER"))
        print("Approved '" .. name .. "'")
        return
    end

    if action == "revoke" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: fossci view revoke <name>")
            return
        end
        view.revoke(db_path, name)
        print("Revoked '" .. name .. "'")
        return
    end

    print("Usage: fossci view <list|show|approve|revoke> [args]")
end

return view
