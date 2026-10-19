// Embedding integration: CoreML backend EmbeddingGemma-2 (FluidInference/embeddinggemma-2-coreml,
// Apache-2.0) — a port of the Swift implementation FluidInference/FluidUse
// (Sources/FluidUse/EmbeddingGemma2/EmbeddingGemma2Manager.swift,
// EmbeddingGemma2Tokenizer.swift, EmbeddingGemma2Types.swift, Apache-2.0).
//
// The model is an ML Program with seven fixed-shape functions sharing one set
// of weights: embed_<S> for a single text up to S tokens (S ∈ 32…512) and
// pack_256 for eight short texts in one call. Fixed shapes are what keep the
// whole graph on the ANE (3862/3862 ops per the model card). The token
// embedding table (262144×512 bf16) lives outside the model: the file is
// mapped (Data .alwaysMapped) and OS residency drops pages on demand —
// behaviorally matching the FIX-2/FIX-4 residency policy (model unloaded —
// the table leaves together with the strong references).
//
// Protocol (config.json of the model card, verified by the A/B stand
// evals/embeddinggemma2-vs-qwen.py):
// - passage prefix "title: none | text: ", query prefix "task: search result | query: "
// - tokenization <bos>=2 … <eos>=1, truncation at 512 tokens
// - rows from embeddings.bf16: bf16 -> f32 via <<16, multiply by √512
//   (22.627417), feed as fp16
// - the smallest embed_S that fits the length; output is L2-normalized (the
//   model returns a normalized 768-dim vector; normalizing is idempotent and
//   insures against fp16 drift)
//
// CAREFUL (the key point for indexing): Gemma and Qwen vectors are both
// 768-dim but the SPACES ARE DIFFERENT. embed_cache is keyed by
// (content_hash, model, chunker); the model tag = the model directory name
// (Engine.swift), for Gemma it is "embeddinggemma-2-coreml". A new run = new
// cache rows, Qwen rows stay untouched, rollback is cheap.
import Foundation
@preconcurrency import CoreML

enum GemmaEmbedderError: Error, LocalizedError {
    case invalidAsset(String)
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAsset(let reason): "EmbeddingGemma 2 asset invalid: \(reason)"
        case .predictionFailed(let reason): "EmbeddingGemma 2 prediction failed: \(reason)"
        }
    }
}

/// Task prefixes the model was trained with (config.json / README of the model card).
enum GemmaPrompt {
    static let document = "title: none | text: "
    static let searchQuery = "task: search result | query: "
}

// MARK: - Tokenizer (Gemma BPE from tokenizer.json)

/// Gemma BPE tokenizer (tokenizer.json): spaces -> "▁", ranked merges over
/// unicode scalars, UTF-8 byte fallback for scalars outside the vocab,
/// <bos> … <eos> around the text. Merges run through a min-heap — O(n log n)
/// for long text. Tokens are keyed by UTF-8 bytes, NOT Swift String:
/// String equality is canonical and would collapse distinct tokens (CJK
/// compatibility with unified forms). Port of EmbeddingGemma2Tokenizer from FluidUse (Apache-2.0).
///
/// STORAGE (FOOTPRINT fix 16.10): the vocab and the merge table are flat
/// contiguous arrays (one token-bytes blob + open-addressing hash table +
/// sorted merge arrays). The [[UInt8]: Int32] and [UInt64: ...] dictionaries
/// from the initial port scattered ~1.5M tiny allocations across libmalloc
/// small zones; after idle-unloading the model the pages stayed dirty
/// (+100 MB fragmentation, 387 MB footprint after unload vs 164 MB of the
/// Qwen base — the only failed gate of the EMB-REDONE acceptance). Flat
/// arrays are a few Malloc Large allocations that free() returns to the OS whole.
/// to the OS whole.
final class GemmaBpeTokenizer: Sendable {
    let bosId: Int32
    let eosId: Int32
    let padId: Int32

