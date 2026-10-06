import SwiftUI

/// A small app with predictable state for the harness's own tests.
/// Every control has an accessibility identifier; grow it as milestones need more controls.
@main
struct HarnessFixtureApp: App {
    var body: some Scene {
        WindowGroup("Harness Fixture") {
            FixtureView()
        }
        .windowResizability(.contentSize)
    }
}

struct FixtureView: View {
    @State private var count = 0
    @State private var name = ""
    @State private var enabled = false
    @State private var flavor = "Vanilla"
    @State private var volume = 0.5
    @State private var showingSheet = false

    var body: some View {
        Form {
            Section("Basics") {
                LabeledContent("Count") {
                    Text("\(count)").accessibilityIdentifier("count-value")
                }
                Button("Increment") { count += 1 }
                    .accessibilityIdentifier("increment-button")
                Button("Locked") {}
                    .disabled(true)
                    .accessibilityIdentifier("locked-button")
                TextField("Name", text: $name)
                    .accessibilityIdentifier("name-field")
                Text(name.isEmpty ? "Hello, nobody" : "Hello, \(name)")
                    .accessibilityIdentifier("greeting")
                Toggle("Enabled", isOn: $enabled)
                    .accessibilityIdentifier("enabled-toggle")
            }
            Section("Pickers") {
                Picker("Flavor", selection: $flavor) {
                    ForEach(["Vanilla", "Chocolate", "Strawberry"], id: \.self) { Text($0) }
                }
                .accessibilityIdentifier("flavor-picker")
                Slider(value: $volume) { Text("Volume") }
                    .accessibilityIdentifier("volume-slider")
                Button("Show Sheet") { showingSheet = true }
                    .accessibilityIdentifier("show-sheet-button")
            }
            Section("Rows") {
                // Taller than its frame, so most rows are scrolled out of view.
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(1...30, id: \.self) { row in
                            Text("Row \(row)").accessibilityIdentifier("row-\(row)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
                .accessibilityIdentifier("rows-scroll")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 600)
        .sheet(isPresented: $showingSheet) {
            VStack(spacing: 12) {
                Text("A sheet").font(.headline).accessibilityIdentifier("sheet-title")
                TextField("Note", text: $name).accessibilityIdentifier("sheet-field")
                Button("Done") { showingSheet = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("sheet-done-button")
            }
            .padding(24)
            .frame(width: 280)
        }
    }
}
