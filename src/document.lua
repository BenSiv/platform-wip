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

-- A document's cached semantic-search embedding -- computed and stored
-- explicitly (document.reindex_embedding/_all), never automatically on
-- every save, since that would mean every save costs a real embedding
-- API call. Search itself only ever *reads* this cache; it never
-- computes a document's embedding on the fly.
DOCUMENT_EMBEDDING_SCHEMA = """
CREATE TABLE IF NOT EXISTS document_embedding (
    document_id INTEGER PRIMARY KEY,
    model TEXT NOT NULL,
    vector_json TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now', 'localtime'))
);
"""

EMBEDDING_MODEL = "text-embedding-005"

function document.init_schema(db_path)
    schema.register(db_path, DOCUMENT_SCHEMA)
    db.exec(db_path, DOCUMENT_LINK_SCHEMA)
    db.exec(db_path, DOCUMENT_EMBEDDING_SCHEMA)
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

-- entity.create/update + document.sync_links together -- the full
-- "save a page" sequence, shared by the web save route and the agent's
-- document tool so the two can never drift apart on what "saving a
-- page" actually entails.
function document.create_page(db_path, author, title, parent_id, content, source)
    values = {title = title, content = content, parent_id = parent_id}
    created_id, issues = entity.create(db_path, "document", values, author, source)
    if created_id == nil then
        return nil, issues
    end
    document.sync_links(db_path, created_id, content)
    return created_id, issues
end

function document.update_page(db_path, author, document_id, title, parent_id, content, source)
    values = {title = title, content = content, parent_id = parent_id}
    updated_id, issues = entity.update(db_path, "document", document_id, values, author, source)
    if updated_id == nil then
        return nil, issues
    end
    document.sync_links(db_path, updated_id, content)
    return updated_id, issues
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

--------------------------------------------------------------------------
-- Semantic search
--------------------------------------------------------------------------
--
-- SQLite FTS5 was evaluated first, per the original plan's lean --
-- confirmed directly (not assumed) that Luam's bundled sqlite3 binding
-- does not have FTS5 compiled in ("no such module: fts5"). Scores every
-- active document directly in Lua instead: simpler, no index/trigger
-- machinery to keep in sync, and an entirely reasonable tradeoff at the
-- scale this is built for -- revisit only if a real deployment's
-- document count makes an O(n)-per-search scan actually show up.
--
-- The scoring formula is adapted from brain-ex's
-- knowledge_pool.search_score -- ported the reusable core (field-
-- weighted lexical matching, a whole-query substring bonus, blended
-- embedding cosine-similarity, a relevance floor) and dropped what
-- doesn't apply to Pages: there's no curation-tier, heat/retrieval-
-- count reinforcement, or duplicate-suppression concept the way
-- brain-ex's knowledge_pool has for notes.

