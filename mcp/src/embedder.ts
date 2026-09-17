import { readFileSync } from "node:fs"
import { join } from "node:path"
import { AutoModel, AutoTokenizer, env } from "@huggingface/transformers"
import { z } from "zod"
import type { QueryEmbedder } from "./search.ts"

export const EMBEDDING_MODEL_ID = "onnx-community/embeddinggemma-300m-ONNX"
export const EMBEDDING_MODEL_REVISION = "5090578d9565bb06545b4552f76e6bc2c93e4a66"
export const EMBEDDING_DIMENSIONS = 256
/// Stamped on every chunk this model embeds. Search compares it so vectors from an earlier
/// model are never ranked against a query vector they cannot be compared with.
export const EMBEDDING_MODEL_VERSION = `${EMBEDDING_MODEL_ID}@${EMBEDDING_MODEL_REVISION}:q4:mrl256`

/// The record the app writes beside the model folders when it installs one.
///
/// The app downloads this model now, and it records the revision it verified the bytes of. Reading
/// that record keeps one source of truth: without it, an app and a model that drifted apart would
/// fail as a load error instead of being used at the revision that is actually on disk.
export const InstalledMarkerSchema = z
  .object({ model: z.string(), revision: z.string().min(1) })
  .readonly()

export const installedRevision = (cacheDirectory: string): string => {
  try {
    const marker = InstalledMarkerSchema.safeParse(
      JSON.parse(readFileSync(join(cacheDirectory, "installed.json"), "utf8")),
    )
    if (marker.success && marker.data.model === EMBEDDING_MODEL_ID) return marker.data.revision
  } catch {
    // No marker, or one written before the app wrote any. The pinned revision is the honest
    // fallback: it is the revision this build was written against.
  }
  return EMBEDDING_MODEL_REVISION
}

/// The stamp put on every embedded chunk, for the revision that is installed.
export const embeddingModelVersion = (cacheDirectory: string): string =>
  `${EMBEDDING_MODEL_ID}@${installedRevision(cacheDirectory)}:q4:mrl256`

export const embeddingModelSource = (cacheDirectory: string, allowDownload: boolean): string =>
  allowDownload
    ? EMBEDDING_MODEL_ID
    : join(cacheDirectory, EMBEDDING_MODEL_ID, installedRevision(cacheDirectory))

export type FeatureExtractor = (texts: readonly string[]) => Promise<readonly (readonly number[])[]>

export class InvalidModelOutputError extends Error {
  readonly name = "InvalidModelOutputError"
}

const ModelOutputSchema = z.array(z.array(z.number()))

const searchVector = (values: readonly number[]): readonly number[] => {
  if (values.length < EMBEDDING_DIMENSIONS || values.some((value) => !Number.isFinite(value))) {
    throw new InvalidModelOutputError("embedding model returned an invalid vector")
  }
  const truncated = values.slice(0, EMBEDDING_DIMENSIONS)
  const norm = Math.sqrt(truncated.reduce((sum, value) => sum + value * value, 0))
  if (!Number.isFinite(norm) || norm === 0) {
    throw new InvalidModelOutputError("embedding model returned a zero vector")
  }
  return truncated.map((value) => value / norm)
}

export class EmbeddingService implements QueryEmbedder {
  constructor(
    private readonly extractor: FeatureExtractor,
    readonly modelVersion: string,
  ) {}

  async embedQuery(query: string): Promise<readonly number[]> {
    return (await this.embed([`task: search result | query: ${query}`]))[0] ?? []
  }

  async embedDocuments(documents: readonly string[]): Promise<readonly (readonly number[])[]> {
    return this.embed(documents.map((text) => `title: none | text: ${text}`))
  }

  private async embed(texts: readonly string[]): Promise<readonly (readonly number[])[]> {
    const vectors = await this.extractor(texts)
    if (vectors.length !== texts.length) {
      throw new InvalidModelOutputError("embedding model returned the wrong batch size")
    }
    return vectors.map(searchVector)
  }
}

export const loadEmbeddingService = async (
  cacheDirectory: string,
  allowDownload: boolean,
): Promise<EmbeddingService> => {
  env.allowLocalModels = true
  env.allowRemoteModels = allowDownload
  env.cacheDir = cacheDirectory
  const options = {
    cache_dir: cacheDirectory,
    local_files_only: !allowDownload,
    revision: installedRevision(cacheDirectory),
  }
  const modelSource = embeddingModelSource(cacheDirectory, allowDownload)
  const [tokenizer, model] = await Promise.all([
    AutoTokenizer.from_pretrained(modelSource, options),
    AutoModel.from_pretrained(modelSource, { ...options, dtype: "q4" }),
  ])

  return new EmbeddingService(async (texts) => {
    const inputs = tokenizer([...texts], { padding: true, truncation: true })
    const output = await model(inputs)
    const raw: unknown = output.sentence_embedding.tolist()
    return ModelOutputSchema.parse(raw)
  }, embeddingModelVersion(cacheDirectory))
}