    /// Bytes of all vocab tokens and merge pairs, concatenated into one blob.
    private let tokenBlob: [UInt8]
    /// Open-addressing table bytes -> vocab entry: slotKey = hash+1
    /// (0 = empty), slotVal = index into vocabOfs/vocabLen/vocabId.
    private let slotKey: [UInt64]
    private let slotVal: [Int32]
    private let slotMask: Int
    private let vocabOfs: [UInt32]
    private let vocabLen: [UInt32]
    private let vocabIds: [Int32]

    /// Merges sorted by key = left << 32 | right; binary search.
    private let mergeKey: [UInt64]
    private let mergeRank: [Int32]
    private let mergeId: [Int32]

    private let byteIds: [Int32]
    private let unkId: Int32
    private let spaceId: Int32

    convenience init(tokenizerJsonURL: URL) throws {
        try self.init(data: Data(contentsOf: tokenizerJsonURL))
    }

    init(data: Data) throws {
        // Parsing from raw bytes: JSONSerialization drops the leading U+FEFF from
        // keys and collapses canonically distinct strings in a String dictionary —
        // both bugs would remap real tokens.
        var reader = TokenizerJSONReader(bytes: [UInt8](data))
        guard let raw = reader.raw() else {
            throw GemmaEmbedderError.invalidAsset("tokenizer.json is not a Gemma BPE tokenizer")
        }
        // Vocab hash table over the blob (2^k slots, load <= 50%):
        // slotVal is the entry index into vocabOfs/vocabLen/vocabId.
        var capacity = 1
        while capacity < raw.vocabOfs.count * 2 { capacity <<= 1 }
        var slotKey = [UInt64](repeating: 0, count: capacity)
        var slotVal = [Int32](repeating: -1, count: capacity)
        let mask = capacity - 1
        let blob = raw.blob
        func hashRange(_ ofs: UInt32, _ len: UInt32) -> UInt64 {
            blob.withUnsafeBufferPointer { Self.hash($0.baseAddress!.advanced(by: Int(ofs)), Int(len)) }
        }
        func rangesEqual(_ aOfs: UInt32, _ aLen: UInt32, _ bOfs: UInt32, _ bLen: UInt32) -> Bool {
            guard aLen == bLen else { return false }
            return blob.withUnsafeBufferPointer {
                memcmp($0.baseAddress!.advanced(by: Int(aOfs)), $0.baseAddress!.advanced(by: Int(bOfs)), Int(aLen)) == 0
            }
        }
        func rangesEqualBytes(_ ofs: UInt32, _ len: UInt32, _ bytes: [UInt8]) -> Bool {
            guard len == UInt32(bytes.count) else { return false }
            return blob.withUnsafeBufferPointer { bb in
                bytes.withUnsafeBufferPointer { tb in
                    memcmp(bb.baseAddress!.advanced(by: Int(ofs)), tb.baseAddress!, bytes.count) == 0
                }
            }
        }
        for entry in 0..<raw.vocabOfs.count {
            var probe = hashRange(raw.vocabOfs[entry], raw.vocabLen[entry]) &+ 1  // 0 = «empty»
            while true {
                let slot = Int(probe & UInt64(mask))
                if slotKey[slot] == 0 {
                    slotKey[slot] = probe
                    slotVal[slot] = Int32(entry)
                    break
                }
                probe &+= 1
            }
        }
        func lookupBytes(_ token: [UInt8]) -> Int32? {
            var probe = Self.hash(token) &+ 1
            while true {
                let slot = Int(probe & UInt64(mask))
                let key = slotKey[slot]
                if key == 0 { return nil }
                if key == probe {
                    let e = Int(slotVal[slot])
                    if rangesEqualBytes(raw.vocabOfs[e], raw.vocabLen[e], token) { return raw.vocabId[e] }
                }
                probe &+= 1
            }
        }
        func lookupRange(_ ofs: UInt32, _ len: UInt32) -> Int32? {
            var probe = hashRange(ofs, len) &+ 1
            while true {
                let slot = Int(probe & UInt64(mask))
                let key = slotKey[slot]
                if key == 0 { return nil }
                if key == probe {
                    let e = Int(slotVal[slot])
                    if rangesEqual(raw.vocabOfs[e], raw.vocabLen[e], ofs, len) { return raw.vocabId[e] }
                }
                probe &+= 1
            }
        }
        func id(_ token: String) -> Int32? { lookupBytes(Array(token.utf8)) }
        guard let bos = id("<bos>"), let eos = id("<eos>"), let pad = id("<pad>") else {
            throw GemmaEmbedderError.invalidAsset("tokenizer.json has no <bos>, <eos> or <pad>")
        }
        // Merges: three parallel arrays, sorted by key for binary search.
        var mk: [UInt64] = []
        var mr: [Int32] = []
        var mi: [Int32] = []
        mk.reserveCapacity(raw.leftOfs.count)
        mr.reserveCapacity(raw.leftOfs.count)
        mi.reserveCapacity(raw.leftOfs.count)
        var joined: [UInt8] = []  // reusable scratch for left+right
        for pair in 0..<raw.leftOfs.count {
            guard let left = lookupRange(raw.leftOfs[pair], raw.leftLen[pair]),
                  let right = lookupRange(raw.rightOfs[pair], raw.rightLen[pair])
            else { continue }
            joined.removeAll(keepingCapacity: true)
            joined.append(contentsOf: blob.withUnsafeBufferPointer {
                $0[Int(raw.leftOfs[pair])..<Int(raw.leftOfs[pair] + raw.leftLen[pair])]
            })
            joined.append(contentsOf: blob.withUnsafeBufferPointer {
                $0[Int(raw.rightOfs[pair])..<Int(raw.rightOfs[pair] + raw.rightLen[pair])]
            })
            guard let merged = lookupBytes(joined) else { continue }
            mk.append(Self.key(left, right))
            mr.append(Int32(pair))
            mi.append(merged)
        }
        let order = mk.indices.sorted { mk[$0] < mk[$1] }
        self.tokenBlob = blob
        self.slotKey = slotKey
        self.slotVal = slotVal
        self.slotMask = mask
        self.vocabOfs = raw.vocabOfs
        self.vocabLen = raw.vocabLen
        self.vocabIds = raw.vocabId
        self.mergeKey = order.map { mk[$0] }
        self.mergeRank = order.map { mr[$0] }
        self.mergeId = order.map { mi[$0] }
        unkId = id("<unk>") ?? 3
        byteIds = (0..<256).map { id(String(format: "<0x%02X>", $0)) ?? id("<unk>") ?? 3 }
        spaceId = id("\u{2581}") ?? unkId
        bosId = bos
        eosId = eos
        padId = pad
    }

