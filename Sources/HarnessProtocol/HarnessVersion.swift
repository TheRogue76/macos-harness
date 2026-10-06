/// Version of the CLI, helper and wire protocol. scripts/build-app.sh reads `string` for Info.plist.
public enum HarnessVersion {
    public static let string = "0.0.1"
    /// Bumped whenever a request or response shape changes incompatibly.
    public static let protocolVersion = 1
}
