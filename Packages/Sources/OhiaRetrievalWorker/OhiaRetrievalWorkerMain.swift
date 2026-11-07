import OhiaWorkerSupport

@main
struct OhiaRetrievalWorkerMain {
    static func main() {
        OhiaWorkerEntrypoint.runXPCService(role: .bge)
    }
}
