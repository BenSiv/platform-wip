-- The document/notebook entity type: a real parent_id tree, not a
-- name-is-identity convention. Unlike a schema a deployment authors
-- itself (schemas/*.lua), "document" is a built-in type this module
-- registers directly via schema.register -- its own extra behavior
-- here (link parsing, backlinks, breadcrumbs, rendering) is tightly
-- coupled to its exact field shape, so keeping the schema and that
-- behavior in the same trusted, first-party module (not a deployment-
-- editable file) guarantees they can never drift apart.
--
-- Cross-document linking adopts the "[[title]]" / "[[subject/title]]"
-- inline-link convention -- parsed the same way (regex over the raw
-- content, split on the first "/"), but NOT ported as-is: the source
-- convention strips a matched link out of the displayed content
-- entirely once parsed (fine for a personal note's tag-like link
-- list, wrong here, since a document's prose needs the link to stay
-- visible and readable in place). Links here are left in the content
-- and rendered as an inline Markdown link over the same text instead.
--
-- Link resolution deliberately doesn't walk a full multi-level path --
-- "title" alone matches by title (first match wins if more than one
-- document shares a title); "subject/title" additionally requires the
-- resolved document's immediate parent to be titled "subject". A full
-- path-chain resolver would be more precise but is more machinery than
-- inline prose links need; this one-level disambiguator covers the
-- realistic case (two same-titled pages in different folders) without
-- it.
--
-- Links are a derived index over document content, not user-authored
-- data in their own right -- recomputed wholesale (delete + reinsert)
-- on every save, the same resync pattern the source convention uses,
-- rather than a schema-driven entity type with its own ledger history.
-- The content that generates them already has full audit history via
-- the document entity itself; a link row's own history would just be
-- churn (every content edit potentially archiving/recreating several),
-- not a real audit trail of anyone's actions.

db = require("db")
schema = require("schema")
entity = require("entity")

document = {}

DOCUMENT_SCHEMA = {
    name = "document",
    fields = {
        {name = "parent_id", type = "reference", required = false, entity_type = "document"},
        {name = "title", type = "text", required = true, display = true},
        {name = "content", type = "text", required = false},
    },
}

DOCUMENT_LINK_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_link (
    from_document_id INTEGER NOT NULL,
    to_document_id INTEGER,
    link_text TEXT NOT NULL,
    PRIMARY KEY (from_document_id, link_text)
);
"""

function document.init_schema(db_path)
    schema.register(db_path, DOCUMENT_SCHEMA)
    db.exec(db_path, DOCUMENT_LINK_SCHEMA)
end

--------------------------------------------------------------------------
-- Tree structure
--------------------------------------------------------------------------

function document.children(db_path, parent_id)
    where = "parent_id IS NULL"
    if parent_id != nil then
        where = "parent_id = " .. tostring(tonumber(parent_id))
    end
    rows = db.query(db_path, string.format(
        "SELECT id, title FROM document WHERE %s AND (archived_at IS NULL OR archived_at = '') ORDER BY title ASC;",
        where
    ))
    if rows == nil then
        return {}
    end
    return rows
end

-- Every active document's id/title/parent_id, for building the full
-- tree view in one query rather than one query per level.
function document.all_active(db_path)
    rows = db.query(db_path,
        "SELECT id, title, parent_id FROM document WHERE archived_at IS NULL OR archived_at = '' ORDER BY title ASC;")
    if rows == nil then
        return {}
    end
    return rows
end

-- Root-to-self list of {id, title}, for breadcrumbs. `path` is
-- deliberately not cached on the row -- it's fully derived from
-- parent_id (the actual source of identity), recomputed on read, so it
-- can never go stale the way a cached copy could.
function document.breadcrumbs(db_path, document_id)
    crumbs = {}
    current_id = tonumber(document_id)
    guard = 0
    while current_id != nil and guard < 100 do
        guard = guard + 1
        row = entity.get(db_path, "document", current_id)
        if row == nil then
            break
        end
        table.insert(crumbs, 1, {id = row.id, title = row.title})
        current_id = tonumber(row.parent_id)
    end
    return crumbs
end

-- True if setting `document_id`'s parent to `new_parent_id` would make
-- it its own ancestor (moving a page underneath its own descendant).
-- Checked explicitly at save time rather than only guarded against by
-- breadcrumbs' own iteration cap -- a real error message beats a
-- silently-truncated breadcrumb trail.
function document.would_create_cycle(db_path, document_id, new_parent_id)
    if new_parent_id == nil or new_parent_id == "" then
        return false
    end
    target_id = tonumber(new_parent_id)
    self_id = tonumber(document_id)
    if target_id == self_id then
        return true
    end
    current_id = target_id
    guard = 0
    while current_id != nil and guard < 100 do
        guard = guard + 1
        if current_id == self_id then
            return true
        end
        row = entity.get(db_path, "document", current_id)
        if row == nil then
            return false
        end
        current_id = tonumber(row.parent_id)
    end
    return false
end

--------------------------------------------------------------------------
-- Link parsing, resolution, backlinks
--------------------------------------------------------------------------

-- "subject/title" -> subject, title; "title" alone -> nil, title.
function document.parse_link_ref(raw_link)
    trimmed = string.gsub(raw_link, "^%s*(.-)%s*$", "%1")
    slash_pos = string.find(trimmed, "/", 1, true)
    if slash_pos != nil then
        return string.sub(trimmed, 1, slash_pos - 1), string.sub(trimmed, slash_pos + 1)
    end
    return nil, trimmed
end

-- Resolves a parsed link ref to a document id, or nil if unresolved
-- (a "dangling" link -- the target hasn't been created yet, or was
-- archived/renamed away).
function document.resolve_link(db_path, subject, title)
    rows = db.query(db_path, string.format(
        "SELECT id, parent_id FROM document WHERE title = %s AND (archived_at IS NULL OR archived_at = '') ORDER BY id ASC;",
        db.quote(title)
    ))
    if rows == nil or #rows == 0 then
        return nil
    end
    if subject == nil then
        return rows[1].id
    end
    for _, row in ipairs(rows) do
        if row.parent_id != nil then
            parent = entity.get(db_path, "document", tonumber(row.parent_id))
            if parent != nil and parent.title == subject then
                return row.id
            end
        end
    end
    return nil
end

-- Recomputes every outgoing link for `document_id` from `content`:
-- delete the old set, re-parse, re-resolve, reinsert. Idempotent, safe
-- to call on every save regardless of whether content actually changed.
function document.sync_links(db_path, document_id, content)
    db.exec(db_path, string.format("DELETE FROM document_link WHERE from_document_id = %d;", tonumber(document_id)))
    if content == nil then
        return
    end
    seen = {}
    for raw_link in string.gmatch(content, "%[%[(.-)%]%]") do
        if seen[raw_link] == nil then
            seen[raw_link] = true
            subject, title = document.parse_link_ref(raw_link)
            to_id = document.resolve_link(db_path, subject, title)
            db.exec(db_path, string.format(
                "INSERT OR IGNORE INTO document_link (from_document_id, to_document_id, link_text) VALUES (%d, %s, %s);",
                tonumber(document_id), db.literal(to_id), db.quote(raw_link)
            ))
        end
    end
end

-- Documents linking TO `document_id` -- "linked from" for the detail view.
function document.backlinks(db_path, document_id)
    rows = db.query(db_path, string.format("""
        SELECT dl.from_document_id AS id, d.title AS title
        FROM document_link dl
        JOIN document d ON d.id = dl.from_document_id
        WHERE dl.to_document_id = %d AND (d.archived_at IS NULL OR d.archived_at = '');
    """, tonumber(document_id)))
    if rows == nil then
        return {}
    end
    return rows
end

--------------------------------------------------------------------------
-- Rendering: Markdown -> HTML via cmark, "[[...]]" -> inline links
--------------------------------------------------------------------------

-- Rewrites every "[[...]]" occurrence into a plain CommonMark link
-- (resolved) or an unlinked, clearly-marked placeholder (dangling) --
-- ordinary Markdown either way, so cmark itself needs no special
-- handling for this project's own link syntax.
function document.inline_links_to_markdown(db_path, content)
    return (string.gsub(content, "%[%[(.-)%]%]", function(raw_link)
        subject, title = document.parse_link_ref(raw_link)
        target_id = document.resolve_link(db_path, subject, title)
        if target_id != nil then
            return "[" .. raw_link .. "](document?entity_id=" .. tostring(target_id) .. ")"
        end
        return "*" .. raw_link .. "* _(not created yet)_"
    end))
end

-- Shells out to cmark (CommonMark, not vendored/hand-rolled) rather
-- than writing a Markdown parser -- same reasoning as bcrypt/hmac:
-- prefer a small, battle-tested existing implementation. Content goes
-- through a temp file, not shell-interpolated directly -- the only
-- shell-interpolated value is a path this process generated itself,
-- never anything from the document's own content. Requires `cmark` on
-- PATH at runtime (not statically linked into this binary the way
-- bcrypt/hmac are -- a real external dependency, not bundled).
-- cmark's default (non---unsafe) mode strips raw HTML blocks/inline
-- HTML from the input, which is exactly the safety property wanted
-- here: document content is user-authored and shown to other users, so
-- it must never be able to inject a raw <script> or event handler.
function document.render_markdown(content)
    if content == nil or content == "" then
        return ""
    end
    tmp_path = os.tmpname()
    file = io.open(tmp_path, "w")
    if file == nil then
        return ""
    end
    io.write(file, content)
    io.close(file)

    handle = io.popen("cmark " .. shell_quote(tmp_path), "r")
    html = ""
    if handle != nil then
        html = io.read(handle, "*all")
        io.close(handle)
    end
    os.remove(tmp_path)
    if html == nil then
        html = ""
    end
    return html
end

function shell_quote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- The full pipeline: resolve "[[...]]" refs into plain Markdown links
-- first, then hand the whole thing to cmark once.
function document.render_html(db_path, content)
    if content == nil or content == "" then
        return ""
    end
    return document.render_markdown(document.inline_links_to_markdown(db_path, content))
end

return document
