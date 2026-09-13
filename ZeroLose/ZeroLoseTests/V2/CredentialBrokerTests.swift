import Foundation
import Security
import XCTest
@testable import ZeroLose

final class CredentialBrokerTests: XCTestCase {
    func testAvailabilityExposesOnlyScopeMetadata() async {
        let broker = InMemoryCredentialBroker(scopes: ["openai.responses"])

        let availability = await broker.availability(
            for: CredentialScope(rawValue: "openai.responses")
        )

        XCTAssertTrue(availability.available)
        XCTAssertEqual(availability.scope, CredentialScope(rawValue: "openai.responses"))
    }

    func testRevocationInvalidatesHandle() async throws {
        let broker = InMemoryCredentialBroker(scopes: ["openai.responses"])
        let scope = CredentialScope(rawValue: "openai.responses")

        let handle = try await broker.issueHandle(for: scope)
        await broker.revoke(scope: scope)
        let isValid = await broker.isValid(handle)

        XCTAssertFalse(isValid)
    }

    func testDiscardHandlesKeepsScopeAvailableWhileInvalidatingHandles() async throws {
        let broker = InMemoryCredentialBroker(scopes: ["openai.responses"])
        let scope = CredentialScope(rawValue: "openai.responses")

        let handle = try await broker.issueHandle(for: scope)
        await broker.discardHandles([handle])

        let isValid = await broker.isValid(handle)
        let outstanding = await broker.outstandingHandleCount
        XCTAssertFalse(isValid, "A discarded handle must no longer validate")
        XCTAssertEqual(outstanding, 0, "Discarded handles must not accumulate in memory")

        let replacement = try await broker.issueHandle(for: scope)
        let replacementIsValid = await broker.isValid(replacement)
        XCTAssertTrue(
            replacementIsValid,
            "Discarding an invocation handle must not revoke the underlying scope"
        )
    }

    /// Documents where macOS actually stores these generic-password items: the legacy
    /// login keychain, where `kSecAttrAccessible` is neither applied nor surfaced
    /// (hardening there would require a data-protection-keychain migration, which is a
    /// separate, key-migrating change). This test pins the observable reality so a future
    /// accessibility claim is not made without evidence.
    func testRealKeychainAdapterDoesNotExposeDataProtectionAccessibilityClass() async throws {
        let service = "com.zerolose.tests.credential-broker.\(UUID().uuidString)"
        let adapter = KeychainCredentialBrokerAdapter(openAIKeyService: service)
        addTeardownBlock {
            try? await adapter.remove()
        }

        do {
            try await adapter.store("sk-accessibility-\(UUID().uuidString)")
        } catch let error as OpenAIKeyStoreError {
            if case .keychainFailure = error {
                throw XCTSkip("Keychain unavailable in this environment: \(error)")
            }
            throw error
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "openai_api_key",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecReturnData as String] = false

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess, "Expected the stored key to be readable")
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertNil(
            attributes[kSecAttrAccessible as String],
            "macOS login-keychain items do not expose a data protection accessibility class; if this starts failing, the storage backend changed and #9 must be re-evaluated"
        )
    }
}
