-- The knowledge pool: retrieval activity logging, note tiering, and
-- rule-based review, adapted from a Fossil SCM fork's much larger
-- ai_note/ai_retrieval/ai_review system (not copied verbatim -- see
-- doc/architecture.md's "Knowledge pool" section for the mapping).
-- Deliberately dropped from the source system: per-source-type
-- authority weighting, a metadata-quality gate (tied to fields this
-- codebase's notes don't have), and heat decay (the source system has
-- none either -- heat only ever grows).
--
-- Hand-rolled tables (own CREATE TABLE + init_schema), not a
-- schema.register() entity type -- same reasoning as document_link/
-- document_embedding/agent_session: these are system/derived records,
-- not user-authored data with its own field-level audit needs.
--
-- A note is created lazily, the first time its source document is
-- actually retrieved (see knowledge.ensure_note_for_document) -- not
-- an eager bulk sweep over every document at init time.

db = require("db")
document = require("document")
entity = require("entity")

knowledge = {}

TIER_WEIGHT = {[0] = 0.0, [1] = 0.10, [2] = 0.20, [3] = 0.35}

KNOWLEDGE_SCHEMA = """
CREATE TABLE IF NOT EXISTS knowledge_note (
    id INTEGER PRIMARY KEY %s,
    tier INTEGER NOT NULL DEFAULT 0,
    title TEXT,
    body TEXT NOT NULL,
    source_type TEXT,
    source_id INTEGER,
    source_ref TEXT,
    content_hash TEXT,
    duplicate_of INTEGER,
    merged_into INTEGER,
    heat REAL NOT NULL DEFAULT 1.0,
    retrieval_count INTEGER NOT NULL DEFAULT 0,
    last_retrieved_at TEXT,
    created_at TEXT DEFAULT (%s),
    updated_at TEXT DEFAULT (%s)
);
CREATE INDEX IF NOT EXISTS knowledge_note_tier_idx ON knowledge_note(tier, heat DESC, retrieval_count DESC);
CREATE INDEX IF NOT EXISTS knowledge_note_hash_idx ON knowledge_note(%s);

CREATE TABLE IF NOT EXISTS knowledge_retrieval (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT,
    query_text TEXT,
    hit_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT (%s)
);

CREATE TABLE IF NOT EXISTS knowledge_retrieval_note (
    retrieval_id INTEGER NOT NULL,
    note_id INTEGER NOT NULL,
    rank INTEGER,
    score REAL,
    tier_weight REAL,
    reinforcement_delta REAL,
    PRIMARY KEY (retrieval_id, note_id)
);
CREATE INDEX IF NOT EXISTS knowledge_retrieval_note_note_idx ON knowledge_retrieval_note(note_id);

CREATE TABLE IF NOT EXISTS knowledge_review (
    id INTEGER PRIMARY KEY %s,
    retrieval_id INTEGER NOT NULL,
    note_id INTEGER NOT NULL,
    atomicity_status TEXT,
    connectivity_status TEXT,
    duplication_status TEXT,
    title_status TEXT,
    action_summary TEXT,
    created_at TEXT DEFAULT (%s)
);
"""

function knowledge_schema_sql(db_path)
    return string.format(KNOWLEDGE_SCHEMA,
        db.autoincrement_keyword(db_path), db.now_expr(db_path), db.now_expr(db_path),
        db.text_index_column(db_path, "content_hash"),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path)
    )
end

function knowledge.init_schema(db_path)
    return db.exec(db_path, knowledge_schema_sql(db_path))
end

--------------------------------------------------------------------------
-- Pure functions -- no DB access, fully unit-testable in isolation
--------------------------------------------------------------------------

-- A fast, deterministic (not cryptographic -- dedup fingerprinting has
-- no adversarial threat model here) djb2-style hash, since no SHA1/MD5
-- binding is available in this Lua fork's stdlib. Kept within 2^32 so
-- the running total stays exactly representable in a Lua 5.1 double.
function knowledge.content_hash(body)
    body = tostring(body)
    hash = 5381
    for i = 1, string.len(body) do
        hash = (hash * 33 + string.byte(body, i)) % 4294967296
    end
    return string.format("%08x", hash)
