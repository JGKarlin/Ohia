import Foundation

/// One-slot memo for values a SwiftUI body derives on every evaluation:
/// returns the stored value while the key is unchanged and recomputes when
/// it changes. Held in `@State` as a reference, so storing a new value never
/// invalidates the view that reads it.
@MainActor
final class LastValueMemo<Key: Equatable, Value> {
    private var stored: (key: Key, value: Value)?

    func value(for key: Key, compute: () -> Value) -> Value {
        if let stored, stored.key == key {
            return stored.value
        }
        let value = compute()
        stored = (key, value)
        return value
    }
}