    /// <bos> + tokens + <eos>, keeping the first maxLength-2 tokens of long text.
    func encode(_ text: String, maxLength: Int) -> [Int32] {
        [bosId] + tokenize(text).prefix(max(maxLength - 2, 0)) + [eosId]
    }

    /// Token ids without special tokens.
    func tokenize(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        for scalar in text.unicodeScalars {
            if scalar == " " {
                ids.append(spaceId)
                continue
            }
            let bytes = Array(String(scalar).utf8)
            if let id = vocabId(bytes) {
                ids.append(id)
            } else {
                for byte in bytes { ids.append(byteIds[Int(byte)]) }
            }
        }
        return merge(ids)
    }

    /// Token lookup by bytes (equivalent to the old dictionary lookup).
    private func vocabId(_ token: [UInt8]) -> Int32? {
        var probe = Self.hash(token) &+ 1
        while true {
            let slot = Int(probe & UInt64(slotMask))
            let key = slotKey[slot]
            if key == 0 { return nil }
            if key == probe {
                let e = Int(slotVal[slot])
                let ofs = Int(vocabOfs[e])
                let len = Int(vocabLen[e])
                if len == token.count, token.withUnsafeBufferPointer({ tb in
                    tokenBlob.withUnsafeBufferPointer({ bb in
                        memcmp(bb.baseAddress!.advanced(by: ofs), tb.baseAddress!, len) == 0
                    })
                }) { return vocabIds[e] }
            }
            probe &+= 1
        }
    }

