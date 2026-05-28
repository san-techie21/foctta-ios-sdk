// Storage.swift — local persistence (idempotency keys, receipts, offline queue).
//
// All three stores back to JSON files in the app's Application Support
// directory. Atomic writes via FileManager.replaceItemAt. Plain JSON is
// fine for the volume — a heavy user generates ≈100 records / year × small
// payload ≈ a few KB. GRDB.swift is wired up in Package.swift for v1.x when
// query patterns grow more complex; v1.0 stays with simple JSON files.

import Foundation

// MARK: - Idempotency

/// Persists Idempotency-Keys across cold starts. Stored in UserDefaults
/// since the values are tiny (~36 bytes/UUID) and we want zero IO cost.
final class IdempotencyStore: @unchecked Sendable {
    private let prefix = "foctta.idempotency."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func getOrCreate(operationTag: String) -> String {
        let key = prefix + operationTag
        if let existing = defaults.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }

    func clear(operationTag: String) {
        defaults.removeObject(forKey: prefix + operationTag)
    }
}

// MARK: - Receipts

public struct StoredReceipt: Codable, Sendable, Equatable {
    public let receiptId: String
    public let eventType: String
    public let entityId: String
    public let chainPosition: Int64
    public let eventHash: String
    public let previousHash: String?
    // Cookie-banner receipts omit `signature` (verified against staging
    // 27 May 2026). Audit module receipts include it. Optional to handle
    // both. Mirrors Kotlin StoredReceipt.signature change.
    public let signature: String?
    public let timestamp: String
}

/// Local 90-day TTL cache of compliance receipts. Powers in-app
/// consent-history UIs without a network round-trip.
final class ReceiptStore: @unchecked Sendable {
    private let ttl: TimeInterval = 90 * 24 * 60 * 60
    private let maxCached = 1000
    private let file: URL
    private let lock = NSLock()
    private let isoFormatter = ISO8601DateFormatter()

    private var observers: [(([StoredReceipt]) -> Void)] = []

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FOCTTA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.file = dir.appendingPathComponent("receipts.json")
    }

    func all() -> [StoredReceipt] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    func observe(_ block: @escaping ([StoredReceipt]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        observers.append(block)
        block(load())
    }

    func append(_ receipt: ComplianceReceipt, eventType: String, entityId: String) {
        lock.lock(); defer { lock.unlock() }
        let stored = StoredReceipt(
            receiptId: receipt.receiptId,
            eventType: eventType,
            entityId: entityId,
            chainPosition: receipt.chainPosition,
            eventHash: receipt.eventHash,
            previousHash: receipt.previousHash,
            signature: receipt.signature,
            timestamp: receipt.timestamp
        )
        var current = load()
        if current.contains(where: { $0.receiptId == stored.receiptId }) { return }
        current.append(stored)
        let pruned = prune(current)
        persist(pruned)
        observers.forEach { $0(pruned) }
    }

    private func load() -> [StoredReceipt] {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([StoredReceipt].self, from: data)) ?? []
    }

    private func persist(_ receipts: [StoredReceipt]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(receipts) else { return }
        let tmp = file.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } catch {
            // Best-effort; corrupt cache will rebuild on next append.
        }
    }

    private func prune(_ receipts: [StoredReceipt]) -> [StoredReceipt] {
        let cutoff = Date().addingTimeInterval(-ttl)
        return receipts
            .filter { (isoFormatter.date(from: $0.timestamp) ?? Date()) > cutoff }
            .sorted { $0.chainPosition > $1.chainPosition }
            .prefix(maxCached)
            .map { $0 }
    }
}

// MARK: - Offline queue

public struct QueuedRequest: Codable, Sendable {
    public let id: String
    public let operation: String
    public let method: String
    public let path: String
    public let body: Data?
    public let idempotencyKey: String
    public let queuedAt: TimeInterval
    public var attempts: Int
}

/// FIFO queue of POSTs that failed after retries. Cap 100; oldest drops
/// when full (long-offline runaway prevention).
final class OfflineQueue: @unchecked Sendable {
    private let maxEntries = 100
    private let file: URL
    private let lock = NSLock()

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FOCTTA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.file = dir.appendingPathComponent("offline-queue.json")
    }

    @discardableResult
    func enqueue(
        operation: String,
        method: String,
        path: String,
        body: Data?,
        idempotencyKey: String
    ) -> String {
        lock.lock(); defer { lock.unlock() }
        var current = load()
        let id = UUID().uuidString
        let item = QueuedRequest(
            id: id,
            operation: operation,
            method: method,
            path: path,
            body: body,
            idempotencyKey: idempotencyKey,
            queuedAt: Date().timeIntervalSince1970,
            attempts: 0
        )
        current.append(item)
        if current.count > maxEntries { current.removeFirst(current.count - maxEntries) }
        persist(current)
        return id
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        persist(load().filter { $0.id != id })
    }

    func snapshot() -> [QueuedRequest] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private func load() -> [QueuedRequest] {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([QueuedRequest].self, from: data)) ?? []
    }

    private func persist(_ items: [QueuedRequest]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let tmp = file.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }
}
