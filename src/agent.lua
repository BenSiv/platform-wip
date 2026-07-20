-- The chat/agent subsystem: real per-user sessions and DB-backed
-- conversation history (not brain-ex's hardcoded single 'default'
-- session -- every session belongs to a specific login, and every
-- lookup checks that ownership), context-window compaction, and (see
-- the tool-use section further down) a bounded turn loop that can act
-- on the platform's own data through a small, explicit tool registry.
--
-- Nothing here is ever deleted. Compacting history marks old messages
-- out-of-context (in_context = 0) rather than removing them -- the
-- full conversation stays in SQL, only the live prompt sent to the
-- model shrinks.

db = require("db")
agent_provider = require("agent_provider")
document = require("document")
entity = require("entity")
schema = require("schema")
knowledge = require("knowledge")

agent = {}

DEFAULT_COMPACTION_THRESHOLD = 4000
MAX_TURNS = 10

AGENT_SCHEMA = """
-- VARCHAR(255), not TEXT -- MariaDB/InnoDB refuses a bare TEXT column
-- as a key without an explicit length; see ledger.lua's own SCHEMA
-- comment for the full reasoning.
CREATE TABLE IF NOT EXISTS agent_session (
    id VARCHAR(255) PRIMARY KEY,
    login TEXT NOT NULL,
    title TEXT,
    created_at TEXT DEFAULT (%s),
    updated_at TEXT DEFAULT (%s)
);

CREATE TABLE IF NOT EXISTS agent_message (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    in_context INTEGER DEFAULT 1,
    created_at TEXT DEFAULT (%s)
);

-- A destructive tool call the model has proposed but not yet run --
-- see "Tool use" below for why this has to be a real, persisted state
-- rather than a blocking prompt: a single CGI request can't pause
-- mid-call waiting on a human's real-world response time.
CREATE TABLE IF NOT EXISTS agent_pending_action (
    id INTEGER PRIMARY KEY %s,
    session_id TEXT NOT NULL,
    tool TEXT NOT NULL,
    method TEXT NOT NULL,
    args_json TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT DEFAULT (%s),
    resolved_at TEXT
);
"""

function agent_schema_sql(db_path)
    return string.format(AGENT_SCHEMA,
        db.now_expr(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path),
        db.autoincrement_keyword(db_path), db.now_expr(db_path)
    )
end

function agent.init_schema(db_path)
    return db.exec(db_path, agent_schema_sql(db_path))
end

--------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------

