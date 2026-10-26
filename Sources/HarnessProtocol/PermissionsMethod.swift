/// What the desktop lets the helper do, and asking for it or taking it back: Accessibility and
/// Screen Recording on macOS; on Linux, the accessibility bus and, on GNOME, the harness's Shell
/// extension and the screenshot and remote desktop portals. Granting shows the system's own
/// dialogs, which the user answers; resetting removes only what the harness was given.
public enum PermissionsMethod: RPCMethod {
    public static let name = "permissions"
    public static let requiresPairing = false

    public enum Action: String, Codable, Sendable, CaseIterable {
        case status, grant, reset
    }

    public struct Params: Codable, Sendable {
        public var action: Action
        /// One item's `id`; nil means every item.
        public var item: String?

        public init(action: Action = .status, item: String? = nil) {
            self.action = action
            self.item = item
        }
    }

    public enum State: String, Codable, Sendable {
        case granted, missing
        /// This desktop doesn't ask for it.
        case notNeeded
        /// The harness can't get it on this desktop yet.
        case unsupported
    }

    public struct Item: Codable, Sendable, Equatable {
        /// `accessibility` and `screen-recording` on macOS; `accessibility`, `windows`,
        /// `screenshots` and `input` on Linux.
        public var id: String
        public var name: String
        public var state: State
        /// What it's for, or why it's in this state.
        public var detail: String
        /// What the user will see when it's granted, said before the dialog shows.
        public var prompt: String?

        public init(id: String, name: String, state: State, detail: String, prompt: String? = nil) {
            self.id = id
            self.name = name
            self.state = state
            self.detail = detail
            self.prompt = prompt
        }
    }

    public struct Result: Codable, Sendable {
        /// Every item, as it is after the action.
        public var items: [Item]
        /// What the action did, one sentence each.
        public var performed: [String]
        /// What the user still has to do, such as logging out and back in.
        public var notices: [String]

        public init(items: [Item], performed: [String] = [], notices: [String] = []) {
            self.items = items
            self.performed = performed
            self.notices = notices
        }
    }
}
