import OhiaWorkerSupport

@main
struct OhiaGenerativeWorkerMain {
    static func main() {
        OhiaWorkerEntrypoint.runXPCService(role: .qwen)
    }
}
