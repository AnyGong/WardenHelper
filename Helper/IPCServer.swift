import Foundation
import Darwin

/// The helper's only way in: a Unix socket owned by the WardenHelper user (mode 0600). Each
/// connection is also checked with the kernel's peer credentials, so a process of another user
/// is dropped even if the socket file's permissions were changed. One JSON line in, one out.
final class IPCServer {

    private let path: String
    private let allowedUID: uid_t
    private let handler: (HelperRequest) -> HelperResponse
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let connections = DispatchQueue(label: "warden-helper.daemon.connections", attributes: .concurrent)

    init(path: String, allowedUID: uid_t, handler: @escaping (HelperRequest) -> HelperResponse) {
        self.path = path
        self.allowedUID = allowedUID
        self.handler = handler
    }

    struct StartError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Start / stop

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError(description: "socket: \(String(cString: strerror(errno)))") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let name = Array(path.utf8CString)                       // with the trailing NUL
        guard name.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw StartError(description: "socket path too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: name.count) { dst in
                for (i, byte) in name.enumerated() { dst[i] = byte }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let oldMask = umask(0o177)                               // created as 0600 from the start
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindError = errno
        umask(oldMask)
        guard bound == 0 else {
            close(fd)
            throw StartError(description: "bind: \(String(cString: strerror(bindError)))")
        }
        chown(path, allowedUID, 0)
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            throw StartError(description: "listen: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }

    // MARK: Accepting

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }                             // EAGAIN: nothing more queued
            // A BSD accepted socket can inherit O_NONBLOCK from the listener.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            connections.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == allowedUID || uid == 0 else {
            helperLog("refused a connection from uid \(uid)")
            return
        }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)              // a stalled peer cannot hold a thread
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                guard reply(to: line, on: fd) else { return }
            }
            if pending.count > BlockIPC.maxMessageBytes {
                _ = send(HelperResponse(ok: false, error: "message too large"), on: fd)
                return
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }                                  // closed, timed out or failed
            pending.append(contentsOf: chunk[0..<n])
        }
    }

    private func reply(to line: Data, on fd: Int32) -> Bool {
        guard let request = try? JSONDecoder().decode(HelperRequest.self, from: line) else {
            return send(HelperResponse(ok: false, error: "bad request"), on: fd)
        }
        return send(handler(request), on: fd)
    }

    private func send(_ response: HelperResponse, on fd: Int32) -> Bool {
        guard var data = try? JSONEncoder().encode(response) else { return false }
        data.append(0x0A)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}
