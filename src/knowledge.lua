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

knowledge = {}

TIER_WEIGHT = {[0] = 0.0, [1] = 0.10, [2] = 0.20, [3] = 0.35}

KNOWLEDGE_SCHEMA = """
CREATE TABLE IF NOT EXISTS knowledge_note (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
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
    created_at TEXT DEFAULT (datetime('now', 'localtime')),
    updated_at TEXT DEFAULT (datetime('now', 'localtime'))
);
CREATE INDEX IF NOT EXISTS knowledge_note_tier_idx ON knowledge_note(tier, heat DESC, retrieval_count DESC);
CREATE INDEX IF NOT EXISTS knowledge_note_hash_idx ON knowledge_note(content_hash);

CREATE TABLE IF NOT EXISTS knowledge_retrieval (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    query_text TEXT,
    hit_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now', 'localtime'))
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
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    retrieval_id INTEGER NOT NULL,
    note_id INTEGER NOT NULL,
    atomicity_status TEXT,
    connectivity_status TEXT,
    duplication_status TEXT,
    title_status TEXT,
    action_summary TEXT,
    created_at TEXT DEFAULT (datetime('now', 'localtime'))
);
"""

function knowledge.init_schema(db_path)
    return db.exec(db_path, KNOWLEDGE_SCHEMA)
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

return knowledge