-- Self-contained (not calling auth.lua's identical helper) so this
-- module has no load-order dependency on auth.lua being required
-- first -- it isn't conceptually an auth concern, just a source of
-- unguessable ids, so it gets its own copy rather than an implicit
-- cross-file dependency on one.
function random_session_token()
    urandom = io.open("/dev/urandom", "rb")
    if urandom == nil then
        return nil, "cannot open /dev/urandom"
    end
    raw = io.read(urandom, 16)
    io.close(urandom)
    if raw == nil or string.len(raw) != 16 then
        return nil, "short read from /dev/urandom"
    end
    hex = {}
    for i = 1, string.len(raw) do
        table.insert(hex, string.format("%02x", string.byte(raw, i)))
    end
    return table.concat(hex)
end

function agent.create_session(db_path, login, title)
    session_id, err = random_session_token()
    if session_id == nil then
        return nil, err
    end
    db.exec(db_path, string.format(
        "INSERT INTO agent_session (id, login, title) VALUES (%s, %s, %s);",
        db.quote(session_id), db.quote(login), db.literal(title)
    ))
    return session_id
end

-- Requires the session to belong to `login` -- one user can never
-- read or continue another user's conversation just by guessing or
-- reusing a session id.
function agent.get_session(db_path, session_id, login)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_session WHERE id = %s AND login = %s;",
        db.quote(session_id), db.quote(login)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

-- Derives a short session title from a real user message, once, if the
-- session doesn't already have one -- avoids leaving chats "Untitled"
-- in history/knowledge-pool listings just because chat-start's own
-- optional title field was left blank, which is the common case (see
-- render_chat_sessions_list's own "Untitled chat" fallback). Only ever
-- fires on the first message that finds an empty title, so in the
-- normal case that's the session's actual first message; a title set
-- explicitly at chat-start is never overwritten. Reuses
-- knowledge.guess_title_from_body's own text-to-title logic (skip
-- headings, strip bullet/quote prefixes, ~72-char word-boundary
-- cutoff) rather than duplicating it -- same underlying problem
-- (turn a blob of text into a short display title), and
-- agent.display_content strips the [Current user: ...]/[Current
-- page: ...] annotations first, or they'd end up as the "title"
-- instead of the actual question.
function agent.maybe_set_title_from_message(db_path, session_id, login, user_message)
    session = agent.get_session(db_path, session_id, login)
    if session == nil or (session.title != nil and session.title != "") then
        return
    end
    clean_message = agent.display_content(user_message)
    title = knowledge.guess_title_from_body(clean_message)
    if title == "Untitled note" then
        return
    end
    db.exec(db_path, string.format(
        "UPDATE agent_session SET title = %s WHERE id = %s;",
        db.quote(title), db.quote(session_id)
    ))
end

function agent.list_sessions(db_path, login)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_session WHERE login = %s ORDER BY updated_at DESC;",
        db.quote(login)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

function agent.touch_session(db_path, session_id)
    db.exec(db_path, string.format(
        "UPDATE agent_session SET updated_at = %s WHERE id = %s;",
        db.now_expr(db_path), db.quote(session_id)
    ))
end

--------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------

function agent.add_message(db_path, session_id, role, content, in_context)
    if in_context == nil then
        in_context = true
    end
    in_context_flag = 0
    if in_context == true then
        in_context_flag = 1
    end
    db.exec(db_path, string.format(
        "INSERT INTO agent_message (session_id, role, content, in_context) VALUES (%s, %s, %s, %d);",
        db.quote(session_id), db.quote(role), db.quote(content), in_context_flag
    ))
    agent.touch_session(db_path, session_id)
    rows = db.query(db_path, "SELECT MAX(id) AS id FROM agent_message;")
    return tonumber(rows[1].id)
end

function agent.active_messages(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_message WHERE session_id = %s AND in_context = 1 ORDER BY id ASC;",
        db.quote(session_id)
    ))
    if rows == nil then
        return {}
    end
    return rows
end

-- Cleans a message's content for DISPLAY only -- never called on what
-- active_messages/build_history_prompt feeds back to the model itself,
-- which still needs its own raw <tool>/<method>/<args>/<done> tag
-- protocol and the real page-context text intact to make sense of its
-- own prior turns. A human reading the transcript doesn't need any of
-- that literally: a <done>...</done>-wrapped final answer should just
-- read as its own inner text, a tool call as a short "-> what ran"
-- line instead of raw tags, and the [Current user: ...]/[Current
-- page: ...] annotations html.render_chat_widget's own JS prepends to
-- every user message (see its own comment on why every message, not
-- just the first) are there for the model, not for the user to see
-- restated back to them.
function agent.display_content(content)
    if content == nil then
        return content
    end
    content = string.gsub(content, "^%[Current user: .-%]\n", "")
    content = string.gsub(content, "^%[Current page: .-%]\n\n", "")
    done_message = string.match(content, "^%s*<done>%s*(.-)%s*</done>%s*$")
    if done_message != nil then
        return done_message
    end
    tool_name = string.match(content, "<tool>%s*(.-)%s*</tool>")
    method_name = string.match(content, "<method>%s*(.-)%s*</method>")
    if tool_name != nil and method_name != nil then
        return "-> " .. tool_name .. "." .. method_name .. "(...)"
    end
    return content
end

-- Every message, active or compacted-away -- the full, never-deleted
-- transcript, for a "show full history" view.
function agent.all_messages(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_message WHERE session_id = %s ORDER BY id ASC;",
        db.quote(session_id)
    ))
    if rows == nil then
        return {}
    end
    for _, row in ipairs(rows) do
        row.content = agent.display_content(row.content)
    end
    return rows
end

--------------------------------------------------------------------------
-- Context-window compaction
--------------------------------------------------------------------------

-- A simple chars/4 heuristic, not a real tokenizer -- ported as-is
-- from brain-ex: cheap, no model-specific vocabulary to keep in sync,
-- and only needs to be roughly right (the threshold check it feeds has
-- headroom built in, not a hard model context limit).
function agent.estimate_tokens(text)
    if text == nil then
        return 0
    end
    return math.ceil(string.len(text) / 4)
