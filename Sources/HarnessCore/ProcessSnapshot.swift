import Foundation
import HarnessProtocol

/// What the helper knows about one process: enough to recognize an agent and to show the user.
public struct ProcessSnapshot: Sendable, Equatable {
    public var pid: pid_t
    public var parentPID: pid_t
    public var path: String
    public var arguments: [String]
    public var signingIdentifier: String?
    public var teamIdentifier: String?
    /// Organization from the signing certificate, e.g. "OpenAI, L.L.C." or "Apple".
    public var signer: String?

    public init(
        pid: pid_t, parentPID: pid_t, path: String, arguments: [String],
        signingIdentifier: String? = nil, teamIdentifier: String? = nil, signer: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.path = path
        self.arguments = arguments
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.signer = signer
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The last path component of argv[0], as the process presents it.
    public var title: String { ((arguments.first ?? "") as NSString).lastPathComponent }

    public var summary: ProcessSummary {
        ProcessSummary(
            pid: pid, name: name, path: path,
            signingIdentifier: signingIdentifier, teamIdentifier: teamIdentifier
        )
    }
}
