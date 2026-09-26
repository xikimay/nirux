import Darwin

/// Checks whether something accepts TCP connections on a loopback port.
/// Blocking — call it off the main thread. Loopback connects never trigger
/// the Local Network privacy prompt.
enum LocalPortProbe {
    static func isListening(_ url: LocalServerURL, timeoutMilliseconds: Int32 = 250) -> Bool {
        guard let port = UInt16(exactly: url.port), port > 0 else { return false }
        switch url.host {
        case "127.0.0.1":
            return connects(family: AF_INET, port: port, timeoutMilliseconds: timeoutMilliseconds)
        case "[::1]":
            return connects(family: AF_INET6, port: port, timeoutMilliseconds: timeoutMilliseconds)
        default:
            // "localhost" (or a normalized unspecified bind): the server may
            // listen on either stack, like the browser would try.
            return connects(family: AF_INET, port: port, timeoutMilliseconds: timeoutMilliseconds)
                || connects(family: AF_INET6, port: port, timeoutMilliseconds: timeoutMilliseconds)
        }
    }

    /// Non-blocking connect + poll: a plain blocking connect can stall for
    /// over a minute when the listener's accept backlog is full.
    private static func connects(family: Int32, port: UInt16, timeoutMilliseconds: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        let result: Int32
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, timeoutMilliseconds) == 1 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }
}
