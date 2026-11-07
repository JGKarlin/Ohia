import Foundation
import OhiaCore

public enum WorkerRole: String, Sendable {
    case bge
    case qwen

    public var processName: String {
        coreRole.processName
    }

    public var logPrefix: String {
        "[\(processName)]"
    }

    var lockFilename: String {
        "\(processName).lock"
    }

    var coreRole: OhiaCore.WorkerRole {
        switch self {
        case .bge: .bge
        case .qwen: .qwen
        }
    }

    var expectedSchedulerRoleAPIName: String {
        switch self {
        case .bge: "OhiaScheduler.WorkerRole.bge"
        case .qwen: "OhiaScheduler.WorkerRole.qwen"
        }
    }
}
