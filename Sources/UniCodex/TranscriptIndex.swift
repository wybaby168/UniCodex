import Darwin
import Foundation

struct TranscriptRecord: Sendable {
    let id: String
    let kind: TranscriptEntry.Kind
    let activity: Activity?
    var location: TranscriptSpool.Location?

    struct Activity: Sendable {
        let title: String
        let state: TranscriptEntry.ActivityState?
        let logLines: Int
    }

    init(_ entry: TranscriptEntry, location: TranscriptSpool.Location? = nil) {
        id = entry.id
        kind = entry.kind
        activity =
            entry.kind == .activity
            ? .init(
                title: entry.text, state: entry.activityState,
                logLines: entry.detail.isEmpty ? 0 : min(11, entry.detail.lazy.filter(\.isNewline).prefix(10).count + 1)
            ) : nil
        self.location = location
    }
}

struct TranscriptIndex: Sendable {
    private(set) var records: [TranscriptRecord] = []
    private(set) var positions: [String: Int] = [:]
    private var spool: TranscriptSpool?

    mutating func update(_ entry: TranscriptEntry) -> Int {
        let record = TranscriptRecord(entry)
        if let index = positions[entry.id] {
            records[index] = record
            return index
        }
        let index = records.count
        positions[entry.id] = index
        records.append(record)
        return index
    }

    mutating func store(_ entry: TranscriptEntry) throws {
        if let index = positions[entry.id], records[index].location != nil { return }
        if spool == nil { spool = try TranscriptSpool() }
        guard let spool else { throw WorkbenchError("无法建立会话历史缓存。") }
        let location = try spool.append(entry)
        let index = positions[entry.id] ?? update(entry)
        records[index].location = location
    }

    mutating func reconcile(_ provisional: String, with entry: TranscriptEntry) -> Int? {
        guard let index = positions.removeValue(forKey: provisional) else { return nil }
        if positions[entry.id] != nil, entry.id != provisional {
            records.remove(at: index)
            rebuildPositions(from: index)
        } else {
            positions[entry.id] = index
            records[index] = TranscriptRecord(entry)
        }
        return index
    }

    mutating func remove(_ id: String) -> Int? {
        guard let index = positions.removeValue(forKey: id) else { return nil }
        records.remove(at: index)
        rebuildPositions(from: index)
        return index
    }

    func snapshot(recent: [TranscriptEntry], folder: URL) -> TranscriptSnapshot {
        TranscriptSnapshot(
            records: records, spool: spool,
            recent: Dictionary(uniqueKeysWithValues: recent.map { ($0.id, $0) }), folder: folder)
    }

    private mutating func rebuildPositions(from start: Int) {
        for index in start..<records.count { positions[records[index].id] = index }
    }
}

struct TranscriptSnapshot: Sendable {
    let records: [TranscriptRecord]
    fileprivate let spool: TranscriptSpool?
    private let recent: [String: TranscriptEntry]
    let folder: URL

    fileprivate init(
        records: [TranscriptRecord], spool: TranscriptSpool?, recent: [String: TranscriptEntry], folder: URL
    ) {
        self.records = records
        self.spool = spool
        self.recent = recent
        self.folder = folder
    }

    func entry(_ index: Int) -> TranscriptEntry? {
        let record = records[index]
        if let live = recent[record.id] { return live }
        guard let location = record.location else { return nil }
        return spool?.read(location)
    }
}

// The unlinked temporary file belongs to this process. Old rows are seekable
// without keeping their text, command output, or parsed documents in memory.
final class TranscriptSpool: @unchecked Sendable {
    struct Location: Sendable {
        let offset: UInt64
        let length: Int
    }

    private let file: FileHandle
    private let writer = NSLock()

    init() throws {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("api-workbench-history-XXXXXX")
            .path
        var name = Array(template.utf8CString)
        let descriptor = mkstemp(&name)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard unlink(name) == 0 else {
            let error = errno
            close(descriptor)
            throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append(_ entry: TranscriptEntry) throws -> Location {
        let data = try JSONEncoder().encode(entry)
        writer.lock()
        defer { writer.unlock() }
        let offset = try file.seekToEnd()
        try file.write(contentsOf: data)
        return .init(offset: offset, length: data.count)
    }

    func read(_ location: Location) -> TranscriptEntry? {
        var bytes = Data(count: location.length)
        let complete = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let address = buffer.baseAddress else { return false }
            var read = 0
            while read < buffer.count {
                let count = pread(
                    file.fileDescriptor, address + read, buffer.count - read, off_t(location.offset) + off_t(read))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                read += count
            }
            return true
        }
        return complete ? try? JSONDecoder().decode(TranscriptEntry.self, from: bytes) : nil
    }
}