end

-- Summarizes everything except the last `keep_last` active messages
-- into one new 'compaction_summary' message once the active window's
-- estimated token count crosses the threshold, then marks the
-- summarized originals in_context = 0 -- ported from brain-ex's
-- agent_engine.run_agent, same threshold/keep-last defaults. Never
-- deletes anything; the summary is itself just another additive
-- message.
function agent.compact_if_needed(db_path, session_id, system_prompt, model)
    active = agent.active_messages(db_path, session_id)

    threshold = DEFAULT_COMPACTION_THRESHOLD
    env_threshold = tonumber(os.getenv("AGENT_COMPACTION_THRESHOLD"))
    if env_threshold != nil then
        threshold = env_threshold
    end

    keep_last = 4
    if #active <= keep_last then
        return false
    end

    total_tokens = agent.estimate_tokens(system_prompt)
    for _, msg in ipairs(active) do
        total_tokens = total_tokens + agent.estimate_tokens(msg.content)
    end

    if total_tokens <= threshold then
        return false
    end

    to_compact = {}
    for i = 1, #active - keep_last do
        table.insert(to_compact, active[i])
    end

    summary_prompt = "You are a context compaction engine. Please summarize the following " ..
        "conversation history into a concise, structured Markdown summary of goals, key " ..
        "information established, and progress. Focus on preserving factual details and " ..
        "state, so that a future model invocation has all the necessary context. Keep the " ..
        "summary under 300 words.\n\nConversation to summarize:\n"
    for _, msg in ipairs(to_compact) do
        summary_prompt = summary_prompt .. string.upper(msg.role) .. ": " .. msg.content .. "\n"
    end

    summary, err = agent_provider.generate(model, "You are a concise summarizer.", summary_prompt)
    if summary == nil or err != nil then
        return false, err
    end

    agent.add_message(db_path, session_id, "compaction_summary", summary, true)

    ids = {}
    for _, msg in ipairs(to_compact) do
        table.insert(ids, tostring(msg.id))
    end
    db.exec(db_path, "UPDATE agent_message SET in_context = 0 WHERE id IN (" .. table.concat(ids, ",") .. ");")

    return true
end

--------------------------------------------------------------------------
-- Tool use
--------------------------------------------------------------------------
--
-- A small, explicit built-in registry (not an open-ended plugin
-- system the way extensions are) -- the model can only ever call
-- exactly what's listed here, with no escape hatch. Each entry is
-- marked destructive or not; the turn loop below auto-executes
-- non-destructive calls and pauses destructive ones for a human to
-- approve, replacing brain-ex's blocking terminal y/N prompt (which
-- assumes a synchronous, long-lived process -- CGI has neither) with a
-- real two-phase state machine: a destructive request is persisted as
-- an agent_pending_action row and the turn loop returns immediately;
-- a *separate* later request (agent.approve_pending/deny_pending)
-- executes it (or records the denial) and resumes the loop from there.

AGENT_TOOLS = {
    document = {
        search = {destructive = false},
        create = {destructive = true},
        update = {destructive = true},
    },
    -- Generic entity access -- any registered schema, not a curated
    -- subset (schema.lua/entity.lua's own validation is the safety
    -- boundary, same as the HTTP/CLI layer already relies on). list_types
    -- and fields exist so the model can discover real entity types and
    -- their field names/types itself rather than the system prompt
    -- needing to hardcode every schema that might ever be registered.
    entity = {
        list_types = {destructive = false},
        fields = {destructive = false},
        list = {destructive = false},
        get = {destructive = false},
        create = {destructive = true},
        update = {destructive = true},
    },
    -- Read-only introspection into the knowledge pool's own tiering/
    -- retrieval activity (see knowledge.lua) -- no destructive knowledge
    -- tool yet, since note creation is retrieval-driven, not model-invoked.
    knowledge = {
        stats = {destructive = false},
    },
}

function agent.is_known_tool(tool_name, method_name)
    group = AGENT_TOOLS[tool_name]
    if group == nil then
        return false
    end
    return group[method_name] != nil
end

