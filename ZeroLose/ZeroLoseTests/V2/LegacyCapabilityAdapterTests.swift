import Foundation
import XCTest
@testable import ZeroLose

final class LegacyCapabilityAdapterTests: XCTestCase {
    func testAdapterContainsNoActionRoundTrip() throws {
        let source = try String(contentsOf: adapterSourceURL(), encoding: .utf8)

        XCTAssertFalse(source.contains("[ACTION:"))
        XCTAssertFalse(source.contains("handleActions"))
    }

    func testAdapterProducesInventoryOnlyDescriptorsInStableNamespace() {
        let descriptors = AgentCapabilityRegistryAdapter().descriptors()

        XCTAssertFalse(descriptors.isEmpty)
        XCTAssertEqual(Set(descriptors.map(\.id)).count, descriptors.count)
        XCTAssertTrue(descriptors.allSatisfy { $0.id.rawValue.hasPrefix("builtin.legacy.") })
        XCTAssertTrue(descriptors.allSatisfy { $0.providerID == "legacy.inventory" })
        XCTAssertTrue(descriptors.allSatisfy { !$0.enabled })
    }

    func testKnownReadCapabilityRemainsReadOnlyInventory() throws {
        let descriptor = try XCTUnwrap(
            AgentCapabilityRegistryAdapter().descriptors().first {
                $0.id.rawValue == "builtin.legacy.web_search"
            }
        )

        XCTAssertEqual(descriptor.effectClass, .read)
        XCTAssertEqual(descriptor.declaredRisk, .readOnly)
        XCTAssertEqual(descriptor.idempotency, .none)
        XCTAssertEqual(descriptor.concurrencyClass, .read)
    }

    func testKnownExternalMutationRequiresIdempotencyAndVerification() throws {
        let descriptor = try XCTUnwrap(
            AgentCapabilityRegistryAdapter().descriptors().first {
                $0.id.rawValue == "builtin.legacy.computer_submit"
            }
        )

        XCTAssertEqual(descriptor.effectClass, .externalCommunication)
        XCTAssertEqual(descriptor.declaredRisk, .externalCommunication)
        XCTAssertEqual(descriptor.idempotency, .logicalOperationKeyRequired)
        XCTAssertEqual(descriptor.concurrencyClass, .mutation)
        XCTAssertFalse(descriptor.verificationContract.kind.isEmpty)
    }

    func testNoExternalMutationDescriptorUsesNoIdempotency() {
        let descriptors = AgentCapabilityRegistryAdapter().descriptors()

        for descriptor in descriptors {
            switch descriptor.effectClass {
            case .externalCommunication, .highImpactExternalMutation, .irreversible:
                XCTAssertNotEqual(
                    descriptor.idempotency,
                    .none,
                    "External mutation descriptor must declare idempotency: \(descriptor.id.rawValue)"
                )
                XCTAssertFalse(
                    descriptor.verificationContract.kind.isEmpty,
                    "External mutation descriptor must declare verification: \(descriptor.id.rawValue)"
                )
            case .read, .reversibleLocalMutation:
                break
            }
        }
    }

    private func adapterSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZeroLose/V2/Legacy/AgentCapabilityRegistryAdapter.swift")
    }
}
