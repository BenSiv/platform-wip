-- Schema-as-code: loads entity type definitions (Luam table files, see
-- doc/schema.md) and generates/migrates the real typed SQL table each
-- one describes. This is the only place field-type -> SQL-type mapping
-- happens.

db = require("db")
sandbox = require("sandbox")
paths = require("paths")
lfs = require("lfs")

schema = {}

FIELD_TYPES = {"text", "number", "date", "select", "reference"}

SQL_TYPE = {
    text = "TEXT",
    number = "REAL",
    date = "TEXT",
    select = "TEXT",
    reference = "INTEGER",
}

function is_valid_field_type(t)
    for _, valid in ipairs(FIELD_TYPES) do
        if t == valid then
            return true
        end
    end
    return false
end

-- Loads a schema definition from a Luam table file, sandboxed (see
-- doc/schema.md: schema files are executable, not inert data, so they
-- run through the same environment extension code would).
function schema.load_file(path)
    file = io.open(path, "r")
    if file == nil then
        return nil, "cannot open schema file: " .. path
    end
    source = io.read(file, "*all")
    io.close(file)

    ok, result = sandbox.run(source, path, sandbox.data_env())
    if ok == nil or ok == false then
        return nil, "error loading schema " .. path .. ": " .. tostring(result)
    end
    def = result

    err = schema.validate(def)
    if err != nil then
        return nil, err
    end
    return def
end

-- Structural validation only -- does the definition make sense on its
-- own terms. Whether it's consistent with what's already registered
-- (e.g. a reference to an unknown entity_type) is checked at register
-- time, since that needs the database.
function schema.validate(def)
    if type(def) != "table" then
        return "schema definition must be a table"
    end
    if type(def.name) != "string" or def.name == "" then
        return "schema must have a non-empty string 'name'"
    end
    if type(def.fields) != "table" then
        return "schema '" .. tostring(def.name) .. "' must have a 'fields' list"
    end
    for i, field in ipairs(def.fields) do
        if type(field.name) != "string" or field.name == "" then
            return string.format("schema '%s' field #%d: missing 'name'", def.name, i)
        end
        if is_valid_field_type(field.type) == false then
            return string.format("schema '%s' field '%s': invalid type '%s'", def.name, field.name, tostring(field.type))
        end
        if field.type == "select" and type(field.values) != "table" then
            return string.format("schema '%s' field '%s': type 'select' requires a 'values' list", def.name, field.name)
        end
        -- Optional bounds on a "number" field -- UI-hint only for now
        -- (wired into the registration table's <input type="number">
        -- min/max, see html.lua), not yet enforced server-side. A real
        -- bug found in production: without this, the registration
        -- table's number input had no min/max at all, so its native
        -- spinner arrows could be clicked past any sensible bound
        -- (e.g. past 5 for a 1-5 field) with no feedback. Server-side
        -- range enforcement, if a schema author needs it, is still a
        -- before-hook extension's job (see software's
        -- task-priority-range) -- consolidating that into a generic,
        -- schema-declared, DB-enforced constraint is a bigger change
        -- (entity_field would need new columns) not attempted here.
        if field.min != nil and type(field.min) != "number" then
            return string.format("schema '%s' field '%s': 'min' must be a number", def.name, field.name)
        end
        if field.max != nil and type(field.max) != "number" then
            return string.format("schema '%s' field '%s': 'max' must be a number", def.name, field.name)
        end
        if field.min != nil and field.max != nil and field.min > field.max then
            return string.format("schema '%s' field '%s': 'min' (%s) is greater than 'max' (%s)", def.name, field.name, tostring(field.min), tostring(field.max))
        end
    end
    return nil
end

-- Registers a validated schema definition: upserts entity_type/entity_field
-- rows, then creates or migrates the projected table.
-- entity_field predates the `display` flag (see schema.fields()'s own
-- header comment on entity_display_label in html.lua) -- ledger.lua's
-- CREATE TABLE IF NOT EXISTS never retrofits an existing table, so this
-- migrates it the same way sync_table() already migrates per-type
-- tables: additive, idempotent, safe to re-run on every sync.
function ensure_entity_field_display_column(db_path)
    existing = db.get_columns(db_path, "entity_field")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["display"] == nil then
        db.exec(db_path, "ALTER TABLE entity_field ADD COLUMN display INTEGER DEFAULT 0;")
    end
