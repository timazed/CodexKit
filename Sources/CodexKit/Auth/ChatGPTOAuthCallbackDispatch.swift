import Foundation

func runAuthenticationCallbackOnMainActor(
    _ operation: @MainActor @escaping @Sendable () -> Void
) {
    Task { @MainActor in
        operation()
    }
}