function agent.is_destructive(tool_name, method_name)
    group = AGENT_TOOLS[tool_name]
    if group == nil or group[method_name] == nil then
        return false
    end
    return group[method_name].destructive == true
end

function issues_summary(issues)
    if issues == nil or #issues == 0 then
        return "failed"
    end
    parts = {}
    for _, issue in ipairs(issues) do
        if issue.severity == "error" then
            table.insert(parts, tostring(issue.message))
        end
    end
    if #parts == 0 then
        return "failed"
    end
    return table.concat(parts, "; ")
end

-- Compact "field=value; field=value" text for one entity.get/list row,
-- for the model to read -- sorted so output is deterministic rather
-- than depending on pairs()'s unspecified iteration order.
function row_summary(row)
    parts = {}
    for k, v in pairs(row) do
        table.insert(parts, tostring(k) .. "=" .. tostring(v))
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

-- Runs one already-approved (or non-destructive) tool call. `author`
-- is the real, authenticated login the call runs as -- tool actions
-- are attributed the same way any other write in this system is, never
-- to a separate "agent" identity. `session_id` is recorded as the
-- write's source (entity_event.source_notebook_entry_id) so the ledger
-- can still distinguish *how* a change happened -- via this chat
-- session, not the direct edit form -- without that ever affecting who
-- it's attributed to.
function agent.execute_tool(db_path, author, session_id, tool_name, method_name, args)
    source = {notebook_entry_id = "agent-session:" .. tostring(session_id)}

    if tool_name == "document" and method_name == "search" then
        results = knowledge.search_and_log(db_path, args.query, 5, true, session_id)
        if #results == 0 then
            return "No matching pages found."
        end
        lines = {}
        for _, r in ipairs(results) do
            table.insert(lines, string.format("#%s %s", tostring(r.id), r.title))
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "document" and method_name == "create" then
        parent_id = tonumber(args.parent_id)
        created_id, issues = document.create_page(db_path, author, args.title, parent_id, args.content, source)
        if created_id == nil then
            return nil, issues_summary(issues)
        end
        return "Created page #" .. tostring(created_id) .. " (" .. tostring(args.title) .. ")"
    end

    if tool_name == "document" and method_name == "update" then
        target_id = tonumber(args.entity_id)
        if target_id == nil then
            return nil, "update requires entity_id"
        end
        parent_id = tonumber(args.parent_id)
        updated_id, issues = document.update_page(db_path, author, target_id, args.title, parent_id, args.content, source)
        if updated_id == nil then
            return nil, issues_summary(issues)
        end
        return "Updated page #" .. tostring(updated_id)
    end

    if tool_name == "entity" and method_name == "list_types" then
        types = schema.list(db_path)
        if #types == 0 then
            return "No entity types registered."
        end
        names = {}
        for _, t in ipairs(types) do
            table.insert(names, t.name)
        end
        return table.concat(names, ", ")
    end

    if tool_name == "entity" and method_name == "fields" then
        if args.entity_type == nil then
            return nil, "fields requires entity_type"
        end
        fields = schema.fields(db_path, args.entity_type)
        if #fields == 0 then
            return nil, "unknown entity type, or it has no fields: " .. tostring(args.entity_type)
        end
        lines = {}
        for _, f in ipairs(fields) do
            required = ""
            if tonumber(f.required) == 1 then
                required = ", required"
            end
            table.insert(lines, string.format("%s (%s%s)", f.name, f.type, required))
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "entity" and method_name == "list" then
        if args.entity_type == nil then
            return nil, "list requires entity_type"
        end
        limit = tonumber(args.limit)
        if limit == nil then
            limit = 20
        end
        rows = entity.list(db_path, args.entity_type, limit, nil, false)
        if #rows == 0 then
            return "No " .. tostring(args.entity_type) .. " rows found."
        end
        lines = {}
        for _, row in ipairs(rows) do
            table.insert(lines, "#" .. tostring(row.id) .. " " .. row_summary(row))
        end
        return table.concat(lines, "\n")
    end

    if tool_name == "entity" and method_name == "get" then
        target_id = tonumber(args.entity_id)
        if args.entity_type == nil or target_id == nil then
            return nil, "get requires entity_type and entity_id"
        end
        row = entity.get(db_path, args.entity_type, target_id)
        if row == nil then
            return nil, "no such " .. tostring(args.entity_type) .. " #" .. tostring(target_id)
        end
        return row_summary(row)
    end

    if tool_name == "entity" and method_name == "create" then
        if args.entity_type == nil then
            return nil, "create requires entity_type"
        end
        values = {}
        for k, v in pairs(args) do
            if k != "entity_type" then
                values[k] = v
            end
        end
        created_id, issues = entity.create(db_path, args.entity_type, values, author, source)
        if created_id == nil then
            return nil, issues_summary(issues)
        end
        return "Created " .. tostring(args.entity_type) .. " #" .. tostring(created_id)
    end

    if tool_name == "entity" and method_name == "update" then
        target_id = tonumber(args.entity_id)
        if args.entity_type == nil or target_id == nil then
            return nil, "update requires entity_type and entity_id"
        end
        values = {}
        for k, v in pairs(args) do
            if k != "entity_type" and k != "entity_id" then
                values[k] = v
            end
        end
        updated_id, issues = entity.update(db_path, args.entity_type, target_id, values, author, source)
        if updated_id == nil then
            return nil, issues_summary(issues)
        end
        return "Updated " .. tostring(args.entity_type) .. " #" .. tostring(updated_id)
    end

    if tool_name == "knowledge" and method_name == "stats" then
        stats = knowledge.stats(db_path)
        return string.format(
            "tier0=%d tier1=%d tier2=%d tier3=%d notes=%d retrievals=%d reviewed=%d sessions=%d",
            stats.tier_counts[0], stats.tier_counts[1], stats.tier_counts[2], stats.tier_counts[3],
            stats.note_count, stats.retrieval_count, stats.reviewed_note_count, stats.session_count
        )
    end

    return nil, "unknown tool: " .. tostring(tool_name) .. "." .. tostring(method_name)
