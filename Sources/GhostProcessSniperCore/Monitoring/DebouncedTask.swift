import Foundation

/// Cancelling a pending debounce must cancel the work, not just its delay.
enum DebouncedTask {
    static func schedule(
        delay: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let seconds = delay.isFinite ? min(max(0, delay), 86_400) : 0.45
        return Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
                try Task.checkCancellation()
            } catch {
                return
            }
            await operation()
        }
    }
}
