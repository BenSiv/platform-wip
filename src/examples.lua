-- Example config-as-code content for `platform init --with-examples`
-- (task #89) -- a fresh, truly empty install (confirmed by task #101)
-- gives a new user zero indication of what a schema/view/extension/
-- template file actually looks like or how to write one. This module
-- is the opt-in alternative: one small, realistic, working example of
-- each kind, so there's something real to read and copy rather than
-- an empty directory and a doc page.
--
-- Every writer here skips a destination that already exists rather
-- than overwriting it -- safe to run against an existing store too
-- (e.g. after deleting one example to see the rest regenerate), same
-- "never clobber real content" convention as schema.sync_table's own
-- add-column-only semantics.

paths = require("paths")
config = require("config")

examples = {}

EXAMPLE_CATEGORY_SCHEMA = """-- Example entity type (see doc/schema.md for the full field-type
-- reference). "category" is referenced by the "widget" example below,
-- to demonstrate the "reference" field type end to end.
--
-- The field is named "label", not "name" -- every generated entity
-- table already has a builtin "name" column (schema.lua's own
-- builtin_columns), so a field also called "name" collides with it
-- ("duplicate column name" on `schema add`, confirmed directly while
-- writing this example).
return {
    name = "category",
    fields = {
        {name = "label", type = "text", required = true, display = true},
    },
}
"""

EXAMPLE_WIDGET_SCHEMA = """-- Example entity type demonstrating every field type this platform
-- supports: text, number (with an optional min/max UI hint), date,
-- select (a fixed list of values), and reference (a link to another
-- entity type, here "category" -- see category.lua alongside this
-- file). Delete this file (and category.lua) once you've defined your
-- own real entity types; nothing else depends on either.
return {
    name = "widget",
    fields = {
        {name = "label", type = "text", required = true, display = true},
        {name = "quantity", type = "number", required = false, min = 0},
        {name = "received_on", type = "date", required = false},
        {name = "status", type = "select", required = false,
            values = {"pending", "in_stock", "discontinued"}},
        {name = "category", type = "reference", required = false, entity_type = "category"},
    },
}
"""

EXAMPLE_VIEW = """-- Example saved view: a named, read-only SELECT query rendered as a
-- table (see doc/schema.md). Every entity type's generated table has
-- id/label/etc columns from its own schema plus the builtin ones
-- (created_at, archived_at, ...) -- this one reads the "widget"
-- example schema's own columns. Views need an explicit admin approval
-- before they can run (System -> a real security control, not
-- skippable even for this example) -- `platform view approve
-- widgets-in-stock` once initialized, or approve it from the /system
-- page.
return {
    name = "widgets-in-stock",
    title = "Widgets in stock",
    entity_type = "widget",
    sql = "SELECT id, label, quantity, status FROM widget WHERE status = 'in_stock' AND archived_at IS NULL ORDER BY label ASC;",
    columns = {
        {name = "id", label = "ID"},
        {name = "label", label = "Label"},
        {name = "quantity", label = "Quantity"},
        {name = "status", label = "Status"},
    },
}
"""

EXAMPLE_EXTENSION_MANIFEST = """-- Example extension manifest (see doc/extensibility.md). Declares
-- what this extension is allowed to do -- an admin has to approve
-- these exact capabilities before the extension actually runs; editing
-- main.lua's logic doesn't need re-approval, but changing this
-- manifest's own capabilities does. This one only reads the values
-- already passed into its before-hook, so it needs none of the real
-- capabilities (read/write/net) at all.
return {
    name = "widget-quantity-range",
    events = {"entity.before_create", "entity.before_update"},
    entity_types = {"widget"},
    capabilities = {
        read = {},
        write = {},
        net = "none",
    },
}
"""

EXAMPLE_EXTENSION_MAIN = """-- Example before-hook: rejects a negative "quantity" on the "widget"
-- example entity type. Before-hooks run synchronously inside the write
-- and can return issues that block it outright (see
-- doc/extensibility.md) -- this is where validation rules that a
-- schema's own field types can't express directly (like "must be >=
-- 0") belong.
--
-- `new[field_name]` arrives as whatever the caller submitted (often a
-- string, e.g. from a web form) -- tonumber() it before comparing, the
-- same real gotcha this pattern hit in production once already (see
-- the task-priority-range extension this one is modeled on).
function on_before(new, old, ctx)
    issues = {}
    raw = new["quantity"]
    if raw != nil then
        value = tonumber(raw)
        if value != nil and value < 0 then
            table.insert(issues, {field = "quantity", severity = "error",
                message = "quantity cannot be negative"})
        end
    end
    return issues
end
"""

EXAMPLE_TEMPLATE = """-- Example entry template (see src/template.lua's own header comment
-- for the full shape reference). Produces a Markdown snippet a user
-- copies into a new Notebook page -- templates never write a page
-- directly, so this carries no execution risk and needs no admin
-- approval the way extensions/views do.
return {
    name = "widget-intake",
    label = "Widget intake",
    description = "A starting layout for logging a new widget delivery.",
    default_path = "Notebook/Widget intake",
    sections = {
        {type = "heading", text = "Delivery details"},
        {type = "text", text = "Received from: \\nPurchase order #: "},
        {type = "registration_table", entity_type = "widget",
            label = "Widget", columns = {"label", "quantity", "status"}},
    },
}
"""

-- theme.json can't hold real comments (it's parsed as plain JSON), so
-- "_comment" is a plain, harmless key here: config.load_theme ignores
-- any key it doesn't recognize, and it naturally drops out the first
-- time this file is saved through the Settings UI (task #89) or
-- edited by hand -- not a real field, just a note for whoever opens
-- the file before that happens.
EXAMPLE_THEME_JSON = """{
  "_comment": "Every field here is optional -- delete this file entirely for the plain generic default (indigo/slate, no logo, no extra chat instructions). Edit through Settings once the store is initialized, or by hand here before first boot.",
  "site_name": "My Deployment",
  "has_logo": false,
  "hide_home_heading": false,
  "system_prompt_extra": "",
  "colors": {
    "accent": "#4f46e5",
    "accent_2": "#6366f1",
    "bg": "#f8fafc",
    "bg_2": "#f1f5f9",
    "border": "#e2e8f0",
    "border_2": "#cbd5e1",
    "heading": "#0f172a",
    "input_text": "#0f172a",
    "muted": "#64748b",
    "muted_2": "#94a3b8",
    "text": "#334155",
    "th_text": "#475569"
  }
}
"""

function write_if_missing(path, contents)
    if paths.file_exists(path) then
        return false
    end
    file, err = io.open(path, "w")
    if file == nil then
        return nil, err
    end
    io.write(file, contents)
    io.close(file)
    return true
end

-- Writes every example file, skipping any destination that already
-- exists. Returns the list of paths actually written (empty on a
-- store where every example already exists -- e.g. a second
-- `--with-examples` run).
function examples.write_all(root)
    written = {}

    targets = {
        {dir = config.schemas_dir(root), name = "category.lua", contents = EXAMPLE_CATEGORY_SCHEMA},
        {dir = config.schemas_dir(root), name = "widget.lua", contents = EXAMPLE_WIDGET_SCHEMA},
        {dir = config.views_dir(root), name = "widgets-in-stock.lua", contents = EXAMPLE_VIEW},
        {dir = config.templates_dir(root), name = "widget-intake.lua", contents = EXAMPLE_TEMPLATE},
    }
    for _, target in ipairs(targets) do
        path = paths.joinpath(target.dir, target.name)
        ok = write_if_missing(path, target.contents)
        if ok == true then
            table.insert(written, path)
        end
    end

    ext_dir = paths.joinpath(config.extensions_dir(root), "widget-quantity-range")
    paths.create_dir_if_not_exists(ext_dir)
    manifest_path = paths.joinpath(ext_dir, "manifest.lua")
    if write_if_missing(manifest_path, EXAMPLE_EXTENSION_MANIFEST) == true then
        table.insert(written, manifest_path)
    end
    main_path = paths.joinpath(ext_dir, "main.lua")
    if write_if_missing(main_path, EXAMPLE_EXTENSION_MAIN) == true then
        table.insert(written, main_path)
    end

    theme_path = config.theme_path(root)
    if write_if_missing(theme_path, EXAMPLE_THEME_JSON) == true then
        table.insert(written, theme_path)
    end

    return written
end

return examples