end

function agent.create_pending_action(db_path, session_id, tool_name, method_name, args)
    json = require("dkjson")
    db.exec(db_path, string.format(
        "INSERT INTO agent_pending_action (session_id, tool, method, args_json) VALUES (%s, %s, %s, %s);",
        db.quote(session_id), db.quote(tool_name), db.quote(method_name), db.quote(json.encode(args))
    ))
    rows = db.query(db_path, "SELECT MAX(id) AS id FROM agent_pending_action;")
    return tonumber(rows[1].id)
end

-- Requires the pending action's own session to belong to `login` --
-- same ownership discipline as agent.get_session.
function agent.get_pending_action(db_path, pending_id, login)
    rows = db.query(db_path, string.format("""
        SELECT p.* FROM agent_pending_action p
        JOIN agent_session s ON s.id = p.session_id
        WHERE p.id = %d AND s.login = %s;
    """, tonumber(pending_id), db.quote(login)))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

function agent.resolve_pending_action(db_path, pending_id, status)
    db.exec(db_path, string.format(
        "UPDATE agent_pending_action SET status = %s, resolved_at = %s WHERE id = %d;",
        db.quote(status), db.now_expr(db_path), tonumber(pending_id)
    ))
end

-- The most recent unresolved pending action for a session, if any --
-- what a chat UI checks to decide whether to show an approve/deny
-- prompt instead of a plain message input.
function agent.latest_pending(db_path, session_id)
    rows = db.query(db_path, string.format(
        "SELECT * FROM agent_pending_action WHERE session_id = %s AND status = 'pending' ORDER BY id DESC LIMIT 1;",
        db.quote(session_id)
    ))
    if rows == nil or rows[1] == nil then
        return nil
    end
    return rows[1]
end

--------------------------------------------------------------------------
-- The turn loop
--------------------------------------------------------------------------

function build_history_prompt(messages)
    parts = {}
    for _, msg in ipairs(messages) do
        if msg.role == "compaction_summary" then
            table.insert(parts, "[COMPACTED HISTORY SUMMARY]:\n" .. msg.content)
        elseif msg.role == "user" then
            table.insert(parts, "User: " .. msg.content)
        elseif msg.role == "assistant" then
            table.insert(parts, "Assistant: " .. msg.content)
        elseif msg.role == "tool_result" then
            table.insert(parts, "Tool Output:\n" .. msg.content)
        end
    end
    return table.concat(parts, "\n\n")
