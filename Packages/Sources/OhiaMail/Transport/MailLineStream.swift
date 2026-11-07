import Foundation
import CoreFoundation
import Security
import CryptoKit

public enum MailStreamError: Error, Sendable {
    case notConnected
    case connectionClosed
    case tlsHandshakeFailed(underlying: Error?)
    case stream(underlying: Error)
    case invalidUTF8
    case wrongState(String)
    /// Server's leaf cert did not match the account's pinned SHA-256.
    /// `presented` is the actual hex-encoded SHA-256 of what the server sent.
    case certPinMismatch(presented: String)
}

extension MailStreamError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Mail stream is not connected."
        case .connectionClosed:
            return "Mail stream connection closed."
        case .tlsHandshakeFailed(let underlying):
            if let underlying {
                return "TLS handshake failed: \((underlying as NSError).localizedDescription)"
            }
            return "TLS handshake failed before completion."
        case .stream(let underlying):
            return "Mail stream I/O error: \((underlying as NSError).localizedDescription)"
        case .invalidUTF8:
            return "Mail stream received bytes that are not valid UTF-8."
        case .wrongState(let detail):
            return "Mail stream in wrong state: \(detail)"
        case .certPinMismatch(let presented):
            return "Server certificate did not match the pinned fingerprint (presented \(presented))."
        }
    }
}

public final class MailLineStream: NSObject, StreamDelegate, @unchecked Sendable {
    public enum State: Equatable {
        case initial, connecting, plaintext, tlsHandshaking, tls, closed
    }

    public var connectTimeout: TimeInterval = 30
    public var readTimeout: TimeInterval = 60
    internal var allowsUnverifiedChain: Bool = false

    /// Hex-encoded SHA-256 (64 chars, lowercase, no colons) of the peer leaf
    /// certificate's DER encoding. When set, `connect()` disables system chain
    /// validation and requires the peer's leaf cert to match this fingerprint
    /// exactly. Mismatch throws `MailStreamError.certPinMismatch`. When nil
    /// (default), standard system trust applies.
    public var pinnedCertSHA256: String? = nil

    // Stream + thread state. All access serialized through stateQueue.
    private let stateQueue = DispatchQueue(label: "ohia.mail.linestream.state")
    private var _state: State = .initial
    private var input: InputStream?
    private var output: OutputStream?
    private var runloopThread: Thread?
    private var runloop: RunLoop?
    private var connectedHost: String = ""

    // Signalled by the runloop thread closure when its while-loop exits.
    // close() and cleanupOnError await this (bounded) before clearing references.
    private let runloopExited = DispatchSemaphore(value: 0)

    private struct PendingLineRead {
        let id: UUID
        let cont: CheckedContinuation<String, Error>
    }

    private struct PendingByteRead {
        let id: UUID
        let count: Int
        let cont: CheckedContinuation<Data, Error>
    }

    // Read buffer + pending readLine continuation.
    private var readBuffer = Data()
    private var pendingRead: PendingLineRead?

    // Byte-count-bounded read (for IMAP literal strings). Only one of
    // pendingRead / pendingByteRead may be set at a time.
    private var pendingByteRead: PendingByteRead?

    // Pending write continuation (waiting on hasSpaceAvailable).
    private var pendingWrite: (data: Data, offset: Int, cont: CheckedContinuation<Void, Error>)?

    // Pending TLS handshake continuation.
    private var pendingTLS: CheckedContinuation<Void, Error>?

    // Pending open-readiness continuation. Both streams must reach .open
    // before connect() returns.
    private var pendingOpen: CheckedContinuation<Void, Error>?
    private var inputOpened = false
    private var outputOpened = false

    public override init() { super.init() }

    public func currentState() -> State {
        stateQueue.sync { _state }
    }

    fileprivate func setState(_ new: State) {
        stateQueue.sync { _state = new }
    }

    // MARK: - Public API