end

function schema.register(db_path, def)
    ensure_entity_field_display_column(db_path)
    db.exec(db_path, string.format(
        "INSERT OR IGNORE INTO entity_type (name) VALUES (%s);", db.quote(def.name)
    ))

    for i, field in ipairs(def.fields) do
        enum_json = nil
        if field.values != nil then
            json = require("dkjson")
            enum_json = json.encode(field.values)
        end
        required_flag = 0
        if field.required == true then
            required_flag = 1
        end
        display_flag = 0
        if field.display == true then
            display_flag = 1
        end
        db.exec(db_path, string.format(
            "INSERT OR REPLACE INTO entity_field (entity_type, name, type, required, enum_values, ref_entity_type, field_order, display) VALUES (%s, %s, %s, %d, %s, %s, %d, %d);",
            db.quote(def.name), db.quote(field.name), db.quote(field.type),
            required_flag,
            db.literal(enum_json),
            db.literal(field.entity_type),
            i,
            display_flag
        ))
    end

    schema.sync_table(db_path, def)
    return true
end

-- Always-present bookkeeping columns, independent of anything a schema
-- file declares -- external_id lets an external importer (e.g.
-- import_data_rest.py) look up "does a row for this source record
-- already exist" and upsert instead of blindly re-creating it every
-- sync run (a real, confirmed-live duplication bug this fixed: entity
-- tables had no external-id concept at all, so every run re-inserted
-- every source row from scratch).
--
-- "name" is the same idea for a real display label: an external source
-- like Benchling already assigns every record a genuine name (e.g. a
-- container literally named "50L stainless steel bioreactor"), distinct
-- from any of its own schema fields. Confirmed live: an importer was
-- already fetching this value to use as a natural key for dedup
-- matching, then discarding it -- never persisting it anywhere. A
-- schema-author's own {display = true} field (schema.lua's
-- entity_field.display column) is a reasonable per-type fallback for
-- data that has no such external source, but shouldn't be the first
-- choice when a real name already exists.
BUILTIN_COLUMNS = {
    {name = "created_by", sql_type = "TEXT"},
    {name = "created_at", sql_type = "TEXT DEFAULT (datetime('now', 'localtime'))"},
    {name = "updated_by", sql_type = "TEXT"},
    {name = "updated_at", sql_type = "TEXT DEFAULT (datetime('now', 'localtime'))"},
    {name = "last_event_id", sql_type = "INTEGER"},
    {name = "external_id", sql_type = "TEXT"},
    {name = "name", sql_type = "TEXT"},
    -- NULL means active; a real timestamp means archived. Never a
    -- boolean/plain flag -- recording *when* costs nothing extra and
    -- means "archived" doesn't need a second column to also answer
    -- "since when". Nothing ever hard-deletes a row; this plus the
    -- ledger's own 'archive' event (ledger.append_archive) are the only
    -- two places "this entity is no longer active" is recorded, and
    -- both are additive, not destructive.
    {name = "archived_at", sql_type = "TEXT"},
}

-- Creates the projected table if it doesn't exist, or adds any columns
-- for fields/builtins that aren't present yet. Never drops or renames a
-- column -- that's a deliberately manual, reviewed operation, not an
-- automatic one.
function schema.sync_table(db_path, def)
    if db.table_exists(db_path, def.name) == false then
        columns = {"id INTEGER PRIMARY KEY AUTOINCREMENT"}
        for _, field in ipairs(def.fields) do
            table.insert(columns, field.name .. " " .. SQL_TYPE[field.type])
        end
        for _, builtin in ipairs(BUILTIN_COLUMNS) do
            table.insert(columns, builtin.name .. " " .. builtin.sql_type)
        end
        db.exec(db_path, string.format(
            "CREATE TABLE %s (%s);", def.name, table.concat(columns, ", ")
        ))
        db.exec(db_path, string.format(
            "CREATE INDEX IF NOT EXISTS idx_%s_external_id ON %s (external_id);", def.name, def.name
        ))
        return
    end

    existing = db.get_columns(db_path, def.name)
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    for _, field in ipairs(def.fields) do
        if have[field.name] == nil then
            db.exec(db_path, string.format(
                "ALTER TABLE %s ADD COLUMN %s %s;", def.name, field.name, SQL_TYPE[field.type]
            ))
        end
    end
    for _, builtin in ipairs(BUILTIN_COLUMNS) do
        if have[builtin.name] == nil then
            db.exec(db_path, string.format(
                "ALTER TABLE %s ADD COLUMN %s %s;", def.name, builtin.name, builtin.sql_type
            ))
        end
    end
    db.exec(db_path, string.format(
        "CREATE INDEX IF NOT EXISTS idx_%s_external_id ON %s (external_id);", def.name, def.name
    ))
