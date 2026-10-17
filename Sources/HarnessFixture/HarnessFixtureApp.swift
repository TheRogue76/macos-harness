import AppKit
import SwiftUI

/// A small app with predictable state for the harness's own tests.
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
    @ViewBuilder private var desktopSection: some View {
        if OtherSpace.isAsked {
            Section("Desktop") {
                Text(spaceState).accessibilityIdentifier("space-state")
            }
        }
    }

    @State private var count = 0
    @State private var name = ""
    @State private var enabled = false
    @State private var flavor = "Vanilla"
    @State private var volume = 0.5
    @State private var showingSheet = false
    @State private var clickResult = "No clicks yet"
    @State private var dropped = "Nothing dropped"
    @State private var hovering = false
    @State private var contextResult = "Not chosen"
    @State private var spaceState = "Not moved"

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
            Section("Pointer") {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(height: 70)
                    .overlay(Text("Click canvas").foregroundStyle(.secondary))
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        clickResult = "Clicked at \(Int(location.x)),\(Int(location.y))"
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Click canvas")
                    .accessibilityIdentifier("click-canvas")
                Text(clickResult).accessibilityIdentifier("click-result")
                HStack {
                    Text("Drag me")
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.3)))
                        .draggable("token")
                        .accessibilityIdentifier("drag-source")
                    Spacer()
                    Text(dropped)
                        .frame(width: 160, height: 40)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])))
                        .dropDestination(for: String.self) { items, _ in
                            dropped = "Dropped: \(items.first ?? "?")"
                            return true
                        }
                        .accessibilityIdentifier("drop-target")
                }
                Text(hovering ? "Hovering: yes" : "Hovering: no")
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(hovering ? 0.3 : 0.1)))
                    .onHover { hovering = $0 }
                    .help("Hover help text")
                    .accessibilityIdentifier("hover-target")
                Text("Right-click me")
                    .contextMenu {
                        Button("Mark as done") { contextResult = "Chosen: done" }
                        Button("Mark as later") { contextResult = "Chosen: later" }
                    }
                    .accessibilityIdentifier("context-target")
                Text(contextResult).accessibilityIdentifier("context-result")
            }
            Section("Rows") {
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
            desktopSection
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 620)
        .task {
            guard OtherSpace.isAsked else { return }
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.title == "Harness Fixture" }) else { return }
            spaceState = OtherSpace.move(window) ? "Moved to another desktop" : "No other desktop"
        }
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

/// Sends the fixture's window to a desktop that isn't showing when it's launched with
/// `--other-space`, for the harness's tests of windows on other Spaces.
enum OtherSpace {
    static var isAsked: Bool { CommandLine.arguments.contains("--other-space") }

    /// Moves `window` to the first desktop on its display that isn't showing; false when there's none.
    @MainActor
    static func move(_ window: NSWindow) -> Bool {
        typealias MainConnection = @convention(c) () -> UInt32
        typealias CopySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
        typealias MoveToSpace = @convention(c) (UInt32, CFArray, UInt64) -> Void
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(handle, "CGSMainConnectionID").map({ unsafeBitCast($0, to: MainConnection.self)() }),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces").map({ unsafeBitCast($0, to: CopySpaces.self) }),
              let move = dlsym(handle, "SLSMoveWindowsToManagedSpace").map({ unsafeBitCast($0, to: MoveToSpace.self) }),
              let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return false }
        for display in displays {
            let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            let desktops = spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            if let other = desktops.first(where: { $0 != current }) {
                move(connection, [NSNumber(value: window.windowNumber)] as CFArray, other)
                return true
            }
        }
        return false
    }
}
