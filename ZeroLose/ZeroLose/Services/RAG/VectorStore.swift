import Foundation
import SQLite3
import os

extension Notification.Name {
    static let vectorStoreDidChange = Notification.Name("VectorStoreDidChange")
}

/// Vector database for storing and retrieving embeddings
actor VectorStore {
    private var db: OpaquePointer?
    nonisolated private let logger = Logger(subsystem: "com.senoldogan.ZeroLose", category: "VectorStore")
    private let dbPath: String
    private var hasInitialized = false
    
    init(dbPath: String? = nil) {
        if let explicitPath = dbPath {
            self.dbPath = explicitPath
        } else {
            self.dbPath = Self.defaultDatabasePath()
        }
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    // MARK: - Lifecycle
    
    func initialize() async throws {
        try initializeIfNeeded()
    }

    private func initializeIfNeeded() throws {
        guard !hasInitialized else { return }

        // Create directory if needed
        let dirPath = (dbPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        
        // Open database
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            throw RAGError.vectorStoreFailed("Failed to open database")
        }
        
        // Create schema
        try createSchema()
        hasInitialized = true
        logger.info("VectorStore initialized at \(self.dbPath)")
    }
    
    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
        hasInitialized = false
    }
    
    // MARK: - Schema
    
    private func createSchema() throws {
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS embeddings (
            id TEXT PRIMARY KEY,
            chunk_text TEXT NOT NULL,
            embedding BLOB NOT NULL,
            metadata_json TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        
        CREATE INDEX IF NOT EXISTS idx_created_at ON embeddings(created_at);
        CREATE INDEX IF NOT EXISTS idx_metadata ON embeddings(metadata_json);
        """
        
        try execute(sql: createTableSQL)
    }
    
    // MARK: - Insert
    
    func insert(chunk: DocumentChunk, embedding: [Float]) async throws {
        try initializeIfNeeded()
        guard let db = db else {
            throw RAGError.vectorStoreFailed("Database not initialized")
        }

        let metadataString = try serializeMetadata(chunk.metadata)
        
        let embeddingData = embedding.withUnsafeBytes { Data($0) }
        
        let insertSQL = """
        INSERT OR REPLACE INTO embeddings (id, chunk_text, embedding, metadata_json, created_at)
        VALUES (?, ?, ?, ?, ?);
        """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw RAGError.vectorStoreFailed("Failed to prepare insert statement")
        }
        
        sqlite3_bind_text(statement, 1, chunk.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, chunk.text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_blob(statement, 3, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, metadataString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 5, chunk.metadata.timestamp.timeIntervalSince1970)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RAGError.vectorStoreFailed("Failed to insert embedding")
        }
        
        NotificationCenter.default.post(name: .vectorStoreDidChange, object: nil)
    }
    
    // MARK: - Search
    
    func search(queryEmbedding: [Float], topK: Int = 5) async throws -> [SearchResult] {
        try initializeIfNeeded()
        guard let db = db else {
            throw RAGError.vectorStoreFailed("Database not initialized")
        }

        let selectSQL = "SELECT id, chunk_text, embedding, metadata_json FROM embeddings;"
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) == SQLITE_OK else {
            throw RAGError.vectorStoreFailed("Failed to prepare select statement")
        }
        
        var results: [SearchResult] = []
        
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(statement, 0),
                  let textCStr = sqlite3_column_text(statement, 1),
                  let metadataCStr = sqlite3_column_text(statement, 3) else {
                continue
            }
            
            let id = String(cString: idCStr)
            let text = String(cString: textCStr)
            let metadataString = String(cString: metadataCStr)
            
            // Extract embedding blob
            let embeddingSize = sqlite3_column_bytes(statement, 2)
            guard let embeddingBlob = sqlite3_column_blob(statement, 2), embeddingSize > 0 else {
                continue
            }
            let embeddingData = Data(bytes: embeddingBlob, count: Int(embeddingSize))
            let floatCount = embeddingData.count / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            let embedding = embeddingData.withUnsafeBytes { rawBuffer -> [Float] in
                guard let baseAddress = rawBuffer.baseAddress else { return [] }
                return Array(
                    UnsafeBufferPointer(
                        start: baseAddress.assumingMemoryBound(to: Float.self),
                        count: floatCount
                    )
                )
            }
            guard !embedding.isEmpty else { continue }
            
            // Decode metadata
            guard let metadata = deserializeMetadata(metadataString),
                  let chunkID = UUID(uuidString: id) else {
                continue
            }
            
            let chunk = DocumentChunk(id: chunkID, text: text, metadata: metadata)
            let similarity = cosineSimilarity(a: queryEmbedding, b: embedding)
            
            results.append(SearchResult(chunk: chunk, similarity: similarity, embedding: embedding))
        }
        
        // Sort by similarity (descending) and return top-K
        return results.sorted { $0.similarity > $1.similarity }.prefix(topK).map { $0 }
    }
    
    // MARK: - Delete
    
    func deleteDocument(sourceID: String) async throws {
        try initializeIfNeeded()
        guard let db = db else {
            throw RAGError.vectorStoreFailed("Database not initialized")
        }

        let deleteSQL = "DELETE FROM embeddings WHERE metadata_json LIKE ?;"
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK else {
            throw RAGError.vectorStoreFailed("Failed to prepare delete statement")
        }
        
        let pattern = "%\(sourceID)%"
        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RAGError.vectorStoreFailed("Failed to delete document")
        }
        
        logger.info("Deleted all chunks for document: \(sourceID)")
        NotificationCenter.default.post(name: .vectorStoreDidChange, object: nil)
    }
    
    func deleteAll() async throws {
        try initializeIfNeeded()
        try execute(sql: "DELETE FROM embeddings;")
        logger.info("Cleared all embeddings from vector store")
        NotificationCenter.default.post(name: .vectorStoreDidChange, object: nil)
    }
    
    func countEmbeddings() async throws -> Int {
        try initializeIfNeeded()
        guard let db = db else {
            throw RAGError.vectorStoreFailed("Database not initialized")
        }
        
        let countSQL = "SELECT COUNT(*) FROM embeddings;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, countSQL, -1, &statement, nil) == SQLITE_OK else {
            throw RAGError.vectorStoreFailed("Failed to prepare count statement")
        }
        
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RAGError.vectorStoreFailed("Failed to read embeddings count")
        }
        
        return Int(sqlite3_column_int64(statement, 0))
    }
    
    // MARK: - Helpers
    
    private func execute(sql: String) throws {
        guard let db = db else {
            throw RAGError.vectorStoreFailed("Database not initialized")
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let error = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw RAGError.vectorStoreFailed(error)
        }
    }

    nonisolated private static func defaultDatabasePath() -> String {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("ZeroLose/vectors.db").path
    }
    
    private func cosineSimilarity(a: [Float], b: [Float]) -> Float {
        guard a.count == b.count else { return 0.0 }
        
        let dotProduct = zip(a, b).map(*).reduce(0, +)
        let magnitudeA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let magnitudeB = sqrt(b.map { $0 * $0 }.reduce(0, +))
        
        guard magnitudeA > 0 && magnitudeB > 0 else { return 0.0 }
        
        return dotProduct / (magnitudeA * magnitudeB)
    }

    private func serializeMetadata(_ metadata: ChunkMetadata) throws -> String {
        var dictionary: [String: Any] = [
            "sourceType": metadata.sourceType.rawValue,
            "sourceID": metadata.sourceID,
            "timestamp": metadata.timestamp.timeIntervalSince1970
        ]
        if let pageNumber = metadata.pageNumber {
            dictionary["pageNumber"] = pageNumber
        }

        let jsonData = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw RAGError.vectorStoreFailed("Failed to serialize metadata")
        }
        return jsonString
    }

    private func deserializeMetadata(_ metadataString: String) -> ChunkMetadata? {
        guard let metadataData = metadataString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let sourceTypeRawValue = object["sourceType"] as? String,
              let sourceType = SourceType(rawValue: sourceTypeRawValue),
              let sourceID = object["sourceID"] as? String else {
            return nil
        }

        let timestampSeconds = object["timestamp"] as? Double ?? Date().timeIntervalSince1970
        let pageNumber = object["pageNumber"] as? Int

        return ChunkMetadata(
            sourceType: sourceType,
            sourceID: sourceID,
            pageNumber: pageNumber,
            timestamp: Date(timeIntervalSince1970: timestampSeconds)
        )
    }
}

// MARK: - SQLITE Transient Constant
nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
