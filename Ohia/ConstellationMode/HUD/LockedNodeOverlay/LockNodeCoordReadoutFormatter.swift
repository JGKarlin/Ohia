import Foundation
import simd

struct LockNodeCoordReadoutFormatter {
    static func string(world: SIMD3<Float>, vectorId: Int64) -> String {
        "α \(format(world.x)) · δ \(format(world.y)) · vec \(vectorId)"
    }

    private static let valueFormat: FloatingPointFormatStyle<Float> = .number
        .precision(.fractionLength(3))
        .locale(Locale(identifier: "en_US_POSIX"))

    private static func format(_ value: Float) -> String {
        value.formatted(valueFormat).replacing("-", with: "−")
    }
}
