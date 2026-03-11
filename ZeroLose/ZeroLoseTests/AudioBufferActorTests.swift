import XCTest
@testable import ZeroLose

final class AudioBufferActorTests: XCTestCase {
    var actor: AudioBufferActor!
    
    override func setUp() {
        super.setUp()
        actor = AudioBufferActor()
    }
    
    func testAppendAndSilenceTracking() async {
        let samples: [Float] = Array(repeating: 0.1, count: 1600) // 0.1s at 16kHz
        
        // Test silence tracking
        var silence = await actor.appendAndCheckSilence(samples, chunkDuration: 0.1, isSpeech: false)
        XCTAssertEqual(silence, 0.1, accuracy: 0.001)
        
        silence = await actor.appendAndCheckSilence(samples, chunkDuration: 0.1, isSpeech: false)
        XCTAssertEqual(silence, 0.2, accuracy: 0.001)
        
        // Test speech resetting silence
        silence = await actor.appendAndCheckSilence(samples, chunkDuration: 0.1, isSpeech: true)
        XCTAssertEqual(silence, 0.0)
    }
    
    func testFlushIfReady() async {
        let samples: [Float] = Array(repeating: 0.5, count: 1000)
        
        // Should NOT flush if below minSamples
        var flushed = await actor.flushIfReady(minSamples: 2000)
        XCTAssertNil(flushed)
        
        // Should flush if above minSamples
        _ = await actor.appendAndCheckSilence(samples, chunkDuration: 0.0625, isSpeech: true)
        _ = await actor.appendAndCheckSilence(samples, chunkDuration: 0.0625, isSpeech: true)
        
        flushed = await actor.flushIfReady(minSamples: 2000)
        XCTAssertNotNil(flushed)
        XCTAssertEqual(flushed?.count, 2000)
        
        // Buffer should be empty after flush
        flushed = await actor.flushIfReady(minSamples: 1)
        XCTAssertNil(flushed)
    }
    
    func testBusyState() async {
        let samples: [Float] = Array(repeating: 0.5, count: 1000)
        _ = await actor.appendAndCheckSilence(samples, chunkDuration: 0.1, isSpeech: true)
        
        // Set busy
        await actor.setBusy(true)
        
        // Should NOT flush even if data is plenty
        let flushed = await actor.flushIfReady(minSamples: 500)
        XCTAssertNil(flushed)
        
        // Set not busy
        await actor.setBusy(false)
        let flushedNow = await actor.flushIfReady(minSamples: 500)
        XCTAssertNotNil(flushedNow)
    }
}