end

-- Scans the schemas directory, registers any schema files found,
-- and ensures all projected tables are synced/created.
function schema.sync_all(db_path, root)
    config = require("config")
    schemas_dir = config.schemas_dir(root)
    attr = lfs.attributes(schemas_dir)
    if attr == nil or attr.mode != "directory" then
        return false, "schemas directory not found: " .. schemas_dir
    end
    for file_name in lfs.dir(schemas_dir) do
        if string.match(file_name, "%.lua$") != nil then
            full_path = paths.joinpath(schemas_dir, file_name)
            def, err = schema.load_file(full_path)
            if def != nil then
                schema.register(db_path, def)
            end
        end
    end
    return true
end

-- The schema layout as a plain Luam table: {name, fields = {{name, label,
-- type, required, values?, ref_entity_type?}, ...}}. Shared by
-- schema.show_json (JSON for the client-side registration table) and
-- the browse/detail HTML views (cgi.lua/html.lua) -- one source of
-- truth for "what does this entity type's layout look like", native
-- consumers don't need to decode JSON just to get a Luam table back.
-- Prefers labels from the version-controlled schema file if available,
-- falling back to the database description (e.g. for a schema whose
-- file was since removed but whose table/data still exists).
function schema.layout(db_path, name)
    config = require("config")
    schemas_dir = config.schemas_dir()
    path = paths.joinpath(schemas_dir, name .. ".lua")
    def = nil
    if paths.file_exists(path) then
        def = schema.load_file(path)
    end

    if def != nil then
        result = {
            name = def.name,
            fields = {}
        }
        for _, field in ipairs(def.fields) do
            required = (field.required == true)
            label = field.label
            if label == nil then
                label = string.gsub(string.gsub(field.name, "^%l", string.upper), "_", " ")
            end
            field_def = {
                name = field.name,
                label = label,
                type = field.type,
                required = required
            }
            if field.values != nil then
                field_def.values = field.values
            end
            if field.entity_type != nil then
                field_def.ref_entity_type = field.entity_type
            end
            if field.min != nil then
                field_def.min = field.min
            end
            if field.max != nil then
                field_def.max = field.max
            end
            table.insert(result.fields, field_def)
        end
        return result
    else
        dkjson = require("dkjson")
        if schema.is_registered(db_path, name) == false then
            return nil, "unknown entity type: " .. name
        end
        fields = schema.fields(db_path, name)
        result = {
            name = name,
            fields = {}
        }
        for _, f in ipairs(fields) do
            required = (tonumber(f.required) == 1)
            label = string.gsub(string.gsub(f.name, "^%l", string.upper), "_", " ")
            field_def = {
                name = f.name,
                label = label,
                type = f.type,
                required = required
            }
            if f.enum_values != nil and f.enum_values != "" then
                field_def.values = dkjson.decode(f.enum_values)
            end
            if f.ref_entity_type != nil and f.ref_entity_type != "" then
                field_def.ref_entity_type = f.ref_entity_type
            end
            table.insert(result.fields, field_def)
        end
        return result
    end
end

-- Renders the schema structure as a JSON string (see schema.layout).
function schema.show_json(db_path, name)
    layout, err = schema.layout(db_path, name)
    if layout == nil then
        return nil, err
    end
    dkjson = require("dkjson")
    return dkjson.encode(layout)
end

