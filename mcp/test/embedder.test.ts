import { describe, expect, test } from "bun:test"
import { EmbeddingService, embeddingModelSource, type FeatureExtractor } from "../src/embedder.ts"

describe("EmbeddingService", () => {
  test("offline loading opens the exact downloaded snapshot", () => {
    // Given
    const cacheDirectory = "/tmp/embedding-cache"

    // When
    const source = embeddingModelSource(cacheDirectory, false)

    // Then
    expect(source).toBe(
      "/tmp/embedding-cache/onnx-community/embeddinggemma-300m-ONNX/5090578d9565bb06545b4552f76e6bc2c93e4a66",
    )
  })

  test("uses distinct retrieval prompts for queries and documents", async () => {
    // Given
    /** Test observation buffer: recording extractor inputs is its sole purpose. */
    const inputs: string[] = []
    const extractor: FeatureExtractor = async (texts) => {
      inputs.push(...texts)
      return texts.map(() => [1, ...Array.from({ length: 767 }, () => 0)])
    }
    const service = new EmbeddingService(extractor, "test-model")

    // When
    await service.embedQuery("find the launch plan")
    await service.embedDocuments(["The launch plan was approved."])

    // Then
    expect(inputs).toEqual([
      "task: search result | query: find the launch plan",
      "title: none | text: The launch plan was approved.",
    ])
  })

  test("truncates to 256 dimensions and renormalizes vectors", async () => {
    // Given
    const extractor: FeatureExtractor = async () => [
      [3, 4, ...Array.from({ length: 766 }, () => 0)],
    ]
    const service = new EmbeddingService(extractor, "test-model")

    // When
    const embedding = await service.embedQuery("query")

    // Then
    expect(embedding).toHaveLength(256)
    expect(embedding[0]).toBeCloseTo(0.6)
    expect(embedding[1]).toBeCloseTo(0.8)
  })

  test("rejects non-finite or too-short model output", async () => {
    // Given
    const extractor: FeatureExtractor = async () => [[Number.NaN]]
    const service = new EmbeddingService(extractor, "test-model")

    // When / Then
    expect(service.embedQuery("query")).rejects.toMatchObject({
      name: "InvalidModelOutputError",
    })
  })
})
