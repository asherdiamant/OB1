-- Delete Archive: Automatic backup of deleted thoughts
-- Copies every deleted row from `thoughts` to `thoughts_deleted` via a trigger.
-- No changes to existing code — the MCP server's delete_thought tool continues
-- to call .delete().eq("id", id) as before. The trigger fires transparently.
--
-- Recovery: SELECT * FROM thoughts_deleted WHERE original_id = '<uuid>';
-- To restore: INSERT INTO thoughts (id, content, embedding, metadata, created_at)
--             SELECT original_id, content, embedding, metadata, original_created_at
--             FROM thoughts_deleted WHERE original_id = '<uuid>';
-- Cleanup:   DELETE FROM thoughts_deleted WHERE deleted_at < NOW() - INTERVAL '90 days';

-- Archive table mirrors thoughts but adds deletion metadata
CREATE TABLE IF NOT EXISTS thoughts_deleted (
    id BIGSERIAL PRIMARY KEY,
    original_id TEXT NOT NULL,              -- the id from the thoughts table
    content TEXT NOT NULL,
    embedding vector(1536),
    metadata JSONB DEFAULT '{}'::jsonb,
    original_created_at TIMESTAMPTZ,        -- when the thought was originally created
    deleted_at TIMESTAMPTZ DEFAULT NOW(),   -- when it was deleted
    deleted_by TEXT DEFAULT 'mcp'           -- source of deletion (future-proofing)
);

CREATE INDEX IF NOT EXISTS idx_thoughts_deleted_original_id ON thoughts_deleted (original_id);
CREATE INDEX IF NOT EXISTS idx_thoughts_deleted_deleted_at ON thoughts_deleted (deleted_at DESC);

-- Trigger function: runs BEFORE DELETE on thoughts
CREATE OR REPLACE FUNCTION archive_deleted_thought()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO thoughts_deleted (original_id, content, embedding, metadata, original_created_at)
    VALUES (OLD.id::TEXT, OLD.content, OLD.embedding, OLD.metadata, OLD.created_at);
    RETURN OLD;  -- allow the delete to proceed
END;
$$;

-- Attach the trigger
DROP TRIGGER IF EXISTS trg_archive_deleted_thought ON thoughts;
CREATE TRIGGER trg_archive_deleted_thought
    BEFORE DELETE ON thoughts
    FOR EACH ROW
    EXECUTE FUNCTION archive_deleted_thought();

-- Undelete function: restores a thought from the archive back to the main table
-- Pass either the archive row id or the original_id to find the thought.
-- If multiple archived versions exist for the same original_id, restores the most recent.
-- Returns the restored thought's id, or null if not found.
CREATE OR REPLACE FUNCTION recover_deleted_thought(archive_id BIGINT DEFAULT NULL, orig_id TEXT DEFAULT NULL)
RETURNS TABLE (restored_id TEXT, content TEXT, deleted_at TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    -- Find the archived thought
    IF archive_id IS NOT NULL THEN
        SELECT * INTO rec FROM thoughts_deleted td WHERE td.id = archive_id;
    ELSIF orig_id IS NOT NULL THEN
        SELECT * INTO rec FROM thoughts_deleted td WHERE td.original_id = orig_id
        ORDER BY td.deleted_at DESC LIMIT 1;
    ELSE
        RAISE EXCEPTION 'Must provide either archive_id or orig_id';
    END IF;

    IF rec IS NULL THEN
        RETURN;
    END IF;

    -- Re-insert into thoughts (disable the delete trigger temporarily isn't needed —
    -- we're inserting, not deleting)
    INSERT INTO thoughts (id, content, embedding, metadata, created_at)
    VALUES (rec.original_id, rec.content, rec.embedding, rec.metadata, rec.original_created_at)
    ON CONFLICT (id) DO NOTHING;

    -- Remove from archive
    DELETE FROM thoughts_deleted WHERE thoughts_deleted.id = rec.id;

    -- Return what was restored
    restored_id := rec.original_id;
    content := rec.content;
    deleted_at := rec.deleted_at;
    RETURN NEXT;
END;
$$;

-- Purge old deleted thoughts from the archive
CREATE OR REPLACE FUNCTION purge_deleted_thoughts(older_than_days INT DEFAULT 90)
RETURNS TABLE (purged_count BIGINT)
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM thoughts_deleted
    WHERE deleted_at < NOW() - (older_than_days || ' days')::INTERVAL;

    GET DIAGNOSTICS purged_count = ROW_COUNT;
    RETURN NEXT;
END;
$$;

-- List recently deleted thoughts (for browsing the archive)
CREATE OR REPLACE FUNCTION list_deleted_thoughts(
    search_term TEXT DEFAULT NULL,
    max_results INT DEFAULT 20
)
RETURNS TABLE (
    archive_id BIGINT,
    original_id TEXT,
    content TEXT,
    metadata JSONB,
    original_created_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT td.id, td.original_id, td.content, td.metadata, td.original_created_at, td.deleted_at
    FROM thoughts_deleted td
    WHERE (search_term IS NULL OR td.content ILIKE '%' || search_term || '%')
    ORDER BY td.deleted_at DESC
    LIMIT max_results;
END;
$$;
