import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A one-request-per-connection HTTP server over a unix domain socket.
///
/// Plain BSD sockets plus `DispatchSource`, NOT `NWListener`. Network.framework
/// can listen on a unix path, but only through an undocumented
/// Swift-overlay-only endpoint with no defined lifecycle for the socket FILE —
/// nothing tells you whether it unlinks on cancel, and stale-socket takeover is
/// precisely the behaviour this server exists to get right.
///
/// Threading: every callback — accept, read, `onRequest` — runs on the `queue`
/// handed to `init`. Pass a SERIAL queue and the request handler is
/// automatically serialised with itself. `start()` and `stop()` use
/// `queue.sync`, so they must NOT be called from `onRequest`.
public final class UnixSocketServer: @unchecked Sendable {
    public enum StartError: Error, Sendable, Equatable {
        /// Something is already listening on this path. Not a takeover
        /// candidate — it answered.
        case alreadyRunning(existingPID: Int32?)
        /// The path would overflow `sockaddr_un.sun_path`. Carries the byte count.
        case pathTooLong(Int)
        case posix(errno: Int32, call: String)
    }

    public let path: URL

    private let queue: DispatchQueue
    private let onRequest: @Sendable (HTTPParse.Request) -> Data
    private let maxBody: Int

    /// Queue-confined.
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private let runningLock = NSLock()
    private var _isRunning = false

    public init(
        path: URL,
        queue: DispatchQueue,
        maxBody: Int = 1 << 20,
        onRequest: @escaping @Sendable (HTTPParse.Request) -> Data
    ) {
        self.path = path
        self.queue = queue
        self.maxBody = maxBody
        self.onRequest = onRequest
    }

    deinit {
        // Cancel, never close: the source's cancel handler owns the fd, and
        // closing here too would be a double-close on a descriptor number that
        // may already have been reused.
        acceptSource?.cancel()
    }

    public var isRunning: Bool {
        runningLock.lock()
        defer { runningLock.unlock() }
        return _isRunning
    }

    /// mkdir 0700 → probe/unlink stale → bind → chmod 0600 → listen(16).
    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    public func stop() {
        queue.sync {
            for connection in connections.values { connection.close() }
            connections.removeAll()

            // The cancel handler owns closing the listen fd.
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1

            unlink(path.path)
            setRunning(false)
        }
    }

    // MARK: - Setup

    private func startOnQueue() throws {
        guard listenFD < 0 else { return }

        let p = path.path
        guard SocketPath.fits(p) else { throw StartError.pathTooLong(p.utf8.count) }

        // 0700: the socket is per-user and nobody else needs to traverse to it.
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.posix(errno: errno, call: "socket") }

        try bindWithTakeover(fd: fd, path: p)

        // 0600: only this user may talk to it. Do it after bind — the file does
        // not exist until then — and before listen, so there is no window where
        // it is both connectable and group-writable.
        if chmod(p, 0o600) != 0 {
            Log.server.error("chmod 0600 failed on \(p, privacy: .public): \(errno)")
        }

        guard listen(fd, 16) == 0 else {
            let err = errno
            Darwin.close(fd)
            unlink(p)
            throw StartError.posix(errno: err, call: "listen")
        }

        // Non-blocking so the accept loop can drain to EAGAIN without stalling
        // the queue. Accepted connections stay BLOCKING: a read only happens
        // after the source says bytes are ready, and responses are ~100 bytes.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }

        listenFD = fd
        acceptSource = source
        setRunning(true)
        source.resume()

