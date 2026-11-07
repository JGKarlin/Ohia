import Foundation

enum OhiaAnimationCadence {
    static let framesPerSecond: Double = 60
    static let frameInterval: TimeInterval = 1.0 / framesPerSecond
    static let frameDuration: Duration = .nanoseconds(16_666_667)
}
