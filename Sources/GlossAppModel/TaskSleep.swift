/// The real sleep the debounced models wait with (tests inject their own).
///
/// A named nonisolated function, not a `{ try await Task.sleep(for: $0) }` default-argument
/// closure: Swift 6.2.3 miscompiles that closure in a `@MainActor` initializer's default argument,
/// and cancelling the sleep (the next settings change) aborted the app with "freed pointer was not
/// the last allocation" in `swift_task_dealloc` (D-143).
@usableFromInline
func taskSleep(_ duration: Duration) async throws {
    try await Task.sleep(for: duration)
}
