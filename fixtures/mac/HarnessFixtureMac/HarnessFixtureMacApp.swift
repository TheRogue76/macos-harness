import SwiftUI

/// A small native Mac app built with xcodebuild, for testing `build --run` on the Mac.
@main
struct HarnessFixtureMacApp: App {
    var body: some Scene {
        WindowGroup("Harness Fixture Mac") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

/// The fixture's only window: a counter and a greeting.
struct ContentView: View {
    @State private var count = 0
    @State private var name = ""

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
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize()
    }
}
