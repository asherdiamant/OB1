# Delete Archive

Automatic backup of deleted thoughts. A Postgres trigger copies every deleted row from `thoughts` to `thoughts_deleted` before the delete executes, making all deletions recoverable. Paired with the `delete_thought` tool to ensure destructive operations always have a recovery path.

## How it works

- A `BEFORE DELETE` trigger on the `thoughts` table fires on every delete
- The trigger copies the full row (content, embedding, metadata, timestamps) to `thoughts_deleted`
- The original delete proceeds normally
- Two MCP tools (`recover_deleted_thought`, `list_deleted`) provide recovery access

## Schema

- `thoughts_deleted` — mirrors the `thoughts` table with added `deleted_at`, `deleted_by`, and `original_id` columns
- `trg_archive_deleted_thought` — the trigger that fires on every DELETE

## MCP Tools

Two new tools are added to the MCP server when this extension is installed:

| Tool | Description |
|------|-------------|
| `recover_deleted_thought` | Restore a deleted thought by its original ID. Moves it back to `thoughts` and removes it from the archive. |
| `list_deleted` | Browse recently deleted thoughts. Optional keyword search. Returns content previews and deletion timestamps. |
| `purge_deleted` | Permanently remove old entries from the archive. Takes a `days` param (default 90). |

## Recovery

### Via MCP tools (recommended)
```
list_deleted(search="keyword")     → browse deleted thoughts
recover_deleted_thought(id="<uuid>")  → restore a specific thought
```

### Via SQL (direct)
```sql
-- Find a deleted thought
SELECT * FROM thoughts_deleted WHERE content ILIKE '%search term%';

-- Restore via the function
SELECT * FROM recover_deleted_thought(orig_id := '<uuid>');

-- Or manually
INSERT INTO thoughts (id, content, embedding, metadata, created_at)
SELECT original_id, content, embedding, metadata, original_created_at
FROM thoughts_deleted WHERE id = <archive_id>;
```

## Cleanup

Use the `purge_deleted` MCP tool to remove old archive entries:

```
purge_deleted(days=90)   → permanently remove entries deleted more than 90 days ago
```

## Installation

1. Run `schema.sql` against your Supabase/Postgres instance (creates the table, trigger, and functions)
2. Redeploy the MCP server with the updated `index.ts` (adds `recover_deleted_thought` and `list_deleted` tools)

The trigger activates immediately on future deletes. No existing data is affected.