    /// (rank, id) of a pair merge or nil — binary search over sorted arrays.
    private func mergeLookup(_ key: UInt64) -> (rank: Int32, id: Int32)? {
        var low = 0
        var high = mergeKey.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = mergeKey[mid]
            if candidate == key { return (mergeRank[mid], mergeId[mid]) }
            if candidate < key { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    private func merge(_ initial: [Int32]) -> [Int32] {
        let count = initial.count
        guard count > 1 else { return initial }
        var ids = initial
        var next = Array(1...count)  // `count` = end sentinel
        var previous = Array(-1..<(count - 1))
        var alive = [Bool](repeating: true, count: count)
        var heap = MergeHeap()
        for index in 0..<(count - 1) {
            if let merge = mergeLookup(Self.key(ids[index], ids[index + 1])) {
                heap.push(.init(rank: merge.rank, position: Int32(index), left: ids[index], right: ids[index + 1]))
            }
        }
        while let candidate = heap.pop() {
            let position = Int(candidate.position)
            let right = next[position]
            guard alive[position], right < count, ids[position] == candidate.left, ids[right] == candidate.right,
                let merge = mergeLookup(Self.key(candidate.left, candidate.right))
            else { continue }
            ids[position] = merge.id
            alive[right] = false
            next[position] = next[right]
            if next[right] < count { previous[next[right]] = position }
            let before = previous[position]
            if before >= 0, let pair = mergeLookup(Self.key(ids[before], ids[position])) {
                heap.push(.init(rank: pair.rank, position: Int32(before), left: ids[before], right: ids[position]))
            }
            let after = next[position]
            if after < count, let pair = mergeLookup(Self.key(ids[position], ids[after])) {
                heap.push(.init(rank: pair.rank, position: Int32(position), left: ids[position], right: ids[after]))
            }
        }
        var result: [Int32] = []
        result.reserveCapacity(count)
        var index = 0
        while index < count {
            result.append(ids[index])
            index = next[index]
        }
        return result
    }

    private static func key(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: left)) << 32 | UInt64(UInt32(bitPattern: right))
    }

    /// FNV-1a over token bytes + splitmix avalanche (cheap, no cluster collisions).
    private static func hash(_ token: [UInt8]) -> UInt64 {
        guard !token.isEmpty else { return hash(UInt64(0xcbf2_9ce4_8422_2325)) }
        return token.withUnsafeBufferPointer { hash($0.baseAddress!, token.count) }
    }

