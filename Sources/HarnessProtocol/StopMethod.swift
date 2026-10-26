/// Stops every agent, as the stop shortcut and the menu bar's Stop All do, or resumes them.
/// Anyone may stop; only the user resumes, so agents are refused it.
public enum StopMethod: RPCMethod {
    public static let name = "stop"
    public static let requiresPairing = false

    public struct Params: Codable, Sendable {
        /// Resume instead: let every agent act again.
        public var resume: Bool

        public init(resume: Bool = false) {
            self.resume = resume
        }
    }

    public struct Result: Codable, Sendable {
        /// What happened, in a sentence.
        public var performed: String

        public init(performed: String) {
            self.performed = performed
        }
    }
}
