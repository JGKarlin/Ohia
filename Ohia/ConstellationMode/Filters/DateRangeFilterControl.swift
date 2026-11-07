import SwiftUI

public struct DateRangeFilterControl: View {
    @Binding public var range: ClosedRange<Date>?
    @State private var start: Date
    @State private var end: Date

    public init(range: Binding<ClosedRange<Date>?>) {
        _range = range
        let now = Date.now
        _start = State(initialValue: range.wrappedValue?.lowerBound ?? now.addingTimeInterval(-7 * 86400))
        _end = State(initialValue: range.wrappedValue?.upperBound ?? now)
    }

    public var body: some View {
        HStack(spacing: 4) {
            DatePicker("", selection: $start, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact)
            Text("→").font(.system(size: 10)).foregroundStyle(.secondary)
            DatePicker("", selection: $end, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact)
        }
        // Snap the opposite end on crossover so the committed range is always
        // valid. The inner `newValue != end` / `newValue != start` guards break
        // the reentrant `.onChange` cycle when one handler assigns the other's
        // state — a no-op write still ticks `.onChange`, so we must check first.
        .onChange(of: start) { _, newValue in
            if newValue > end, newValue != end {
                end = newValue
            }
            commit()
        }
        .onChange(of: end) { _, newValue in
            if newValue < start, newValue != start {
                start = newValue
            }
            commit()
        }
    }

    private func commit() {
        range = start...end
    }
}
