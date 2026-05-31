# Commits and Time Travel

Embrace has a built-in version control system. Every data change is stored in a commit,
and users can navigate back in time, branch, and view different versions simultaneously.

## The Commit Model

All data storage in embrace is three-dimensional: `(FieldLID, RecordLID, CommitLID) → value`.
The third dimension — commits — provides full history.

### How Commits Work

In `Backend::Memory` (`src/persistency.cr`):

1. **Writing**: `set_value(field, record, value)` stores the value at the current commit.
   If the current commit is already closed (has a successor), a new commit is automatically
   created first via `close_and_add_commit`.

2. **Closing**: `close_and_add_commit` seals the current commit and creates a new one:
   ```crystal
   lid = get_new_lid
   @field2record2commit2value[RootCommit][lid][RootCommit] = context.current_commit
   context.current_commit = lid
   ```
   The new commit's predecessor is recorded in the `RootCommit` meta-field.

3. **Reading**: `get_value(field, record)` finds the most recent commit along the
   current commit path that has a value for that `(field, record)` pair:
   ```crystal
   commit = (commit_path_commits & cell_commits).max_by { |c| commit_rank[c] }
   ```

### Commit DAG

Commits form a directed acyclic graph (DAG), not a linear history. The `RootCommit`
meta-field (FieldLID = 0) stores predecessor relationships:

```
@field2record2commit2value[RootCommit][commit_lid][RootCommit] = predecessor_commit_lid
```

`get_commit_path` traverses from `context.current_commit` back to `context.root_commit`,
producing `[oldest, ..., newest]`.

Multiple branch tips can exist simultaneously:
```
    0 → 1 → 2 → 3 → 4        (branch A, tip = 4)
                  └→ 5 → 6    (branch B, tip = 6)
```

`get_ordered_commit_leaves` finds all commits that have no successors — these are the
branch tips.

## Context

`Persistency::Context` (`src/persistency.cr`) tracks the current position in the history:

| Field | Purpose |
|-------|---------|
| `root_commit` | Oldest commit in the current view (history boundary) |
| `current_commit` | Where new changes are written |
| `metadata_commit` | Reserved for future use |
| `version` | Increments on any context change (for cache invalidation) |

### ContextStack

`ContextStack` allows temporary context switching:

```crystal
persistency.contexts.push(other_context)
# ... read data at different commit ...
persistency.contexts.pop
```

This is used for transactions and temporary reads without affecting the main context.

## History Navigation in the GUI

`ShapeState` in `src/gui/shape.cr` provides history navigation:

### Navigating

`navigate_history(delta)` moves forward/backward along the commit path:
- `delta = -1`: move one commit back (Alt-Left)
- `delta = +1`: move one commit forward (Alt-Right)

The GUI shows the current position as `"3/5 (open)"` meaning commit 3 of 5 in the
current branch, with the commit still open for changes.

### Branching

Modifying data at an old commit automatically creates a new branch:
1. Navigate to commit 2 in a 5-commit history
2. Edit a cell → `set_value` is called
3. Since commit 2 is closed, `close_and_add_commit` creates commit 7
4. Commit 7's predecessor is commit 2
5. Now there are two branch tips: 5 (original) and 7 (new)

### Branch Selection

`select_branch(index)` switches between branch tips. The GUI provides a dropdown
showing available branches (auto-named, up to 200+).

### Committing

`do_commit()` explicitly closes the current commit and opens a new one.
This is available via Edit > Commit in the menu.

## Per-Shape Independence

Each Shape has its own `@context`. This means:
- Shape A can view commit 3 while Shape B views commit 7
- Shape A can be on branch A while Shape B is on branch B
- Navigating history in one Shape does not affect other Shapes
- Editing in one Shape at its current commit is visible to other Shapes
  (if they are at or after that commit)

## What Gets Committed

| Committed (in history) | Not committed (volatile) |
|------------------------|-------------------------|
| Table structure (add/remove table/field/record) | Shape configurations |
| Cell values | Configurator selections |
| Field names and ordering | Fieldlist assignments |
| Reference relationships | GUI layout |
| Commit metadata | Pivot caches |

## Transactions

`transaction(&)` in `Backend::Memory` provides a poor man's transaction:
- Clones the entire persistency state before the block
- On exception: replaces state with the clone (rollback)
- On success: the changes are kept

This is used for operations that must be atomic (e.g., factor-out).

## See Also

- [01-tables-fields-records](01-tables-fields-records.md) — the 3D storage model
- [08-shapes](08-shapes.md) — per-Shape contexts
- [10-file-format](10-file-format.md) — how history is persisted to disk
- `src/persistency.cr` — `Backend::Memory`, `Context`, `ContextStack`
- `src/gui/shape.cr` — `navigate_history`, `select_branch`, `do_commit`
