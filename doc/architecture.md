# Architecture

## Overview

The system is built around one idea: a record type is data, not code
you write per-type, and every change to a record is remembered, not
overwritten. Defining a new kind of record (a reagent, a sample, a
person) is authoring a small declarative definition; the platform
takes care of storage, validation, a full audit trail, and a queryable
table for that type. Nothing about using the system requires touching
the platform's own source.

```
                     +------------------+
                     |   web server     |   ordinary web request dispatch
                     +--------+---------+   (not wired up yet)
                              |
                     +--------v---------+
                     |     platform     |
                     | record history,  |
                     | registration     |
                     | semantics,       |
                     | accounts/        |
                     | sessions,        |
                     | validation,      |
                     | lineage, queries |
                     +--------+---------+
                              |
                     +--------v---------+
                     |     storage      |   history log (append-only)
                     |                  |   one table per record type
                     +------------------+   accounts
```

The application owns its full request/response cycle end to end: the
web surface, accounts and permissions, and its own rendering. Record
type, extension, and saved-query definitions are plain files, read and
sandboxed at request time -- nothing external to run alongside it to
make any of this work.

## History as the source of truth, not a side effect

Two options were considered for "nothing is ever really lost, and
every change is fully accountable": versioning individual records as
files, or an append-only log of changes with a materialized
current-state table per record type. Files were rejected because the
explicit requirement is real downstream analysis -- diffing files
doesn't give you fast joins and aggregations for a dashboard. An
append-only log gives both: nothing is ever overwritten (only
appended), *and* a normal table exists for every record type that a
dashboard can query directly.

```
history log                               <record type> (e.g. "reagent")
  entry_id      (monotonic, the version)    id
  entity_id     (stable logical identity)   <field columns, typed>
  entity_type                               created_by, created_at
  event_type    create | update | archive   updated_by, updated_at
  field_changes (old/new per field)         last_event_id
  author, timestamp                         archived_at (unset = active)
  source references (where the change came from)
```

The log is the answer to "what changed, when, and by whom" for any
record -- append-only, never edited after the fact. A record's own
identity is the id of its own creation entry, so identity is tied
directly to the history itself rather than to whatever the projected
table's own storage happens to assign. Each record type also gets a
real typed table generated from its definition (`schema.md`), kept in
sync in the same transaction as the log entry. That's what a dashboard
queries; nothing about analysis touches the log directly.

**Nothing is ever hard-deleted.** Archiving/unarchiving a record are
themselves just additive log entries -- never a row removal, never a
rewrite of prior history. Listing/counting records excludes archived
ones by default (an opt-in flag brings them back); looking a record up
directly, or its full history, always reaches it regardless of archive
state. Accounts follow the same convention.

### Storage

Runs on SQLite today -- available, reliable, and enough to prove the
history/projection design end to end. The storage layer (`src/db.lua`)
is written as a small, deliberately thin adapter so that moving to a
different backend later, if concurrency or scale ever demands it,
doesn't require touching the history or record logic above it.

Multiple independent installations (each with its own users and data)
are one database file per installation, not one shared database
filtered by an installation id -- clean isolation by construction, and
enough concurrency headroom for many people using one installation's
data at once.

## Sandboxed extensibility

Because record-type definitions and extensions are both just small
scripts, and both need to run without becoming a way for one
definition or extension to reach outside what it was actually granted,
loading either kind of file happens inside a restricted execution
environment: untrusted source runs bound to an environment table
exposing only what's needed for its role -- a record-type definition
gets just enough to construct and return a plain description, nothing
that touches the filesystem, network, or process state; an extension
gets read-only lookups, write access, or networking, but only exactly
what its own declaration asked for and had approved. Nothing gets more
than it explicitly asked for and was granted, and nothing needs a
second sandboxing layer or trust boundary bolted on separately -- one
mechanism covers both.

## Event model

Implemented today:

- **Before-hooks** (`entity.before_create`, `entity.before_update`):
  synchronous, inside the write, and can return issues that block the
  change from happening at all. This is where validation rules live.
- **After-hooks** (`entity.after_create`, `entity.after_update`,
  `entity.after_archive`): queued at write time, executed later
  (see `extensibility.md`), and cannot block or undo anything. This is
  where integrations and derived-record automation live -- a slow or
  broken extension can never hang or corrupt someone's data entry.
  Unarchiving a record does **not** trigger an after-hook today (only
  archiving does) -- not a deliberate design stance, just not wired up
  yet.