-- Whether `name` has the shape a real registered entity-type name could
-- ever have -- lowercase ASCII letters/digits/underscore, not starting
-- with a digit, matching how every real schema file names itself
-- (`schema.register`'s `def.name`, always written this way by hand).
--
-- Security finding, fixed 2026-07-17 (see fossci's own TODO.md, M3):
-- `entity_type` flows unescaped into raw SQL as a table name
-- (`entity.lua`/`db.lua`, `"SELECT * FROM " .. entity_type`) and into a
-- file path for schema lookup (`schemas_dir .. "/" .. name .. ".lua"`)
-- wherever it comes from a request parameter (`params.type`). Every
-- call site happened to be safe only because it incidentally checked
-- the name resolves via schema.layout/schema.fields first -- not a
-- deliberate guard. This is that guard: a single charset check, applied
-- once, centrally, at every point in cgi.lua where `params.type`/
-- `params.ref_type`-shaped external input becomes an `entity_type`,
-- before it can reach any raw SQL or path-building call.
function schema.valid_name_syntax(name)
    return type(name) == "string" and string.match(name, "^[a-z_][a-z0-9_]*$") != nil
end

-- Whether `entity_type` has been registered at all. A registered type
-- can legitimately have zero custom fields (e.g. a schema whose only
-- data is its name plus the system-managed created/updated columns),
-- so callers must not use "schema.fields() returned nothing" as a
-- stand-in for "this type doesn't exist" -- that conflates the two.
function schema.is_registered(db_path, entity_type)
    rows = db.query(db_path, string.format(
        "SELECT 1 FROM entity_type WHERE name = %s;",
        db.quote(entity_type)
    ))
    return rows != nil and #rows > 0
end

-- The registered field list for an entity type, in declaration order --
-- what entity.lua validates rows against.
function schema.fields(db_path, entity_type)
    rows = db.query(db_path, string.format(
        "SELECT * FROM entity_field WHERE entity_type = %s ORDER BY field_order ASC;",
        db.quote(entity_type)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

-- Every reference relationship between registered entity types --
-- {from_type, to_type, field_name}, one per reference-typed field, across
-- every registered schema. Backs the Data page's entity-relation diagram;
-- a pure introspection query (like schema.fields()), so it belongs here
-- rather than in html.lua/cgi.lua alongside the rendering.
function schema.relationships(db_path)
    types = schema.list(db_path)
    edges = {}
    for _, t in ipairs(types) do
        fields = schema.fields(db_path, t.name)
        for _, field in ipairs(fields) do
            if field.type == "reference" and field.ref_entity_type != nil and field.ref_entity_type != "" then
                table.insert(edges, {from_type = t.name, to_type = field.ref_entity_type, field_name = field.name})
            end
        end
    end
    return edges
end

function schema.list(db_path)
    rows = db.query(db_path, "SELECT name FROM entity_type ORDER BY name ASC;")
    if rows == nil then
        return {}
    end
    return rows
end

-- CLI entry point: `fossci schema <add|list|show|show-json|sync> [args]`
function schema.do_schema(cmd_args, db_path)
    action = cmd_args[1]

    if action == "add" then
        path = cmd_args[2]
        if path == nil then
            print("Usage: fossci schema add <file>")
            return
        end
        def, err = schema.load_file(path)
        if def == nil then
            print("Error: " .. err)
            return
        end
        schema.register(db_path, def)
        print("Registered entity type '" .. def.name .. "'")
        return
    end

    if action == "list" then
        schema.sync_all(db_path)
        for _, row in ipairs(schema.list(db_path)) do
            print(row.name)
        end
        return
    end

    if action == "show-json" or (action == "show" and cmd_args[3] == "--json") then
        name = cmd_args[2]
        if name == nil then
            print("Usage: fossci schema show-json <name>")
            return
        end
        schema.sync_all(db_path)
        json_str, err = schema.show_json(db_path, name)
        if json_str == nil then
            print("Error: " .. tostring(err))
            return
        end
        print(json_str)
        return
    end

    if action == "show" then
        name = cmd_args[2]
        if name == nil then
            print("Usage: fossci schema show <name>")
            return
        end
        schema.sync_all(db_path)
        for _, field in ipairs(schema.fields(db_path, name)) do
            required = "optional"
            if tonumber(field.required) == 1 then
                required = "required"
            end
            print(string.format("%-20s %-10s %s", field.name, field.type, required))
        end
        return
    end

    if action == "sync" then
        ok, err = schema.sync_all(db_path)
        if not ok then
            print("Error: " .. tostring(err))
        else
            print("Schema sync complete")
        end
        return
    end

    print("Usage: fossci schema <add|list|show|show-json|sync> [args]")
end

return schema