        Log.server.info("listening on \(p, privacy: .public)")
    }

    /// Bind, and on `EADDRINUSE` decide whether the file is a live server or a
    /// corpse.
    ///
    /// This is the whole reason the server exists in this shape. A unix socket
    /// file outlives the process that made it — a crash, a `kill -9`, a reboot
    /// that did not run our cleanup — and the leftover file makes every future
    /// launch fail to bind. `connect()` is the only reliable test: a live
    /// listener accepts it, a corpse answers `ECONNREFUSED`.
    private func bindWithTakeover(fd: Int32, path p: String) throws {
        var didUnlink = false
        while true {
            var addr = Self.address(for: p)
            let rc = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 { return }

            let err = errno
            guard err == EADDRINUSE, !didUnlink else {
                Darwin.close(fd)
                throw StartError.posix(errno: err, call: "bind")
            }

            if Self.isLive(path: p) {
                Darwin.close(fd)
                // We do not probe for the other instance's pid in M0: that means
                // a blocking round-trip on a socket we have just decided we do
                // not control.
                throw StartError.alreadyRunning(existingPID: nil)
            }

            // Only ever unlink something that is actually a socket. If a real
            // file is sitting on our path, that is a configuration problem and
            // deleting the user's data is not our call.
            guard Self.isSocketFile(p) else {
                Darwin.close(fd)
                throw StartError.posix(errno: err, call: "bind")
            }

            Log.server.info("removing stale socket at \(p, privacy: .public)")
            unlink(p)
            didUnlink = true
        }
    }

    private func setRunning(_ value: Bool) {
        runningLock.lock()
        _isRunning = value
        runningLock.unlock()
    }

    // MARK: - Accept

    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return // EAGAIN/EWOULDBLOCK: drained
            }

            // Without SO_NOSIGPIPE, a peer that hangs up before we finish
            // writing kills the whole process with SIGPIPE.
            var on: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            let connection = Connection(
                fd: clientFD,
                queue: queue,
                maxBody: maxBody,
                onRequest: onRequest,
                onClose: { [weak self] fd in self?.connections.removeValue(forKey: fd) }
            )
            connections[clientFD] = connection
            connection.resume()
        }
    }

    // MARK: - sockaddr_un

    static func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bytes = Array(path.utf8CString) // includes the NUL
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for i in 0..<min(bytes.count, capacity) { dst[i] = bytes[i] }
            }
        }
        return addr
    }

    /// Is somebody listening on this path right now?
    static func isLive(path p: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = address(for: p)
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    static func isSocketFile(_ p: String) -> Bool {
        var st = stat()
        guard lstat(p, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }
}

// MARK: - Connection

/// One accepted connection. Queue-confined: created, driven and destroyed on the
/// server's queue, which is why the mutable buffer needs no lock.
private final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let maxBody: Int
    private let onRequest: @Sendable (HTTPParse.Request) -> Data
    private let onClose: @Sendable (Int32) -> Void
    private let source: DispatchSourceRead

    private var buffer = Data()
    private var finished = false

    init(
        fd: Int32,
        queue: DispatchQueue,
        maxBody: Int,
        onRequest: @escaping @Sendable (HTTPParse.Request) -> Data,
        onClose: @escaping @Sendable (Int32) -> Void
    ) {
        self.fd = fd
        self.maxBody = maxBody
        self.onRequest = onRequest
        self.onClose = onClose
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

        source.setEventHandler { [weak self] in self?.readable() }
        source.setCancelHandler { Darwin.close(fd) }
    }

    func resume() { source.resume() }

    func close() {
        guard !finished else { return }
        finished = true
        source.cancel() // cancel handler closes the fd
    }

    private func readable() {
        guard !finished else { return }

        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let n = chunk.withUnsafeMutableBytes { raw -> Int in
            read(fd, raw.baseAddress, raw.count)
        }

        if n < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            finish()
            return
        }
        if n == 0 { // peer hung up
            finish()
            return
        }

        buffer.append(contentsOf: chunk[0..<n])

        switch HTTPParse.parse(buffer, maxBody: maxBody) {
        case .needMore:
            return
        case .malformed(let reason):
            Log.server.error("malformed request: \(reason, privacy: .public)")
            send(EventRouter.badRequest(reason: reason))
            finish()
        case .complete(let request, _):
            send(onRequest(request))
            // Every response says `Connection: close`, so there is no second
            // request to wait for.
            finish()
        }
    }

    private func send(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                break // EPIPE and friends: the peer left, nothing to do
            }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        source.cancel()
        onClose(fd)
    }
}
