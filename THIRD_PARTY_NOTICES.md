# Third Party Notices

This file lists third-party model artifacts that RemoteCode may download on demand for Token Saver. The app does not vendor these weights in the source tree.

## Token Saver MLX Models

### samuelfaj/distill-1.7B-4bit-MLX

- Source: https://huggingface.co/samuelfaj/distill-1.7B-4bit-MLX
- Runtime: MLX
- License metadata: Apache-2.0
- Hugging Face API revision observed on 2026-06-13: `af905e680e12ab4630b78c8c7c8fc69eb1ddf288`
- Base model metadata: `samuelfaj/distill-1.7B-MLX`
- Use: fallback Token Saver distill/compression model below 16 GiB unified memory or when higher-tier migration fails.

### samuelfaj/distill-E4B-it-4-bit-MLX

- Source: https://huggingface.co/samuelfaj/distill-E4B-it-4-bit-MLX
- Runtime: MLX
- License metadata: blocked; Hugging Face API returned HTTP 401 without authentication on 2026-06-14.
- Hugging Face API revision observed on 2026-06-14: unavailable without authentication.
- Base model metadata: unavailable without authentication.
- Use: selected Token Saver distill/compression model on hosts with at least 16 GiB unified memory after download, checksum validation, warmup, and perf gates pass.

## Vendored Source Code

### mlx-swift-lm `gemma4` model port (patched copy)

- Source: https://github.com/ml-explore/mlx-swift-lm (tag `3.31.3`, files `Libraries/MLXLLM/Models/Gemma4Text.swift` and `Gemma4.swift`)
- License: MIT — Copyright (c) 2024 ml-explore
- Vendored at: `Sources/DistillCore/Gemma4ModelOverride.swift`
- Reason: the upstream `gemma4` port cannot load the fully-quantized, KV-shared `samuelfaj/distill-E4B-it-4-bit-MLX` checkpoint. This is a near-verbatim copy with two marked `// RC FIX` patches (KV-shared optional projections; quantizable `per_layer_model_projection`), registered as the `gemma4` model type. Remove once upstream loads the checkpoint directly.

## Token Saver Encoder Models (optional, BERT-family via MLXEmbedders)

These run real embedding inference for the encoder lane (cosine / near-dup / query-rerank / embedding-prototype zero-shot). License + pinned commit SHA verified against the Hugging Face model API on 2026-06-14. Only permissive licenses {Apache-2.0, MIT, BSD-3-Clause} pass the structural hard-gate (`TokenSaverEncoderManifest.approvedLicenses`); the download gate additionally requires an immutable 40-hex commit SHA.

### BAAI/bge-small-en-v1.5  (default embedder)

- Source: https://huggingface.co/BAAI/bge-small-en-v1.5
- Runtime: MLXEmbedders (MLX) · Role: embedder · max_seq_len 512
- License metadata: MIT
- Pinned revision: `5c38ec7c405ec4b44b94cc5a9bb96e735b38267a`

### TaylorAI/bge-micro-v2  (tiny / CI live-inference proof)

- Source: https://huggingface.co/TaylorAI/bge-micro-v2
- Runtime: MLXEmbedders (MLX) · Role: embedder · max_seq_len 512
- License metadata: MIT
- Pinned revision: `3edf6d7de0faa426b09780416fe61009f26ae589`

### sentence-transformers/all-MiniLM-L6-v2  (alternate embedder)

- Source: https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
- Runtime: MLXEmbedders (MLX) · Role: embedder · max_seq_len 512
- License metadata: Apache-2.0
- Pinned revision: `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`

> Provenance (V12): these are off-the-shelf public encoders used as-is — no weights retrained, no code copied from the `headroom` repo; the encoder lane is a clean Swift port of the *ideas*. The previously-listed `answerdotai/answerai-colbert-small-v1` and `nomic-ai/modernbert-embed-base` manifests keep the `pin-required-before-download` placeholder revision and are therefore NOT download-approved until a SHA is pinned and their arch is supported by the embedder backend (ModernBERT/ColBERT are not loadable by the vendored `Bert`/`NomicBert`).

## Verification Notes

- License metadata for the public 1.7B fallback was read from the Hugging Face model API on 2026-06-13.
- The `samuelfaj/distill-E4B-it-4-bit-MLX` endpoint returned HTTP 401 during unauthenticated license verification on 2026-06-14, so license metadata is still pending authenticated proof. The artifact itself is now runtime-verified: it loads and generates via the patched `RCGemma4ModelOverride` (`DistillE4BModelLoadTests` / `DistillE4BRawGenerationProbe`), and is the selected model on hosts with ≥16 GiB unified memory.
