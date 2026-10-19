// bmem core: md-vault index (SQLite WAL: notes + chunks + FTS5 + fp32 vectors),
// hybrid search (BGE-band Qwen3 vectors + FTS bm25), note CRUD.
//
// Key decisions:
// - one DB file for everything (~/.bmem/bmem.db), projects are separated by the project column;
// - vectors live both in the DB and in memory (brute-force cosine — at hundreds of
//   chunks it is faster than any index and more accurate on Cyrillic text);
// - md files are the source of truth; the DB is derived, a full rebuild is safe.
import Foundation
import CryptoKit

public struct NoteHit: Sendable {
    public var title: String
    public var permalink: String
    public var content: String
    public var score: Double
    public var filePath: String
    /// UI-1 trust filter: "human"/"agent" from frontmatter `source:` (defaults to human).
    public var source: String
    public init(title: String, permalink: String, content: String, score: Double, filePath: String,
                source: String = "human") {
        self.title = title; self.permalink = permalink; self.content = content
        self.score = score; self.filePath = filePath; self.source = source
    }
}

public struct NoteResult: Sendable {
    public var title: String
    public var permalink: String
    public var content: String
    public var filePath: String
    public var checksum: String
}

public enum EngineError: Error, Sendable {
    case unknownProject(String)
    case notFound(String)
    case alreadyExists(String)
    case notSupported(String)
}

private struct ChunkRow {
    let noteId: Int
    let ord: Int
    let text: String
    var vec: [Float]
}

private final class ProjectState {
    var chunks: [ChunkRow] = []                 // for vector search
    var notes: [Int: (title: String, permalink: String, relPath: String, source: String)] = [:]
    var indexedAt: Date = .distantPast
}

/// Index-run report (added/updated/unchanged/deleted) plus a counter of real
/// model runs. Embeddings are content-addressed (embed_cache), so "reembedded"
/// means text that was never in the cache under any previous text.
public struct IndexReport: Sendable {
    public var added = 0        // new files
    public var updated = 0      // files with changed content
    public var unchanged = 0    // files matched by checksum — zero work
    public var deleted = 0      // files gone from disk
    public var failed = 0       // index reporting: files not read during the run (EACCES etc.)
    public var chunksTotal = 0  // chunks in the registry after the run
    public var modelRuns = 0    // embedder calls (excluding cache hits)
    public init() {}
}