    public func connect(host: String, port: Int, initialTLS: Bool) async throws {
        try checkTransition(allowedFrom: [.initial], to: .connecting)
        connectedHost = host

        // Resolve the socket streams FIRST, before starting the dedicated runloop
        // thread. If getStreamsToHost returns nil, an early throw here cannot leak
        // a runloop thread that never got cancelled.
        var inStream: InputStream?
        var outStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inStream, outputStream: &outStream)
        guard let i = inStream, let o = outStream else {
            setState(.closed)
            throw MailStreamError.stream(underlying: NSError(domain: "MailLineStream", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Stream.getStreamsToHost returned nil pair"]))
        }

        // Start the dedicated runloop thread and wait for it to be ready.
        // We use a CheckedContinuation bridged via a SendableBox to carry the
        // non-Sendable RunLoop reference back to the async context. Access is safe
        // because the box is written exactly once (from the thread, before signal)
        // and read exactly once (from the async context, after await).
        let exitGate = self.runloopExited
        let rl = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RunLoop, Error>) in
            let box = SendableBox<CheckedContinuation<RunLoop, Error>>(cont)
            let thread = Thread {
                let runloop = RunLoop.current
                // Add a port so the runloop has at least one source and doesn't exit.
                RunLoop.current.add(NSMachPort(), forMode: .default)
                // Signal the async side with our RunLoop reference.
                box.value.resume(returning: runloop)
                // Tight 0.05s tick so cancel() is noticed promptly (runloop may
                // not always wake from perform()-based teardown). Idle cost is
                // ~20 wakeups/sec of the Mach-port source, negligible.
                while !Thread.current.isCancelled {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
                }
                // Signal that the runloop has fully exited so close()/cleanupOnError
                // can join before tearing down references.
                exitGate.signal()
            }
            thread.name = "ohia.mail.linestream.runloop"
            thread.stackSize = 1 * 1024 * 1024
            thread.start()
            // Store thread reference synchronously — we'll capture it after the
            // continuation resumes on the async side.
            self.stateQueue.sync { self.runloopThread = thread }
        }
        self.runloop = rl

        i.delegate = self
        o.delegate = self
        self.input = i
        self.output = o

        if initialTLS {
            applyTLSSettings(host: host)
            // Mark state as .tlsHandshaking before opening so a cert/handshake
            // failure during open() reaches handleError with wasTLS=true and
            // maps to .tlsHandshakeFailed → .transportFailed (permanent fail),
            // not .stream → .transient (5x retry). Affects implicit-TLS
            // providers (port-465 Fastmail, Zoho).
            setState(.tlsHandshaking)
        }

