import AppKit
import DiscImageStudioKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BurnModel: ObservableObject {
    @Published var devices: [BurnDevice] = []
    @Published var selectedDevice: Int?
    @Published var sourcePath = ""
    @Published var speed: Int?
    @Published var verify = true
    @Published var eject = true
    @Published var testBurn = true
    @Published var isRefreshing = false

    func refreshDevices() async {
        isRefreshing = true
        devices = await BurnService.listDevices()
        if !devices.contains(where: { $0.index == selectedDevice }) { selectedDevice = devices.first?.index }
        isRefreshing = false
    }

    func burn(app: AppModel) async {
        let path = sourcePath
        let isAudio = path.lowercased().hasSuffix(".wav")
        let device = devices.first { $0.index == selectedDevice }
        let speed = speed, verify = verify, eject = eject, testBurn = testBurn
        do {
            let title = "\(testBurn ? "Test burning" : "Burning") \(URL(fileURLWithPath: path).lastPathComponent)…"
            try await app.runBurn(title: title) {
                isAudio
                    ? try BurnService.burnAudio(wavPath: path, speed: speed, testBurn: testBurn)
                    : try BurnService.burn(imagePath: path, device: device, speed: speed, verify: verify, eject: eject, testBurn: testBurn)
            }
            app.appendLog(testBurn ? "Test burn finished. The disc wasn't written." : "Burn finished. Check the result on the real disc.")
        } catch {
            app.report(error, title: "The burn didn't finish")
        }
    }
}

extension AppModel {
    /// Like runJob, but reads hdiutil's progress lines instead of the engine's.
    func runBurn(title: String, start: () throws -> CLIJob) async throws {
        guard job == nil else {
            throw CLIFailure(message: "Another job is still running.", exitCode: -1, wasCancelled: false)
        }
        let running = try start()
        job = ActiveJob(title: title, fraction: nil, detail: "", cancel: { running.cancel() })
        appendLog(title)
        defer { job = nil }
        var lastMessage: String?
        for await event in running.events {
            let line: String
            switch event {
            case .stdout(let text), .stderr(let text): line = text
            case .progress: continue
            }
            switch BurnService.parseBurnLine(line) {
            case .progress(let fraction):
                job?.fraction = fraction
            case .message(let message):
                appendLog(message)
                job?.detail = message
                lastMessage = message
            case nil:
                break
            }
        }
        let result = await running.wait()
        if result.wasCancelled {
            throw CLIFailure(message: "Cancelled.", exitCode: result.exitCode, wasCancelled: true)
        }
        guard result.succeeded else {
            throw CLIFailure(message: lastMessage ?? "The burn failed with exit code \(result.exitCode).", exitCode: result.exitCode, wasCancelled: false)
        }
    }
}

struct BurnView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: BurnModel
    @State private var confirming = false

    private var sourceExists: Bool { FileManager.default.fileExists(atPath: model.sourcePath) }
    private var isRaw: Bool { model.sourcePath.lowercased().hasSuffix(".raw") }
    private var isAudio: Bool { model.sourcePath.lowercased().hasSuffix(".wav") }

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Experimental, and not verified on a real disc").font(.callout.weight(.semibold))
                        Text("The Windows app controls the burner directly, and this page uses macOS's own hdiutil and drutil, so the result may not match. A CD data image may lose sectors at the end of the disc, because macOS doesn't write it the disc-at-once way Windows does. Use spare media, and start with a test burn.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section("Burner") {
                if model.devices.isEmpty {
                    HStack {
                        Text("Drive")
                        Spacer()
                        Text(model.isRefreshing ? "Looking for drives…" : "No burner found. Connect one and refresh.")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Button("Refresh") { Task { await model.refreshDevices() } }
                    }
                } else {
                    Picker("Drive", selection: $model.selectedDevice) {
                        ForEach(model.devices) { Text($0.name).tag(Optional($0.index)) }
                    }
                    Button("Refresh") { Task { await model.refreshDevices() } }
                }
                Picker("Speed", selection: $model.speed) {
                    Text("Maximum").tag(Int?.none)
                    ForEach([1, 2, 4, 6, 8, 10, 12, 16, 24], id: \.self) { Text("\($0)x").tag(Optional($0)) }
                }
            }
            Section("What to write") {
                PathRow(title: "File", path: model.sourcePath, placeholder: "Generate one on the Export page") {
                    if let url = FilePanels.open(types: [.iso, .wav]) { model.sourcePath = url.path }
                }
                if isRaw {
                    Text("A .raw track can't be burned here. Generate a .wav instead.")
                        .font(.caption).foregroundStyle(.red)
                }
                if isAudio {
                    Text("macOS adds its own track gap to audio discs and offers no choice of drive here. Check that the picture lines up before relying on this.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Test burn (laser off)", isOn: $model.testBurn)
                if !isAudio {
                    Toggle("Verify after burning", isOn: $model.verify)
                    Toggle("Eject when done", isOn: $model.eject)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button(role: model.testBurn ? nil : .destructive) {
                        confirming = true
                    } label: {
                        Label(model.testBurn ? "Start Test Burn" : "Burn Disc", systemImage: "flame")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!sourceExists || isRaw || model.devices.isEmpty || app.job != nil)
                }
            }
        }
        .formStyle(.grouped)
        .pageWidth(720)
        .task {
            if model.sourcePath.isEmpty, let artifact = app.lastArtifactPath { model.sourcePath = artifact }
            await model.refreshDevices()
        }
        .confirmationDialog(
            model.testBurn ? "Start a test burn?" : "Burn this disc?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button(model.testBurn ? "Start Test Burn" : "Burn Disc", role: model.testBurn ? nil : .destructive) {
                Task { await model.burn(app: app) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.testBurn
                 ? "The drive goes through the motions with the laser off. Nothing is written."
                 : "This writes \(URL(fileURLWithPath: model.sourcePath).lastPathComponent) to the disc and can't be undone. An interrupted burn usually ruins a write-once disc.")
        }
    }
}
