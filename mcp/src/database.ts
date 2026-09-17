import { homedir } from "node:os"
import { isAbsolute, join } from "node:path"
import { type Client, createClient } from "@libsql/client"

export class InvalidDatabasePathError extends Error {
  readonly name = "InvalidDatabasePathError"

  constructor(readonly path: string) {
    super("database path must be absolute")
  }
}

export const openDatabase = (path: string): Client => {
  if (!isAbsolute(path)) throw new InvalidDatabasePathError(path)
  return createClient({ url: `file:${path}` })
}

/// Where the app keeps its data on this Mac.
export const applicationDirectory = (): string =>
  join(homedir(), "Library", "Application Support", "CallRecorder")

/// The database the server was told to read, or the one the app writes by default.
///
/// One function rather than the same expression in two files: a second copy that drifts would
/// send the server looking for audio beside the wrong database.
///
/// The setting is read per call rather than at import, because a caller is allowed to set it after
/// this module loads. It is read by destructuring: the compiler forbids dot access on the
/// environment's index signature and the linter forbids the bracket form.
export const resolveDatabasePath = (): string => {
  const { CALL_RECORDER_DB_PATH: configured } = process.env
  return configured ?? join(applicationDirectory(), "calls.db")
}

export const migrateSearchSchema = async (database: Client): Promise<void> => {
  await database.execute("PRAGMA foreign_keys = ON")
  await database.execute("PRAGMA busy_timeout = 3000")
  const version = await database.execute("PRAGMA user_version")
  if (Number(version.rows[0]?.[0] ?? 0) < 2) {
    const transaction = await database.transaction("write")
    try {
      const lockedVersion = await transaction.execute("PRAGMA user_version")
      if (Number(lockedVersion.rows[0]?.[0] ?? 0) < 2) {
        await transaction.executeMultiple(`
    CREATE TABLE IF NOT EXISTS transcript_chunks (
      id TEXT PRIMARY KEY,
      call_id TEXT NOT NULL REFERENCES transcripts(call_id) ON DELETE CASCADE,
      start_ms INTEGER NOT NULL CHECK(start_ms >= 0),
      end_ms INTEGER NOT NULL CHECK(end_ms >= start_ms),
      text TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      embedding F32_BLOB(256),
      embedding_model TEXT,
      UNIQUE(call_id, content_hash, start_ms, end_ms)
    );

    CREATE INDEX IF NOT EXISTS transcript_chunks_call_time_idx
      ON transcript_chunks(call_id, start_ms, end_ms);

    DROP INDEX IF EXISTS transcript_chunks_embedding_idx;

    CREATE VIRTUAL TABLE IF NOT EXISTS transcript_chunks_fts USING fts5(
      id UNINDEXED,
      text,
      content='transcript_chunks',
      content_rowid='rowid',
      tokenize='unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER IF NOT EXISTS transcript_chunks_after_insert
      AFTER INSERT ON transcript_chunks BEGIN
        INSERT INTO transcript_chunks_fts(rowid, id, text)
        VALUES (new.rowid, new.id, new.text);
      END;

    CREATE TRIGGER IF NOT EXISTS transcript_chunks_after_delete
      AFTER DELETE ON transcript_chunks BEGIN
        INSERT INTO transcript_chunks_fts(transcript_chunks_fts, rowid, id, text)
        VALUES ('delete', old.rowid, old.id, old.text);
      END;

    CREATE TRIGGER IF NOT EXISTS transcript_chunks_after_update
      AFTER UPDATE ON transcript_chunks BEGIN
        INSERT INTO transcript_chunks_fts(transcript_chunks_fts, rowid, id, text)
        VALUES ('delete', old.rowid, old.id, old.text);
        INSERT INTO transcript_chunks_fts(rowid, id, text)
        VALUES (new.rowid, new.id, new.text);
      END;

    PRAGMA user_version = 2;
    `)
      }
      await transaction.commit()
    } catch (error: unknown) {
      await transaction.rollback()
      throw error
    }
  }
  await migrateSpeakerReviewRequestSchema(database)
}

const migrateSpeakerReviewRequestSchema = async (database: Client): Promise<void> => {
  const existing = await database.execute(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'speaker_review_requests'",
  )
  if (existing.rows.length > 0) return

  const transaction = await database.transaction("write")
  try {
    const locked = await transaction.execute(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'speaker_review_requests'",
    )
    if (locked.rows.length === 0) {
      await transaction.executeMultiple(`
        CREATE TABLE speaker_review_requests (
          id TEXT PRIMARY KEY,
          cluster_id TEXT NOT NULL REFERENCES pending_speaker_clusters(id) ON DELETE CASCADE,
          participant_id TEXT REFERENCES participants(id) ON DELETE RESTRICT,
          action TEXT NOT NULL CHECK(action IN ('confirm','keepUnknown','reopen')),
          status TEXT NOT NULL CHECK(status IN ('pending','running','completed','failed')),
          error TEXT,
          claim_token TEXT UNIQUE,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          CHECK(
            (action = 'confirm' AND participant_id IS NOT NULL)
            OR (action IN ('keepUnknown','reopen') AND participant_id IS NULL)
          )
        );
        CREATE UNIQUE INDEX speaker_review_requests_active
          ON speaker_review_requests(cluster_id)
          WHERE status IN ('pending','running');
      `)
    }
    await transaction.commit()
  } catch (error: unknown) {
    await transaction.rollback()
    throw error
  }
}