    private static func hash(_ seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    private static func hash(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in 0..<count { h = (h ^ UInt64(bytes[i])) &* 0x100_0000_01b3 }
        var z = h &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// Exactly as much JSON as needed to read model.vocab (token -> id) and
/// model.merges (pairs [left, right]), keeping every string its exact
/// UTF-8 bytes (no String canonicalization). Token bytes go into one blob
/// with flat indices — not a single per-token allocation (FOOTPRINT fix:
/// per-token [UInt8] fragmented small zones into ~100 MB of dirty pages
/// never returned after idle-unload). Port of TokenizerJSONReader from FluidUse.
/// TokenizerJSONReader from FluidUse.
private struct TokenizerJSONReader {
    struct Raw {
        var blob: [UInt8] = []
        var vocabOfs: [UInt32] = []
        var vocabLen: [UInt32] = []
        var vocabId: [Int32] = []
        var leftOfs: [UInt32] = []
        var leftLen: [UInt32] = []
        var rightOfs: [UInt32] = []
        var rightLen: [UInt32] = []
    }

    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func raw() -> Raw? {
        var out = Raw()
        out.blob.reserveCapacity(12_000_000)
        out.vocabOfs.reserveCapacity(262_144)
        out.vocabLen.reserveCapacity(262_144)
        out.vocabId.reserveCapacity(262_144)
        out.leftOfs.reserveCapacity(600_000)
        out.leftLen.reserveCapacity(600_000)
        out.rightOfs.reserveCapacity(600_000)
        out.rightLen.reserveCapacity(600_000)
        guard seek(key: "model") else { return nil }
        let modelStart = index
        guard seek(key: "vocab"), skipSpace(), consume(UInt8(ascii: "{")) else { return nil }
        while skipSpace(), !consume(UInt8(ascii: "}")) {
            _ = consume(UInt8(ascii: ","))
            _ = skipSpace()
            guard let tokenOfs = string(into: &out.blob), skipSpace(), consume(UInt8(ascii: ":")), skipSpace(),
                let value = integer()
            else { return nil }
            out.vocabOfs.append(tokenOfs)
            out.vocabLen.append(UInt32(out.blob.count) - tokenOfs)
            out.vocabId.append(Int32(value))
        }
        index = modelStart
        guard seek(key: "merges"), skipSpace(), consume(UInt8(ascii: "[")) else { return nil }
        while skipSpace(), !consume(UInt8(ascii: "]")) {
            _ = consume(UInt8(ascii: ","))
            guard skipSpace(), consume(UInt8(ascii: "[")), skipSpace(), let leftOfs = string(into: &out.blob)
            else { return nil }
            let leftEnd = UInt32(out.blob.count)
            guard skipSpace(), consume(UInt8(ascii: ",")), skipSpace(), let rightOfs = string(into: &out.blob),
                skipSpace(), consume(UInt8(ascii: "]"))
            else { return nil }
            out.leftOfs.append(leftOfs)
            out.leftLen.append(leftEnd - leftOfs)
            out.rightOfs.append(rightOfs)
            out.rightLen.append(UInt32(out.blob.count) - rightOfs)
        }
        return out
    }

    /// Moves the cursor past the next `"key":` starting from the current position.
    private mutating func seek(key: String) -> Bool {
        let pattern = Array("\"\(key)\"".utf8)
        guard pattern.count <= bytes.count else { return false }
        while index + pattern.count <= bytes.count {
            if bytes[index] == pattern[0], Array(bytes[index..<(index + pattern.count)]) == pattern {
                index += pattern.count
                if skipSpace(), consume(UInt8(ascii: ":")) { return true }
            } else {
                index += 1
            }
        }
        return false
    }

    @discardableResult
    private mutating func skipSpace() -> Bool {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        return index < bytes.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func integer() -> Int? {
        var value = 0
        var digits = 0
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
            value = value * 10 + Int(bytes[index] - 0x30)
            index += 1
            digits += 1
        }
        return digits > 0 ? value : nil
    }

    /// Reads a JSON string, appending its bytes as-is into the blob; returns
    /// the start offset in the blob (length = blob.count at return - ofs).
    private mutating func string(into blob: inout [UInt8]) -> UInt32? {
        guard consume(UInt8(ascii: "\"")) else { return nil }
        let ofs = UInt32(blob.count)
        var pendingHigh: UInt32?
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") { return ofs }
            guard byte == UInt8(ascii: "\\") else {
                blob.append(byte)
                continue
            }
            guard index < bytes.count else { return nil }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "n"): blob.append(0x0A)
            case UInt8(ascii: "t"): blob.append(0x09)
            case UInt8(ascii: "r"): blob.append(0x0D)
            case UInt8(ascii: "b"): blob.append(0x08)
            case UInt8(ascii: "f"): blob.append(0x0C)
            case UInt8(ascii: "u"):
                guard index + 4 <= bytes.count,
                    let unit = UInt32(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16)
                else { return nil }
                index += 4
                if (0xD800..<0xDC00).contains(unit) {
                    pendingHigh = unit
                    continue
                }
                var scalarValue = unit
                if let high = pendingHigh, (0xDC00..<0xE000).contains(unit) {
                    scalarValue = 0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00)
                }
                pendingHigh = nil
                guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
                blob.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: blob.append(escape)  // \" \\ \/
            }
        }
        return nil
    }
}

