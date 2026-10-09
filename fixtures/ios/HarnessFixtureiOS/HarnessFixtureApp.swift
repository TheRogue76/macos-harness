import SwiftUI

/// An iOS app with one of each kind of control, for testing macOS Harness against the simulator.
@main
struct HarnessFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// The fixture's main screen.
struct ContentView: View {
    @State private var taps = 0
    @State private var name = ""
    @State private var greeting = ""
    @State private var notifications = false
    @State private var volume = 50.0
    @State private var longPresses = 0
    @State private var swipes = 0
    @State private var showAlert = false
    @State private var lastItem = "none"

    var body: some View {
        NavigationStack {
            List {
                Section("Buttons") {
                    Button("Tap me") { taps += 1 }
                        .accessibilityIdentifier("tap-button")
                    Text("Taps: \(taps)")
                        .accessibilityIdentifier("tap-count")
                    Text("Last item: \(lastItem)")
                        .accessibilityIdentifier("last-item")
                }
                Section("Text") {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { greeting = "Hello, \(name)!" }
                        .accessibilityIdentifier("name-field")
                    Button("Greet") { greeting = "Hello, \(name)!" }
                        .accessibilityIdentifier("greet-button")
                    Text(greeting.isEmpty ? "No greeting yet" : greeting)
                        .accessibilityIdentifier("greeting")
                }
                Section("Controls") {
                    Toggle("Notifications", isOn: $notifications)
                        .accessibilityIdentifier("notifications-toggle")
                    Slider(value: $volume, in: 0...100, step: 10) { Text("Volume") }
                        .accessibilityIdentifier("volume-slider")
                    Text("Volume: \(Int(volume))")
                        .accessibilityIdentifier("volume-value")
                }
                Section("Gestures") {
                    Text("Hold me")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.6) { longPresses += 1 }
                        .accessibilityIdentifier("hold-target")
                    Text("Long presses: \(longPresses)")
                        .accessibilityIdentifier("long-press-count")
                    Text("Swipe me sideways")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                            if abs(value.translation.width) > 60 { swipes += 1 }
                        })
                        .accessibilityIdentifier("swipe-target")
                    Text("Swipes: \(swipes)")
                        .accessibilityIdentifier("swipe-count")
                }
                Section("More") {
                    NavigationLink("Details") { DetailView() }
                        .accessibilityIdentifier("details-link")
                    Button("Show alert") { showAlert = true }
                        .accessibilityIdentifier("alert-button")
                }
                Section("Items") {
                    ForEach(1...40, id: \.self) { index in
                        Button("Item \(index)") { lastItem = "Item \(index)" }
                            .accessibilityIdentifier("item-\(index)")
                    }
                }
            }
            .navigationTitle("Harness Fixture")
            .alert("Hello from the fixture", isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

/// A second screen to navigate to and back from.
struct DetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Detail screen")
                .font(.title2)
                .accessibilityIdentifier("detail-title")
            Text("Go back with the Back button.")
        }
        .navigationTitle("Details")
    }
}
