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

    var body: some View {
        Form {
            LabeledContent("Count") {
                Text("\(count)").accessibilityIdentifier("count-value")
            }
            Button("Increment") { count += 1 }
                .accessibilityIdentifier("increment-button")
            TextField("Name", text: $name)
                .accessibilityIdentifier("name-field")
            Text(name.isEmpty ? "Hello, nobody" : "Hello, \(name)")
                .accessibilityIdentifier("greeting")
            Toggle("Enabled", isOn: $enabled)
                .accessibilityIdentifier("enabled-toggle")
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 260)
    }
}