public actor Engine {
    private let db: SQLiteDB
    private var config: Config
    private let embedder = Embedder()
    private var states: [String: ProjectState] = [:]
    /// Current model run and chunker version — embed_cache key tags.
    /// A model change = explicit invalidation (new tag); a chunker change is free
    /// (chunk hashes simply stop matching old rows).
    private let embedModelTag: String
    private let chunkerTag = "para1200"
    /// Background reindex runs per project (write/edit does not wait for re-embedding).
    private var reindexInFlight: [String: Task<Void, Never>] = [:]
    /// Rel-paths touched by a write since the last freshness check.
    private var dirtyFiles: [String: Set<String>] = [:]
    /// Index reporting: files not read during the last reindex run
    /// (project → rel-path → error text). Reporting only: the indexer
    /// skipped them before too, silently and without a trace in the stats.
    private var indexFailures: [String: [String: String]] = [:]
    /// Last index-run reports (for CLI/benchmarks).
    private var lastReports: [String: IndexReport] = [:]
    /// FIX-5: for each project — relative prefixes of subfolders that are the
    /// root of ANOTHER registry project (e.g. ai-projects ⊃ memory/hermes).
    /// Such a subfolder is not indexed as part of the parent: it lives entirely
    /// in its own project (1 file = 1 note, exactly once). Otherwise —
    /// 2× re-embedding, 2× DB space and duplicate hits in parent search.
    /// Links (wikilink/permalink) do not break: the file stays resolvable in
    /// its own project, and the parent's permalink resolver for «project/dir/name»
    /// simply does not see it (and should not).
    private var projectExcludes: [String: [String]]

    public init(dbPath: String, config: Config) throws {
        self.db = try SQLiteDB(path: dbPath)
        self.config = config
        self.projectExcludes = Self.computeExcludes(from: config)
        self.embedModelTag = Embedder.activeModelTag()
        db.exec("""
        CREATE TABLE IF NOT EXISTS notes(
          id INTEGER PRIMARY KEY,
          project TEXT NOT NULL,
          rel_path TEXT NOT NULL,
          title TEXT NOT NULL,
          permalink TEXT NOT NULL,
          checksum TEXT NOT NULL,
          UNIQUE(project, rel_path)
        );
        CREATE TABLE IF NOT EXISTS chunks(
          id INTEGER PRIMARY KEY,
          note_id INTEGER NOT NULL,
          project TEXT NOT NULL,
          ord INTEGER NOT NULL,
          text TEXT NOT NULL,
          content_hash TEXT NOT NULL,
          vec BLOB
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_note ON chunks(note_id);
        CREATE INDEX IF NOT EXISTS idx_chunks_proj ON chunks(project);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text);
        -- FIX-3: content-addressed embed store (course 12.10, daftari #38 / seahorse /
        -- RooCode #4619). Key = md5(embedText)+model+chunker; a chunk no longer stores
        -- the vector, it references the cache by hash. Reindex = O(changed chunks):
        -- an unchanged chunk hits the cache and the model never runs at all, regardless
        -- of which file it appeared in (duplicate paragraph across notes = 0 runs).
        CREATE TABLE IF NOT EXISTS embed_cache(
          content_hash TEXT NOT NULL,
          vec BLOB NOT NULL,
          model TEXT NOT NULL,
          chunker TEXT NOT NULL,
          created_at TEXT NOT NULL,
          PRIMARY KEY(content_hash, model, chunker)
        );
        CREATE TABLE IF NOT EXISTS edges(
          project TEXT NOT NULL,
          src INTEGER NOT NULL,
          dst INTEGER NOT NULL,
          kind TEXT NOT NULL,
          UNIQUE(project, src, dst, kind)
        );
        CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(project, src);
        CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(project, dst);
        """)
        // UI-1 migration: notes.source — author marker for the trust filter
        // (human/agent from frontmatter `source:`). Old rows = human.
        var notesCols: [String] = []
        db.query("PRAGMA table_info(notes)") { row in
            if let name = row[1] as? String { notesCols.append(name) }
        }
        if !notesCols.isEmpty && !notesCols.contains("source") {
            db.exec("ALTER TABLE notes ADD COLUMN source TEXT NOT NULL DEFAULT 'human'")
            FileHandle.standardError.write(Data("bmem: schema migration: notes + source column\n".utf8))
        }
        // FIX-3 schema migration: CREATE TABLE IF NOT EXISTS does not touch live tables
        // of the old schema (chunks had no content_hash, and vec was NOT NULL). Without
        // a rebuild the LEFT JOIN on content_hash and the vec=NULL insert returned nil /
        // failed silently (SQLiteDB.run does not throw), every cold-start re-embedded the
        // whole corpus, and FTS rowids drifted. The rebuild runs once, detected by schema.
        var chunksSql = ""
        db.query("SELECT sql FROM sqlite_master WHERE name = 'chunks' AND type = 'table'") {
            chunksSql = $0[0] as? String ?? ""
        }
        if !chunksSql.isEmpty && !chunksSql.contains("content_hash") {
            db.exec("""
            BEGIN;
            CREATE TABLE chunks_new(
              id INTEGER PRIMARY KEY,
              note_id INTEGER NOT NULL,
              project TEXT NOT NULL,
              ord INTEGER NOT NULL,
              text TEXT NOT NULL,
              content_hash TEXT NOT NULL DEFAULT '',
              vec BLOB
            );
            INSERT INTO chunks_new(id, note_id, project, ord, text, content_hash, vec)
              SELECT id, note_id, project, ord, text, '', vec FROM chunks;
            DROP TABLE chunks;
            ALTER TABLE chunks_new RENAME TO chunks;
            CREATE INDEX idx_chunks_note ON chunks(note_id);
            CREATE INDEX idx_chunks_proj ON chunks(project);
            COMMIT;
            """)
            FileHandle.standardError.write(Data("bmem: schema migration: chunks -> content-addressed scheme\n".utf8))
        }
// Embedding cache schema migration: embed_cache used to key on content_hash alone,
// model/chunker rode along as passengers. A second model run (different
// model = different tag) via INSERT OR REPLACE did NOT add its own row —
// it overwrote the first model's vector (verified on a stand 14.10: Qwen
// rows shrank from 10328 to 39 after a gemma run). The old schema was correct
// only with exactly one model in the DB; with two models, "keep old rows,
// cheap rollback" requires a composite key. The rebuild runs once, detected
// by the inline-PK in the schema; all rows are preserved as-is (hash
// duplicates across models before the migration are physically impossible —
// the old PK never let them in).
        var cacheSql = ""
        db.query("SELECT sql FROM sqlite_master WHERE name = 'embed_cache' AND type = 'table'") {
            cacheSql = $0[0] as? String ?? ""
        }
        let cacheSqlFlat = cacheSql
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        if !cacheSqlFlat.isEmpty && cacheSqlFlat.localizedCaseInsensitiveContains("content_hash TEXT PRIMARY KEY") {
            db.exec("""
            BEGIN;
            CREATE TABLE embed_cache_new(
              content_hash TEXT NOT NULL,
              vec BLOB NOT NULL,
              model TEXT NOT NULL,
              chunker TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY(content_hash, model, chunker)
            );
            INSERT OR IGNORE INTO embed_cache_new(content_hash, vec, model, chunker, created_at)
              SELECT content_hash, vec, model, chunker, created_at FROM embed_cache;
            DROP TABLE embed_cache;
            ALTER TABLE embed_cache_new RENAME TO embed_cache;
            COMMIT;
            """)
            FileHandle.standardError.write(Data("bmem: schema migration: embed_cache -> composite key (content_hash, model, chunker)\n".utf8))
        }
    }

    // MARK: - Indexing

    private func projectRoot(_ project: String) throws -> String {
        guard let path = config.projects[project] else { throw EngineError.unknownProject(project) }
        return path
    }

    /// Scans the vault, re-embeds changed files, cleans up deleted ones.
    /// Embeddings are content-addressed: a chunk whose text was already in the
    /// corpus hits embed_cache and the model does not run for it (the motivation
    /// behind FIX-3 — live transcripts where 150 of 151 chunks don't change between appends).
    @discardableResult
    public func reindex(project: String) async throws -> IndexReport {
        let root = try projectRoot(project)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { throw EngineError.unknownProject(project) }
        let files = Self.markdownFiles(in: root, excludes: projectExcludes[project] ?? [])
        let state = states[project] ?? ProjectState()
        // Snapshot of «dirty» paths at run start; files written fresh during
        // the awaits stay in dirtyFiles and will be caught by the next run.
        let snapshotDirty = dirtyFiles[project] ?? []

        var report = IndexReport()
        /// Index reporting: failures of THIS run; published to indexFailures at the end
        /// so a crashed/aborted run never reports stale failures as current.
        var runFailures: [String: String] = [:]
        func intAt(_ row: [Any?], _ i: Int) -> Int? { (row[i] as? Int64).flatMap { Int(exactly: $0) } }
        func sha(_ data: Data) -> String {
            SHA256.hash(data: data).reduce(into: "") { $0 += String(format: "%02x", $1) }
        }
        func chunkIds(noteId: Int) -> [Int] {
            var ids: [Int] = []
            db.query("SELECT id FROM chunks WHERE note_id = ?", [Int64(noteId)]) { if let i = intAt($0, 0) { ids.append(i) } }
            return ids
        }
        func dropNote(_ noteId: Int) {
            for id in chunkIds(noteId: noteId) { db.run("DELETE FROM chunks_fts WHERE rowid = ?", [Int64(id)]) }
            state.chunks.removeAll { $0.noteId == noteId }
            db.run("DELETE FROM chunks WHERE note_id = ?", [Int64(noteId)])
            db.run("DELETE FROM notes WHERE id = ?", [Int64(noteId)])
        }
        /// Chunk vector from embed_cache; the model runs only on cache misses.
        /// Returns (vector, was-it-a-cache-miss = model ran). The report counter is
        /// incremented by the calling code in the actor body: a local @concurrent
        /// function cannot capture the mutable region-isolated report
        /// (Swift 6 RegionIsolation, confirmed by the FIX-5 grab-bag on 12.10).
        func embedCached(_ text: String) async throws -> (vec: [Float], modelRan: Bool) {
            let h = Self.md5hex(Data(text.utf8))
            var vec: [Float] = []
            db.query("SELECT vec FROM embed_cache WHERE content_hash = ? AND model = ? AND chunker = ?",
                     [h, embedModelTag, chunkerTag]) { row in
                if let v = row[0] as? Data {
                    vec = v.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                }
            }
            var modelRan = false
            if vec.isEmpty {
                vec = try await embedder.embedDocument(text)
                modelRan = true
                db.run("INSERT OR REPLACE INTO embed_cache(content_hash, vec, model, chunker, created_at) VALUES(?,?,?,?,?)",
                       [h, vec.withUnsafeBytes { Data($0) }, embedModelTag, chunkerTag,
                        ISO8601DateFormatter().string(from: Date())])
            }
            return (vec, modelRan)
        }

        // files known to the DB -> checksum
        var known: [String: (id: Int, checksum: String)] = [:]
        db.query("SELECT id, rel_path, checksum FROM notes WHERE project = ?", [project]) { row in
            if let p = row[1] as? String, let c = row[2] as? String, let id = intAt(row, 0) {
                known[p] = (id, c)
            }
        }

        // FIX-3 migration (once per run): chunks of the old schema (vector lived in
        // chunks.vec, content_hash = '') move into embed_cache keyed by md5 of the text;
        // after the move a chunks row stores only the reference (content_hash) and text.
        // Rows are gathered before writing: the write goes to the same connection the
        // iteration uses (SQLite tolerates it, but gather-then-apply is more deterministic).
        var migrateRows: [(id: Int, text: String, vec: Data)] = []
        db.query("""
        SELECT c.id, c.text, c.vec FROM chunks c
        JOIN notes n ON n.id = c.note_id
        WHERE n.project = ? AND c.content_hash = '' AND c.vec IS NOT NULL
        """, [project]) { row in
            guard let cid = intAt(row, 0), let t = row[1] as? String, let v = row[2] as? Data else { return }
            migrateRows.append((cid, t, v))
        }
        if !migrateRows.isEmpty {
            let now = ISO8601DateFormatter().string(from: Date())
            for m in migrateRows {
                let h = Self.md5hex(Data(m.text.utf8))
                db.run("INSERT OR IGNORE INTO embed_cache(content_hash, vec, model, chunker, created_at) VALUES(?,?,?,?,?)",
                       [h, m.vec, embedModelTag, chunkerTag, now])
                db.run("UPDATE chunks SET content_hash = ?, vec = NULL WHERE id = ?", [h, Int64(m.id)])
            }
            FileHandle.standardError.write(Data("bmem: [\(project)] embed_cache migration: \(migrateRows.count) vectors\n".utf8))
        }

        // Graph: edges are fully rebuilt on every reindex — cheap and drift-free.
        db.run("DELETE FROM edges WHERE project = ?", [project])
        var pendingLinks: [(src: Int, target: String)] = []
        // Cold start with a ready DB: load chunks from the DB instead of re-embedding.
        // Without this, a process restart would give an empty in-memory index and zero hits.
        let cold = state.chunks.isEmpty && state.notes.isEmpty
        for fileURL in files {
            let rel = String(fileURL.path.dropFirst(root.count + 1))
            // Index reporting: an unreadable file used to vanish from the report silently;
            // now it lands in failed (and stays dirty) instead of blurring the open/failed line.
            let data: Data
            do { data = try Data(contentsOf: fileURL) }
            catch { runFailures[rel] = String(describing: error); continue }
            let checksum = sha(data)
            if let k = known[rel], k.checksum == checksum {
                known[rel] = nil
                report.unchanged += 1
                var skip = true
                if cold {
                    var title = "", permalink = "", source = "human"
                    db.query("SELECT title, permalink, source FROM notes WHERE id = ?", [Int64(k.id)]) {
                        title = $0[0] as? String ?? ""; permalink = $0[1] as? String ?? ""
                        source = $0[2] as? String ?? "human"
                    }
                    var loaded: [ChunkRow] = []
                    // vec: from embed_cache by hash; for pre-migration old rows — from chunks.vec
                    db.query("""
                    SELECT c.ord, c.text, COALESCE(e.vec, c.vec)
                    FROM chunks c LEFT JOIN embed_cache e
                      ON e.content_hash = c.content_hash AND e.model = ? AND e.chunker = ?
                    WHERE c.note_id = ? ORDER BY c.ord
                    """, [embedModelTag, chunkerTag, Int64(k.id)]) { row in
                        if let ord = intAt(row, 0), let t = row[1] as? String, let v = row[2] as? Data {
                            let vec = v.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                            loaded.append(ChunkRow(noteId: k.id, ord: ord, text: t, vec: vec))
                        }
                    }
                    var expectedRows = 0
                    db.query("SELECT COUNT(*) FROM chunks WHERE note_id = ?", [Int64(k.id)]) {
                        expectedRows = intAt($0, 0) ?? 0
                    }
                    // loaded is empty (no chunks) or incomplete (vectors under other
                    // model/chunker tags) — re-embed the whole file, otherwise the in-memory
                    // index would be holey and its top-1 would drift.
                    if loaded.isEmpty || loaded.count != expectedRows {
                        // notes rows exist but chunks don't (or vectors are broken) — re-embed the file
                        dropNote(k.id)
                        skip = false
                    } else {
                        state.chunks.append(contentsOf: loaded)
                        state.notes[k.id] = (title, permalink, rel, source)
                    }
                }
                if skip {
                    pendingLinks += NoteCodec.wikilinks(String(decoding: data, as: UTF8.self))
                        .map { (src: k.id, target: $0) }
                    continue
                }
            }

            let text = String(decoding: data, as: UTF8.self)
            let fallbackPermalink = Self.permalink(project: project, relPath: rel)
            let note = NoteCodec.parse(text, fallbackTitle: Self.title(of: fileURL), fallbackPermalink: fallbackPermalink)

            // OLD chunks of the file: match new chunks by ord+text. Rows matching by text
            // stay as they are (own id, own FTS, own vector) — when appending to a live
            // transcript that is the whole prefix except the last chunk.
            // The note id is preserved (UPSERT instead of REPLACE) — otherwise child chunks would be orphaned.
            var oldNoteId: Int?
            db.query("SELECT id FROM notes WHERE project = ? AND rel_path = ?", [project, rel]) {
                oldNoteId = intAt($0, 0)
            }
            let isUpdate = oldNoteId != nil
            db.run("""
            INSERT INTO notes(project, rel_path, title, permalink, checksum, source) VALUES(?,?,?,?,?,?)
            ON CONFLICT(project, rel_path) DO UPDATE SET title=excluded.title,
              permalink=excluded.permalink, checksum=excluded.checksum, source=excluded.source
            """, [project, rel, note.title, note.permalink, checksum, note.source])
            var noteId = 0
            db.query("SELECT id FROM notes WHERE project = ? AND rel_path = ?", [project, rel]) { noteId = intAt($0, 0) ?? 0 }

            let body = note.body
            let newChunks = NoteCodec.chunk(body.isEmpty ? text : body)
            var oldRows: [(id: Int, ord: Int, text: String)] = []
            if let oid = oldNoteId {
                db.query("SELECT id, ord, text FROM chunks WHERE note_id = ?", [Int64(oid)]) { row in
                    if let id = intAt(row, 0), let ord = intAt(row, 1), let t = row[2] as? String {
                        oldRows.append((id, ord, t))
                    }
                }
            }
            var oldByOrd: [Int: (id: Int, text: String)] = [:]
            for o in oldRows { oldByOrd[o.ord] = (o.id, o.text) }
            // old rows with no place in the new chunking (tails, boundary shifts)
            for o in oldRows {
                let reused = newChunks.indices.contains(o.ord) && newChunks[o.ord] == o.text
                guard !reused else { continue }
                db.run("DELETE FROM chunks_fts WHERE rowid = ?", [Int64(o.id)])
                db.run("DELETE FROM chunks WHERE id = ?", [Int64(o.id)])
                state.chunks.removeAll { $0.noteId == noteId && $0.ord == o.ord }
            }
            for (ord, chunkText) in newChunks.enumerated() {
                if let o = oldByOrd[ord], o.text == chunkText {
                    // chunk unchanged: DB/FTS row is in place; the in-memory vector may
                    // not have been loaded only on a cold start — take it from embed_cache
                    if !state.chunks.contains(where: { $0.noteId == noteId && $0.ord == ord }) {
                        let r = try await embedCached(chunkText)
                        if r.modelRan { report.modelRuns += 1 }
                        state.chunks.append(ChunkRow(noteId: noteId, ord: ord, text: chunkText, vec: r.vec))
                    }
                    continue
                }
                let r = try await embedCached(chunkText)
                if r.modelRan { report.modelRuns += 1 }
                db.run("DELETE FROM chunks WHERE note_id = ? AND ord = ?", [Int64(noteId), Int64(ord)])
                db.run("INSERT INTO chunks(note_id, project, ord, text, content_hash, vec) VALUES(?,?,?,?,?,NULL)",
                       [Int64(noteId), project, Int64(ord), chunkText, Self.md5hex(Data(chunkText.utf8))])
                db.run("INSERT INTO chunks_fts(rowid, text) VALUES(?,?)", [Int64(db.lastRowId), chunkText])
                state.chunks.removeAll { $0.noteId == noteId && $0.ord == ord }
                state.chunks.append(ChunkRow(noteId: noteId, ord: ord, text: chunkText, vec: r.vec))
            }
            state.notes[noteId] = (note.title, note.permalink, rel, note.source)
            pendingLinks += NoteCodec.wikilinks(text).map { (src: noteId, target: $0) }
            known[rel] = nil
            if isUpdate { report.updated += 1 } else { report.added += 1 }
        }

        // files gone from disk
        for (_, k) in known { dropNote(k.id); report.deleted += 1 }

        // Wikilink resolution -> edges. Resolver over all notes of the project:
        // rel_path, permalink (full and without the project prefix), title, file name.
        var byRel: [String: Int] = [:]
        var byPermalink: [String: Int] = [:]
        var byTitle: [String: Int] = [:]
        var byName: [String: Int] = [:]
        for (id, n) in state.notes {
            byRel[n.relPath.lowercased()] = id
            byRel[(n.relPath as NSString).deletingPathExtension.lowercased()] = id
            byPermalink[n.permalink.lowercased()] = id
            byTitle[n.title.lowercased()] = id
            let name = ((n.relPath as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            byName[name] = id
        }
        var edgeCount = 0
        for (src, raw) in pendingLinks {
            var t = raw
            if t.hasPrefix("./") { t = String(t.dropFirst(2)) }
            let srcDir = state.notes[src].map { ($0.relPath as NSString).deletingLastPathComponent } ?? ""
            var dst: Int?
            for cand in [t, srcDir.isEmpty ? t : srcDir + "/" + t] {
                if let id = byRel[cand.lowercased()] { dst = id; break }
            }
            if dst == nil {
                for cand in [t, "\(project)/\(t)"] {
                    if let id = byPermalink[cand.lowercased()] { dst = id; break }
                }
            }
            if dst == nil { dst = byTitle[t.lowercased()] }
            if dst == nil { dst = byName[(t as NSString).lastPathComponent.lowercased()] }
            guard let dstId = dst, dstId != src else { continue }
            db.run("INSERT OR IGNORE INTO edges(project, src, dst, kind) VALUES(?,?,?,?)",
                   [project, Int64(src), Int64(dstId), "link"])
            edgeCount += 1
        }
        if edgeCount > 0 {
            FileHandle.standardError.write(Data("bmem: [\(project)] graph: \(edgeCount) edges\n".utf8))
        }

        state.indexedAt = Date()
        states[project] = state
        // Index reporting: the run finished — its failure snapshot becomes the current one
        // (empty if everything read fine); reporting only, no behavior impact.
        indexFailures[project] = runFailures
        report.failed = runFailures.count
        // Paths processed by this run come off the dirty registry; anything
        // written during the awaits stays and lands in the next run.
        if var d = dirtyFiles[project] {
            d.subtract(snapshotDirty)
            dirtyFiles[project] = d
        }
        db.query("SELECT COUNT(*) FROM chunks WHERE project = ?", [project]) {
            report.chunksTotal = intAt($0, 0) ?? 0
        }
        lastReports[project] = report
        if report.added + report.updated + report.deleted > 0 || report.modelRuns > 0 {
            let line = "bmem: [\(project)] index: added=\(report.added) updated=\(report.updated) "
                + "unchanged=\(report.unchanged) deleted=\(report.deleted) "
                + "model_runs=\(report.modelRuns) chunks=\(report.chunksTotal)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        return report
    }

    /// Quick freshness check before search/read:
    /// 1) a background reindex is in flight (after write/edit) — wait for it: acceptance
    ///    requires a fresh transcript line to be found immediately (FTS already has it);
    /// 2) the set of md files diverged from the DB (external adds/deletes) or there are
    ///    dirty paths (edits bypassing write/edit) — full run; it is cheap because
    ///    unchanged files are not re-hashed and the model never runs on any chunk
    ///    already seen (embed_cache).
    /// Set comparison — directory listing only (as before FIX-3), no file reads.
    private func ensureFresh(project: String) async throws {
        if let task = reindexInFlight[project] {
            _ = await task.value
            reindexInFlight[project] = nil
        }
        guard states[project] != nil else {
            try await reindex(project: project)
            return
        }
        let root = try projectRoot(project)
        let dirty = dirtyFiles[project] ?? []
        if !dirty.isEmpty {
            try await reindex(project: project)
            return
        }
        let files = Set(Self.markdownFiles(in: root, excludes: projectExcludes[project] ?? []).map { String($0.path.dropFirst(root.count + 1)) })
        var knownPaths: Set<String> = []
        db.query("SELECT rel_path FROM notes WHERE project = ?", [project]) { knownPaths.insert($0[0] as! String) }
        if files != knownPaths { try await reindex(project: project) }
    }

    // MARK: - Search

    public func search(project: String, query: String, limit: Int) async throws -> [NoteHit] {
        try await ensureFresh(project: project)
        guard let state = states[project] else { return [] }
        let root = try projectRoot(project)

        let qv = try await embedder.embedQuery(query)

        // 1) vector pass
        var bestPerNote: [Int: (score: Double, text: String)] = [:]
        for ch in state.chunks {
            let cos = Self.dot(qv, ch.vec)
            if cos >= config.minSimilarity {
                if bestPerNote[ch.noteId] == nil || cos > bestPerNote[ch.noteId]!.score {
                    bestPerNote[ch.noteId] = (cos, ch.text)
                }
            }
        }

        // 2) FTS pass (bm25), only to complement the vector, not drown it
        var ftsHits: [(noteId: Int, text: String, rank: Double)] = []
        let match = Self.ftsMatch(query)
        if !match.isEmpty {
            db.query("""
            SELECT f.rowid, f.rank FROM chunks_fts f WHERE chunks_fts MATCH ? ORDER BY f.rank LIMIT 40
            """, [match]) { row in
                if let cid = row[0] as? Int64, let rank = row[1] as? Double {
                    db.query("SELECT note_id, text FROM chunks WHERE id = ?", [cid]) { r in
                        if let nid = r[0] as? Int64, let t = r[1] as? String {
                            ftsHits.append((Int(nid), t, rank))
                        }
                    }
                }
            }
        }

        // 3) merge: vector hits first, then FTS-only
        var results: [(noteId: Int, score: Double, text: String, fromVector: Bool)] =
            bestPerNote.map { ($0.key, $0.value.score, $0.value.text, true) }
                .sorted { $0.score > $1.score }
        let seen = Set(results.map { $0.noteId })
        for hit in ftsHits where !seen.contains(hit.noteId) && !bestPerNote.keys.contains(hit.noteId) {
            results.append((hit.noteId, 0.0, hit.text, false))
        }

        var hits: [NoteHit] = []
        for r in results.prefix(limit) {
            guard let note = state.notes[r.noteId] else { continue }
            hits.append(NoteHit(title: note.title,
                                permalink: note.permalink,
                                content: String(r.text.prefix(600)),
                                score: (r.score * 1000).rounded() / 1000,
                                filePath: root + "/" + note.relPath,
                                source: note.source))
        }
        return hits
    }

    // MARK: - Reading

    public func read(project: String, identifier: String) async throws -> NoteResult {
        try await ensureFresh(project: project)
        let root = try projectRoot(project)
        var ident = identifier
        if ident.hasPrefix("memory://") { ident = String(ident.dropFirst("memory://".count)) }
        if ident.hasPrefix("\(project)/") { ident = String(ident.dropFirst(project.count + 1)) }

        // candidates: rel_path == ident, permalink == ident|project/ident, title == ident
        var relPath: String?
        func find(_ sql: String, _ p: [Any?]) {
            db.query(sql, p) { if relPath == nil { relPath = $0[0] as? String } }
        }
        find("SELECT rel_path FROM notes WHERE project = ? AND rel_path = ?", [project, ident])
        find("SELECT rel_path FROM notes WHERE project = ? AND (permalink = ? OR permalink = ?)", [project, ident, "\(project)/\(ident)"])
        find("SELECT rel_path FROM notes WHERE project = ? AND lower(title) = lower(?)", [project, ident])
        guard let rel = relPath, let data = FileManager.default.contents(atPath: root + "/" + rel) else {
            throw EngineError.notFound(identifier)
        }
        let text = String(decoding: data, as: UTF8.self)
        let note = NoteCodec.parse(text, fallbackTitle: Self.title(ofPath: rel), fallbackPermalink: Self.permalink(project: project, relPath: rel))
        return NoteResult(title: note.title, permalink: note.permalink, content: text,
                          filePath: root + "/" + rel,
                          checksum: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - Graph

    /// build_context v2: a real 1-hop walk over wikilink edges (out + backlinks),
    /// complemented by vector search.
    public func buildContext(project: String, identifier: String, limit: Int)
        async throws -> (target: NoteResult, graph: [(NoteHit, String)], vector: [NoteHit])
    {
        let target = try await read(project: project, identifier: identifier)
        let root = try projectRoot(project)
        let rel = String(target.filePath.dropFirst(root.count + 1))
        guard let state = states[project],
              let targetId = state.notes.first(where: { $0.value.relPath == rel })?.key else {
            return (target, [], [])
        }
        // First gather neighbor ids (the query callback is @Sendable — mutable state
        // cannot be captured into it, Swift 6 region isolation), then build the hits.
        var pending: [(id: Int, kind: String)] = []
        db.query("SELECT dst FROM edges WHERE project = ? AND src = ? AND kind = 'link'",
                 [project, Int64(targetId)]) { row in
            if let d = row[0] as? Int64 { pending.append((Int(d), "out")) }
        }
        db.query("SELECT src FROM edges WHERE project = ? AND dst = ? AND kind = 'link'",
                 [project, Int64(targetId)]) { row in
            if let s = row[0] as? Int64 { pending.append((Int(s), "in")) }
        }
        var graph: [(NoteHit, String)] = []
        var seen: Set<Int> = [targetId]
        for (id, kind) in pending {
            guard !seen.contains(id), let n = state.notes[id] else { continue }
            seen.insert(id)
            let path = root + "/" + n.relPath
            let body = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? ""
            graph.append((NoteHit(title: n.title, permalink: n.permalink,
                                  content: String(body.prefix(300)), score: 0, filePath: path,
                                  source: n.source), kind))
        }
        let words = target.title.components(separatedBy: " ").filter { $0.count > 3 }.prefix(6).joined(separator: " ")
        let vec = try await search(project: project, query: words.isEmpty ? target.title : words, limit: limit + graph.count)
            .filter { h in h.permalink != target.permalink && !graph.contains { $0.0.permalink == h.permalink } }
        return (target, graph, Array(vec.prefix(limit)))
    }

    // MARK: - Writing

    public func write(project: String, title: String, content: String, directory: String, tags: [String], overwrite: Bool) async throws -> NoteResult {
        let root = try projectRoot(project)
        let dir = directory.isEmpty ? "" : directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileName = Self.sanitizeFileName(title) + ".md"
        let rel = dir.isEmpty ? fileName : dir + "/" + fileName
        let fullPath = root + "/" + rel
        let exists = FileManager.default.fileExists(atPath: fullPath)
        if exists && !overwrite { throw EngineError.alreadyExists(rel) }

        let permalink = Self.permalink(project: project, relPath: rel)
        var fm = ["---", "title: \(title)", "permalink: \(permalink)", "type: note"]
        if !tags.isEmpty { fm.append("tags: [\(tags.joined(separator: ", "))]") }
        fm.append("---")
        fm.append("")
        let body = content.hasSuffix("\n") ? content : content + "\n"
        try (fm.joined(separator: "\n") + body).write(toFile: fullPath, atomically: true, encoding: .utf8)

        touchIndex(project: project, relPath: rel)
        return NoteResult(title: title, permalink: permalink, content: content, filePath: fullPath,
                          checksum: "")
    }

    public func edit(project: String, identifier: String, operation: String, content: String,
                     findText: String?, section: String?) async throws -> NoteResult {
        let current = try await read(project: project, identifier: identifier)
        return try await rawEdit(project: project, path: current.filePath, current: current,
                                 operation: operation, content: content, findText: findText, section: section)
    }

    private func rawEdit(project: String, path: String, current: NoteResult, operation: String, content: String, findText: String?, section: String?) async throws -> NoteResult {
        let full = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let note = NoteCodec.parse(full, fallbackTitle: current.title, fallbackPermalink: current.permalink)
        var body = note.body
        var newContent = content
        if !newContent.hasSuffix("\n") { newContent += "\n" }

        switch operation {
        case "append": body = body + "\n" + newContent
        case "prepend": body = newContent + "\n" + body
        case "find_replace":
            guard let needle = findText, !needle.isEmpty else { throw EngineError.notFound("find_text") }
            if !body.contains(needle) { throw EngineError.notFound("find_text not found") }
            body = body.replacingOccurrences(of: needle, with: content)
        case "replace_section":
            guard let section else { throw EngineError.notFound("section") }
            var lines = body.components(separatedBy: "\n")
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == section }) else {
                throw EngineError.notFound("section")
            }
            let level = section.prefix(while: { $0 == "#" }).count
            var end = lines.count
            for i in (start + 1)..<lines.count {
                let l = lines[i]
                if l.hasPrefix("#"), l.prefix(while: { $0 == "#" }).count <= level { end = i; break }
            }
            lines.replaceSubrange(start..<end, with: content.components(separatedBy: "\n"))
            body = lines.joined(separator: "\n")
        default:
            throw EngineError.notSupported("operation \(operation)")
        }

        var fm = ["---", "title: \(note.title)", "permalink: \(note.permalink)", "type: \(note.type)"]
        if note.source != "human" { fm.append("source: \(note.source)") }  // UI-1: an edit does not lose the author
        if !note.tags.isEmpty { fm.append("tags: [\(note.tags.joined(separator: ", "))]") }
        fm.append("---")
        fm.append("")
        try (fm.joined(separator: "\n") + body).write(toFile: path, atomically: true, encoding: .utf8)

        let rel = String(path.dropFirst((try projectRoot(project)).count + 1))
        touchIndex(project: project, relPath: rel)
        return NoteResult(title: note.title, permalink: note.permalink, content: body, filePath: path, checksum: "")
    }

    /// Reindex after writing/editing one note — as a BACKGROUND task:
    /// the write does not wait for re-embedding (acceptance item 4). The file is
    /// marked dirty immediately, so the next search waits for the unfinished background
    /// run and sees fresh text via FTS. The cache table makes the run O(changed chunk).
    private func touchIndex(project: String, relPath: String) {
        dirtyFiles[project, default: []].insert(relPath)
        guard reindexInFlight[project] == nil else { return }  // already computing
        reindexInFlight[project] = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.reindex(project: project)
        }
    }

    /// Last index-run report for the project (CLI `bmem index`, FIX-3 benchmarks).
    public func indexReport(project: String) -> IndexReport? { lastReports[project] }

    /// gc pass over embed_cache: rows referenced by no chunk
    /// (orphaned after edits) are deleted. Cheap LEFT JOIN on content.
    @discardableResult
    public func gcEmbedCache() -> Int {
        var removed = 0
        db.query("""
        SELECT e.content_hash FROM embed_cache e
        LEFT JOIN chunks c ON c.content_hash = e.content_hash
        WHERE c.content_hash IS NULL
        """) { row in
            if let h = row[0] as? String {
                db.run("DELETE FROM embed_cache WHERE content_hash = ?", [h])
                removed += 1
            }
        }
        FileHandle.standardError.write(Data("bmem: embed_cache gc: removed \(removed) orphaned vectors\n".utf8))
        return removed
    }

    /// UI-4 "Forget project": purge the project index from DB and memory.
    /// Files are handled by the caller (BackupManager archives to ~/.bmem/forgotten);
    /// here — notes/chunks/chunks_fts/edges rows and the actor's cache state.
    /// embed_cache is deliberately not cleared: it is content-addressed and reused
    /// by other projects; orphaned vectors are removed by gcEmbedCache.
    public func dropProject(_ project: String) -> (notes: Int, chunks: Int) {
        var notes = 0, chunks = 0
        db.query("SELECT COUNT(*) FROM notes WHERE project = ?", [project]) {
            notes = ($0[0] as? Int64).flatMap { Int(exactly: $0) } ?? 0
        }
        db.query("SELECT COUNT(*) FROM chunks WHERE project = ?", [project]) {
            chunks = ($0[0] as? Int64).flatMap { Int(exactly: $0) } ?? 0
        }
        db.run("DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE project = ?)", [project])
        db.run("DELETE FROM chunks WHERE project = ?", [project])
        db.run("DELETE FROM notes WHERE project = ?", [project])
        db.run("DELETE FROM edges WHERE project = ?", [project])
        states[project] = nil
        dirtyFiles[project] = nil
        lastReports[project] = nil
        return (notes, chunks)
    }

    // MARK: - Misc

    public func warm() async throws {
        try await embedder.ensureLoaded()
    }

    /// UI-7: apply config changed by PUT /v1/config without restarting the daemon.
    /// Before this, Engine lived on the config snapshot taken at start: onboarding
    /// added a folder while search kept answering "unknown project" until restart
    /// (the 1.1.1-beta1 smoke caught exactly this). The new folder's index is built
    /// synchronously by the first search — here we only refresh the path registry and excludes.
    public func updateConfig(_ c: Config) {
        config = c
        projectExcludes = Self.computeExcludes(from: c)
    }

    /// For the daemon's idle-watchdog: unload the model if it has been loading for
    /// more than timeout seconds (check and reset are atomic inside the Embedder actor).
    public func unloadModelIfIdle(timeout: TimeInterval) async {
        await embedder.unloadIfIdle(timeout: timeout)
    }

    /// FIX-4: system memory pressure level. Raw values match the
    /// DispatchSource.makeMemoryPressureSource event names.
    public enum MemoryPressure: String, Sendable {
        case warning, critical, normal
    }

    /// Memory-pressure signal handler (shared by the live DispatchSource and
    /// test injection via the control-FIFO):
    /// .warning  — immediate model unload (without waiting for the idle timer) +
    ///              reset of in-memory index state (vector chunks) to minimum;
    /// .critical — same plus SQLite PRAGMA shrink_memory (the page cache returns
    ///              pages to the OS; no need to vacuum mid-flight);
    /// .normal   — nothing: the model reloads on demand (the reload path
    ///              is provided by FIX-2).
    /// Returns MB freed (for the log).
    public func handleMemoryPressure(_ level: MemoryPressure) async -> Double {
        guard level != .normal else {
            FileHandle.standardError.write(Data("bmem: memory pressure normal, model stays as-is\n".utf8))
            return 0
        }
        // FOOTPRINT fix: measure the product's memory — daemon + engine child.
        let before = processFootprintMB() + (await embedder.workerFootprintMB())
        await embedder.forceUnload(reason: "on \(level.rawValue) memory pressure")
        states.removeAll()  // vector chunks are the largest in-memory structure;
                            // the first search rebuilds them from the DB without model runs
        if level == .critical { db.exec("PRAGMA shrink_memory") }
        // the child needs a moment to die (SIGTERM), otherwise shed comes out zero
        try? await Task.sleep(for: .milliseconds(300))
        let after = processFootprintMB() + (await embedder.workerFootprintMB())
        let shed = max(0, before - after)
        let line = level == .critical
            ? String(format: "bmem: critical memory pressure, shed %.0f MB (footprint %.0f -> %.0f)\n", shed, before, after)
            : String(format: "bmem: memory pressure warning, shed %.0f MB (footprint %.0f -> %.0f)\n", shed, before, after)
        FileHandle.standardError.write(Data(line.utf8))
        return shed
    }

    /// FIX-4: memory-metrics line for the daemon's periodic log plus a counter of
    /// footprint-threshold breaches (BMEM_MEM_LIMIT_MB). Called every 60 s by a
    /// detached task in daemon mode; returns the number of consecutive samples
    /// above the limit (0 — normal; the counter resets on a sample below the
    /// threshold).
    public func memSample(limitMB: Double) async -> (line: String, overCount: Int) {
        let rss = processRSSMB()
        // FOOTPRINT fix: product footprint = daemon + engine child (if alive).
        let fp = processFootprintMB() + (await embedder.workerFootprintMB())
        peakFootprintMB = max(peakFootprintMB, fp)
        let swap = swapUsedPct()
        var chunkTotal = 0
        db.query("SELECT COUNT(*) FROM chunks") { row in
            chunkTotal = (row[0] as? Int64).map { Int($0) } ?? 0
        }
        if fp > limitMB { overLimitStreak += 1 } else { overLimitStreak = 0 }
        let line = String(format: "mem: rss %.0f MB footprint %.0f MB swap_used %.1f%% (projects=%d chunks=%d)",
                          rss, fp, swap, config.projects.count, chunkTotal)
        return (line, overLimitStreak)
    }

    private var overLimitStreak = 0

    /// UI-1 GET /v1/status: snapshot for the facade showcase — index size and freshness
    /// per project, model state, current daemon footprint.
    public struct ProjectStat: Sendable {
        public var name: String
        public var notes: Int
        public var chunks: Int
        public var indexedAt: Date?   // nil — the project has never been indexed
        /// Index reporting: files on disk normally awaiting indexing — live
        /// session tails (>256 KB, indexed after closing) and files
        /// added after the last run. Not failures.
        public var open = 0
        /// Files the last run genuinely failed to read (EACCES etc.).
        public var failed = 0
    }
    public struct DaemonStatus: Sendable {
        public var projects: [ProjectStat]
        public var totalChunks: Int
        public var modelLoaded: Bool
        public var footprintMB: Double
        /// Max footprint since daemon start (UI-5: "idle X · peak Y").
        public var peakMB: Double
        /// Index reporting: total open/failed across projects and honest dirty:
        /// yes only when failed>0 or an open file older than openStaleLimit.
        /// A live session tail or a fresh new file no longer makes the index
        /// "dirty" all night.
        public var openFiles = 0
        public var failedFiles = 0
        public var dirty = false
    }
    /// Index reporting: age of an open file (by mtime) after which it is considered
    /// stuck and raises dirty. 24 h — overnight transcripts close sooner.
    public static let openStaleLimit: TimeInterval = 24 * 3600
    /// Footprint peak is tracked passively: in every daemonStatus() and memSample().
    /// No separate ticker — the showcase is polled by the facade every 5 s anyway.
    private var peakFootprintMB: Double = 0
    public func daemonStatus() async -> DaemonStatus {
        var notesPer: [String: Int] = [:]
        var chunksPer: [String: Int] = [:]
        db.query("SELECT project, COUNT(*) FROM notes GROUP BY project") { row in
            if let p = row[0] as? String, let n = (row[1] as? Int64).flatMap({ Int(exactly: $0) }) { notesPer[p] = n }
        }
        db.query("SELECT project, COUNT(*) FROM chunks GROUP BY project") { row in
            if let p = row[0] as? String, let n = (row[1] as? Int64).flatMap({ Int(exactly: $0) }) { chunksPer[p] = n }
        }
        var total = 0
        db.query("SELECT COUNT(*) FROM chunks") { row in total = (row[0] as? Int64).map { Int($0) } ?? 0 }
        // Index reporting: indexed rel-paths per project — the denominator for
        // open (files on disk missing from the DB and not among the failures).
        var indexedRels: [String: Set<String>] = [:]
        db.query("SELECT project, rel_path FROM notes") { row in
            if let p = row[0] as? String, let r = row[1] as? String { indexedRels[p, default: []].insert(r) }
        }
        var stats: [ProjectStat] = []
        let now = Date()
        var openTotal = 0, failedTotal = 0, oldestOpen: TimeInterval = 0
        for name in config.projects.keys.sorted() {
            let raw = states[name]?.indexedAt
            var stat = ProjectStat(name: name,
                                   notes: notesPer[name] ?? 0,
                                   chunks: chunksPer[name] ?? 0,
                                   indexedAt: (raw ?? .distantPast) == .distantPast ? nil : raw)
            // open/failed — reporting over already-existing fields (disk vs notes,
            // failure snapshot of the last run); DB and indexer untouched.
            // Failures of files no longer on disk are not counted: runs no longer
            // touch them, and ensureFresh without a path-set change won't rewrite
            // them — the counter would stick.
            var failures = indexFailures[name] ?? [:]
            if let root = try? projectRoot(name) {
                let scan = Self.scanMarkdown(in: root, excludes: projectExcludes[name] ?? [])
                let known = indexedRels[name] ?? []
                var eligibleRels: Set<String> = []
                for url in scan.eligible { eligibleRels.insert(String(url.path.dropFirst(root.count + 1))) }
                failures = failures.filter { eligibleRels.contains($0.key) }
                stat.failed = failures.count
                func noteOpen(_ url: URL) {
                    stat.open += 1
                    if let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                        oldestOpen = max(oldestOpen, now.timeIntervalSince(m))
                    }
                }
                for url in scan.eligible {
                    let rel = String(url.path.dropFirst(root.count + 1))
                    if known.contains(rel) || failures[rel] != nil { continue }
                    noteOpen(url)
                }
                // session tails >256 KB — normally pending, not failures
                for url in scan.oversize {
                    noteOpen(url)
                }
            } else {
                stat.failed = 0
            }
            openTotal += stat.open
            failedTotal += stat.failed
            stats.append(stat)
        }
        let fp = processFootprintMB() + (await embedder.workerFootprintMB())
        peakFootprintMB = max(peakFootprintMB, fp)
        return DaemonStatus(projects: stats,
                            totalChunks: total,
                            modelLoaded: await embedder.isLoaded,
                            footprintMB: fp,
                            peakMB: peakFootprintMB,
                            openFiles: openTotal,
                            failedFiles: failedTotal,
                            dirty: failedTotal > 0 || oldestOpen > Self.openStaleLimit)
    }

    /// For the external openai endpoint: a single lane without prompt prefixes
    /// (EmbedServer builds external clients' index and queries one way).
    public func embedRaw(_ text: String) async throws -> [Float] {
        try await embedder.embedRaw(text)
    }

    /// Embedding integration: text vector via the active backend's document/query path —
    /// for numeric cross-check of the CoreML pipeline against the python reference
    /// (evals/embeddinggemma2-vs-qwen.py). Test CLI: bmem embed-probe.
    public func embedProbe(_ text: String, kind: String) async throws -> [Float] {
        switch kind {
        case "query": return try await embedder.embedQuery(text)
        case "document": return try await embedder.embedDocument(text)
        default: return try await embedder.embedRaw(text)
        }
    }

    public func deleteNote(project: String, identifier: String) async throws -> Bool {
        let current = try await read(project: project, identifier: identifier)
        try FileManager.default.removeItem(atPath: current.filePath)
        try await reindex(project: project)
        return true
    }

    public func moveNote(project: String, identifier: String, newFolder: String) async throws -> Bool {
        let current = try await read(project: project, identifier: identifier)
        let root = try projectRoot(project)
        let name = (current.filePath as NSString).lastPathComponent
        let dir = newFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let destDir = dir.isEmpty ? root : root + "/" + dir
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let dest = destDir + "/" + name
        guard !FileManager.default.fileExists(atPath: dest) else { throw EngineError.alreadyExists(name) }
        try FileManager.default.moveItem(atPath: current.filePath, toPath: dest)
        try await reindex(project: project)
        return true
    }

    public func recent(project: String, limit: Int) -> [NoteHit] {
        guard let state = states[project], let root = try? projectRoot(project) else { return [] }
        var hits: [NoteHit] = []
        for (_, note) in state.notes {
            let path = root + "/" + note.relPath
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            hits.append(NoteHit(title: note.title, permalink: note.permalink, content: "",
                                score: mtime.timeIntervalSince1970, filePath: path,
                                source: note.source))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Utilities

    /// Content hash for embed_cache. md5 (Insecure) is enough: a collision in a
    /// 30-thousand embedding corpus means broken search, not an attack; md5 is 5-10×
    /// faster than sha256 on a gigabyte run, and sha256 is already busy on file
    /// checksums (change detection).
    static func md5hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).reduce(into: "") { $0 += String(format: "%02x", $1) }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var sum: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 0..<pa.count { sum += pa[i] * pb[i] }
            }
        }
        return Double(sum)
    }

    static func ftsMatch(_ query: String) -> String {
        let tokens = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.prefix(12).map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    static let skipDirs: Set<String> = ["node_modules", "__pycache__", "venv", ".venv",
                                         "dist", "build", "DerivedData", "target", "checkouts",
                                         "SANDBOX BASIC MEMORY"]

    /// FIX-5: prefixes of a project's subfolders that are the root of another
    /// registry project. Only exact path nesting (ai-projects/memory/hermes ⊂
    /// memory/hermes); symlinks are not resolved — reindex walks real paths
    /// with an enumerator.
    static func computeExcludes(from config: Config) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var roots: [(name: String, path: String)] = []
        for (name, path) in config.projects {
            roots.append((name, path.hasSuffix("/") ? String(path.dropLast()) : path))
        }
        for parent in roots {
            var ex: [String] = []
            for other in roots where other.name != parent.name {
                if other.path.hasPrefix(parent.path + "/") {
                    ex.append(String(other.path.dropFirst(parent.path.count + 1)))
                }
            }
            if !ex.isEmpty { out[parent.name] = ex.sorted() }
        }
        return out
    }

    static func isExcluded(_ rel: String, _ excludes: [String]) -> Bool {
        for ex in excludes where rel == ex || rel.hasPrefix(ex + "/") { return true }
        return false
    }

    static func listMarkdown(in root: String) -> [URL] {
        markdownFiles(in: root, excludes: [])
    }

    static func markdownFiles(in root: String, excludes: [String]) -> [URL] {
        scanMarkdown(in: root, excludes: excludes).eligible
    }

    /// Index reporting: the same walk, but separately returns files dropped by the
    /// 256 KB limit — live session transcripts (indexed after close/
    /// rotation). Reporting only for /v1/status; the indexer still sees
    /// exclusively `eligible`.
    /// Live-machine acceptance: enumerate(atPath:)
    /// descended into every .build/.git/node_modules and filtered after the fact —
    /// on a live vault (273k entries) one walk cost ~2.2 s, and /v1/status is polled
    /// by the facade every 5 s: the actor queue piled up, the showcase stopped
    /// answering entirely. Skipped directories (dot-dirs and skipDirs) are now cut
    /// with skipDescendants() without descending — the result set is identical
    /// to the old post-filters on path prefixes.
    static func scanMarkdown(in root: String, excludes: [String]) -> (eligible: [URL], oversize: [URL]) {
        var out: [URL] = []
        var oversize: [URL] = []
        let rootURL = URL(fileURLWithPath: root)
        // The URL enumerator resolves symlinks at the root (/tmp → /private/tmp), while
        // callers (indexer, backup, daemonStatus) cut the rel-path as dropFirst(root.count+1)
        // from the UNresolved root. We cut rel from the realpath(3) prefix ourselves and
        // rebuild the URL under the original root — byte-for-byte like the old
        // enumerate(atPath:) + appendingPathComponent.
        // (URL.resolvingSymlinksInPath() does not resolve /tmp — verified by probe.)
        let realRoot: String = {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            return realpath(root, &buf).map { String(cString: $0) } ?? rootURL.path
        }()
        let realPrefix = realRoot + "/"
        guard let en = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return ([], []) }
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if vals?.isDirectory == true {
                let name = url.lastPathComponent
                if name.hasPrefix(".") || skipDirs.contains(name) { en.skipDescendants() }
                continue
            }
            let name = url.lastPathComponent
            if name.hasPrefix(".") || !name.hasSuffix(".md") { continue }
            let path = url.path
            guard path.hasPrefix(realPrefix) else { continue }
            let rel = String(path.dropFirst(realPrefix.count))
            if isExcluded(rel, excludes) { continue }
            let fileURL = URL(fileURLWithPath: root).appendingPathComponent(rel)
            if let sz = vals?.fileSize, sz > 262_144 {
                oversize.append(fileURL)
                continue
            }
            out.append(fileURL)
        }
        return (out.sorted { $0.path < $1.path }, oversize.sorted { $0.path < $1.path })
    }

    static func title(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if let first = try? String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }) {
            return String(first.dropFirst(2))
        }
        return name
    }

    static func title(ofPath rel: String) -> String {
        URL(fileURLWithPath: rel).deletingPathExtension().lastPathComponent
    }

    static func permalink(project: String, relPath: String) -> String {
        let dir = (relPath as NSString).deletingLastPathComponent
        let name = (relPath as NSString).deletingPathExtension
        let slug = NoteCodec.slugify(name)
        let dirSlug = dir.isEmpty ? "" : NoteCodec.slugify(dir) + "/"
        return "\(project)/\(dirSlug)\(slug)"
    }

    static func sanitizeFileName(_ title: String) -> String {
        title.components(separatedBy: "/").joined(separator: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }
}
