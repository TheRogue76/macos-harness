import Foundation
import HarnessProtocol

/// Turns a journal session into a flow file. Typed and set text wasn't recorded, so it becomes
/// `${text_N}` variables to fill in.
public enum FlowExporter {
    /// Methods that only read, which a replay doesn't need.
    static let reads: Set<String> = [
        SnapshotMethod.name, FindMethod.name, ScreenshotMethod.name, MenuMethod.name, AppsMethod.name,
        WindowsMethod.name, RestrictMethod.name, RecordStartMethod.name, RecordStopMethod.name, HelloMethod.name, DoctorMethod.name,
    ]

    /// The YAML for a flow that repeats the session's successful actions.
    public static func yaml(name: String, entries: [JournalEntry]) -> String {
        let actions = entries.filter { $0.error == nil && !reads.contains($0.method) }
        let apps = actions.compactMap(\.app)
        let mainApp = Dictionary(grouping: apps, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        var variables: [(name: String, length: Int)] = []
        var lines: [String] = []
        var skipped = 0
        for entry in actions {
            guard let step = step(for: entry, variables: &variables) else {
                skipped += 1
                continue
            }
            lines.append("  - \(step)")
            if let app = entry.app, app != mainApp, entry.method != LaunchMethod.name, entry.method != QuitMethod.name {
                lines.append("    app: \(quote(app))")
            }
        }

        var out = ["name: \(quote(name))"]
        if let mainApp { out.append("app: \(quote(mainApp))") }
        if !variables.isEmpty {
            out.append("vars:")
            for variable in variables {
                out.append("  \(variable.name): null  # \(variable.length) characters were typed; the journal doesn't record them")
            }
        }
        out.append("steps:")
        out += lines.isEmpty ? ["  []"] : lines
        if skipped > 0 {
            out.append("# \(skipped) action\(skipped == 1 ? "" : "s") couldn't be turned into steps (the element was only known by a ref).")
        }
        out.append("# Add `expect` steps to check the result.")
        return out.joined(separator: "\n") + "\n"
    }

    static func step(for entry: JournalEntry, variables: inout [(name: String, length: Int)]) -> String? {
        let params = entry.params
        switch entry.method {
        case LaunchMethod.name:
            guard let app = params?["app"]?.stringValue ?? entry.app else { return nil }
            let activate = params?["activate"]?.boolValue == true
            return activate ? "launch: { app: \(quote(app)), activate: true }" : "launch: \(quote(app))"
        case QuitMethod.name:
            guard let app = params?["app"]?.stringValue ?? entry.app else { return nil }
            return "quit: \(quote(app))"
        case MenuSelectMethod.name:
            let path = params?["path"]?.arrayValue?.compactMap(\.stringValue) ?? entry.value?.components(separatedBy: " › ") ?? []
            return path.isEmpty ? nil : "menu: [\(path.map(quote).joined(separator: ", "))]"
        case WindowActionMethod.name:
            guard let action = entry.action else { return nil }
            let extras = ["x", "y", "width", "height"].compactMap { key in params?[key]?.numberValue.map { "\(key): \(number($0))" } }
            return extras.isEmpty ? "window: \(action)" : "window: { action: \(action), \(extras.joined(separator: ", ")) }"
        case WaitMethod.name:
            guard let selector = selector(for: entry, params?["element"]) else { return nil }
            let gone = params?["gone"]?.boolValue == true ? ", gone: true" : ""
            return "wait: { \(selector)\(gone) }"
        case ActMethod.name:
            return act(entry, variables: &variables)
        case PointerMethod.name:
            return pointer(entry)
        default:
            return nil
        }
    }

    static func act(_ entry: JournalEntry, variables: inout [(name: String, length: Int)]) -> String? {
        let params = entry.params
        let action = entry.action ?? params?["action"]?.stringValue ?? ""
        let real = params?["real"]?.boolValue == true ? ", real: true" : ""
        let target = selector(for: entry, params?["element"])
        switch action {
        case "type", "set-value":
            variables.append(("text_\(variables.count + 1)", entry.redactedLength ?? 0))
            let text = "\"${\(variables.last!.name)}\""
            if action == "set-value" {
                guard let target else { return nil }
                return "set-value: { \(target), value: \(text) }"
            }
            return "type: { text: \(text)\(target.map { ", \($0)" } ?? "")\(real) }"
        case "key":
            guard let combo = entry.value ?? params?["value"]?.stringValue else { return nil }
            return real.isEmpty ? "key: \(quote(combo))" : "key: { combo: \(quote(combo))\(real) }"
        case "increment", "decrement":
            guard let target else { return nil }
            let count = Int(params?["count"]?.numberValue ?? 1)
            return "\(action): { \(target)\(count > 1 ? ", count: \(count)" : "") }"
        default:
            guard let target, !action.isEmpty else { return nil }
            return "\(action): { \(target) }"
        }
    }

    static func pointer(_ entry: JournalEntry) -> String? {
        let params = entry.params
        guard let action = entry.action ?? params?["action"]?.stringValue else { return nil }
        let modifiers = params?["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let modifierText = modifiers.isEmpty ? "" : ", modifiers: [\(modifiers.joined(separator: ", "))]"
        let place = selector(for: entry, params?["element"]) ?? point(params?["point"])
        switch action {
        case "drag":
            let destination = selector(for: nil, params?["to"]) ?? point(params?["toPoint"])
            guard let place, let destination else { return nil }
            return "drag: { from: { \(place) }, to: { \(destination) }\(modifierText) }"
        case "scroll":
            guard let place else { return nil }
            let dx = params?["dx"]?.numberValue ?? 0
            let dy = params?["dy"]?.numberValue ?? 0
            var amounts: [String] = []
            if dy < 0 { amounts.append("down: \(number(-dy))") }
            if dy > 0 { amounts.append("up: \(number(dy))") }
            if dx < 0 { amounts.append("right: \(number(-dx))") }
            if dx > 0 { amounts.append("left: \(number(dx))") }
            return "scroll: { \(place), \(amounts.joined(separator: ", ")) }"
        case "hover":
            guard let place else { return nil }
            return "hover: { \(place) }"
        default:
            guard let place else { return nil }
            return "\(action): { \(place)\(modifierText) }"
        }
    }

    /// The most stable way to find the element again: its identifier, then its role and exact
    /// label, then the selector the agent used (never a ref, which ends with the app).
    static func selector(for entry: JournalEntry?, _ requested: JSONValue?) -> String? {
        if let element = entry?.element {
            if let identifier = element.identifier { return "id: \(quote(identifier))" }
            if let label = element.label, !label.isEmpty {
                return "role: \(quote(Render.shortRole(element.role))), text: \(quote(label)), exact: true"
            }
        }
        let selector = (requested ?? entry?.selector.flatMap { try? JSONValue(encoding: $0) }).flatMap { try? $0.decode(as: ElementSelector.self) }
        guard let selector else { return nil }
        var parts: [String] = []
        if let identifier = selector.identifier { parts.append("id: \(quote(identifier))") }
        if let role = selector.role { parts.append("role: \(quote(role))") }
        if let text = selector.text { parts.append("text: \(quote(text))") }
        if selector.exact, selector.text != nil { parts.append("exact: true") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func point(_ value: JSONValue?) -> String? {
        guard let x = value?["x"]?.numberValue, let y = value?["y"]?.numberValue else { return nil }
        return "x: \(number(x)), y: \(number(y))"
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// A YAML double-quoted string (JSON string syntax is valid YAML).
    static func quote(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
