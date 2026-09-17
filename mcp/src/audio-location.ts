import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { resolveDatabasePath } from "./database.ts"

/// Where a deleted recording is kept until its purge date.
///
/// The app writes this store beside its database, under the same Application Support directory,
/// so the path is derived from the database the server was given rather than from a second
/// setting that could disagree with it.
export const recoverableStoreRoot = (): string =>
  join(dirname(resolveDatabasePath()), "Recently Deleted")

/// Whether a call's audio can still be read from disk.
///
/// A call that finished and was cleaned up keeps its row and loses its working folder, so the
/// path the row holds no longer exists. The audio itself is usually not gone: the app moves it to
/// the recoverable store before removing the folder, which is how a recording can still be played
/// and still be restored. Reporting the stored path alone told a caller the audio was there when
/// the folder had been removed, and reported false for every one of the nine calls waiting on a
/// name, whose audio had moved to that store. Both halves of the answer have to be checked, and
/// both are checked here so the two tools that answer this question cannot drift apart.
export const audioAvailable = (audioPath: string | null, callId: string): boolean => {
  const candidates: string[] = []
  if (audioPath !== null) {
    const directory = dirname(audioPath)
    candidates.push(audioPath, join(directory, "system.m4a"), join(directory, "call.m4a"))
  }
  const recent = join(recoverableStoreRoot(), callId, "payload")
  candidates.push(
    join(recent, "system.m4a"),
    join(recent, "call.m4a"),
    join(recent, "microphone.m4a"),
  )
  return candidates.some(existsSync)
}
