import XCTest
@testable import XuQiaoCore

final class BluetoothAuthorizationTests: XCTestCase {
    func testUndecidedWithPairedDevicesRequestsOnEachNewManagerLifetime() {
        // 历史申请标记不参与决策，系统重新变成未决定时仍可触发正式授权。
        for _ in 0..<3 {
            XCTAssertTrue(BluetoothWakeCoordinator.shouldCreateManager(authorization: .notDetermined, hasTargets: true, manual: false))
        }
        XCTAssertFalse(BluetoothWakeCoordinator.shouldCreateManager(authorization: .notDetermined, hasTargets: false, manual: false))
        XCTAssertTrue(BluetoothWakeCoordinator.shouldCreateManager(authorization: .notDetermined, hasTargets: false, manual: true))
    }
    func testDeniedOrRestrictedNeverRequestsAgainAndAllowedCanResume() {
        for state in [BluetoothWakeAuthorization.denied, .restricted, .unknown] {
            for manual in [false, true] {
                XCTAssertFalse(BluetoothWakeCoordinator.shouldCreateManager(authorization: state, hasTargets: true, manual: manual))
            }
        }
        XCTAssertTrue(BluetoothWakeCoordinator.shouldCreateManager(authorization: .allowed, hasTargets: true, manual: false))
    }
}
