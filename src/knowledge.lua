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
    -- task #87: the "durable artifact" layer the source Fossil-fork
    -- design describes but this port never built until now -- a
    -- promotable note materialized into a real Notebook page, not just
    -- a tier number change. artifact_status is 'none' until
    -- materialized (see knowledge.materialize_note).
    artifact_document_id INTEGER,
    artifact_status TEXT DEFAULT 'none',
    created_at TEXT DEFAULT (%s),
    updated_at TEXT DEFAULT (%s)
);

CREATE TABLE IF NOT EXISTS knowledge_retrieval (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT,
    query_text TEXT,
    hit_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT (%s)
);

-- `rank` (backtick-quoted, not a bare identifier): a genuine reserved
-- word in MySQL 8.0 (window functions), though not in MariaDB -- found
-- running tst/integration/mariadb_backend.bats against a real Cloud SQL
-- for MySQL instance. Backtick quoting is valid MySQL/MariaDB syntax and
-- SQLite's own MySQL-compatibility extension, so this is a single,
-- unified fix needing no per-backend branch.
CREATE TABLE IF NOT EXISTS knowledge_retrieval_note (
    retrieval_id INTEGER NOT NULL,
    note_id INTEGER NOT NULL,
    `rank` INTEGER,
    score REAL,
    tier_weight REAL,
    reinforcement_delta REAL,
    PRIMARY KEY (retrieval_id, note_id)
);

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

-- task #87: the actual prompt/reasoning/token record per chat turn --
-- adapted from a Fossil fork's own `ai_context` (see doc/architecture.md).
-- Linked to `agent_message` (the assistant response this context
-- produced), not a commit/rid the way the source system's version-
-- control-centric design was -- platform-wip's own immutable,
-- append-only chat log is the natural anchor here, not a Fossil-style
-- checkin. `reasoning_note_id` points at a knowledge_note
-- (source_type='reasoning') rather than storing reasoning text inline
-- -- reasoning goes through the exact same tiering/retrieval/decay
-- pipeline as everything else, not a second parallel log.
CREATE TABLE IF NOT EXISTS knowledge_context (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    message_id INTEGER,
    prompt TEXT,
    model_id TEXT,
    reasoning_note_id INTEGER,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    created_at TEXT DEFAULT (%s)
);

