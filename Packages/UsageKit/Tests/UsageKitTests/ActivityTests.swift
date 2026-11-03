import Foundation
import Testing
@testable import UsageKit

@Suite struct ActivityTests {
    let id = UUID()

    func snapshot(_ windows: [(String, Double)], error: String? = nil) -> AccountSnapshot {
        AccountSnapshot(
            id: id, accountName: "A", provider: .anthropic,
            windows: windows.map { UsageWindow(id: $0.0, label: $0.0, kind: .other, usedPercent: $0.1, resetsAt: nil) },
            error: error
        )
    }

    @Test func growthIsRising() {
        #expect(snapshot([("weekly", 45)]).isRising(from: snapshot([("weekly", 44)])))
    }

    @Test func flatOrResetIsNotRising() {
        #expect(!snapshot([("weekly", 44)]).isRising(from: snapshot([("weekly", 44)])))
        #expect(!snapshot([("weekly", 2)]).isRising(from: snapshot([("weekly", 100)])))
    }

    @Test func newSessionWindowWithUsageIsRising() {
        #expect(snapshot([("session", 3), ("weekly", 44)]).isRising(from: snapshot([("weekly", 44)])))
        #expect(!snapshot([("session", 0), ("weekly", 44)]).isRising(from: snapshot([("weekly", 44)])))
    }

    @Test func needsAPreviousSuccessfulSnapshot() {
        #expect(!snapshot([("weekly", 50)]).isRising(from: nil))
        #expect(!snapshot([("weekly", 50)], error: "offline").isRising(from: snapshot([("weekly", 10)])))
    }
}
