// A minimal wrapper over sqlite3: one connect per process, access is serialized
// inside the Engine actor, so there is deliberately no lock here.
import CSQLite
import Foundation

final class SQLiteDB: @unchecked Sendable {
    private let handle: OpaquePointer

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = Int32(SQLITE_OPEN_READWRITE) | Int32(SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            throw NSError(domain: "bmem", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "sqlite open failed: \(String(cString: sqlite3_errmsg(h)))"])
        }
        handle = h
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(handle) }

    var lastRowId: Int { Int(sqlite3_last_insert_rowid(handle)) }

    func exec(_ sql: String) {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    /// Runs one parameterized query; calls body for every result row.
    func query(_ sql: String, _ params: [Any?] = [], _ rowHandler: ([Any?]) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for i in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(Int64(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i) {
                        row.append(Data(bytes: p, count: n))
                    } else { row.append(nil) }
                default: row.append(nil)
                }
            }
            rowHandler(row)
        }
    }

    func run(_ sql: String, _ params: [Any?] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        _ = sqlite3_step(stmt)
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [Any?]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let v as Data: sqlite3_bind_blob(stmt, idx, (v as NSData).bytes, Int32(v.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let v as [Float]:
                let data = v.withUnsafeBytes { Data($0) }
                sqlite3_bind_blob(stmt, idx, (data as NSData).bytes, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }
}
