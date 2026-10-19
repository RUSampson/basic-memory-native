// md-note parsing: YAML frontmatter (title/permalink/tags/type), chunking,
// permalink generation for files without one.
import Foundation

struct NoteFile {
    var title: String
    var permalink: String
    var tags: [String]
    var type: String
    /// UI-1 trust filter: the note author — "human" (default, unregistered
    /// authors count as human too) or "agent". Frontmatter key `source:`.
    var source: String
    var body: String          // text without frontmatter
    var frontmatterLines: [String]
}

enum NoteCodec {
    /// Parses the file: `---\n...\n---\n` at the start, if present.
    static func parse(_ text: String, fallbackTitle: String, fallbackPermalink: String) -> NoteFile {
        var frontmatterLines: [String] = []
        var body = text
        let lines = text.components(separatedBy: "\n")
        if lines.first == "---", let close = (1..<max(1, lines.count)).first(where: { lines[$0] == "---" || lines[$0].hasPrefix("--- ") }) {
            frontmatterLines = Array(lines[1..<close])
            body = lines[(close + 1)...].joined(separator: "\n")
        }
        var title = fallbackTitle
        var permalink: String?
        var tags: [String] = []
        var type = "note"
        var source = "human"
        for line in frontmatterLines {
            let kv = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let val = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "title": title = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            case "permalink": permalink = val
            case "type": type = val
            case "source":
                let s = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
                if !s.isEmpty { source = s }
            case "tags":
                tags = val.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    .filter { !$0.isEmpty }
            default: break
            }
        }
        return NoteFile(title: title,
                        permalink: permalink ?? fallbackPermalink,
                        tags: tags, type: type, source: source, body: body,
                        frontmatterLines: frontmatterLines)
    }

    /// Extracts wikilinks [[Target]] / [[Target|alias]] from the text.
    /// Skips image embeds ![[...]], stops at nested brackets, cuts the
    /// alias after '|' and the anchor after '#'.
    static func wikilinks(_ text: String) -> [String] {
        var out: [String] = []
        let chars = Array(text)
        var i = 0
        while i + 1 < chars.count {
            guard chars[i] == "[", chars[i + 1] == "[" else { i += 1; continue }
            let isImage = i > 0 && chars[i - 1] == "!"
            var j = i + 2
            var target = ""
            var closed = false
            while j + 1 < chars.count, target.count <= 300 {
                if chars[j] == "]", chars[j + 1] == "]" { closed = true; break }
                if chars[j] == "[" { break }
                target.append(chars[j]); j += 1
            }
            if closed && !isImage {
                var t = target
                if let bar = t.firstIndex(of: "|") { t = String(t[..<bar]) }
                if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !t.hasPrefix("http"), !t.contains("\n") { out.append(t) }
            }
            i = closed ? j + 2 : i + 2
        }
        return out
    }

    /// The «garbage in» threshold: paragraphs longer than this are cut by maxChars
    /// without searching spaces (a quadratic scan on a megabyte single paragraph cost hours of CPU).
    static let hardParaLimitBytes = 2 * 1024 * 1024

    /// Chunks of ~1200 characters at paragraph boundaries.
    ///
    /// Linear chunker: a long paragraph is indexed in ONE pass into a
    /// Character array (graphemes — the exact semantics of the old Substring.count),
    /// space positions are collected in the same pass, cuts are array-index slices.
    /// Semantics unchanged: cut at the last space before maxChars, fallback —
    /// exactly maxChars; the remainder becomes «current».
    /// Monster paragraphs (> hardParaLimitBytes UTF-8 bytes) are cut strictly
    /// by maxChars without searching spaces.
    static func chunk(_ body: String, maxChars: Int = 1200) -> [String] {
        var chunks: [String] = []
        var current = ""
        for para in body.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if current.count + p.count + 2 > maxChars {
                if !current.isEmpty { chunks.append(current) }
                if p.count <= maxChars {
                    current = p
                } else {
                    // cut the long paragraph by sentences/spaces (linear)
                    current = splitLongParagraph(p, maxChars: maxChars, into: &chunks)
                }
            } else {
                current += current.isEmpty ? p : "\n\n" + p
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Cuts a long paragraph into pieces <= maxChars. Everything except the last
    /// piece goes into `chunks` right away; returns the tail (<= maxChars) as String.
    /// Complexity O(n): one pass over scalars + binary search over the space array.
    static func splitLongParagraph(_ p: String, maxChars: Int, into chunks: inout [String]) -> String {
        // Garbage in: megabytes without paragraphs — do not look for spaces at all.
        if p.utf8.count > hardParaLimitBytes {
            let chars = Array(p)
            var i = 0
            while chars.count - i > maxChars {
                chunks.append(String(chars[i..<(i + maxChars)]))
                i += maxChars
            }
            return String(chars[i...])
        }
        // One pass: graphemes + space positions in the same numbering as the old
        // Substring.count / lastIndex(of: " ") — byte-compatible cut boundaries
        // with the previous chunker (the embedding cache table stays valid).
        // The predicate == the old grapheme-vs-" " comparison: only the ASCII space
        // (and its canonical equivalents like «space + combining space»),
        // without \n\t — the old lastIndex(of: " ") did not count those.
        let spaceSet = CharacterSet(charactersIn: " ")
        let chars = Array(p)
        var spaceIdx: [Int] = []
        spaceIdx.reserveCapacity(chars.count / 16)
        for (i, c) in chars.enumerated()
            where c.unicodeScalars.allSatisfy({ spaceSet.contains($0) }) { spaceIdx.append(i) }
        var start = 0
        var si = 0  // index of the first space >= start + maxChars (monotonic)
        while chars.count - start > maxChars {
            let bound = start + maxChars
            while si < spaceIdx.count && spaceIdx[si] < bound { si += 1 }
            // si = first space >= bound; the last one before bound = si-1
            // (a space exactly at start is not taken — the old code looped forever there)
            var cut = bound
            if si > 0 && spaceIdx[si - 1] > start { cut = spaceIdx[si - 1] }
            chunks.append(String(chars[start..<cut]))
            start = cut
        }
        return String(chars[start...])
    }

    /// Permalink: folder + title slug. Cyrillic is kept as-is, spaces -> '-',
    /// /.#[]:` and other markdown noise are removed.
    static func slugify(_ s: String) -> String {
        let drop = CharacterSet(charactersIn: " /\\:*?\"<>|#[]`.,;:!(){}")
        return s.unicodeScalars.map { c in
            if drop.contains(c) { return "-" }
            if c == "\n" || c == "\t" { return "-" }
            return String(Character(c))
        }
        .joined()
        .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
        .lowercased()
    }
}
