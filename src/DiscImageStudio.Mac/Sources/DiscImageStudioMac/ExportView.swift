import DiscImageStudioKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @EnvironmentObject private var app: AppModel

    private var family: DiscFamily { app.project?.discFamily ?? .cd }
    private var outputs: ProjectOutputs { app.project?.outputs ?? ProjectOutputs() }
    private var hasFiles: Bool { !outputs.dataDirectory.isEmpty }
    private var isAudio: Bool { family == .cd && !hasFiles }

    var body: some View {
        Form {
            Section("Source") {
                LabeledContent("Picture") {
                    Text(app.layers.isEmpty ? "Import an image on the Design page first." : "Design composite (\(DesignComposer.exportSize) px)")
                        .foregroundStyle(app.layers.isEmpty ? .secondary : .primary)
                }
                if let geometry = app.project?.geometry {
                    HStack {
                        Text("Geometry")
                        Spacer()
                        Text("\(CommandBuilder.number(geometry.innerRadiusMm))–\(CommandBuilder.number(geometry.outerRadiusMm)) mm · \(geometry.sectors.formatted()) sectors")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Button("Edit…") { app.showingProjectSettings = true }
                    }
                }
            }
            Section("Output") {
                PathRow(title: "Save to", path: outputs.outputPath, choose: chooseOutput)
                if isAudio {
                    Toggle("Delay interleave", isOn: outputBinding(\.interleave))
                    Toggle("Also write a CUE file", isOn: outputBinding(\.writeCue))
                        .disabled(outputs.outputPath.lowercased().hasSuffix(".raw"))
                }
            }
            Section("Files on the disc") {
                PathRow(title: "Folder", path: outputs.dataDirectory, placeholder: "None. The whole disc holds the picture.",
                        choose: {
                            if let url = FilePanels.folder(prompt: "Choose a folder to put on the disc") { setDataDirectory(url.path) }
                        },
                        clear: { setDataDirectory("") })
                if hasFiles {
                    Picker("File position", selection: outputBinding(\.filesAtOuterRing)) {
                        Text("Inner ring").tag(false)
                        Text("Outer ring").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if hasFiles || family != .cd {
                    TextField("Volume label", text: outputBinding(\.volumeLabel))
                }
            }
            Section {
                HStack {
                    Text(isAudio ? "Tone settings are on the Design page." : "Tone settings are on the Design page. A Blu-ray or DVD image can take a long time and needs up to its full disc size in free space.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await app.generate() }
                    } label: {
                        Label("Generate", systemImage: "gearshape.2")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(app.layers.isEmpty || outputs.outputPath.isEmpty || app.job != nil)
                }
                if let artifact = app.lastArtifactPath {
                    LabeledContent("Last output") {
                        HStack {
                            Text(artifact).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact)])
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .pageWidth(720)
    }

    private func outputBinding<T>(_ key: WritableKeyPath<ProjectOutputs, T>) -> Binding<T> {
        Binding(get: { outputs[keyPath: key] }, set: { value in app.updateProject { $0.outputs[keyPath: key] = value } })
    }

    private func chooseOutput() {
        let current = URL(fileURLWithPath: outputs.outputPath)
        let types: [UTType] = isAudio ? [.wav, .raw] : [.iso]
        let name = outputs.outputPath.isEmpty ? "\(app.project?.name ?? "disc").\(isAudio ? "wav" : "iso")" : current.lastPathComponent
        if let url = FilePanels.save(defaultName: name, directory: current.deletingLastPathComponent(), types: types) {
            app.updateProject { $0.outputs.outputPath = url.path }
        }
    }

    /// A CD with files is a data disc, so its output becomes an ISO, and clearing the folder
    /// brings the audio track back.
    private func setDataDirectory(_ path: String) {
        app.updateProject { document in
            document.outputs.dataDirectory = path
            guard document.discFamily == .cd, !document.outputs.outputPath.isEmpty else { return }
            let url = URL(fileURLWithPath: document.outputs.outputPath).deletingPathExtension()
            document.outputs.outputPath = url.appendingPathExtension(path.isEmpty ? "wav" : "iso").path
        }
    }
}
