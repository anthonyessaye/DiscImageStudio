import DiscImageStudioKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Disc Image Studio").font(.largeTitle.weight(.semibold))
                    Text("Turn a picture into a CD, DVD or Blu-ray image whose data draws that picture on the disc.")
                        .foregroundStyle(.secondary)
                }
                if app.runner == nil {
                    Label("The disc engine wasn't found. Build the app with scripts/build-app.sh, or set DISC_IMAGE_STUDIO_CLI during development.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button {
                        if app.confirmDiscardChanges() { app.showingNewProject = true }
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button {
                        app.openWithPanel()
                    } label: {
                        Label("Open…", systemImage: "folder")
                    }
                    .controlSize(.large)
                }
                if !app.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent projects").font(.headline)
                        ForEach(app.recents) { recent in
                            HStack {
                                Image(systemName: "opticaldisc")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(recent.name)
                                    Text(recent.path).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(recent.family.label).font(.caption).foregroundStyle(.secondary)
                                Button {
                                    app.removeRecent(recent)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove from recents")
                            }
                            .padding(10)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard app.confirmDiscardChanges() else { return }
                                let url = URL(fileURLWithPath: recent.path)
                                Task { await app.open(url) }
                            }
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct NewProjectSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var family: DiscFamily = .cd
    @State private var presetID: String?
    @State private var name = "Untitled Disc"
    @State private var directory: URL?

    private var presets: [DiscPreset] { app.catalog?.presets(for: family) ?? [] }
    private var preset: DiscPreset? { presets.first { $0.id == presetID } ?? presets.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Disc type", selection: $family) {
                    ForEach(DiscFamily.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Template", selection: $presetID) {
                    ForEach(presets) { Text(app.text.translate($0.displayName)).tag(Optional($0.id)) }
                }
                if let preset {
                    Text(app.text.translate(preset.description))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Name", text: $name)
                PathRow(title: "Location", path: (directory ?? app.defaultProjectsDirectory).path) {
                    if let url = FilePanels.folder(prompt: "Choose where to save the project") { directory = url }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let preset else { return }
                    let target = directory ?? app.defaultProjectsDirectory
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    Task { await app.createProject(name: trimmed, preset: preset, directory: target) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preset == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
            }
            .padding()
        }
        .frame(width: 560, height: 400)
        .onAppear { presetID = presets.first?.id }
        .onChange(of: family) { _, _ in presetID = presets.first?.id }
    }
}

/// The one place generation geometry can be edited; other pages only summarize it.
struct ProjectSettingsSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var geometry = ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 32)
    @State private var sectorsText = ""
    @State private var invert = false
    @State private var presetName = ""
    @State private var error: String?

    private var family: DiscFamily { app.project?.discFamily ?? .cd }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("\(family.label) geometry") {
                    NumberField(title: "Inner radius", value: $geometry.innerRadiusMm, unit: "mm")
                    NumberField(title: "Outer radius", value: $geometry.outerRadiusMm, unit: "mm")
                    LabeledContent("Sectors") {
                        TextField("", text: $sectorsText).labelsHidden().multilineTextAlignment(.trailing)
                    }
                    if family == .dvd {
                        NumberField(title: "Pitch, linear term", value: $geometry.pitchLinear)
                        NumberField(title: "Pitch, quadratic term", value: $geometry.pitchQuadratic)
                        NumberField(title: "Pitch, cubic term", value: $geometry.pitchCubic)
                    }
                    if family == .bd {
                        Toggle("Swap 3T/6T assignment", isOn: $invert)
                    }
                }
                Section("Save these values as a preset") {
                    HStack {
                        TextField("Preset name", text: $presetName)
                        Button("Save Preset") {
                            let name = presetName
                            presetName = ""
                            Task { await app.saveCurrentGeometryAsPreset(name: name) }
                        }
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty || app.isDirty)
                    }
                    if app.isDirty {
                        Text("Save the project first. Presets are made from its saved geometry.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 500)
        .onAppear {
            guard let project = app.project else { return }
            geometry = project.geometry
            sectorsText = String(project.geometry.sectors)
            invert = project.bluRay?.invertMapping ?? false
        }
    }

    private func apply() {
        guard var document = app.project else { return }
        guard let sectors = Int64(sectorsText.trimmingCharacters(in: .whitespaces)) else {
            error = "Sectors must be a whole number."
            return
        }
        var updated = geometry
        updated.sectors = sectors
        document.geometry = updated
        if family == .bd { document.bluRay = ProjectBluRaySettings(invertMapping: invert) }
        Task {
            do {
                // The engine's own rules decide what's valid, as they would on opening the file.
                try await app.check(document)
                app.updateProject(recompose: true) { $0 = document }
                dismiss()
            } catch {
                self.error = app.text.translate(error.localizedDescription)
            }
        }
    }
}
