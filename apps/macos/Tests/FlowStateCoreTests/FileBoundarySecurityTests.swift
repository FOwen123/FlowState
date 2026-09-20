import Foundation
import Testing
@testable import FlowStateCore

@Test func fileApprovalRejectsSymlinkOutsideApprovedFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let allowed = root.appendingPathComponent("allowed")
    try FileManager.default.createDirectory(at:allowed,withIntermediateDirectories:true)
    let outsideDirectory = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at:outsideDirectory,withIntermediateDirectories:true)
    let outside = outsideDirectory.appendingPathComponent("private.txt")
    try Data("private".utf8).write(to:outside)
    let link = allowed.appendingPathComponent("linked-folder")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outsideDirectory)
    #expect(throws: FileBoundaryError.outsideApprovedDirectory) {
        try ApprovedFile.approve(fileURL:link.appendingPathComponent("private.txt"),taskID:"file-task",allowedDirectory:allowed)
    }
}