end

-- Exact port of ai_note_record_retrieval's reinforcement formula: a
-- flat 0.15 plus the retrieved note's own tier weight, added to heat
-- on every retrieval hit. No decay -- heat is monotonic, matching the
-- source system.
function knowledge.reinforcement_delta(tier)
    tier_weight = TIER_WEIGHT[tier]
    if tier_weight == nil then
        tier_weight = 0.0
    end
    return 0.15 + tier_weight
end

-- Exact port of ai_promotion_target_tier: automatic, threshold-based,
-- never demotes, duplicates never advance.
function knowledge.promotion_target_tier(tier, retrieval_count, heat, is_duplicate, atomicity)
    target = tier
    if is_duplicate == true then
        return target
    end
    if target < 1 and retrieval_count >= 2 then
        target = 1
    end
    if target < 2 and retrieval_count >= 4 and heat >= 1.60 and atomicity != "needs-split" then
        target = 2
    end
    if target < 3 and retrieval_count >= 7 and heat >= 2.60 and atomicity == "ok" then
        target = 3
    end
    return target
end

-- Exact port of the atomicity heuristic: counts "#"-prefixed heading
-- lines and blank-line-delimited paragraphs.
function knowledge.atomicity_status(body)
    body = tostring(body)
    heading_count = 0
    for _ in string.gmatch(body, "\n#[^\n]*") do
        heading_count = heading_count + 1
    end
    if string.match(body, "^#") != nil then
        heading_count = heading_count + 1
    end

    paragraph_count = 0
    for para in string.gmatch(body .. "\n\n", "(.-)\n\n") do
        if string.match(para, "%S") != nil then
            paragraph_count = paragraph_count + 1
        end
    end

    if heading_count > 1 or paragraph_count > 6 then
        return "needs-split"
    end
    if paragraph_count <= 1 and string.len(body) < 64 then
        return "thin"
    end
    return "ok"
end

function knowledge.connectivity_status(peer_count)
    return "linked-" .. tostring(peer_count)
end

GENERIC_TITLES = {["note"] = true, ["untitled note"] = true, ["manual note"] = true, [""] = true}

function knowledge.title_is_generic(title)
    if title == nil then
        return true
    end
    return GENERIC_TITLES[string.lower(strip_spaces(title))] == true
end

