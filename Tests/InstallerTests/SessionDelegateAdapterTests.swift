import XCTest
@testable import Installer
import DBIProtocol

final class SessionDelegateAdapterTests: XCTestCase {
    @MainActor
    func testLogCallbackIsDeliveredOnMainActor() async {
        let adapter = SessionDelegateAdapter()
        let delivered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            adapter.onLog = { _, _ in
                MainActor.preconditionIsolated()
                continuation.resume(returning: true)
            }

            Task.detached {
                adapter.sessionDidLog("test", level: .info)
            }
        }

        XCTAssertTrue(delivered)
    }
}