-- task #87: per-reply classification + user feedback -- adapted from
-- the same fork's `ai_chat_eval`. `message_id` is denormalized here
-- (also reachable via context_id -> knowledge_context.message_id) so
-- the feedback route can look a row up directly from what the chat
-- widget already has rendered, without a join.
CREATE TABLE IF NOT EXISTS knowledge_chat_eval (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    context_id INTEGER,
    message_id INTEGER,
    provider TEXT,
    model TEXT,
    reply_kind TEXT,
    quality_status TEXT,
    reasoning_status TEXT,
    action_summary TEXT,
    user_feedback TEXT,
    feedback_at TEXT,
    created_at TEXT DEFAULT (%s)
);
"""

function knowledge_schema_sql(db_path)
    return string.format(KNOWLEDGE_SCHEMA,
        db.autoincrement_keyword(db_path), db.now_expr(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path)
    )
end

-- Real MySQL has no "CREATE INDEX IF NOT EXISTS" at all (a syntax error,
-- not a no-op, unlike MariaDB) -- found running tst/integration/
-- mariadb_backend.bats against a real Cloud SQL for MySQL instance. These
-- three indexes used to live inside KNOWLEDGE_SCHEMA's own semicolon
-- batch; pulled out into their own guarded execs (db.index_exists first,
-- same "check, then conditionally create" shape schema.lua's own
-- CREATE INDEX call sites now use) since a single bad statement fails the
-- whole batch on MySQL, not just that one statement.
function ensure_knowledge_indexes(db_path)
    indexes = {
        {name = "knowledge_note_tier_idx", table = "knowledge_note",
         sql = "CREATE INDEX knowledge_note_tier_idx ON knowledge_note(tier, heat DESC, retrieval_count DESC);"},
        {name = "knowledge_note_hash_idx", table = "knowledge_note",
         sql = string.format("CREATE INDEX knowledge_note_hash_idx ON knowledge_note(%s);",
             db.text_index_column(db_path, "content_hash"))},
        {name = "knowledge_retrieval_note_note_idx", table = "knowledge_retrieval_note",
         sql = "CREATE INDEX knowledge_retrieval_note_note_idx ON knowledge_retrieval_note(note_id);"},
        {name = "knowledge_context_message_idx", table = "knowledge_context",
         sql = "CREATE INDEX knowledge_context_message_idx ON knowledge_context(message_id);"},
        {name = "knowledge_chat_eval_message_idx", table = "knowledge_chat_eval",
         sql = "CREATE INDEX knowledge_chat_eval_message_idx ON knowledge_chat_eval(message_id);"},
    }
    for _, idx in ipairs(indexes) do
        if db.index_exists(db_path, idx.table, idx.name) == false then
            db.exec(db_path, idx.sql)
        end
    end
end

-- CREATE TABLE IF NOT EXISTS never retrofits an existing table (same
-- reasoning as ledger.lua's own ensure_entity_event_reason_column) --
-- an existing knowledge_note needs these added by hand; a brand-new
-- store gets them straight from KNOWLEDGE_SCHEMA.
function ensure_knowledge_note_artifact_columns(db_path)
    existing = db.get_columns(db_path, "knowledge_note")
    have = {}
    for _, name in ipairs(existing) do
        have[name] = true
    end
    if have["artifact_document_id"] == nil then
        db.exec(db_path, "ALTER TABLE knowledge_note ADD COLUMN artifact_document_id INTEGER;")
    end
    if have["artifact_status"] == nil then
        db.exec(db_path, "ALTER TABLE knowledge_note ADD COLUMN artifact_status TEXT DEFAULT 'none';")
    end
end

function knowledge.init_schema(db_path)
    db.exec(db_path, knowledge_schema_sql(db_path))
    ensure_knowledge_indexes(db_path)
    ensure_knowledge_note_artifact_columns(db_path)
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

-- Heat decay (task #87): neither this port nor the source Fossil-fork
-- system it came from ever had decay -- heat only ever grew, so a note
-- that crossed a tier threshold once stayed there forever regardless
-- of whether it was ever retrieved again. Explicit user direction:
-- knowledge should stay fluid, not settle into a fixed state. Computed
-- lazily wherever heat is actually used for a decision (review's own
-- promotion/demotion check) rather than a scheduled job rewriting
-- every row -- matches this codebase's "compute at request time"
-- convention throughout (no in-app background scheduler exists at
-- all; the one periodic job in this whole system, Benchling sync, is
-- an external systemd timer, not something cgi.lua itself runs). The
-- stored `heat` column is left untouched -- it's the raw, monotonic
-- reinforcement total; effective_heat is the read-time view of it.
HEAT_DECAY_HALF_LIFE_DAYS = 14

-- Days between `timestamp_str` (this codebase's "YYYY-MM-DD HH:MM:SS"
-- convention, whatever db.now_expr's own DEFAULT produced) and now.
-- nil (not 0) for anything unparseable -- callers treat that as "no
-- decay information, use heat as-is" rather than "decay as if just
-- retrieved," which would be the wrong direction to fail in.
function knowledge.days_since(timestamp_str)
    if timestamp_str == nil or timestamp_str == "" then
        return nil
    end
    year, month, day, hour, min, sec = string.match(timestamp_str, "(%d+)-(%d+)-(%d+)[ T](%d+):(%d+):(%d+)")
    if year == nil then
        return nil
    end
    then_time = os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    })
    return (os.time() - then_time) / 86400
end

-- Exponential half-life decay: unchanged the instant a note is
-- retrieved, half its value after HEAT_DECAY_HALF_LIFE_DAYS of
-- disuse, a quarter after twice that, and so on -- never negative,
-- never demanding an exact "when did decay start" origin point the
-- way a linear decay would.
function knowledge.effective_heat(heat, last_retrieved_at)
    days = knowledge.days_since(last_retrieved_at)
    if days == nil or days <= 0 then
        return heat
    end
    return heat * (0.5 ^ (days / HEAT_DECAY_HALF_LIFE_DAYS))
end

-- Adapted from ai_promotion_target_tier, made bidirectional (task
-- #87): the source version only ever ratcheted `tier` upward and
-- never demoted. Recomputed from scratch against CURRENT (decayed)
-- stats every time instead of starting from the note's existing tier,
-- so a note that cools off (stops being retrieved, effective_heat
-- decays below a threshold it previously cleared) genuinely drops back
-- down on its next review -- `retrieval_count` alone can't gate this
-- indefinitely once heat has decayed, which is the whole point.
-- Duplicates still never move, same as before.
function knowledge.promotion_target_tier(tier, retrieval_count, effective_heat, is_duplicate, atomicity)
    if is_duplicate == true then
        return tier
    end
    target = 0
    if retrieval_count >= 2 then
        target = 1
    end
    if retrieval_count >= 4 and effective_heat >= 1.60 and atomicity != "needs-split" then
        target = 2
    end
    if retrieval_count >= 7 and effective_heat >= 2.60 and atomicity == "ok" then
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
    if rows == nil or rows[1] == nil then
        return nil
    end
    note = rows[1]
    note.effective_heat = knowledge.effective_heat(tonumber(note.heat), note.last_retrieved_at)
    return note
end

-- Fixed (task #87, in passing): same real concurrent-CGI race as
-- ledger.lua's append_create/agent.add_message had (see their own
-- comments) -- SELECT MAX(id) can collide with another connection's
-- own insert; db.exec's own connection-scoped second return value
-- can't. Matters now that this runs on every chat turn with visible
-- reasoning, not just the occasional document-indexing path.
function knowledge.create_note(db_path, tier, title, body, source_type, source_id, source_ref)
    _, note_id = db.exec(db_path, string.format(
        "INSERT INTO knowledge_note (tier, title, body, source_type, source_id, source_ref, content_hash) " ..
        "VALUES (%d, %s, %s, %s, %s, %s, %s);",
        tonumber(tier), db.literal(title), db.literal(body), db.literal(source_type),
        db.literal(source_id), db.literal(source_ref), db.quote(knowledge.content_hash(body))
    ))
    return tonumber(note_id)
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
        "%s knowledge_retrieval_note (retrieval_id, note_id, `rank`, score, tier_weight, reinforcement_delta) " ..
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
                tonumber(note.tier), tonumber(note.retrieval_count),
                knowledge.effective_heat(tonumber(note.heat), note.last_retrieved_at),
                is_duplicate, atomicity
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
-- task #87: full prompt/reasoning/token persistence + chat evaluation
--------------------------------------------------------------------------

-- Same detection ai_chat_eval_has_visible_reasoning used: a model that
-- leaks its own step-by-step thinking into the visible reply (rather
-- than keeping it internal) instead of a clean final answer. Plain
-- string.find (not a pattern), since none of these markers need
-- pattern matching and a reply's own content is arbitrary text that
-- shouldn't ever be interpreted as one.
function knowledge.reply_has_visible_reasoning(text)
    if text == nil or text == "" then
        return false
    end
    if string.find(text, "<think>", 1, true) != nil then
        return true
    end
    if string.find(text, "</think>", 1, true) != nil then
        return true
    end
    if string.find(text, "Thinking...", 1, true) != nil then
        return true
    end
    return string.find(string.lower(text), "thinking:", 1, true) == 1
end

-- Classifies one reply into (reply_kind, quality_status,
-- reasoning_status) -- same four-way split as the source system's
-- ai_chat_eval_record: error / reasoning-visible / final / empty.
function knowledge.classify_reply(is_error, text)
    if is_error == true then
        return "error", "error", "none"
    end
    if knowledge.reply_has_visible_reasoning(text) then
        return "reasoning-visible", "review", "visible"
    end
    if text != nil and text != "" then
        return "final", "ok", "none"
    end
    return "empty", "empty", "none"
end

-- Persists the exact prompt (system_prompt .. history, verbatim, not
-- reconstructed later from agent_message rows) plus real token counts
-- for one model call. `reasoning_note_id` is optional -- filled in by
-- the caller only when the reply's own reasoning was split out into
-- its own knowledge_note (source_type='reasoning'), not every turn.
-- `usage` is the {prompt_tokens, completion_tokens, total_tokens}
-- table agent_provider.generate's third return value now carries
-- (real counts from Vertex, estimated-but-present under the test
-- provider) -- every field is nil-safe since a provider without usage
-- metadata at all shouldn't fail this call over accounting.
function knowledge.record_context(db_path, session_id, message_id, prompt, model_id, reasoning_note_id, usage)
    if usage == nil then
        usage = {}
    end
    _, context_id = db.exec(db_path, string.format(
        "INSERT INTO knowledge_context (session_id, message_id, prompt, model_id, reasoning_note_id, prompt_tokens, completion_tokens, total_tokens) " ..
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s);",
        db.quote(session_id), db.literal(tonumber(message_id)), db.quote(prompt), db.quote(model_id),
        db.literal(tonumber(reasoning_note_id)), db.literal(usage.prompt_tokens), db.literal(usage.completion_tokens),
        db.literal(usage.total_tokens)
    ))
    return context_id
end

-- Records one chat-reply evaluation row -- classification is rule-based
-- today (knowledge.classify_reply), same as the source system's own
-- ai_chat_eval_record; nothing here requires an extra model call.
function knowledge.record_chat_eval(db_path, session_id, context_id, message_id, provider, model, is_error, reply_text)
    reply_kind, quality_status, reasoning_status = knowledge.classify_reply(is_error, reply_text)
    action_summary = string.format("reply_kind=%s; quality=%s; reasoning=%s", reply_kind, quality_status, reasoning_status)
    _, eval_id = db.exec(db_path, string.format(
        "INSERT INTO knowledge_chat_eval (session_id, context_id, message_id, provider, model, reply_kind, quality_status, reasoning_status, action_summary) " ..
        "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s);",
        db.quote(session_id), db.literal(tonumber(context_id)), db.literal(tonumber(message_id)),
        db.quote(provider), db.quote(model), db.quote(reply_kind), db.quote(quality_status),
        db.quote(reasoning_status), db.quote(action_summary)
    ))
    return eval_id
end

-- The user-feedback half of ai_chat_eval -- looked up by message_id
-- (what the chat widget already has rendered for each reply), not an
-- eval id the frontend was never told about. Checks existence with a
-- real SELECT first, not db.exec's own return value -- sqlite_update
-- and mariadb_update disagree on what their first return value even
-- means (plain `true` vs. a real affected-row count, confirmed
-- directly in luam's lib/database.lua), which is exactly why every
-- other UPDATE call site in this codebase already ignores it too.
function knowledge.record_chat_feedback(db_path, message_id, feedback)
    rows = db.query(db_path, string.format(
        "SELECT id FROM knowledge_chat_eval WHERE message_id = %d;", tonumber(message_id)
    ))
    if rows == nil or rows[1] == nil then
        return false
    end
    db.exec(db_path, string.format(
        "UPDATE knowledge_chat_eval SET user_feedback = %s, feedback_at = %s WHERE message_id = %d;",
        db.quote(feedback), db.now_expr(db_path), tonumber(message_id)
    ))
    return true
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

-- Sorted by raw heat (an index-backed ORDER BY, not a per-row Lua
-- decay computation) -- an approximate, not exact, decayed ordering.
-- Exact enough for a listing command; each row's own effective_heat
-- field (added below) is the exact figure review/promotion decisions
-- actually use.
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
    for _, row in ipairs(rows) do
        row.effective_heat = knowledge.effective_heat(tonumber(row.heat), row.last_retrieved_at)
    end
    return rows
end

function knowledge.set_tier(db_path, note_id, tier)
    db.exec(db_path, string.format(
        "UPDATE knowledge_note SET tier = %d, updated_at = %s WHERE id = %d;",
        tonumber(tier), db.now_expr(db_path), tonumber(note_id)
    ))
end

-- Materializes a promotable note into a real Notebook page (task #87's
-- "durable artifact" layer -- the source Fossil-fork design describes
-- this, but this port never built it: `promote` above was always just
-- a tier number change). Tagged back onto the note via
-- artifact_document_id/artifact_status so a note is never
-- materialized twice. This is the one genuinely mutating knowledge
-- operation, so it's registered as a destructive AGENT_TOOLS entry
-- (see agent.lua) -- the agent can propose it, but nothing is written
-- until a human approves the pending action, same as entity.create/
-- document.update.
function knowledge.materialize_note(db_path, note_id, author)
    note = knowledge.get_note(db_path, note_id)
    if note == nil then
        return nil, "no such note #" .. tostring(note_id)
    end
    if note.artifact_status == "materialized" then
        return nil, "note #" .. tostring(note_id) .. " is already materialized (document #" .. tostring(note.artifact_document_id) .. ")"
    end
    -- note.duplicate_of comes back as "" (not Lua nil) for a genuinely
    -- NULL column under this sqlite binding -- confirmed directly (a
    -- note with duplicate_of never set still tripped a bare `!= nil`
    -- check here until this was added; `knowledge show`'s own
    -- tostring(note.duplicate_of) prints nothing, not the literal
    -- string "nil", on the exact same row).
    if note.duplicate_of != nil and note.duplicate_of != "" then
        return nil, "note #" .. tostring(note_id) .. " is a duplicate, refusing to materialize"
    end
    if tonumber(note.tier) < 2 then
        return nil, "note #" .. tostring(note_id) .. " is tier " .. tostring(note.tier) .. " -- only tier 2/3 notes are ready to materialize"
    end

    title = note.title
    if title == nil or title == "" then
        title = "Knowledge note #" .. tostring(note_id)
    end
    document_id, issues = document.create_page(db_path, author, title, nil, note.body, nil)
    if document_id == nil then
        -- entity.create's own issues shape (a list of {field, severity,
        -- message} tables, not a string) -- flattened here rather than
        -- leaking that shape to this function's own callers (the CLI
        -- and the agent tool dispatch both just want a plain message).
        messages = {}
        if issues != nil then
            for _, issue in ipairs(issues) do
                if issue.severity == "error" then
                    table.insert(messages, tostring(issue.message))
                end
            end
        end
        if #messages == 0 then
            return nil, "failed to create the materialized page"
        end
        return nil, table.concat(messages, "; ")
    end

    db.exec(db_path, string.format(
        "UPDATE knowledge_note SET artifact_document_id = %d, artifact_status = 'materialized', updated_at = %s WHERE id = %d;",
        document_id, db.now_expr(db_path), tonumber(note_id)
    ))
    return document_id
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
            print(string.format("#%s [tier %s] %s (heat=%s, effective=%.2f, retrievals=%s)",
                tostring(row.id), tostring(row.tier), tostring(row.title), tostring(row.heat),
                row.effective_heat, tostring(row.retrieval_count)))
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
        print("heat: " .. tostring(note.heat) .. " (effective: " .. string.format("%.2f", note.effective_heat) .. ")")
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

    if action == "materialize" then
        note_id = tonumber(cmd_args[2])
        if note_id == nil then
            print("Usage: platform knowledge materialize <note_id>")
            return
        end
        document_id, err = knowledge.materialize_note(db_path, note_id, os.getenv("USER"))
        if document_id == nil then
            print("Error: " .. tostring(err))
            return
        end
        print("Note #" .. tostring(note_id) .. " materialized as document #" .. tostring(document_id))
        return
    end

    print("Usage: platform knowledge <stats|list [tier]|show <note_id>|promote <note_id> <tier>|materialize <note_id>|review>")
end

return knowledge
