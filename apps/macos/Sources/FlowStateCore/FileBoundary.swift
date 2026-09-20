import AppKit
import Foundation

public enum FileBoundaryError: Error, Equatable, LocalizedError, Sendable {
    case outsideApprovedDirectory
    case sensitivePath
    case missing
    case changed
    case expired
    case wrongTask
    case tooLarge
    case uploadNotApproved

    public var errorDescription: String? {
        switch self {
        case .outsideApprovedDirectory: "The file is outside the approved folder."
        case .sensitivePath: "This sensitive system path cannot be selected."
        case .missing: "The approved file no longer exists."
        case .changed: "The file changed after approval. Select it again."
        case .expired: "The file approval has expired."
        case .wrongTask: "The file belongs to a different task."
        case .tooLarge: "The selected file exceeds the upload limit."
        case .uploadNotApproved: "Uploading requires an explicit file approval."
        }
    }
}

public struct ApprovedFile: Codable, Equatable, Sendable {
    public let taskID: String
    public let path: String
    public let byteCount: UInt64
    public let modifiedAt: Date
    public let expiresAt: Date

    public static let defaultExpiry: TimeInterval = 10 * 60
    public static let maxUploadBytes: UInt64 = 25 * 1_024 * 1_024

    public static func approve(
        fileURL: URL,
        taskID: String,
        allowedDirectory: URL? = nil,
        expiresAt: Date = Date().addingTimeInterval(defaultExpiry)
    ) throws -> ApprovedFile {
        let standardized = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard !isSensitivePath(standardized) else { throw FileBoundaryError.sensitivePath }
        if let allowedDirectory {
            let directory = allowedDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let path = standardized.path
            guard path == directory || path.hasPrefix(directory + "/") else {
                throw FileBoundaryError.outsideApprovedDirectory
            }
        }
        let values = try standardized.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw FileBoundaryError.missing }
        guard let size = values.fileSize, size >= 0 else { throw FileBoundaryError.missing }
        guard let modified = values.contentModificationDate else { throw FileBoundaryError.missing }
        return ApprovedFile(
            taskID: taskID,
            path: standardized.path,
            byteCount: UInt64(size),
            modifiedAt: modified,
            expiresAt: expiresAt
        )
    }

    public func readData(now: Date = Date()) throws -> Data {
        try FileUploadBoundary.validate(self, taskID: taskID, now: now)
        guard byteCount <= Self.maxUploadBytes else { throw FileBoundaryError.tooLarge }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard UInt64(data.count) == byteCount else { throw FileBoundaryError.changed }
        return data
    }

    private static func isSensitivePath(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let sensitiveFragments = [
            "/library/keychains/",
            "/library/application support/1password/",
            "/library/application support/bitwarden/",
            "/library/containers/com.apple.passwords/",
            "/.ssh/"
        ]
        return sensitiveFragments.contains(where: path.contains)
    }
}

public enum FileUploadBoundary {
    public static func validate(
        _ approved: ApprovedFile,
        taskID: String,
        now: Date = Date()
    ) throws {
        guard approved.taskID == taskID else { throw FileBoundaryError.wrongTask }
        guard approved.expiresAt > now else { throw FileBoundaryError.expired }
        let url = URL(fileURLWithPath: approved.path)
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == approved.path else { throw FileBoundaryError.changed }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw FileBoundaryError.missing }
        guard values.fileSize.map({ UInt64($0) == approved.byteCount }) == true,
              values.contentModificationDate == approved.modifiedAt
        else { throw FileBoundaryError.changed }
    }

    public static func prepare(
        _ approved: ApprovedFile,
        taskID: String,
        now: Date = Date()
    ) throws -> FileUploadRequest {
        try validate(approved, taskID: taskID, now: now)
        guard approved.byteCount <= ApprovedFile.maxUploadBytes else { throw FileBoundaryError.tooLarge }
        return FileUploadRequest(approvedFile: approved, taskID: taskID)
    }
}

public struct FileUploadRequest: Codable, Equatable, Sendable {
    public let approvedFile: ApprovedFile
    public let taskID: String

    public init(approvedFile: ApprovedFile, taskID: String) {
        self.approvedFile = approvedFile
        self.taskID = taskID
    }
}

@MainActor
public final class ApprovedFileSelector {
    public init() {}

    public func selectFile(
        taskID: String,
        allowedDirectory: URL? = nil
    ) throws -> ApprovedFile? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose one file to approve for this task"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try ApprovedFile.approve(
            fileURL: url,
            taskID: taskID,
            allowedDirectory: allowedDirectory
        )
    }
}
