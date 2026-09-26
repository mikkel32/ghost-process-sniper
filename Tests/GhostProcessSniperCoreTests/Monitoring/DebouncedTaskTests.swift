import XCTest
@testable import GhostProcessSniperCore

@MainActor
final class DebouncedTaskTests: XCTestCase {
    func testCancellationPreventsPendingWrite() async {
        let writes = WriteRecorder()
        let task = DebouncedTask.schedule(delay: 60) {
            await writes.record(1)
        }
        task.cancel()
        await task.value
        let values = await writes.values
        XCTAssertEqual(values, [])
    }

    func testReplacingPendingWritesOnlyRunsLatest() async {
        let writes = WriteRecorder()
        let first = DebouncedTask.schedule(delay: 60) { await writes.record(1) }
        first.cancel()
        let second = DebouncedTask.schedule(delay: 60) { await writes.record(2) }
        second.cancel()
        let latest = DebouncedTask.schedule(delay: 0) { await writes.record(3) }
        await first.value
        await second.value
        await latest.value
        let values = await writes.values
        XCTAssertEqual(values, [3])
    }

    func testImmediateWriteRunsOnce() async {
        let writes = WriteRecorder()
        let task = DebouncedTask.schedule(delay: 0) { await writes.record(7) }
        await task.value
        let values = await writes.values
        XCTAssertEqual(values, [7])
    }
}

private actor WriteRecorder {
    private(set) var values: [Int] = []

    func record(_ value: Int) {
        values.append(value)
    }
}