/// Min-heap of merge candidates by rank, then position (leftmost first —
/// as in the reference). Port of MergeHeap from FluidUse.
private struct MergeHeap {
    struct Entry {
        let rank: Int32
        let position: Int32
        let left: Int32
        let right: Int32

        func precedes(_ other: Entry) -> Bool {
            rank != other.rank ? rank < other.rank : position < other.position
        }
    }

    private var entries: [Entry] = []

    mutating func push(_ entry: Entry) {
        entries.append(entry)
        var child = entries.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard entries[child].precedes(entries[parent]) else { break }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Entry? {
        guard let first = entries.first else { return nil }
        let last = entries.removeLast()
        if !entries.isEmpty {
            entries[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var best = parent
                if left < entries.count, entries[left].precedes(entries[best]) { best = left }
                if right < entries.count, entries[right].precedes(entries[best]) { best = right }
                guard best != parent else { break }
                entries.swapAt(parent, best)
                parent = best
            }
        }
        return first
    }
}

// MARK: - CoreML engine

/// EmbeddingGemma-2 text on Core ML: fixed-shape functions over shared weights
/// keep the graph on the Neural Engine. The token table is an mmap bf16 file.
/// Output: an L2-normalized 768-dim vector.
///
/// Flow: one Embedder actor call at a time (as with TextEmbedder), hence the
/// class is @unchecked Sendable: MLModel.prediction is documented
/// thread-safe, the tokenizer is immutable, the table is read-only.
final class GemmaCoreMLModel: @unchecked Sendable {
    static let lengths = [32, 48, 64, 128, 256, 512]
    static let hiddenSize = 512
    static let dimension = 768

    let tokenizer: GemmaBpeTokenizer
    private let models: [Int: MLModel]
    /// URL of the compiled model — for the BMEM_UNLOAD_DEBUG debug line
    /// in Embedder.unloadNow.
    let modelURL: URL
    private let table: Data
    /// √512 = 22.627417 — the table row scale (embed_scale in config.json).
    private let embedScale = Float(GemmaCoreMLModel.hiddenSize).squareRoot()

    private init(tokenizer: GemmaBpeTokenizer, models: [Int: MLModel], table: Data, modelURL: URL) {
        self.tokenizer = tokenizer
        self.models = models
        self.table = table
        self.modelURL = modelURL
    }

    /// Directory with EmbeddingGemma2Text.mlmodelc (or .mlpackage — compiled
    /// once and cached next to the model), embeddings.bf16, tokenizer.json.
    /// The first compilation of the functions for ANE takes minutes once —
    /// CoreML caches the result by model content.
    static func load(from directory: URL, computeUnits: MLComputeUnits = .all) async throws -> GemmaCoreMLModel {
        let fm = FileManager.default
        let compiled = directory.appendingPathComponent("EmbeddingGemma2Text.mlmodelc")
        let package = directory.appendingPathComponent("EmbeddingGemma2Text.mlpackage")
        let modelURL: URL
        if fm.fileExists(atPath: compiled.path) {
            modelURL = compiled
        } else if fm.fileExists(atPath: package.path) {
            let fresh = try await MLModel.compileModel(at: package)
            // PERSIST the compilation next to the model: the next start loads
            // instantly (same path as in FluidUse load(); the move is best-effort).
            let candidate = directory.appendingPathComponent("EmbeddingGemma2Text.mlmodelc")
            if !fm.fileExists(atPath: candidate.path) {
                try? fm.removeItem(at: candidate)
                do {
                    try fm.copyItem(at: fresh, to: candidate)
                    modelURL = candidate
                } catch {
                    modelURL = fresh
                }
            } else {
                modelURL = candidate
            }
        } else {
            throw GemmaEmbedderError.invalidAsset("missing EmbeddingGemma2Text.mlmodelc/.mlpackage in \(directory.path)")
        }
        let tableURL = directory.appendingPathComponent("embeddings.bf16")
        // alwaysMapped: the file lives in virtual memory, residency drops pages
        // under pressure — unloading the model really frees memory.
        guard let table = try? Data(contentsOf: tableURL, options: .alwaysMapped),
              table.count % (GemmaCoreMLModel.hiddenSize * 2) == 0
        else {
            throw GemmaEmbedderError.invalidAsset("missing or malformed embeddings.bf16 in \(directory.path)")
        }
        let tokenizer = try GemmaBpeTokenizer(
            tokenizerJsonURL: directory.appendingPathComponent("tokenizer.json"))

        // One MLModel per function: functionName is fixed in the configuration at
        // load time (multi-function models — macOS 15+, we are on 27+).
        func function(_ name: String) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            configuration.functionName = name
            return try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        }
        var models: [Int: MLModel] = [:]
        for length in lengths { models[length] = try await function("embed_\(length)") }
        // pack_256 (8 texts of 256 tokens in one call) is unused in the initial integration —
        // the Engine API embeds chunk by chunk; batching is a candidate for
        // speeding up reindex (noted in the report).
        return GemmaCoreMLModel(tokenizer: tokenizer, models: models, table: table, modelURL: modelURL)
    }

