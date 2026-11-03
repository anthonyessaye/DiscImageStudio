import AppKit
import DiscImageStudioKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare executable (swift run), the process isn't a foreground app until
        // told so, and its window wouldn't take keyboard focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DiscImageStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("Disc Image Studio", id: "main") {
            ShellView()
                .environmentObject(app)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    if app.confirmDiscardChanges() { app.showingNewProject = true }
                }
                .keyboardShortcut("n")
                Button("Open Project…") { app.openWithPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { Task { await app.save() } }
                    .keyboardShortcut("s")
                    .disabled(app.project == nil)
                Button("Save As…") { app.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(app.project == nil)
                Divider()
                Button("Close Project") { app.closeProject() }
                    .disabled(app.project == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $app.themeRaw) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                PathRow(title: "Projects folder", path: app.projectsDirectory, placeholder: "Documents/DiscImageStudio Projects",
                        choose: { if let url = FilePanels.folder(prompt: "Choose the default projects folder") { app.projectsDirectory = url.path } },
                        clear: { app.projectsDirectory = "" })
                PathRow(title: "Cache folder", path: app.cacheDirectoryOverride, placeholder: app.cacheDirectory.path,
                        choose: { if let url = FilePanels.folder(prompt: "Choose the cache folder") { app.cacheDirectoryOverride = url.path } },
                        clear: { app.cacheDirectoryOverride = "" })
                LabeledContent("Cache") {
                    Button("Clear Cache") { app.clearCache() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 340)
    }
}

/// GPL distribution requires the license and third-party notices to travel with the app.
struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Disc Image Studio for Mac").font(.title3.weight(.semibold))
            Text("Experimental Mac interface for the Disc Image Studio engine. Released under the GNU General Public License v3.0 or later, with no warranty.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(["LICENSE", "THIRD-PARTY-NOTICES.txt"], id: \.self) { name in
                    if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
                       FileManager.default.fileExists(atPath: url.path) {
                        Button(name) { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Link("Original project", destination: URL(string: "https://github.com/JiaFeiMiao-K-Cat/DiscImageStudio")!)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
