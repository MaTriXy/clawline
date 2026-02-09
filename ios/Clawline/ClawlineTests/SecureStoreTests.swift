//
//  SecureStoreTests.swift
//  ClawlineTests
//

import XCTest
@testable import Clawline

final class SecureStoreTests: XCTestCase {
    func testDeviceIdentifierMigratesFromUserDefaultsToSecureStore() {
        let suiteName = "co.clicketyclacks.Clawline.tests.deviceId.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("11111111-1111-1111-1111-111111111111", forKey: "clawline.deviceId")
        let secure = InMemorySecureStore()

        let device = DeviceIdentifier(storage: defaults, secureStore: secure, environment: [:])
        XCTAssertEqual(device.deviceId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(secure.getString("clawline.deviceId"), "11111111-1111-1111-1111-111111111111")
    }

    func testAuthManagerPrefersSecureStoreAndMigratesFromUserDefaults() async {
        let suiteName = "co.clicketyclacks.Clawline.tests.auth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("jwt-token", forKey: "auth.token")
        defaults.set("user_1", forKey: "auth.userId")
        defaults.set(true, forKey: "auth.isAdmin")

        let secure = InMemorySecureStore()
        await MainActor.run {
            let auth = AuthManager(storage: defaults, secureStore: secure)
            XCTAssertTrue(auth.isAuthenticated)
            XCTAssertEqual(auth.token, "jwt-token")
            XCTAssertEqual(auth.currentUserId, "user_1")
            XCTAssertEqual(secure.getString("auth.token"), "jwt-token")
            XCTAssertEqual(secure.getString("auth.userId"), "user_1")
            XCTAssertEqual(secure.getString("auth.isAdmin"), "1")
        }
    }
}
