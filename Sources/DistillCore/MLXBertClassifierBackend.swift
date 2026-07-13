import Foundation
import MLX
import MLXNN
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Real BERT sequence/token classification on MLX (I8.2 NLI, I8.4 NER).
///
/// MLXEmbedders' loader rejects classification checkpoints (`verify: [.all]` trips on the
/// extra `classifier.*` keys), so this loads the BERT trunk MANUALLY: instantiate
/// `BertModel` (which already builds the pooler → `tanh(pooler([CLS]))`), load the
/// safetensors, sanitize+filter to the trunk, then apply the `classifier.*` head here.
///
/// NOTE: the chosen checkpoints (yoshitomo-matsubara/bert-base-uncased-mnli, dslim/bert-base-NER)
/// are BERT-arch with safetensors. License is NOT vetted for commercial use — these run for
/// LOCAL validation only; the commercial path still goes through the V2/V3/V11 license gate.
public actor MLXBertClassifierBackend {
    public enum Mode: Sendable { case sequence, token }
    public enum BackendError: Error { case missingClassifierWeights, loadFailed(String) }

    public struct LocalModel: Sendable {
        public let repoId: String
        public let revision: String
        public let mode: Mode
        public let labels: [String]
        public let lowercase: Bool   // for the WordPiece fallback when no tokenizer.json ships
        public init(repoId: String, revision: String, mode: Mode, labels: [String], lowercase: Bool = true) {
            self.repoId = repoId; self.revision = revision; self.mode = mode; self.labels = labels
            self.lowercase = lowercase
        }

        /// MNLI: BERT-arch, English, safetensors. Label index resolved empirically (config has
        /// only LABEL_0/1/2); torchdistill MNLI order is {0: entailment, 1: neutral, 2: contradiction}.
        public static let mnli = LocalModel(
            repoId: "yoshitomo-matsubara/bert-base-uncased-mnli",
            revision: "0b3878cddf63e50996099c1cd7a3c2bd0aa141dd",
            mode: .sequence,
            labels: ["entailment", "neutral", "contradiction"])

        /// CoNLL NER: BERT-arch, English, safetensors.
        public static let ner = LocalModel(
            repoId: "dslim/bert-base-NER",
            revision: "d1a3e8f13f8c3566299d95fcfc9a8d2382a9affc",
            mode: .token,
            labels: ["O", "B-MISC", "I-MISC", "B-PER", "I-PER", "B-ORG", "I-ORG", "B-LOC", "I-LOC"],
            lowercase: false)  // bert-base-CASED; ships no tokenizer.json → WordPiece from vocab.txt

        /// LLMLingua-2 prose pruner (I12.6): BERT-arch token classifier, per-token keep/drop.
        /// Multilingual cased; ships safetensors + tokenizer.json.
        public static let llmlingua2 = LocalModel(
            repoId: "microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank",
            revision: "5f0c82792b7ea14c6484e015b6a072009496b7f2",
            mode: .token,
            labels: ["drop", "keep"],
            lowercase: false)
    }

    private let model: LocalModel
    private var bert: BertModel?
    private var classifierWeight: MLXArray?   // [numLabels, hidden]
    private var classifierBias: MLXArray?     // [numLabels]
    private var tokenizer: (any MLXLMCommon.Tokenizer)?
    private var wordPiece: BertWordPieceTokenizer?
    private var clsTokenId = 101
    private var sepTokenId = 102
    private var padTokenId = 0

    public init(model: LocalModel) { self.model = model }

    private func ensureLoaded() async throws {
        if bert != nil { return }
        // Download the checkpoint dir (safetensors + config + tokenizer).
        let dir = try await MLXHuggingFaceBridges.hubDownloader().download(
            id: model.repoId, revision: model.revision,
            matching: ["*.safetensors", "*.json", "*.txt", "tokenizer*", "vocab*"],
            useLatest: false, progressHandler: { _ in })

        // Build the trunk from config.json.
        let configData = try Data(contentsOf: dir.appending(component: "config.json"))
        let config = try JSONDecoder().decode(BertConfiguration.self, from: configData)
        let trunk = BertModel(config, lmHead: false)

        // Load all weights, sanitize, split off the classification head.
        guard let stURL = firstSafetensors(in: dir) else { throw BackendError.loadFailed("no safetensors") }
        let raw = try MLX.loadArrays(url: stURL)
        let sanitized = trunk.sanitize(weights: raw)
        guard let w = sanitized["classifier.weight"], let b = sanitized["classifier.bias"] else {
            throw BackendError.missingClassifierWeights
        }
        let trunkWeights = sanitized.filter {
            !$0.key.hasPrefix("classifier") && !$0.key.hasPrefix("lm_head")
        }
        try trunk.update(parameters: ModuleParameters.unflattened(trunkWeights), verify: .none)
        eval(trunk)

        // Prefer the HF tokenizer (needs tokenizer.json); fall back to a WordPiece
        // tokenizer built from vocab.txt for checkpoints that ship no tokenizer.json
        // (e.g. dslim/bert-base-NER).
        do {
            let tok = try await MLXHuggingFaceBridges.tokenizerLoader().load(from: dir)
            clsTokenId = tok.convertTokenToId("[CLS]") ?? 101
            sepTokenId = tok.convertTokenToId("[SEP]") ?? 102
            padTokenId = tok.convertTokenToId("[PAD]") ?? 0
            self.tokenizer = tok
        } catch {
            guard let wp = BertWordPieceTokenizer(
                vocabFile: dir.appending(component: "vocab.txt"), lowercase: model.lowercase) else {
                throw BackendError.loadFailed("no tokenizer.json and no usable vocab.txt: \(error)")
            }
            clsTokenId = wp.clsId; sepTokenId = wp.sepId; padTokenId = wp.padId
            self.wordPiece = wp
        }

        self.bert = trunk
        self.classifierWeight = w
        self.classifierBias = b
    }

    private func encodeNoSpecial(_ text: String) -> [Int] {
        if let tokenizer { return tokenizer.encode(text: text, addSpecialTokens: false) }
        if let wordPiece { return wordPiece.encode(text) }
        return []
    }

    private func tokenString(_ id: Int) -> String {
        if let tokenizer { return tokenizer.decode(tokenIds: [id], skipSpecialTokens: true) }
        if let wordPiece { return wordPiece.tokenString(id) }
        return ""
    }

    public func warmup() async throws {
        try await ensureLoaded()
        switch model.mode {
        case .sequence: _ = try await classifyPair(premise: "warmup", hypothesis: "warmup")
        case .token: _ = try await classifyTokens("warmup")
        }
    }

    public func reclaimIdleMemory() { MLX.Memory.clearCache() }

    /// I8.2: NLI — returns softmax probabilities aligned to `model.labels`.
    public func classifyPair(premise: String, hypothesis: String) async throws -> [Float] {
        try await ensureLoaded()
        guard let bert, let w = classifierWeight, let b = classifierBias else {
            throw BackendError.loadFailed("not loaded")
        }
        let pIds = encodeNoSpecial(premise)
        let hIds = encodeNoSpecial(hypothesis)
        let ids = [clsTokenId] + pIds + [sepTokenId] + hIds + [sepTokenId]
        let types = Array(repeating: Int32(0), count: pIds.count + 2)
            + Array(repeating: Int32(1), count: hIds.count + 1)
        let input = MLXArray(ids.map { Int32($0) }).reshaped([1, ids.count])
        let tokenTypes = MLXArray(types).reshaped([1, ids.count])
        let mask = MLXArray.ones([1, ids.count], type: Int32.self)
        let out = bert(input, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
        guard let pooled = out.pooledOutput else { throw BackendError.loadFailed("no pooled output") }
        let logits = matmul(pooled, w.transposed(1, 0)) + b   // [1, numLabels]
        let probs = softmax(logits, axis: -1)
        probs.eval()
        return probs.reshaped([model.labels.count]).asArray(Float.self)
    }

    public struct EntailmentVerdict: Sendable, Equatable {
        public let entailment: Float
        public let neutral: Float
        public let contradiction: Float
    }

    public func entailment(premise: String, hypothesis: String) async throws -> EntailmentVerdict {
        let probs = try await classifyPair(premise: premise, hypothesis: hypothesis)
        func p(_ label: String) -> Float {
            guard let i = model.labels.firstIndex(of: label), i < probs.count else { return 0 }
            return probs[i]
        }
        return EntailmentVerdict(entailment: p("entailment"), neutral: p("neutral"), contradiction: p("contradiction"))
    }

    /// I8.4: NER — returns (token, label) for non-special tokens.
    public func classifyTokens(_ text: String) async throws -> [(token: String, label: String)] {
        try await ensureLoaded()
        guard let bert, let w = classifierWeight, let b = classifierBias else {
            throw BackendError.loadFailed("not loaded")
        }
        let wordIds = encodeNoSpecial(text)
        let ids = [clsTokenId] + wordIds + [sepTokenId]
        let input = MLXArray(ids.map { Int32($0) }).reshaped([1, ids.count])
        let tokenTypes = MLXArray.zeros([1, ids.count], type: Int32.self)
        let mask = MLXArray.ones([1, ids.count], type: Int32.self)
        let out = bert(input, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
        guard let hidden = out.hiddenStates else { throw BackendError.loadFailed("no hidden states") }
        // hidden: [1, seq, H]; logits: [1, seq, numLabels]
        let logits = matmul(hidden, w.transposed(1, 0)) + b
        let preds = argMax(logits, axis: -1)
        preds.eval()
        let labelIdx = preds.reshaped([ids.count]).asArray(Int32.self)
        var result: [(String, String)] = []
        for (i, wid) in wordIds.enumerated() {
            let li = Int(labelIdx[i + 1]) // +1 to skip [CLS]
            let label = li < model.labels.count ? model.labels[li] : "O"
            result.append((tokenString(wid), label))
        }
        return result
    }

    /// I12.6: per-token keep probability for prose pruning (LLMLingua-2). `keepIndex` is the
    /// logit index for "keep" (label 1 in LLMLingua-2). Higher = more worth preserving.
    public func tokenKeepScores(_ text: String, keepIndex: Int = 1) async throws -> [(token: String, keep: Float)] {
        try await ensureLoaded()
        guard let bert, let w = classifierWeight, let b = classifierBias else {
            throw BackendError.loadFailed("not loaded")
        }
        let wordIds = encodeNoSpecial(text)
        let ids = [clsTokenId] + wordIds + [sepTokenId]
        let input = MLXArray(ids.map { Int32($0) }).reshaped([1, ids.count])
        let tokenTypes = MLXArray.zeros([1, ids.count], type: Int32.self)
        let mask = MLXArray.ones([1, ids.count], type: Int32.self)
        let out = bert(input, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
        guard let hidden = out.hiddenStates else { throw BackendError.loadFailed("no hidden states") }
        let logits = matmul(hidden, w.transposed(1, 0)) + b   // [1, seq, numLabels]
        let probs = softmax(logits, axis: -1)
        probs.eval()
        let flat = probs.reshaped([ids.count, model.labels.count]).asArray(Float.self)
        let n = model.labels.count
        var result: [(String, Float)] = []
        for (i, wid) in wordIds.enumerated() {
            let keep = (keepIndex < n) ? flat[(i + 1) * n + keepIndex] : 0  // +1 skips [CLS]
            result.append((tokenString(wid), keep))
        }
        return result
    }

    /// Distinct non-"O" entity surface strings found in `text` (UNION-only pin source, I8.4).
    public func entities(in text: String) async throws -> [String] {
        let tagged = try await classifyTokens(text)
        return tagged.filter { $0.label != "O" }.map { $0.token.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func firstSafetensors(in dir: URL) -> URL? {
        let direct = dir.appending(component: "model.safetensors")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            if u.pathExtension == "safetensors" { return u }
        }
        return nil
    }
}

/// Minimal BERT WordPiece tokenizer built from `vocab.txt` — used for checkpoints that
/// ship no `tokenizer.json` (e.g. dslim/bert-base-NER). Standard basic-tokenize (split on
/// whitespace, isolate punctuation) + greedy longest-match WordPiece with `##` continuation.
struct BertWordPieceTokenizer: Sendable {
    private let vocab: [String: Int]
    private let idToToken: [String]
    private let lowercase: Bool
    private let unkId: Int
    let clsId: Int, sepId: Int, padId: Int
    private let maxWordChars = 100

    init?(vocabFile: URL, lowercase: Bool) {
        guard let text = try? String(contentsOf: vocabFile, encoding: .utf8) else { return nil }
        var v: [String: Int] = [:]
        var arr: [String] = []
        // vocab.txt: one token per line; the line index IS the token id. Tokens never
        // contain leading/trailing whitespace, but strip the line's \r/\n only.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let tok = String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            v[tok] = arr.count
            arr.append(tok)
        }
        guard let cls = v["[CLS]"], let sep = v["[SEP]"] else { return nil }
        self.vocab = v; self.idToToken = arr; self.lowercase = lowercase
        self.unkId = v["[UNK]"] ?? 100
        self.clsId = cls; self.sepId = sep; self.padId = v["[PAD]"] ?? 0
    }

    func tokenString(_ id: Int) -> String {
        guard id >= 0, id < idToToken.count else { return "[UNK]" }
        return idToToken[id].replacingOccurrences(of: "##", with: "")
    }

    func encode(_ text: String) -> [Int] {
        basicTokens(text).flatMap { wordpiece($0) }
    }

    private func basicTokens(_ text: String) -> [String] {
        let s = lowercase ? text.lowercased() : text
        var tokens: [String] = []
        var cur = ""
        for ch in s {
            if ch.isWhitespace {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else if ch.isPunctuation || ch.isSymbol {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
                tokens.append(String(ch))
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    private func wordpiece(_ token: String) -> [Int] {
        let chars = Array(token)
        if chars.count > maxWordChars { return [unkId] }
        var start = 0
        var pieces: [Int] = []
        while start < chars.count {
            var end = chars.count
            var matched: Int? = nil
            while start < end {
                let sub = (start > 0 ? "##" : "") + String(chars[start..<end])
                if let id = vocab[sub] { matched = id; break }
                end -= 1
            }
            guard let id = matched else { return [unkId] }
            pieces.append(id)
            start = end
        }
        return pieces
    }
}
