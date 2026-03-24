import Foundation
import Testing
@testable import TokenBox

// MARK: - CloudFriend Tests

@Suite("CloudFriend")
struct CloudFriendTests {
    @Test("CloudFriend is identifiable by shareCode")
    func identifiable() {
        let friend = CloudFriend(shareCode: "A3KX9F", displayName: "GEORGE", todayTokens: 12000, todayDate: "2026-03-20")
        #expect(friend.id == "A3KX9F")
    }

    @Test("CloudFriend round-trip encoding")
    func codable() throws {
        let original = CloudFriend(shareCode: "B7YM2P", displayName: "ALICE", todayTokens: 54321, todayDate: "2026-03-20")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CloudFriend.self, from: data)
        #expect(decoded == original)
    }

    @Test("CloudFriend defaults")
    func defaults() {
        let friend = CloudFriend(shareCode: "XXXXXX", displayName: "TEST")
        #expect(friend.todayTokens == 0)
        #expect(friend.todayDate == "")
    }
}

// MARK: - SharingManager Tests

@Suite("SharingManager")
@MainActor
struct SharingManagerTests {

    @Test("Initial state is not registered with empty friends")
    func initialState() {
        let manager = SharingManager()
        #expect(manager.friends.isEmpty)
        #expect(manager.myDisplayName == "")
        #expect(!manager.sharingEnabled)
    }

    @Test("Remove friend by share code")
    func removeFriend() {
        let manager = SharingManager()
        // Manually inject a friend for testing
        manager.friends = [
            CloudFriend(shareCode: "ABC123", displayName: "TEST", todayTokens: 100, todayDate: "2026-03-20")
        ]
        #expect(manager.friends.count == 1)

        manager.removeFriend("ABC123")
        #expect(manager.friends.isEmpty)
    }

    @Test("Remove non-existent friend is a no-op")
    func removeNonExistent() {
        let manager = SharingManager()
        manager.friends = [
            CloudFriend(shareCode: "ABC123", displayName: "TEST")
        ]
        manager.removeFriend("XXXXXX")
        #expect(manager.friends.count == 1)
    }
}

// MARK: - CloudSharingError Tests

@Suite("CloudSharingError")
struct CloudSharingErrorTests {
    @Test("Error descriptions are non-empty")
    func errorDescriptions() {
        let errors: [CloudSharingError] = [
            .invalidResponse,
            .httpError(statusCode: 404),
            .rateLimited,
            .invalidShareCode,
            .friendAlreadyExists,
        ]
        for error in errors {
            #expect(error.localizedDescription.count > 0)
        }
    }

    @Test("HTTP error includes status code")
    func httpErrorCode() {
        let error = CloudSharingError.httpError(statusCode: 503)
        #expect(error.localizedDescription.contains("503"))
    }
}
