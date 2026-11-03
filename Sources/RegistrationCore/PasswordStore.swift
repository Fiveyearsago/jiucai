import Foundation
import Darwin

public protocol PasswordStore: Sendable {
    func read() throws -> String?
    func save(_ password: String) throws
}

/// The password is stored locally as UTF-8 text in a private application-support directory.
public struct LocalPasswordStore: PasswordStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("registration-password", isDirectory: false) }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeautyRegistration", isDirectory: true)
    }

    private func systemError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    public func read() throws -> String? {
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw systemError()
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError() }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw systemError(EINVAL) }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { throw systemError() }
        guard let password = String(data: try file.readToEnd() ?? Data(), encoding: .utf8) else {
            throw systemError(EILSEQ)
        }
        return password
    }

    public func save(_ password: String) throws {
        if password.isEmpty {
            if unlink(fileURL.path) != 0 && errno != ENOENT { throw systemError() }
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temp = directory.appendingPathComponent(".password-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw systemError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); _ = unlink(temp.path) }
        try file.write(contentsOf: Data(password.utf8))
        try file.synchronize()
        try file.close()
        guard rename(temp.path, fileURL.path) == 0 else { throw systemError() }
    }
}