function strip_spaces(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- First non-heading line of body (heading lines are skipped entirely,
-- not stripped-and-used -- "# Heading\n\nFirst real line" guesses
-- "First real line", not "Heading"), with leading bullet/quote
-- decoration stripped, truncated to ~72 chars on a word boundary when
-- one exists past position 24 (short enough truncations just get a
-- hard cut rather than a barely-shorter one).
function knowledge.guess_title_from_body(body)
    if body == nil then
        return "Untitled note"
    end
    for line in string.gmatch(body, "[^\n]+") do
        if string.match(line, "^%s*#") == nil then
            candidate = strip_spaces(string.gsub(line, "^[>%-%*%s]+", ""))
            if candidate != "" then
                if string.len(candidate) <= 72 then
                    return candidate
                end
                cut = string.find(string.sub(candidate, 1, 72), " [^ ]*$")
                if cut != nil and cut > 24 then
                    return string.sub(candidate, 1, cut - 1)
                end
                return string.sub(candidate, 1, 72)
            end
        end
    end
    return "Untitled note"
end

--------------------------------------------------------------------------
-- Notes
--------------------------------------------------------------------------

function knowledge.get_note(db_path, note_id)
    rows = db.query(db_path, "SELECT * FROM knowledge_note WHERE id = " .. tostring(tonumber(note_id)) .. ";")
    if rows == nil then
        return nil
    end
    return rows[1]
end

function knowledge.create_note(db_path, tier, title, body, source_type, source_id, source_ref)
    db.exec(db_path, string.format(
        "INSERT INTO knowledge_note (tier, title, body, source_type, source_id, source_ref, content_hash) " ..
        "VALUES (%d, %s, %s, %s, %s, %s, %s);",
        tonumber(tier), db.literal(title), db.literal(body), db.literal(source_type),
        db.literal(source_id), db.literal(source_ref), db.quote(knowledge.content_hash(body))
    ))
    rows = db.query(db_path, "SELECT MAX(id) AS id FROM knowledge_note;")
    return tonumber(rows[1].id)
end

function knowledge.note_for_document(db_path, document_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM knowledge_note WHERE source_type = 'document' AND source_id = %d LIMIT 1;",
        tonumber(document_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

-- A document gets its tier-0 knowledge_note lazily, the first time
-- it's actually retrieved -- not an eager bulk sweep over every
-- document. Idempotent: a second call for the same document returns
-- the existing note rather than creating a duplicate.
function knowledge.ensure_note_for_document(db_path, document_id)
    existing = knowledge.note_for_document(db_path, document_id)
    if existing != nil then
        return existing
    end
    doc = entity.get(db_path, "document", document_id)
    if doc == nil then
        return nil
    end
    body = doc.content
    if body == nil then
        body = ""
    end
    note_id = knowledge.create_note(db_path, 0, doc.title, body, "document", document_id, nil)
    return knowledge.get_note(db_path, note_id)
end

--------------------------------------------------------------------------
-- Retrieval logging
--------------------------------------------------------------------------

function knowledge.begin_retrieval(db_path, session_id, query_text, hit_count)
    db.exec(db_path, string.format(
        "INSERT INTO knowledge_retrieval (session_id, query_text, hit_count) VALUES (%s, %s, %d);",
        db.literal(session_id), db.literal(query_text), tonumber(hit_count)
    ))
    rows = db.query(db_path, "SELECT MAX(id) AS id FROM knowledge_retrieval;")
    return tonumber(rows[1].id)
end

-- Bumps the note's heat/retrieval_count by the ported reinforcement
-- formula and records the per-hit row audit-style, mirroring
-- ai_note_record_retrieval exactly (see knowledge.reinforcement_delta).
function knowledge.record_retrieval_hit(db_path, retrieval_id, note_id, tier, rank, score)
    delta = knowledge.reinforcement_delta(tier)
    tier_weight = TIER_WEIGHT[tier]
    if tier_weight == nil then
        tier_weight = 0.0
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_note SET heat = heat + %.17g, retrieval_count = retrieval_count + 1, " ..
        "last_retrieved_at = %s, updated_at = %s WHERE id = %d;",
        delta, db.now_expr(db_path), db.now_expr(db_path), tonumber(note_id)
    ))
    db.exec(db_path, string.format(
        "%s knowledge_retrieval_note (retrieval_id, note_id, rank, score, tier_weight, reinforcement_delta) " ..
        "VALUES (%d, %d, %d, %.17g, %.17g, %.17g);",
        db.replace_into(db_path),
        tonumber(retrieval_id), tonumber(note_id), tonumber(rank), tonumber(score), tier_weight, delta
    ))
    return delta
end

--------------------------------------------------------------------------
-- Review gates (DB-touching orchestration; see the pure heuristics above)
--------------------------------------------------------------------------

-- Canonical = lowest id sharing the same content hash. A non-canonical
-- note gets its own duplicate_of/merged_into set, mirroring the source
-- system's dedup bookkeeping.
function knowledge.duplication_status(db_path, note_id, content_hash)
    if content_hash == nil or content_hash == "" then
        return "unique"
    end
    rows = db.query(db_path, string.format(
        "SELECT id FROM knowledge_note WHERE content_hash = %s AND id != %d ORDER BY id ASC LIMIT 1;",
        db.quote(content_hash), tonumber(note_id)
    ))
    if rows == nil or rows[1] == nil then
        return "unique"
    end
    canonical_id = tonumber(rows[1].id)
    if canonical_id < tonumber(note_id) then
        db.exec(db_path, string.format(
            "UPDATE knowledge_note SET duplicate_of = %d, merged_into = %d WHERE id = %d;",
            canonical_id, canonical_id, tonumber(note_id)
        ))
        return "duplicate-of-" .. tostring(canonical_id)
    end
    return "unique"
end

-- Runs once per retrieval, after all hits are logged (mirrors
-- ai_retrieval_review's invocation point): for every note this
-- retrieval touched, computes the review gates, applies any resulting
-- note mutation (retitle, dedup, tier promotion), and records one
-- knowledge_review row per note for audit.
function knowledge.review_retrieval(db_path, retrieval_id)
    rows = db.query(db_path, string.format(
        "SELECT note_id FROM knowledge_retrieval_note WHERE retrieval_id = %d;", tonumber(retrieval_id)
    ))
    if rows == nil then
        return
    end
    peer_count = #rows - 1
    if peer_count < 0 then
        peer_count = 0
    end

    for _, row in ipairs(rows) do
        note = knowledge.get_note(db_path, row.note_id)
        if note != nil then
            atomicity = knowledge.atomicity_status(note.body)
            duplication = knowledge.duplication_status(db_path, note.id, note.content_hash)
            connectivity = knowledge.connectivity_status(peer_count)
            is_duplicate = string.match(duplication, "^duplicate%-of%-") != nil

            title_status = "ok"
            new_title = note.title
            if knowledge.title_is_generic(note.title) then
                new_title = knowledge.guess_title_from_body(note.body)
                title_status = "retitled"
            end

            target_tier = knowledge.promotion_target_tier(
                tonumber(note.tier), tonumber(note.retrieval_count), tonumber(note.heat), is_duplicate, atomicity
            )

            db.exec(db_path, string.format(
                "UPDATE knowledge_note SET tier = %d, title = %s, updated_at = %s WHERE id = %d;",
                target_tier, db.literal(new_title), db.now_expr(db_path), note.id
            ))
            db.exec(db_path, string.format(
                "INSERT INTO knowledge_review (retrieval_id, note_id, atomicity_status, connectivity_status, duplication_status, title_status) " ..
                "VALUES (%d, %d, %s, %s, %s, %s);",
                tonumber(retrieval_id), note.id, db.quote(atomicity), db.quote(connectivity), db.quote(duplication), db.quote(title_status)
            ))
        end
    end
end

--------------------------------------------------------------------------
-- The one integration point every retrieval path goes through
--------------------------------------------------------------------------

-- Wraps document.search rather than modifying it -- document.search
-- stays pure/reusable, knowledge.lua depends on document.lua, never
-- the reverse. A document gets its knowledge_note lazily, the first
-- time it's actually retrieved (knowledge.ensure_note_for_document) --
-- heat/tier/review then apply to it on every retrieval from here on.
function knowledge.search_and_log(db_path, query_text, limit, use_semantic, session_id)
    results = document.search(db_path, query_text, limit, use_semantic)
    retrieval_id = knowledge.begin_retrieval(db_path, session_id, query_text, #results)
    for rank, r in ipairs(results) do
        note = knowledge.ensure_note_for_document(db_path, r.id)
        if note != nil then
            knowledge.record_retrieval_hit(db_path, retrieval_id, note.id, tonumber(note.tier), rank, r.score)
        end
    end
    if #results > 0 then
        knowledge.review_retrieval(db_path, retrieval_id)
    end
    return results, retrieval_id
end

--------------------------------------------------------------------------
-- Stats -- for the agent's knowledge.stats tool and the /knowledge page
--------------------------------------------------------------------------

function count_rows(db_path, query)
    rows = db.query(db_path, query)
    if rows == nil or rows[1] == nil then
        return 0
    end
    return tonumber(rows[1].n)
end

-- session_count reads agent_session directly (agent.lua's own table)
-- rather than requiring agent.lua -- that would be a require cycle,
-- since agent.lua requires knowledge.lua to route its search tool
-- through search_and_log. Guarded since a fresh/unusual bootstrap
-- order could reach here before agent.init_schema has run.
function knowledge.stats(db_path)
    tier_counts = {}
    for tier = 0, 3 do
        tier_counts[tier] = count_rows(db_path, "SELECT COUNT(*) AS n FROM knowledge_note WHERE tier = " .. tostring(tier) .. ";")
    end
    session_count = 0
    if db.table_exists(db_path, "agent_session") then
        session_count = count_rows(db_path, "SELECT COUNT(*) AS n FROM agent_session;")
    end
    return {
        tier_counts = tier_counts,
        note_count = count_rows(db_path, "SELECT COUNT(*) AS n FROM knowledge_note;"),
        retrieval_count = count_rows(db_path, "SELECT COUNT(*) AS n FROM knowledge_retrieval;"),
        reviewed_note_count = count_rows(db_path, "SELECT COUNT(DISTINCT note_id) AS n FROM knowledge_review;"),
        session_count = session_count,
    }
end

function knowledge.recent_retrievals(db_path, limit)
    if limit == nil then
        limit = 10
    end
    rows = db.query(db_path, string.format(
        "SELECT id, query_text, hit_count, created_at FROM knowledge_retrieval ORDER BY id DESC LIMIT %d;",
        tonumber(limit)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

function knowledge.list_notes(db_path, tier)
    query = "SELECT * FROM knowledge_note"
    if tier != nil then
        query = query .. " WHERE tier = " .. tostring(tonumber(tier))
    end
    query = query .. " ORDER BY heat DESC, retrieval_count DESC;"
    rows = db.query(db_path, query)
    if rows == nil then
        return {}
    end
    return rows
end

function knowledge.set_tier(db_path, note_id, tier)
    db.exec(db_path, string.format(
        "UPDATE knowledge_note SET tier = %d, updated_at = %s WHERE id = %d;",
        tonumber(tier), db.now_expr(db_path), tonumber(note_id)
    ))
end

--------------------------------------------------------------------------
-- CLI: `platform knowledge <stats|list|show|promote>`
--------------------------------------------------------------------------

function knowledge.do_knowledge(cmd_args, db_path)
    action = cmd_args[1]

    if action == "stats" then
        s = knowledge.stats(db_path)
        print(string.format("tier0=%d tier1=%d tier2=%d tier3=%d",
            s.tier_counts[0], s.tier_counts[1], s.tier_counts[2], s.tier_counts[3]))
        print("notes=" .. tostring(s.note_count) .. " retrievals=" .. tostring(s.retrieval_count) ..
            " reviewed=" .. tostring(s.reviewed_note_count) .. " sessions=" .. tostring(s.session_count))
        return
    end

    if action == "list" then
        tier = tonumber(cmd_args[2])
        rows = knowledge.list_notes(db_path, tier)
        for _, row in ipairs(rows) do
            print(string.format("#%s [tier %s] %s (heat=%s, retrievals=%s)",
                tostring(row.id), tostring(row.tier), tostring(row.title), tostring(row.heat), tostring(row.retrieval_count)))
        end
        return
    end

    if action == "show" then
        note_id = tonumber(cmd_args[2])
        if note_id == nil then
            print("Usage: platform knowledge show <note_id>")
            return
        end
        note = knowledge.get_note(db_path, note_id)
        if note == nil then
            print("Error: no such note #" .. tostring(note_id))
            return
        end
        print("id: " .. tostring(note.id))
        print("tier: " .. tostring(note.tier))
        print("title: " .. tostring(note.title))
        print("heat: " .. tostring(note.heat))
        print("retrieval_count: " .. tostring(note.retrieval_count))
        print("source: " .. tostring(note.source_type) .. " #" .. tostring(note.source_id))
        print("duplicate_of: " .. tostring(note.duplicate_of))
        print("body:")
        print(tostring(note.body))
        return
    end

    if action == "promote" then
        note_id = tonumber(cmd_args[2])
        tier = tonumber(cmd_args[3])
        if note_id == nil or tier == nil then
            print("Usage: platform knowledge promote <note_id> <tier>")
            return
        end
        knowledge.set_tier(db_path, note_id, tier)
        print("Note #" .. tostring(note_id) .. " set to tier " .. tostring(tier))
        return
    end

    print("Usage: platform knowledge <stats|list [tier]|show <note_id>|promote <note_id> <tier>>")
end

return knowledge
