import Foundation

public struct SimParams {
    public var nodeCount: UInt32
    public var maxNeighborsPerNode: UInt32
    public var negativeSamplesPerNode: UInt32
    public var restLength: Float
    public var repulsionConstant: Float
    public var velocityDamping: Float
    public var dt: Float
    public var iterationSeed: UInt32
}
