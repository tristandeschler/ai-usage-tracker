import Foundation
import Testing
@testable import UsageKit

@Suite struct AlertEvaluatorTests {
    let accountID = UUID()

    func snapshot(_ windows: [(String, Double)], error: String? = nil) -> AccountSnapshot {
        AccountSnapshot(
            id: accountID, accountName: "Work", provider: .anthropic,
            windows: windows.map { UsageWindow(id: $0.0, label: $0.0 == "session" ? "5-hour session" : "Weekly", kind: .other, usedPercent: $0.1, resetsAt: nil) },
            error: error
        )
    }

    func run(_ snap: AccountSnapshot, _ state: inout AlertState) -> [UsageAlert.Kind] {
        AlertEvaluator.evaluate(snap, thresholds: [80, 95, 100], notifyOnReset: true, state: &state).map(\.kind)
    }

    @Test func firesEachThresholdOnce() {
        var state = AlertState()
        #expect(run(snapshot([("weekly", 50)]), &state).isEmpty)
        #expect(run(snapshot([("weekly", 82)]), &state) == [.crossed(threshold: 80)])
        #expect(run(snapshot([("weekly", 85)]), &state).isEmpty)
        #expect(run(snapshot([("weekly", 100)]), &state) == [.crossed(threshold: 100)])
        #expect(run(snapshot([("weekly", 100)]), &state).isEmpty)
    }

    @Test func jumpingPastSeveralThresholdsFiresOnlyTheHighest() {
        var state = AlertState()
        #expect(run(snapshot([("session", 97)]), &state) == [.crossed(threshold: 95)])
    }

    @Test func announcesResetAfterLimit() {
        var state = AlertState()
        _ = run(snapshot([("session", 100)]), &state)
        #expect(run(snapshot([("session", 3)]), &state) == [.reset])
        // A fresh cycle can alert again.
        #expect(run(snapshot([("session", 81)]), &state) == [.crossed(threshold: 80)])
    }

    @Test func vanishedSessionWindowCountsAsReset() {
        var state = AlertState()
        _ = run(snapshot([("session", 100), ("weekly", 40)]), &state)
        #expect(run(snapshot([("weekly", 41)]), &state) == [.reset])
        #expect(state.notified.isEmpty)
    }

    @Test func noResetAlertBelowLimit() {
        var state = AlertState()
        _ = run(snapshot([("weekly", 90)]), &state)
        #expect(run(snapshot([("weekly", 10)]), &state).isEmpty)
    }

    @Test func failedFetchKeepsState() {
        var state = AlertState()
        _ = run(snapshot([("weekly", 100)]), &state)
        #expect(run(snapshot([], error: "offline"), &state).isEmpty)
        #expect(run(snapshot([("weekly", 100)]), &state).isEmpty)
    }

    @Test func alertCopy() {
        let window = UsageWindow(id: "weekly", label: "Weekly", kind: .weekly, usedPercent: 100, resetsAt: nil)
        let alert = UsageAlert(kind: .crossed(threshold: 100), accountID: accountID, accountName: "Work", provider: .anthropic, window: window)
        #expect(alert.title == "Work hit its weekly limit")
        #expect(alert.body == "Claude · 100% used")
    }
}
