import OhiaCore

public enum OhiaWorkerEntrypoint {
    public static func runXPCService(role: WorkerRole) -> Never {
        OhiaWorkerXPCServiceEntrypoint.run(role: role)
    }
}
