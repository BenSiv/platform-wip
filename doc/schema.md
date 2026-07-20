# Record Types as Code

A record type is defined as a small declarative file, one file per
type -- not a schema entered through an admin UI, and not a
serialized data format like YAML or JSON. The definition is itself
executable, in the same language as everything else in the system, so
there's exactly one thing a definition author, an extension author, or
the platform itself ever needs to know how to read or write. That
also means a definition gets ordinary language conveniences (comments,
no quoting-every-key ceremony) for free, with no second parser to
maintain for a serialization format that would have bought nothing a
plain definition doesn't already give.

## Format

```lua
-- schemas/reagent.lua
return {
  name = "reagent",
  fields = {
    {name = "lot_number",    type = "text",      required = true},
    {name = "concentration", type = "number",    required = true},
    {name = "prepared_on",   type = "date",      required = true},
    {name = "status",        type = "select",    required = true,
      values = {"active", "depleted", "discarded"}},
    {name = "prepared_from", type = "reference", required = false,
      entity_type = "reagent"},
  },
}
```

## Field types (deliberately five)

| type | meaning |
|---|---|
| `text` | free string |
| `number` | numeric, integer or float |
| `date` | ISO 8601 date |
| `select` | one of a fixed `values` list |
| `reference` | points at another record by id, optionally constrained to a specific record type |

A `number` field may optionally declare `min`/`max` -- wired into the
registration form's number input (bounding its native spinner arrows),
but **a UI hint only, not enforced when a value is actually saved**. A
real range constraint (rejecting an out-of-bounds value outright) is
still a validation extension's job (see `extensibility.md`) -- `min`/
`max` here don't replace that, they just stop the input widget itself
from suggesting an obviously-invalid value. Making this a real,
enforced constraint at the definition level is a bigger change (the
underlying storage would need new columns) not done yet.

Deferred: multi-select, attachments/files, computed/formula fields,
enforced numeric bounds. None of these are ruled out by the design --
they're just not needed to prove the core registration workflow end
to end. (Rich text editing exists for the built-in Pages record type --
see `architecture.md`'s "Pages" section -- but a schema-defined `text`
field on a custom record type is still a plain string, no markup.)

## Loading is sandboxed, not just a bare load

A definition file is executable, not inert data the way a YAML/JSON
file would have been -- so it isn't loaded by simply running it: it's
bound to a restricted execution environment that can only construct
and return a plain description, nothing that could touch the
filesystem, network, or anything else an extension might legitimately
need. Same security posture a data format would have had, without
needing a second parser to get there.

## What a definition generates

Loading a definition does two things:

1. Registers (or updates) the record type's own field list, which the
   history log and validation both read at runtime.
2. Generates (or migrates) a real, typed table for that record type --
   `reagent(id, lot_number, concentration, prepared_on, status,
   prepared_from, created_by, created_at, updated_by, updated_at,
   last_event_id, archived_at)` -- the thing a dashboard actually
   queries.

Changes to a definition are themselves ordinary version-control
commits: renaming or adding a field is a diff against
`schemas/reagent.lua`, reviewable and revertable the same way any
other change is.

## Where a generic data format still shows up

Only as invisible storage plumbing: the history log serializes each
entry's field changes as a small blob inside a single column. That's
never something a definition or extension author writes by hand, so
it isn't a format anyone needs to learn.