        // Schedule on dedicated runloop, then open. Race the open-readiness
        // continuation against connectTimeout using a structured TaskGroup so
        // the timeout child is properly cancelled when the open child wins (or
        // vice versa). Using structured concurrency avoids the "detached Task
        // runs to completion" problem that arises with unstructured Tasks.
        let iBox = SendableBox<InputStream>(i)
        let oBox = SendableBox<OutputStream>(o)
        let rlBox = SendableBox<RunLoop>(rl)
        let connectTimeout = self.connectTimeout

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Open child: wait for both streams to fire .openCompleted.
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        self.stateQueue.sync { self.pendingOpen = cont }
                        // Schedule stream setup on the dedicated runloop thread.
                        rlBox.value.perform {
                            iBox.value.schedule(in: RunLoop.current, forMode: .default)
                            oBox.value.schedule(in: RunLoop.current, forMode: .default)
                            iBox.value.open()
                            oBox.value.open()
                        }
                    }
                }
                group.addTask {
                    // Timeout child: sleep, then both (a) resume the suspended open
                    // continuation so the read child can unblock and exit cleanly under
                    // structured-concurrency cancellation, and (b) throw to propagate.
                    try await Task.sleep(nanoseconds: UInt64(connectTimeout * 1_000_000_000))
                    let stash: CheckedContinuation<Void, Error>? = self.stateQueue.sync {
                        let s = self.pendingOpen; self.pendingOpen = nil; return s
                    }
                    stash?.resume(throwing: MailStreamError.connectionClosed)
                    throw MailStreamError.connectionClosed
                }
                // First child to finish wins; cancel the other.
                try await group.next()!
                group.cancelAll()
            }
        } catch {
            await cleanupOnError()
            throw error
        }

        setState(initialTLS ? .tls : .plaintext)
    }

    public func readLine() async throws -> String {
        let s = currentState()
        switch s {
        case .plaintext, .tls: break
        case .initial, .closed: throw MailStreamError.notConnected
        case .connecting, .tlsHandshaking: throw MailStreamError.wrongState("readLine in state \(s)")
        }

        let readTimeout = self.readTimeout
        let readID = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                enum Outcome {
                    case immediate(String)
                    case parked
                    case failure(Error)
                }

                let outcome = self.stateQueue.sync { () -> Outcome in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if self.pendingRead != nil || self.pendingByteRead != nil {
                        return .failure(MailStreamError.wrongState("read already pending"))
                    }
                    if let line = self.tryExtractLineLocked() {
                        return .immediate(line)
                    }
                    self.pendingRead = PendingLineRead(id: readID, cont: cont)
                    return .parked
                }

                switch outcome {
                case .immediate(let line):
                    cont.resume(returning: line)
                case .failure(let error):
                    cont.resume(throwing: error)
                case .parked:
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + readTimeout) { [weak self] in
                        let stalled = self?.takePendingRead(id: readID)
                        stalled?.resume(throwing: MailStreamError.connectionClosed)
                    }
                }
            }
        } onCancel: {
            let cancelled = self.takePendingRead(id: readID)
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Read exactly `count` bytes from the stream, bypassing line orientation.
    /// Used for IMAP literal response bodies (`{N}\r\n<N bytes>`). After this
    /// returns, the stream is back in line mode — the caller is responsible
    /// for calling `readLine()` again to continue the outer response.
    public func readBytes(count: Int) async throws -> Data {
        precondition(count >= 0, "readBytes count must be non-negative")
        if count == 0 { return Data() }

        let s = currentState()
        switch s {
        case .plaintext, .tls: break
        case .initial, .closed: throw MailStreamError.notConnected
        case .connecting, .tlsHandshaking: throw MailStreamError.wrongState("readBytes in state \(s)")
        }

        let readTimeout = self.readTimeout
        let readID = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                enum Outcome {
                    case immediate(Data)
                    case parked
                    case failure(Error)
                }

                let outcome = self.stateQueue.sync { () -> Outcome in
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    guard self.pendingRead == nil, self.pendingByteRead == nil else {
                        return .failure(MailStreamError.wrongState("read already pending"))
                    }
                    if self.readBuffer.count >= count {
                        let slice = Data(self.readBuffer.prefix(count))
                        self.readBuffer.removeFirst(count)
                        return .immediate(slice)
                    }
                    self.pendingByteRead = PendingByteRead(id: readID, count: count, cont: cont)
                    return .parked
                }

                switch outcome {
                case .immediate(let data):
                    cont.resume(returning: data)
                case .failure(let error):
                    cont.resume(throwing: error)
                case .parked:
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + readTimeout) { [weak self] in
                        let stalled = self?.takePendingByteRead(id: readID)
                        stalled?.resume(throwing: MailStreamError.connectionClosed)
                    }
                }
            }
        } onCancel: {
            let cancelled = self.takePendingByteRead(id: readID)
            cancelled?.resume(throwing: CancellationError())
        }
    }

    public func write(_ data: Data) async throws {
        let s = currentState()
        switch s {
        case .plaintext, .tls: break
        case .initial, .closed: throw MailStreamError.notConnected
        case .connecting, .tlsHandshaking: throw MailStreamError.wrongState("write in state \(s)")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stateQueue.sync {
                self.pendingWrite = (data: data, offset: 0, cont: cont)
            }
            runloop?.perform { [weak self] in
                self?.tryDrainWrite()
            }
        }
    }

    /// Open a throwaway connection, complete TLS with chain validation disabled,
    /// extract the peer's leaf cert, close, and return parsed `CertificateInfo`.
    /// Never sends or receives protocol bytes. Used by the Verify Certificate UI.
    ///
    /// Only supports implicit TLS (initialTLS=true). STARTTLS inspection would
    /// require a full EHLO/STARTTLS conversation that goes beyond a simple peek;
    /// the UI falls back to generic-failure in that case.
    public func inspectPeerCertificate(
        host: String, port: Int, initialTLS: Bool
    ) async throws -> CertificateInfo {
        guard initialTLS else {
            throw MailStreamError.wrongState("inspectPeerCertificate currently requires initialTLS=true")
        }
        self.allowsUnverifiedChain = true    // bypass chain validation
        self.pinnedCertSHA256 = nil          // bypass pin compare
        do {
            try await self.connect(host: host, port: port, initialTLS: true)
        } catch {
            await self.close()
            throw error
        }
        // Peer trust is only meaningful post-handshake; pull it on the runloop thread.
        let info: CertificateInfo? = stateQueue.sync {
            guard let input = self.input else { return nil }
            let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLPeerTrust)
            guard let trustObj = CFReadStreamCopyProperty(input as CFReadStream, key),
                  CFGetTypeID(trustObj) == SecTrustGetTypeID() else {
                return nil
            }
            let trust = trustObj as! SecTrust
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                return nil
            }
            return CertificateInspector.make(from: leaf)
        }
        await self.close()
        guard let info = info else {
            throw MailStreamError.stream(underlying: NSError(
                domain: "MailLineStream",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "could not extract peer cert"]
            ))
        }
        return info
    }

    public func startTLS(host: String) async throws {
        try checkTransition(allowedFrom: [.plaintext], to: .tlsHandshaking)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stateQueue.sync { self.pendingTLS = cont }
            runloop?.perform { [weak self] in
                // Installing TLS settings starts negotiation on the scheduled
                // streams. Await their handshake events; OutputStream.write
                // with maxLength == 0 has undefined behavior and can end the
                // connection before authentication (observed with iCloud).
                self?.applyTLSSettings(host: host)
            }
        }
    }

    deinit {
        // Failsafe: if the stream is dropped without `close()` being
        // called (e.g. an IMAP auth attempt fails and the session
        // discards the stream while a `readLine` / `readBytes` is
        // suspended), every parked CheckedContinuation gets resumed with
        // a CancellationError before we go away. Without this every
        // unclean teardown produced a `SwiftTaskContinuationMisuse:
        // readLine() leaked its continuation` runtime warning.
        //
        // `deinit` runs on whichever thread released the last reference,
        // not necessarily the runloop thread or MainActor. Using
        // `stateQueue.sync` from inside deinit is fine — the queue is a
        // plain serial DispatchQueue and we never block on anything that
        // could deadlock with our own teardown path.
        let (rCont, wCont, tCont, oCont, brCont) = stateQueue.sync { () -> (
            CheckedContinuation<String, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Data, Error>?
        ) in
            let r = self.pendingRead?.cont; self.pendingRead = nil
            let w = self.pendingWrite?.cont; self.pendingWrite = nil
            let t = self.pendingTLS; self.pendingTLS = nil
            let o = self.pendingOpen; self.pendingOpen = nil
            let br = self.pendingByteRead?.cont; self.pendingByteRead = nil
            return (r, w, t, o, br)
        }
        let err = CancellationError()
        rCont?.resume(throwing: err)
        wCont?.resume(throwing: err)
        tCont?.resume(throwing: err)
        oCont?.resume(throwing: err)
        brCont?.resume(throwing: err)
    }

    public func close() async {
        // Cancel pending continuations.
        let (rCont, wCont, tCont, oCont, brCont) = stateQueue.sync { () -> (
            CheckedContinuation<String, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Data, Error>?
        ) in
            let r = self.pendingRead?.cont; self.pendingRead = nil
            let w = self.pendingWrite?.cont; self.pendingWrite = nil
            let t = self.pendingTLS; self.pendingTLS = nil
            let o = self.pendingOpen; self.pendingOpen = nil
            let br = self.pendingByteRead?.cont; self.pendingByteRead = nil
            self._state = .closed
            return (r, w, t, o, br)
        }
        rCont?.resume(throwing: MailStreamError.connectionClosed)
        wCont?.resume(throwing: MailStreamError.connectionClosed)
        tCont?.resume(throwing: MailStreamError.connectionClosed)
        oCont?.resume(throwing: MailStreamError.connectionClosed)
        brCont?.resume(throwing: MailStreamError.connectionClosed)

        let rlThread = stateQueue.sync { self.runloopThread }
        // Cancel FIRST, then schedule the teardown perform block. The perform
        // wakes the runloop's `run(mode:before:)`, it processes the block, and
        // on the next while-iteration isCancelled is already true — so the
        // thread exits promptly instead of sleeping out its 0.5s tick.
        rlThread?.cancel()
        runloop?.perform { [weak self] in
            self?.input?.remove(from: RunLoop.current, forMode: .default)
            self?.output?.remove(from: RunLoop.current, forMode: .default)
            self?.input?.close()
            self?.output?.close()
            self?.input = nil
            self?.output = nil
        }
        if rlThread != nil {
            await awaitRunloopExit(timeout: 2.0)
        }
        stateQueue.sync { self.runloopThread = nil }
        runloop = nil
    }

    // MARK: - StreamDelegate

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            handleOpenCompleted(aStream)
        case .hasBytesAvailable:
            handleHasBytesAvailable()
        case .hasSpaceAvailable:
            handleHasSpaceAvailable()
        case .errorOccurred:
            handleError(aStream)
        case .endEncountered:
            handleEnd()
        default:
            break
        }
    }

    // MARK: - Event handlers

    private func handleOpenCompleted(_ stream: Stream) {
        // Capture whether both streams are open and whether we need a deferred
        // pin check (implicit-TLS + pin set). When a pin check is needed we
        // *don't* resume `pendingOpen` here — instead we move the continuation
        // to `pendingTLS` so that `handleHasSpaceAvailable` (which fires after
        // `openCompleted` with a freshly-populated peer trust) performs the check.
        let cont: CheckedContinuation<Void, Error>? = stateQueue.sync {
            if stream === self.input { self.inputOpened = true }
            if stream === self.output { self.outputOpened = true }
            guard self.inputOpened, self.outputOpened else { return nil }
            let c = self.pendingOpen; self.pendingOpen = nil
            // When a pin check is needed — or when allowsUnverifiedChain is set
            // (used by inspectPeerCertificate) — defer to the first
            // hasSpaceAvailable (where kCFStreamPropertySSLPeerTrust is
            // guaranteed to be populated) by parking the continuation in
            // pendingTLS. The state stays .tlsHandshaking so the existing
            // handleHasSpaceAvailable pin-check logic picks it up.
            if self._state == .tlsHandshaking,
               self.pinnedCertSHA256 != nil || self.allowsUnverifiedChain {
                self.pendingTLS = c
                return nil  // don't resume yet
            }
            return c
        }
        cont?.resume(returning: ())
    }

    private func handleHasBytesAvailable() {
        guard let input = self.input else { return }
        let chunk = readChunkBlocking(input)
        if chunk.isEmpty { return }

        // First: append to buffer + detect TLS-handshake completion.
        let tlsHandshakeCompleted = tlsPeerTrustIsAvailable()
        let tlsCompletion: (CheckedContinuation<Void, Error>, Bool)? = stateQueue.sync {
            self.readBuffer.append(chunk)
            if self._state == .tlsHandshaking,
               tlsHandshakeCompleted,
               let tls = self.pendingTLS {
                self.pendingTLS = nil
                // Leave state as .tlsHandshaking for the pin check below.
                return (tls, true)
            }
            return nil
        }
        if let (cont, shouldCheckPin) = tlsCompletion {
            if shouldCheckPin, let err = verifyPinIfNeeded() {
                stateQueue.sync { self._state = .closed }
                cont.resume(throwing: err)
            } else {
                stateQueue.sync { self._state = .tls }
                cont.resume(returning: ())
            }
            return
        }

        // Satisfy pendingByteRead if enough bytes have arrived.
        let byteReadCompletion: (CheckedContinuation<Data, Error>, Data)? = stateQueue.sync {
            if let pending = self.pendingByteRead, self.readBuffer.count >= pending.count {
                let slice = Data(self.readBuffer.prefix(pending.count))
                self.readBuffer.removeFirst(pending.count)
                self.pendingByteRead = nil
                return (pending.cont, slice)
            }
            return nil
        }
        if let (cont, data) = byteReadCompletion {
            cont.resume(returning: data)
            return
        }

        // Otherwise fall through to the pending-read completion path.
        let pendingReadCompletion: (CheckedContinuation<String, Error>, String)? = stateQueue.sync {
            if let pending = self.pendingRead, let line = self.tryExtractLineLocked() {
                self.pendingRead = nil
                return (pending.cont, line)
            }
            return nil
        }
        if let (cont, line) = pendingReadCompletion {
            cont.resume(returning: line)
        }
    }

    private func handleHasSpaceAvailable() {
        // A plaintext stream can have a stale hasSpaceAvailable event queued
        // when STARTTLS installs its settings. Peer trust is the handshake
        // result, so do not let that stale event report a false TLS success.
        let tlsHandshakeCompleted = tlsPeerTrustIsAvailable()
        let tls: (CheckedContinuation<Void, Error>, Bool)? = stateQueue.sync {
            if self._state == .tlsHandshaking,
               tlsHandshakeCompleted,
               let t = self.pendingTLS {
                self.pendingTLS = nil
                // Leave state as .tlsHandshaking for the pin check; transition below.
                return (t, true)
            }
            return nil
        }
        if let (cont, shouldCheckPin) = tls {
            if shouldCheckPin, let err = verifyPinIfNeeded() {
                stateQueue.sync { self._state = .closed }
                cont.resume(throwing: err)
            } else {
                stateQueue.sync { self._state = .tls }
                cont.resume(returning: ())
            }
        }

        // Try to drain a pending write.
        tryDrainWrite()
    }

    private func tlsPeerTrustIsAvailable() -> Bool {
        let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLPeerTrust)
        var trustObject: CFTypeRef?
        if let input {
            trustObject = CFReadStreamCopyProperty(input as CFReadStream, key)
        }
        if trustObject == nil, let output {
            trustObject = CFWriteStreamCopyProperty(output as CFWriteStream, key)
        }
        guard let trustObject else { return false }
        return CFGetTypeID(trustObject) == SecTrustGetTypeID()
    }

    private func handleError(_ stream: Stream) {
        let err = stream.streamError ?? NSError(domain: "MailLineStream", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "stream errorOccurred without streamError"])
        let (rCont, wCont, tCont, oCont, brCont, wasTLS) = stateQueue.sync { () -> (
            CheckedContinuation<String, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Data, Error>?,
            Bool
        ) in
            let wasTLS = (self._state == .tlsHandshaking)
            let r = self.pendingRead?.cont; self.pendingRead = nil
            let w = self.pendingWrite?.cont; self.pendingWrite = nil
            let t = self.pendingTLS; self.pendingTLS = nil
            let o = self.pendingOpen; self.pendingOpen = nil
            let br = self.pendingByteRead?.cont; self.pendingByteRead = nil
            self._state = .closed
            return (r, w, t, o, br, wasTLS)
        }
        let mapped: MailStreamError = wasTLS
            ? .tlsHandshakeFailed(underlying: err)
            : .stream(underlying: err)
        rCont?.resume(throwing: mapped)
        wCont?.resume(throwing: mapped)
        tCont?.resume(throwing: mapped)
        oCont?.resume(throwing: mapped)
        brCont?.resume(throwing: mapped)
    }

    private func handleEnd() {
        // Gmail's STARTTLS responder closes the socket (FIN) instead of emitting
        // a TLS alert in some failure modes, so endEncountered can arrive while
        // `pendingTLS` / `pendingOpen` are suspended. If we don't resume them
        // here, the caller hangs forever. Mirror handleError's wasTLS branching
        // so a close during handshake surfaces as `.tlsHandshakeFailed`
        // (permanent), elsewhere as `.connectionClosed` (transient retry).
        let (rCont, wCont, tCont, oCont, brCont, wasTLS) = stateQueue.sync { () -> (
            CheckedContinuation<String, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Void, Error>?,
            CheckedContinuation<Data, Error>?,
            Bool
        ) in
            let wasTLS = (self._state == .tlsHandshaking)
            let r = self.pendingRead?.cont; self.pendingRead = nil
            let w = self.pendingWrite?.cont; self.pendingWrite = nil
            let t = self.pendingTLS; self.pendingTLS = nil
            let o = self.pendingOpen; self.pendingOpen = nil
            let br = self.pendingByteRead?.cont; self.pendingByteRead = nil
            self._state = .closed
            return (r, w, t, o, br, wasTLS)
        }
        let tlsPhaseErr: MailStreamError = wasTLS
            ? .tlsHandshakeFailed(underlying: nil)
            : .connectionClosed
        rCont?.resume(throwing: MailStreamError.connectionClosed)
        wCont?.resume(throwing: MailStreamError.connectionClosed)
        tCont?.resume(throwing: tlsPhaseErr)
        oCont?.resume(throwing: tlsPhaseErr)
        brCont?.resume(throwing: MailStreamError.connectionClosed)
    }

    // MARK: - Helpers

    private func takePendingRead(id: UUID) -> CheckedContinuation<String, Error>? {
        stateQueue.sync {
            guard let pending = self.pendingRead, pending.id == id else {
                return nil
            }
            self.pendingRead = nil
            return pending.cont
        }
    }

    private func takePendingByteRead(id: UUID) -> CheckedContinuation<Data, Error>? {
        stateQueue.sync {
            guard let pending = self.pendingByteRead, pending.id == id else {
                return nil
            }
            self.pendingByteRead = nil
            return pending.cont
        }
    }

    private func readChunkBlocking(_ input: InputStream) -> Data {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = input.read(&buf, maxLength: buf.count)
        if n <= 0 { return Data() }
        return Data(buf.prefix(n))
    }

    private func tryExtractLineLocked() -> String? {
        guard self.readBuffer.count >= 2 else { return nil }
        guard let lineEnd = Self.firstCRLFOffset(in: self.readBuffer) else {
            return nil
        }
        let line = self.readBuffer.prefix(lineEnd)
        self.readBuffer.removeFirst(lineEnd + 2)
        return String(data: line, encoding: .utf8) ?? ""
    }

    static func firstCRLFOffset(in data: Data) -> Int? {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                  rawBuffer.count >= 2 else {
                return nil
            }
            for offset in 0..<(rawBuffer.count - 1) where base[offset] == 0x0D && base[offset + 1] == 0x0A {
                return offset
            }
            return nil
        }
    }

    private func tryDrainWrite() {
        guard let output = self.output else { return }
        // Atomically take ownership of pendingWrite so close()/handleError/handleEnd
        // can't capture the same continuation and resume it in parallel. If we end
        // up needing to continue draining (partial write), we re-stash at the end
        // under the same lock — and only if we haven't since been closed.
        let pending: (data: Data, offset: Int, cont: CheckedContinuation<Void, Error>)? = stateQueue.sync {
            let p = self.pendingWrite
            self.pendingWrite = nil
            return p
        }
        guard let p = pending else { return }
        let remaining = p.data.count - p.offset
        if remaining == 0 {
            p.cont.resume(returning: ())
            return
        }
        let bytesWritten = p.data.withUnsafeBytes { rawBuf -> Int in
            let base = rawBuf.baseAddress!.advanced(by: p.offset).assumingMemoryBound(to: UInt8.self)
            return output.write(base, maxLength: remaining)
        }
        if bytesWritten < 0 {
            let err = output.streamError ?? NSError(domain: "MailLineStream", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "OutputStream.write returned -1 with no streamError"])
            p.cont.resume(throwing: MailStreamError.stream(underlying: err))
            return
        }
        let newOffset = p.offset + bytesWritten
        if newOffset >= p.data.count {
            p.cont.resume(returning: ())
            return
        }
        // Partial write: re-stash and wait for the next .hasSpaceAvailable — but
        // if close() snuck in and transitioned state to .closed while we were
        // draining, fail the continuation instead of parking it on a dead stream.
        let closedDuringDrain: Bool = stateQueue.sync {
            if self._state == .closed { return true }
            self.pendingWrite = (data: p.data, offset: newOffset, cont: p.cont)
            return false
        }
        if closedDuringDrain {
            p.cont.resume(throwing: MailStreamError.connectionClosed)
        }
    }

    /// If a pin is set and chain validation was disabled for it (not for testing),
    /// compute the SHA-256 of the peer's leaf certificate and compare against
    /// `pinnedCertSHA256`. Returns nil on success (pin matches or no pin set);
    /// returns `MailStreamError.certPinMismatch` on mismatch or extraction failure.
    ///
    /// MUST be called on the dedicated runloop thread (the only thread that
    /// touches the streams safely). Tries the read stream first, then the write
    /// stream — CFStream may populate the peer trust on the write side first
    /// (particularly in the implicit-TLS case).
    private func verifyPinIfNeeded() -> MailStreamError? {
        guard let pin = self.pinnedCertSHA256, !self.allowsUnverifiedChain else {
            return nil
        }
        let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLPeerTrust)

        // Try input stream first, then output stream. After the TLS handshake
        // the peer trust is typically available on one or both; the exact side
        // that populates first is CFNetwork-implementation detail.
        var trustObj: CFTypeRef? = nil
        if let i = self.input {
            trustObj = CFReadStreamCopyProperty(i as CFReadStream, key)
        }
        if trustObj == nil, let o = self.output {
            trustObj = CFWriteStreamCopyProperty(o as CFWriteStream, key)
        }
        guard let trustObj = trustObj else {
            return .certPinMismatch(presented: "<no peer trust>")
        }
        guard CFGetTypeID(trustObj) == SecTrustGetTypeID() else {
            return .certPinMismatch(presented: "<peer trust wrong type>")
        }
        let trust = trustObj as! SecTrust
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return .certPinMismatch(presented: "<empty cert chain>")
        }
        let der = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if actual == pin {
            return nil
        }
        return .certPinMismatch(presented: actual)
    }

    private func applyTLSSettings(host: String) {
        var settings: [CFString: Any] = [
            kCFStreamSSLPeerName: host as CFString,
            kCFStreamSSLValidatesCertificateChain: kCFBooleanTrue!
        ]
        if allowsUnverifiedChain || pinnedCertSHA256 != nil {
            settings[kCFStreamSSLValidatesCertificateChain] = kCFBooleanFalse!
        }
        let cf = settings as CFDictionary
        // kCFStreamPropertySSLSettings is a CFString; bridge to CFStreamPropertyKey.
        let key = CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings)
        if let i = input {
            CFReadStreamSetProperty(i as CFReadStream, key, cf)
        }
        if let o = output {
            CFWriteStreamSetProperty(o as CFWriteStream, key, cf)
        }
    }

    private func cleanupOnError() async {
        // Transition to .closed under the lock so any racing connect() retry
        // fails checkTransition, and capture the runloop + thread to tear down.
        let (rl, rlThread) = stateQueue.sync { () -> (RunLoop?, Thread?) in
            self._state = .closed
            return (self.runloop, self.runloopThread)
        }
        // Cancel FIRST, then schedule the teardown perform block so the runloop
        // wakes, processes the block, and re-evaluates isCancelled = true on
        // the next iteration — exits promptly instead of sleeping 0.5s.
        rlThread?.cancel()
        rl?.perform { [weak self] in
            self?.input?.close()
            self?.output?.close()
        }
        // Join the runloop thread (bounded) before dropping references, so a
        // subsequent operation on the same instance can't race a dying thread.
        if rlThread != nil {
            await awaitRunloopExit(timeout: 2.0)
        }
        stateQueue.sync {
            self.input = nil
            self.output = nil
            self.runloopThread = nil
        }
        self.runloop = nil
    }

    /// Bridge the runloop-exit DispatchSemaphore to async with a bounded timeout.
    /// The wait runs on a utility-queue thread so the cooperative pool isn't blocked.
    private func awaitRunloopExit(timeout: TimeInterval) async {
        let gate = self.runloopExited
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = gate.wait(timeout: .now() + timeout)
                cont.resume()
            }
        }
    }

    private func checkTransition(allowedFrom: [State], to: State) throws {
        try stateQueue.sync {
            guard allowedFrom.contains(self._state) else {
                throw MailStreamError.wrongState("transition to \(to) not allowed from \(self._state)")
            }
            self._state = to
        }
    }

}

/// Thread-safe box for carrying a non-Sendable value across a concurrency
/// boundary in a controlled, single-write / single-read pattern.
/// Marked @unchecked Sendable because the caller guarantees the write happens
/// before any read (enforced by the continuation signaling order).
private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
