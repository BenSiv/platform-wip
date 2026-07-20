-- The entity ledger: an append-only event log plus the registry tables
-- (entity_type/entity_field) that describe what kinds of entities exist.
-- See doc/architecture.md, "The entity ledger: event-sourced, not
-- file-versioned" -- this file is exactly that design, nothing more.
--
-- entity_event rows are never updated or deleted. An entity's identity
-- (entity_id) is the event_id of its own create event -- no separate
-- sequence needed, and it ties identity directly to the ledger rather
-- than to whatever the projected table's storage happens to assign.

db = require("db")
json = require("dkjson")

ledger = {}

ledger.SCHEMA = """
CREATE TABLE IF NOT EXISTS entity_type (
    name TEXT PRIMARY KEY,
    created_at TEXT DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS entity_field (
    entity_type TEXT NOT NULL,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    required INTEGER DEFAULT 0,
    enum_values TEXT,
    ref_entity_type TEXT,
    field_order INTEGER NOT NULL,
    PRIMARY KEY (entity_type, name)
);

CREATE TABLE IF NOT EXISTS entity_event (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_id INTEGER,
    entity_type TEXT NOT NULL,
    event_type TEXT NOT NULL,
    field_changes TEXT NOT NULL,
    author TEXT,
    created_at TEXT DEFAULT (datetime('now', 'localtime')),
    source_notebook_entry_id TEXT,
    source_row_id TEXT
);
"""

function ledger.init_schema(db_path)
    return db.exec(db_path, ledger.SCHEMA)
end

-- Appends a 'create' event and returns the new entity_id.
-- `values` is a plain {field_name = value} table.
function ledger.append_create(db_path, entity_type, values, author, source)
    if source == nil then
        source = {}
    end
    field_changes = {}
    for name, value in pairs(values) do
        field_changes[name] = {old = nil, new = value}
    end

    statement = string.format(
        "INSERT INTO entity_event (entity_id, entity_type, event_type, field_changes, author, source_notebook_entry_id, source_row_id) VALUES (NULL, %s, 'create', %s, %s, %s, %s);",
        db.quote(entity_type),
        db.quote(json.encode(field_changes)),
        db.literal(author),
        db.literal(source.notebook_entry_id),
        db.literal(source.row_id)
    )
    -- Fixed 2026-07-20 (task #77): this used to re-derive entity_id via
    -- SELECT MAX(event_id), on the (false, for a real concurrent CGI
    -- deployment) assumption that nothing else could insert between
    -- this connection's own insert and that read -- two simultaneous
    -- creates could both read the same MAX and collide on one entity_id
    -- while the other's row silently kept entity_id NULL forever.
    -- db.exec's second return value is last_insert_rowid(), read on the
    -- very same connection the insert itself just ran on -- inherently
    -- connection-scoped, so it can't see another connection's insert
    -- regardless of timing.
    _, entity_id = db.exec(db_path, statement)
    db.exec(db_path, string.format(
        "UPDATE entity_event SET entity_id = %d WHERE event_id = %d;", entity_id, entity_id
    ))
    return entity_id
end

-- Appends an 'update' event for an existing entity_id. `field_changes`
-- is a plain {field_name = {old = ..., new = ...}} table -- callers
-- compute the diff themselves, since only they know the entity's
-- current projected values.
function ledger.append_update(db_path, entity_type, entity_id, field_changes, author, source)
    if source == nil then
        source = {}
    end
    statement = string.format(
        "INSERT INTO entity_event (entity_id, entity_type, event_type, field_changes, author, source_notebook_entry_id, source_row_id) VALUES (%d, %s, 'update', %s, %s, %s, %s);",
        entity_id,
        db.quote(entity_type),
        db.quote(json.encode(field_changes)),
        db.literal(author),
        db.literal(source.notebook_entry_id),
        db.literal(source.row_id)
    )
    -- Same fix as append_create above (task #77): return the
    -- connection-scoped insert_id directly instead of a separate
    -- SELECT MAX(event_id) that another concurrent writer's own insert
    -- could race ahead of.
    _, event_id = db.exec(db_path, statement)
    return event_id
end

-- Appends an 'archive' event -- never a delete. Returns the new
-- event_id, same as append_update, so callers can stamp
-- last_event_id on the projected table consistently either way.
function ledger.append_archive(db_path, entity_type, entity_id, author, source)
    event_id = ledger.append_update(db_path, entity_type, entity_id, {}, author, source)
    db.exec(db_path, string.format(
        "UPDATE entity_event SET event_type = 'archive' WHERE event_id = %d;", event_id
    ))
    return event_id
end

-- Full event history for one entity, oldest first.
function ledger.history(db_path, entity_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM entity_event WHERE entity_id = %d ORDER BY event_id ASC;", entity_id
    ))
    if rows == nil then
        return {}
    end
    for _, row in ipairs(rows) do
        row.field_changes = json.decode(row.field_changes)
    end
    return rows
end

-- CLI entry point: `fossci ledger <show|history> <entity_id>`
function ledger.do_ledger(cmd_args, db_path)
    action = cmd_args[1]
    entity_id = tonumber(cmd_args[2])

    if action != "show" and action != "history" then
        print("Usage: fossci ledger <show|history> <entity_id>")
        return
    end
    if entity_id == nil then
        print("Usage: fossci ledger " .. action .. " <entity_id>")
        return
    end

    events = ledger.history(db_path, entity_id)
    if #events == 0 then
        print("No events for entity #" .. tostring(entity_id))
        return
    end

    for _, event in ipairs(events) do
        print(string.format("event #%d  %s  %s  by %s  at %s",
            event.event_id, event.event_type, event.entity_type,
            tostring(event.author), event.created_at))
        for field, change in pairs(event.field_changes) do
            print(string.format("    %s: %s -> %s", field, tostring(change.old), tostring(change.new)))
        end
    end
end

return ledger
