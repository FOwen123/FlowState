import AppKit
import CoreGraphics
import FlowStateCore
import SwiftUI

@MainActor
final class FlowStateAppModel: ObservableObject {
    @Published var bundleIdentifier = ""
    @Published private(set) var permissionStatus = "Checking Screen Recording permission…"
    @Published private(set) var taskStatus = "Idle — screen capture is off"
    @Published private(set) var isTaskActive = false

    private let controller: ScreenCaptureController
    private var grant: CaptureGrant?
    private var statusGeneration: UInt64 = 0

    init() {
        controller = ScreenCaptureController()
        refreshPermissionStatus()
    }

    func refreshPermissionStatus() {
        permissionStatus = CGPreflightScreenCaptureAccess()
            ? "Screen Recording permission granted"
            : "Screen Recording permission required"
    }

    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissionStatus()
    }

    func beginTask() {
        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty else {
            taskStatus = "Enter an approved application bundle ID first"
            return
        }

        statusGeneration &+= 1
        let taskGeneration = statusGeneration
        Task {
            let nextGrant = await controller.beginTask(allowedBundleIdentifiers: [bundle])
            guard taskGeneration == statusGeneration else { return }
            grant = nextGrant
            isTaskActive = true
            taskStatus = "Active for \(bundle) — capture only runs on request"
        }
    }

    func revokeTask() {
        statusGeneration &+= 1
        grant = nil
        isTaskActive = false
        taskStatus = "Revoked — screen capture is off"
        Task {
            await controller.revoke()
        }
    }

    func captureApprovedWindow() {
        guard let grant else {
            taskStatus = "Start an active task before capturing"
            return
        }

        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskGeneration = statusGeneration
        taskStatus = "Capturing approved window…"
        Task {
            do {
                let frame = try await controller.capture(
                    bundleIdentifier: bundle,
                    grant: grant
                )
                guard taskGeneration == statusGeneration else { return }
                taskStatus = "Captured \(frame.image.width)×\(frame.image.height) in memory"
            } catch {
                guard taskGeneration == statusGeneration else { return }
                taskStatus = error.localizedDescription
            }
        }
    }
}

struct FlowStateMenuView: View {
    @ObservedObject var model: FlowStateAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FlowState")
                .font(.headline)
            Text("Screen capture is explicit and scoped to an active task.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The selected window is captured in full; fields are not redacted.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Label(model.permissionStatus, systemImage: "lock.shield")
                .font(.caption)
            HStack {
                Button("Request permission") { model.requestPermission() }
                Button("Refresh") { model.refreshPermissionStatus() }
            }

            Divider()
            TextField("Approved app bundle ID", text: $model.bundleIdentifier)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Begin task") { model.beginTask() }
                    .disabled(model.isTaskActive)
                Button("Revoke") { model.revokeTask() }
                    .disabled(!model.isTaskActive)
            }
            Button("Capture approved window") { model.captureApprovedWindow() }
                .disabled(!model.isTaskActive)
            Text(model.taskStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
    }
}

@main
struct FlowStateApp: App {
    @StateObject private var model = FlowStateAppModel()

    var body: some Scene {
        MenuBarExtra("FlowState", systemImage: "waveform") {
            FlowStateMenuView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
