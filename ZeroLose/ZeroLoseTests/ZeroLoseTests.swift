//
//  ZeroLoseTests.swift
//  ZeroLoseTests
//
//  Created by dogan on 20.1.2026.
//

import XCTest
@testable import ZeroLose

final class ZeroLoseTests: XCTestCase {
    private var cacheService: ResponseCacheService!
    private var testCacheURL: URL!

    override func setUpWithError() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroLoseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        testCacheURL = tempDirectory.appendingPathComponent("ResponseCache.json")
        cacheService = ResponseCacheService(cacheURL: testCacheURL)
        cacheService.clearCache()
    }

    override func tearDownWithError() throws {
        cacheService.clearCache()
        cacheService = nil
        if let testCacheURL {
            try? FileManager.default.removeItem(at: testCacheURL.deletingLastPathComponent())
        }
        testCacheURL = nil
    }

    func testPrimeInterviewVaultCachesAllUniqueQuestions() {
        let count = cacheService.primeInterviewVault(entries: [
            (question: "Tell me about yourself", answer: "I am a senior frontend engineer.", category: "Intro"),
            (question: "Tell me about yourself", answer: "I am a lead frontend engineer.", category: "Intro"),
            (question: "How do you handle technical debt?", answer: "I prioritize risk and impact.", category: "Architecture")
        ])
        
        XCTAssertEqual(count, 2)
        XCTAssertEqual(cacheService.getResponse(for: "Tell me about yourself"), "I am a lead frontend engineer.")
    }
    
    func testFuzzyCacheLookupFindsCloseQuestion() {
        _ = cacheService.primeInterviewVault(entries: [
            (question: "How do you solve a production incident quickly?", answer: "I stabilize first, then root-cause and prevent recurrence.", category: "Incident")
        ])
        
        let response = cacheService.getResponse(for: "How do you solve production incidents quickly")
        XCTAssertEqual(response, "I stabilize first, then root-cause and prevent recurrence.")
    }

    func testVariantCacheLookupMatchesParaphrasedQuestion() {
        _ = cacheService.primeInterviewVault(entries: [
            (question: "How do you handle technical debt in legacy projects?", answer: "I rank debt by risk and fix it incrementally.", category: "Architecture")
        ])

        let response = cacheService.getResponse(for: "Legacy kod tabanındaki borcu nasıl yönetiyorsun?")
        XCTAssertEqual(response, "I rank debt by risk and fix it incrementally.")
    }

    func testPerformanceExample() throws {
        self.measure {
            _ = (0..<1000).reduce(0, +)
        }
    }
}
