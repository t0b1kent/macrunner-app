import Darwin
import Foundation

/// Жив ли wineserver бутылки — то есть запущено ли в ней что-нибудь, в том числе не нами.
///
/// Путь сокета — как в нашем Wine (`dlls/ntdll/unix/server.c`, `init_server_dir`):
/// `$TMPDIR/.wine-<uid>/server-<dev>-<ino>/socket`, где TMPDIR берётся, только если он
/// абсолютный, иначе `/tmp`. Файл сокета переживает упавший сервер, поэтому проверяем
/// подключением, а не наличием файла.
enum WineServerProbe {
    static func socketPath(prefix: URL, environment: [String: String]) -> String? {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return nil }
        var tmp = environment["TMPDIR"] ?? ""
        if !tmp.hasPrefix("/") { tmp = "/tmp" }
        return String(format: "%@/.wine-%u/server-%llx-%llx/socket", tmp, getuid(),
                      UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino))
    }

    static func isAlive(prefix: URL, environment: [String: String]) -> Bool {
        probe(prefix: prefix, environment: environment) == true
    }

    /// Update admission fails closed: resource/permission errors do not prove idle.
    static func mayBeAlive(prefix: URL, environment: [String: String]) -> Bool {
        probe(prefix: prefix, environment: environment) != false
    }

    private static func probe(prefix: URL, environment: [String: String]) -> Bool? {
        guard let path = socketPath(prefix: prefix, environment: environment) else {
            return errno == ENOENT ? false : nil
        }
        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0 else { return errno == ENOENT ? false : nil }
        guard socketInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        return errno == ECONNREFUSED || errno == ENOENT ? false : nil
    }
}