Not yet implemented: a batch-level before/after pair distinct from the
per-row hooks (batch validation and creation exist and run the per-row
hooks already, but there's no separate whole-batch hook).

## Pages

A built-in document/notebook record type (not a deployment-authored
one) -- a page's own id is its identity, not its title, so renaming or
moving it is a plain field edit on `title`/`parent_id`, never a
collision risk the way a name-is-identity wiki page has to worry about.

- **A real tree, not a naming convention.** `parent_id` is a nullable
  self-reference (unset = top-level); breadcrumbs are computed by
  walking that chain on read, not cached -- so they can never go stale,
  and moving a page under a different parent is exactly one field
  write. Moving a page underneath its own descendant is rejected
  outright at save time (a real error, not silent data corruption or
  an infinite loop waiting to happen at render time).
- **Cross-page links** use an inline `[[title]]` / `[[folder/title]]`
  syntax, parsed out of the raw content and resolved by title (and, if
  a folder prefix is given, by requiring the resolved page's immediate
  parent to carry that title -- a one-level disambiguator, not a full
  path walk). A link to a page that doesn't exist yet renders as a
  plain, visibly-marked placeholder instead of a broken link. Links are
  a derived index over content (recomputed wholesale on every save, not
  hand-maintained data with their own history) -- the content that
  generates them already has full audit history in its own right.
- **Rendering** shells out to `cmark` (CommonMark) rather than a
  vendored/hand-rolled Markdown parser -- the same "bind to an existing,
  battle-tested implementation" stance as bcrypt/HMAC, except this one
  is an external runtime dependency (must be on `PATH`), not something
  compiled into the binary. `cmark`'s default (non-`--unsafe`) mode
  strips raw HTML out of the source Markdown before rendering, which
  matters here specifically: page content is user-authored and shown
  to other users, so it must never be able to smuggle in a raw
  `<script>` tag.
- Creating/editing a page through the generic `entity create`/`entity
  update` CLI (rather than the dedicated web routes) still works, but
  bypasses link re-indexing -- that's layered on top of the generic
  entity path deliberately (see "Sandboxed extensibility" above: this
  behavior is specific to one record type, not something the generic
  layer should know about), not something every write path gets for
  free.

## Auth

Every request other than logging in or out requires proof of an active
session, and that proof carries no trust in itself: what an account is
allowed to do is re-read from its current record on every single
request, never cached in or trusted from anything the session carries.
That one property is what makes revoking access, changing someone's
permissions, or archiving an account take effect immediately -- on
their very next request -- rather than only once whatever they're
holding expires on its own schedule.

- **Passwords** are never stored or compared directly -- only a
  one-way, deliberately slow hash (bcrypt) is kept, so a leaked
  database doesn't hand over usable credentials.
- **Sessions** are a signed, tamper-evident token (an identity, an
  expiry, and a cryptographic signature over both) rather than a
  server-side record that has to be looked up and kept in sync --
  verifying one is just checking the signature and the expiry, and a
  tampered or expired token is rejected outright.
- **Cross-site request forgery** is guarded against on every action
  that changes data: a second, independent token has to be presented
  alongside the session and match what was issued with it, so a
  request forged from another site (which can ride along with
  cookies, but can't read or replay this second value) is rejected.
- **Routes**: logging in and out are the only actions available
  without a session; everything else resolves who's asking and what
  they're allowed to do from the verified session before anything else
  runs.
- **Permissions** are short capability strings on the account (a
  baseline capability everyone needs, plus elevated ones for
  higher-privilege actions like ad hoc querying), checked per route.

## Chat

A built-in assistant, not a bolted-on integration: real per-user
conversation sessions, DB-backed history (nothing ever deleted --
compaction marks old turns out-of-context, it doesn't remove them),
and a small, explicit tool registry the model can act through.

- **The LLM backend is pluggable, not hardcoded.** A thin interface
  (`generate(model, system_prompt, prompt)`, optionally `embeddings`)
  is loaded dynamically by name rather than required directly -- the
  real backend (Google Vertex AI, via a `curl` shell-out authenticated
  with fresh short-lived credentials, the same "bind to an existing,
  battle-tested tool" stance used for Markdown rendering and password
  hashing) and a fully deterministic backend used by this project's
  own tests are just two named implementations behind the same seam.
  Routine test runs use the deterministic one -- exercising a real
  paid API on every test iteration would be slow, flaky, and a real,
  avoidable cost.
- **Context-window compaction**: once a session's active history
  crosses an estimated token threshold, everything except the most
  recent few turns gets summarized (via one real model call) into a
  single new message, and the summarized originals are marked
  out-of-context -- never deleted. The chat UI still shows them,
  dimmed, so what the model can no longer see stays visible to the
  human, not hidden.
- **Tool use is a small, explicit registry, not an open plugin
  system** -- the model can only ever call exactly what's listed
  (searching pages, creating a page, updating a page today), with no
  escape hatch to anything else.
- **A destructive tool call cannot execute without a human approving
  it first**, and that approval is a real, persisted two-phase state,
  not a blocking prompt: a single web request can't pause mid-call
  waiting on a person's real-world response time, so a destructive
  request instead gets recorded as a pending action and the request
  returns immediately; a separate, later request (clicking Approve or
  Deny in the chat UI) executes it -- or records the refusal -- and
  only then resumes the conversation. Read-only calls (search) run
  immediately with no approval step; nothing about the mechanism
  distinguishes "asking" from "changing data" except that one fact.
- **Every tool call is attributed to the real, authenticated user
  driving that conversation, never a separate "agent" identity** --
  a page the assistant creates or updates shows up in that page's own
  audit history exactly like a direct manual edit, just additionally
  tagged with which chat session it came from, so the ledger can still
  answer "was this a direct edit or something the assistant did" without
  that ever affecting who it's attributed to.
- **Semantic search** blends keyword matching with embedding
  cosine-similarity when a page has been explicitly indexed -- indexing
  a page is a deliberate, separate action, never an automatic side
  effect of saving it, since computing an embedding is a real API call
  per page. A query's own embedding, by contrast, is computed fresh on
  every search (one cheap, real-time call) -- only the *document* side
  of the comparison is precomputed and cached. SQLite FTS5 was
  evaluated for the keyword half first, per the original plan for this
  feature; confirmed directly that this project's SQLite binding
  doesn't have it compiled in, so search instead scores every active
  page directly, an acceptable tradeoff at the scale this is built for.