    /// Vector of a text with a task prefix (empty string — no prefix, embedRaw).
    /// Text longer than 512 tokens is truncated (model card: truncation changed
    /// nothing on the eval set).
    func embed(text: String, prefix: String) async throws -> [Float] {
        let ids = tokenizer.encode(prefix + text, maxLength: Self.lengths.last!)
        let length = Self.lengths.first { $0 >= ids.count } ?? Self.lengths.last!
        let rows = try await run(length: length, ids: ids)
        // L2 normalization (the model returns normalized output; we normalize to
        // stay faithful to the bmem protocol — dot-products in Engine expect unit vectors).
        var norm = 0.0
        for v in rows { norm += Double(v * v) }
        let inv = norm > 0 ? 1 / Float(norm.squareRoot()) : 0
        return rows.map { $0 * inv }
    }

    /// Table rows (bf16 -> f32 <<16 -> ×√512 -> fp16), ids clamped by rows.
    private func writeEmbeddings(_ ids: [Int32], to destination: UnsafeMutablePointer<Float16>) {
        let rows = table.count / (Self.hiddenSize * 2)
        table.withUnsafeBytes { raw in
            let bf16 = raw.bindMemory(to: UInt16.self)
            for (position, id) in ids.enumerated() {
                let row = min(max(Int(id), 0), rows - 1) * Self.hiddenSize
                let target = destination + position * Self.hiddenSize
                for column in 0..<Self.hiddenSize {
                    target[column] = Float16(Float(bitPattern: UInt32(bf16[row + column]) << 16) * embedScale)
                }
            }
        }
    }

    /// One embed_<length> call: the first ids.count rows are tokens, the rest pad;
    /// attention_mask 1 on real positions (right padding alignment).
    private func run(length: Int, ids: [Int32]) async throws -> [Float] {
        guard let model = models[length] else {
            throw GemmaEmbedderError.predictionFailed("no model loaded for embed_\(length)")
        }
        let embeds = try MLMultiArray(
            shape: [1, NSNumber(value: length), NSNumber(value: Self.hiddenSize)], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
        let maskPointer = mask.dataPointer.assumingMemoryBound(to: Float16.self)
        let padded = Array(ids + [Int32](repeating: tokenizer.padId, count: length - ids.count))
        writeEmbeddings(padded, to: embeds.dataPointer.assumingMemoryBound(to: Float16.self))
        for position in 0..<length { maskPointer[position] = position < ids.count ? 1 : 0 }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: embeds),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let output = try await model.prediction(from: input)
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue,
              vector.count == Self.dimension
        else {
            throw GemmaEmbedderError.predictionFailed("missing or malformed embedding output")
        }
        if vector.dataType == .float16 {
            let p = vector.dataPointer.assumingMemoryBound(to: Float16.self)
            return (0..<Self.dimension).map { Float(p[$0]) }
        }
        let p = vector.dataPointer.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: p, count: Self.dimension))
    }
}