end

function strip_spaces(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

function parse_tool_call(result)
    tool_name = string.match(result, "<tool>%s*(.-)%s*</tool>")
    method_name = string.match(result, "<method>%s*(.-)%s*</method>")
    args_str = string.match(result, "<args>%s*(.-)%s*</args>")
    args = {}
    if args_str != nil then
        for line in string.gmatch(args_str, "[^\r\n]+") do
            k, v = string.match(line, "^(.-)=(.*)$")
            if k != nil and v != nil then
                args[strip_spaces(k)] = v
            end
        end
    end
    return tool_name, method_name, args
end

-- The default system prompt teaching the model the tag protocol and
-- listing the tools in AGENT_TOOLS -- hand-maintained text, not
-- generated from the registry, so a new tool needs a line added here
-- too (see AGENT_TOOLS' own comment).
function agent.default_system_prompt()
    return """
You are an assistant embedded in a data platform. Answer directly when you can, or use a tool to look up or change data.

Some of your messages start with "[Current user: ...]" and/or "[Current
page: ...]" lines, automatically added by the app, not typed by the user --
never treat them as part of what the user actually typed.
- "[Current user: ...]" is the real login of the person you're talking to.
  Use it as the sensible default whenever you create or update something with
  an owner/assignee-style field and the user didn't name someone else.
- "[Current page: ...]" tells you what page the user is actually looking at
  right now (its type, title, and, where relevant, the entity type/id or view
  name it shows). Trust it as ground truth (e.g. answer "what page am I on"
  directly from it).

When creating or updating a record, fill in optional fields you can
reasonably infer from the request instead of leaving them blank (e.g. a
concise subject/title summarizing what was asked, a sensible due date if one
is clearly implied) -- the same judgment call a person filling out the same
form by hand would make. If a field is genuinely ambiguous, ask rather than
guessing.

Available tools:
- document.search -- search pages by keyword or topic. Args: query=<search text>
- document.create -- create a new page. Args: title=<title>, parent_id=<optional parent page id>, content=<markdown content>
- document.update -- update an existing page. Args: entity_id=<page id>, title=<optional new title>, parent_id=<optional new parent id>, content=<optional new content>
- entity.list_types -- list every registered entity type (samples, tasks, experiments, whatever this deployment has). No args.
- entity.fields -- list an entity type's fields and their types, so you know what's valid before creating/updating one. Args: entity_type=<name>
- entity.list -- list rows of an entity type. Args: entity_type=<name>, limit=<optional, default 20>
- entity.get -- fetch one entity row by id. Args: entity_type=<name>, entity_id=<id>
- entity.create -- create a new entity row. Args: entity_type=<name>, plus one arg per field (e.g. status=open, due_date=2026-08-01)
- entity.update -- update fields on an existing entity row. Args: entity_type=<name>, entity_id=<id>, plus one arg per field to change
- knowledge.stats -- summarize the knowledge pool's tier distribution and retrieval activity. No args.

If you don't already know an entity type's fields, call entity.fields first rather than guessing field names.

To call a tool, reply with EXACTLY this shape and nothing else:
<tool>document</tool>
<method>search</method>
<args>
query=some search text
</args>

Each argument goes on its own line as key=value. After a tool call you will be given its result as a new turn, and can call another tool or give a final answer.

When you have a final answer for the user, reply with EXACTLY:
<done>Your final answer here.</done>

Never mix a tool call and a <done> reply in the same turn.
"""
end

-- Runs the turn loop starting from the session's current active-message
-- state. `user_message`, if given, is recorded as a new user turn
-- before the loop starts; pass nil when resuming after a tool
-- approval/denial -- the loop just continues from whatever's already
-- in the active history. Returns a table:
--   {status = "done", message = "..."}
--   {status = "pending_approval", pending_id = N, tool = "...", method = "...", args = {...}}
--   {status = "turn_limit", message = "..."}
--   {status = "error", message = "..."}
--
-- Each call gets its own fresh MAX_TURNS budget, even a resume after a
-- pause -- deliberate, not an oversight: the approval pause is itself
-- a human circuit breaker, so restarting the budget on resume doesn't
-- reopen an unbounded-loop risk the way it would in a fully autonomous
-- run with no pauses at all.
function agent.run_turn(db_path, session_id, login, system_prompt, model, user_message)
    if system_prompt == nil or system_prompt == "" then
        system_prompt = agent.default_system_prompt()
    end

    if user_message != nil and user_message != "" then
        agent.add_message(db_path, session_id, "user", user_message, true)
        agent.maybe_set_title_from_message(db_path, session_id, login, user_message)
    end

    agent.compact_if_needed(db_path, session_id, system_prompt, model)

    for turn = 1, MAX_TURNS do
        active = agent.active_messages(db_path, session_id)
        prompt = build_history_prompt(active)

        result, err = agent_provider.generate(model, system_prompt, prompt)
        if result == nil then
            -- Persisted, not just returned -- every run_turn call site
            -- (chat-message, chat-widget-send/approve/deny) previously
            -- discarded this return value entirely, so a provider
            -- failure was completely invisible: the turn just vanished
            -- with no trace in the transcript.
            agent.add_message(db_path, session_id, "tool_result", "ERROR: " .. tostring(err), true)
            return {status = "error", message = tostring(err)}
        end

        agent.add_message(db_path, session_id, "assistant", result, true)

        done_message = string.match(result, "<done>%s*(.-)%s*</done>")
        if done_message != nil then
            return {status = "done", message = done_message}
        end

        tool_name, method_name, args = parse_tool_call(result)
        if tool_name == nil or method_name == nil then
            return {status = "done", message = result}
        end

        if not agent.is_known_tool(tool_name, method_name) then
            agent.add_message(db_path, session_id, "tool_result",
                "ERROR: unknown tool " .. tostring(tool_name) .. "." .. tostring(method_name), true)
        elseif agent.is_destructive(tool_name, method_name) then
            pending_id = agent.create_pending_action(db_path, session_id, tool_name, method_name, args)
            return {status = "pending_approval", pending_id = pending_id, tool = tool_name, method = method_name, args = args}
        else
            tool_result, tool_err = agent.execute_tool(db_path, login, session_id, tool_name, method_name, args)
            summary = tostring(tool_result)
            if tool_err != nil then
                summary = "ERROR: " .. tostring(tool_err)
            end
            agent.add_message(db_path, session_id, "tool_result", summary, true)
        end
    end

    return {status = "turn_limit", message = "Unable to complete tool-assisted run in " .. tostring(MAX_TURNS) .. " turns."}
end

-- Executes an approved pending action, records its result, and resumes
-- the turn loop from there.
function agent.approve_pending(db_path, pending_id, login, system_prompt, model)
    pending = agent.get_pending_action(db_path, pending_id, login)
    if pending == nil then
        return nil, "no such pending action"
    end
    if pending.status != "pending" then
        return nil, "action already " .. tostring(pending.status)
    end

    json = require("dkjson")
    args, _, _ = json.decode(pending.args_json)
    if args == nil then
        args = {}
    end

    tool_result, tool_err = agent.execute_tool(db_path, login, pending.session_id, pending.tool, pending.method, args)
    summary = tostring(tool_result)
    if tool_err != nil then
        summary = "ERROR: " .. tostring(tool_err)
    end
    agent.add_message(db_path, pending.session_id, "tool_result", summary, true)
    agent.resolve_pending_action(db_path, pending_id, "approved")

    return agent.run_turn(db_path, pending.session_id, login, system_prompt, model, nil)
end

-- Denies a pending action, records the denial as a tool_result (so the
-- model sees it and can react), and resumes the turn loop -- a denial
-- is just another outcome the model gets to respond to, not a dead end.
function agent.deny_pending(db_path, pending_id, login, system_prompt, model)
    pending = agent.get_pending_action(db_path, pending_id, login)
    if pending == nil then
        return nil, "no such pending action"
    end
    if pending.status != "pending" then
        return nil, "action already " .. tostring(pending.status)
    end

    agent.add_message(db_path, pending.session_id, "tool_result", "User denied execution of this action.", true)
    agent.resolve_pending_action(db_path, pending_id, "denied")

    return agent.run_turn(db_path, pending.session_id, login, system_prompt, model, nil)
end

return agent