-- Computes and caches one document's embedding -- an explicit,
-- deliberate action (CLI/route-triggered), never a side effect of
-- saving a document (see DOCUMENT_EMBEDDING_SCHEMA's own comment).
function document.reindex_embedding(db_path, document_id)
    agent_provider = require("agent_provider")
    json = require("dkjson")

    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil, "no such document"
    end
    text = doc.title
    if doc.content != nil and doc.content != "" then
        text = text .. "\n" .. doc.content
    end

    vector, err = agent_provider.embeddings(EMBEDDING_MODEL, text)
    if vector == nil then
        return nil, err
    end

    db.exec(db_path, string.format(
        "INSERT OR REPLACE INTO document_embedding (document_id, model, vector_json, updated_at) VALUES (%d, %s, %s, datetime('now', 'localtime'));",
        tonumber(document_id), db.quote(EMBEDDING_MODEL), db.quote(json.encode(vector))
    ))
    return true
end

function document.reindex_all_embeddings(db_path)
    reindexed = 0
    failed = 0
    for _, row in ipairs(document.all_active(db_path)) do
        ok, err = document.reindex_embedding(db_path, row.id)
        if ok == true then
            reindexed = reindexed + 1
        else
            failed = failed + 1
        end
    end
    return reindexed, failed
end

function escape_pattern(text)
    return (string.gsub(text, "([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

function count_matches(text, term)
    if text == nil or term == nil or term == "" then
        return 0
    end
    text = string.lower(text)
    term = string.lower(term)
    pattern = escape_pattern(term)
    count = 0
    for _ in string.gmatch(text, pattern) do
        count = count + 1
    end
    return count
end

function cosine_similarity(v1, v2)
    if v1 == nil or v2 == nil or #v1 == 0 or #v2 == 0 or #v1 != #v2 then
        return 0.0
    end
    dot = 0.0
    norm_a = 0.0
    norm_b = 0.0
    for i = 1, #v1 do
        dot = dot + v1[i] * v2[i]
        norm_a = norm_a + v1[i] * v1[i]
        norm_b = norm_b + v2[i] * v2[i]
    end
    if norm_a == 0.0 or norm_b == 0.0 then
        return 0.0
    end
    return dot / (math.sqrt(norm_a) * math.sqrt(norm_b))
end

function query_terms(query_text)
    terms = {}
    if query_text == nil then
        return terms
    end
    for term in string.gmatch(string.lower(query_text), "%S+") do
        table.insert(terms, term)
    end
    return terms
end

-- Blended lexical + optional semantic relevance for one document
-- against a parsed query. A document with score 0 and similarity at or
-- below 0.45 is excluded outright (the relevance floor) rather than
-- ranked last -- an irrelevant result showing up at the bottom of a
-- results list is still a wrong result.
function document.search_score(row, terms, query_text, query_vector)
    title = row.title
    if title == nil then
        title = ""
    end
    content = row.content
    if content == nil then
        content = ""
    end

    score = 0
    for _, term in ipairs(terms) do
        score = score + (count_matches(title, term) * 4)
        score = score + count_matches(content, term)
    end

    if query_text != nil and query_text != "" then
        lower_query = string.lower(query_text)
        if string.find(string.lower(title), escape_pattern(lower_query)) != nil then
            score = score + 6
        elseif string.find(string.lower(title .. " " .. content), escape_pattern(lower_query)) != nil then
            score = score + 3
        end
    end

    similarity = 0.0
    if query_vector != nil and row.embedding_vector != nil then
        similarity = cosine_similarity(query_vector, row.embedding_vector)
    end

    if score <= 0 and similarity <= 0.45 then
        return 0
    end

    final_score = score
    if similarity > 0 then
        final_score = final_score + (similarity * 8.0)
    end
    return final_score
end

-- Searches active documents by blended relevance. `use_semantic`
-- (default true) computes the *query's* own embedding fresh each call
-- (one cheap, real-time API call) -- but a document only contributes
-- semantic score if it was already indexed via
-- document.reindex_embedding/_all; nothing here computes a document's
-- own embedding on the fly.
function document.search(db_path, query_text, limit, use_semantic)
    if limit == nil then
        limit = 20
    end
    if use_semantic == nil then
        use_semantic = true
    end

    terms = query_terms(query_text)

    query_vector = nil
    if use_semantic == true and query_text != nil and query_text != "" then
        agent_provider = require("agent_provider")
        vector, _ = agent_provider.embeddings(EMBEDDING_MODEL, query_text)
        query_vector = vector
    end

    rows = db.query(db_path, """
        SELECT d.id, d.title, d.content, e.vector_json
        FROM document d
        LEFT JOIN document_embedding e ON e.document_id = d.id
        WHERE d.archived_at IS NULL OR d.archived_at = '';
    """)
    if rows == nil then
        return {}
    end

    json = require("dkjson")
    scored = {}
    for _, row in ipairs(rows) do
        if row.vector_json != nil then
            decoded, _, _ = json.decode(row.vector_json)
            row.embedding_vector = decoded
        end
        row_score = document.search_score(row, terms, query_text, query_vector)
        if row_score > 0 then
            table.insert(scored, {id = row.id, title = row.title, content = row.content, score = row_score})
        end
    end

    table.sort(scored, function(a, b)
        return a.score > b.score
    end)

    results = {}
    for i = 1, math.min(limit, #scored) do
        table.insert(results, scored[i])
    end
    return results
end

-- CLI entry point: `platform document reindex-embeddings [entity_id]`
-- -- the only way (short of calling document.reindex_embedding/_all
-- directly) to actually populate document_embedding, since computing
-- an embedding costs a real API call and must never happen as an
-- automatic side effect of saving a page.
function document.do_document(cmd_args, db_path)
    action = cmd_args[1]

    if action == "reindex-embeddings" then
        entity_id = tonumber(cmd_args[2])
        if entity_id != nil then
            ok, err = document.reindex_embedding(db_path, entity_id)
            if ok == nil then
                print("Error: " .. tostring(err))
                return
            end
            print("Reindexed embedding for page #" .. tostring(entity_id))
            return
        end
        reindexed, failed = document.reindex_all_embeddings(db_path)
        print(string.format("Reindexed %d page(s), %d failed", reindexed, failed))
        return
    end

    print("Usage: platform document reindex-embeddings [entity_id]")
end

return document
