import CoreGraphics
import Foundation
import HarnessProtocol

/// Where a node sits in an Android screen dump, which is how a ref finds it again in the next dump.
public struct AndroidKey: Hashable, Sendable {
    public var serial: String
    /// Child indexes from the root, e.g. `0.0.2.1`.
    public var path: String
    public var className: String
    public var resourceID: String
    /// The text or description: lists reuse their rows, so a row at the same place with other
    /// text is another element.
    public var label: String = ""
}

/// Reads `uiautomator dump` XML into raw nodes, with Android classes shown as the roles the
/// harness uses everywhere (a `Button` is a button, an `EditText` a text field).
public enum AndroidTree {
    /// The subrole of the root node, which stands for the whole screen.
    public static let screenSubrole = "AndroidScreen"

    static let roles: [String: String] = [
        "Button": "AXButton", "ImageButton": "AXButton", "MaterialButton": "AXButton", "FloatingActionButton": "AXButton",
        "EditText": "AXTextField", "AutoCompleteTextView": "AXTextField", "TextInputEditText": "AXTextField",
        "TextView": "AXStaticText", "CheckedTextView": "AXCheckBox",
        "CheckBox": "AXCheckBox", "Switch": "AXCheckBox", "SwitchCompat": "AXCheckBox", "ToggleButton": "AXCheckBox",
        "SwitchMaterial": "AXCheckBox", "MaterialSwitch": "AXCheckBox", "RadioButton": "AXRadioButton",
        "ImageView": "AXImage", "SeekBar": "AXSlider", "RatingBar": "AXSlider", "ProgressBar": "AXProgressIndicator",
        "Spinner": "AXPopUpButton", "WebView": "AXWebArea", "TabWidget": "AXTabGroup",
        "ScrollView": "AXScrollArea", "HorizontalScrollView": "AXScrollArea", "NestedScrollView": "AXScrollArea",
        "RecyclerView": "AXList", "ListView": "AXList", "GridView": "AXList", "ViewPager": "AXGroup",
    ]

    /// The tree of a dump, its root standing for a screen of `size` pixels.
    public static func parse(_ xml: Data, serial: String, size: CGSize) throws -> RawNode {
        let builder = Builder(serial: serial)
        let parser = XMLParser(data: xml)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw RPCError(code: RPCErrorCode.failed, message: "The Android screen dump couldn't be read: \(parser.parserError?.localizedDescription ?? "no hierarchy").")
        }
        var screen = root
        screen.frame = CGRect(origin: .zero, size: size)
        return screen
    }

    /// The raw node for one `<node>` element's attributes.
    static func node(_ attributes: [String: String], key: AndroidKey) -> RawNode {
        let className = attributes["class"] ?? ""
        let short = className.split(separator: ".").last.map(String.init) ?? className
        let text = attributes["text"].flatMap { $0.isEmpty ? nil : $0 }
        let description = attributes["content-desc"].flatMap { $0.isEmpty ? nil : $0 }
        let hint = attributes["hint"].flatMap { $0.isEmpty ? nil : $0 }
        let flag = { (name: String) in attributes[name] == "true" }
        let checkable = flag("checkable")
        let clickable = flag("clickable")

        var role = roles[short] ?? (short.contains("Switch") ? "AXCheckBox" : short.contains("Button") ? "AXButton" : nil)
            ?? (checkable ? "AXCheckBox" : nil)
            ?? (clickable && (text != nil || description != nil) ? "AXButton" : nil)
            ?? (text != nil ? "AXStaticText" : "AXGroup")
        if role == "AXStaticText", clickable { role = "AXButton" }
        var subrole: String? = short.contains("Switch") ? "AXSwitch" : nil
        if flag("password") { subrole = "AXSecureTextField" }

        let isText = role == "AXStaticText"
        let isField = role == "AXTextField"
        var actions: [String] = []
        if clickable || checkable { actions.append("AXPress") }
        if flag("long-clickable") { actions.append("long-press") }
        if flag("scrollable") { actions.append("scroll") }

        let value: String?
        if checkable {
            value = flag("checked") ? "1" : "0"
        } else if isField {
            value = text == hint ? nil : text
        } else if isText {
            value = text ?? description
        } else {
            value = nil
        }
        let title: String? = isText ? nil : (description ?? (isField ? nil : text))
        var resourceID = attributes["resource-id"] ?? ""
        if role == "AXGroup", !clickable, !flag("scrollable"), !flag("long-clickable"), description == nil, text == nil {
            resourceID = ""
        }
        return RawNode(
            element: nil, key: AnyHashable(key), role: role, subrole: subrole, title: title, details: nil,
            placeholder: hint, value: value, identifier: shortID(resourceID), enabled: attributes["enabled"].map { $0 == "true" },
            focused: flag("focused"), selected: flag("selected"), actions: actions, frame: bounds(attributes["bounds"]), children: []
        )
    }

    /// `tap_button` for `com.example:id/tap_button`.
    static func shortID(_ resourceID: String) -> String? {
        guard !resourceID.isEmpty else { return nil }
        if let range = resourceID.range(of: ":id/") { return String(resourceID[range.upperBound...]) }
        return resourceID
    }

    /// A rectangle from `[x1,y1][x2,y2]`.
    static func bounds(_ text: String?) -> CGRect? {
        guard let text else { return nil }
        let numbers = text.split { !"0123456789-".contains($0) }.compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }

    /// Builds the tree while the parser walks the XML.
    final class Builder: NSObject, XMLParserDelegate {
        let serial: String
        var root: RawNode?
        private var stack: [(node: RawNode, path: String)] = []

        init(serial: String) {
            self.serial = serial
        }

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            switch name {
            case "hierarchy":
                let key = AndroidKey(serial: serial, path: "", className: "hierarchy", resourceID: "")
                let screen = RawNode(element: nil, key: AnyHashable(key), role: "AXGroup", subrole: AndroidTree.screenSubrole)
                stack.append((screen, ""))
            case "node":
                let parentPath = stack.last?.path ?? ""
                let index = stack.last?.node.children.count ?? 0
                let path = parentPath.isEmpty ? "\(index)" : "\(parentPath).\(index)"
                let resourceID = attributes["resource-id"] ?? ""
                let label = attributes["text"].flatMap { $0.isEmpty ? nil : $0 } ?? attributes["content-desc"] ?? ""
                let key = AndroidKey(serial: serial, path: path, className: attributes["class"] ?? "", resourceID: resourceID, label: label)
                stack.append((AndroidTree.node(attributes, key: key), path))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "node" || name == "hierarchy", let finished = stack.popLast() else { return }
            if stack.isEmpty {
                root = finished.node
            } else {
                stack[stack.count - 1].node.children.append(finished.node)
            }
        }
    }
}
