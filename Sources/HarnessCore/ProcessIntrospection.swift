import Foundation
import HarnessProtocol

/// What the platform can tell the helper about the processes behind a connection.
public protocol ProcessIntrospection: Sendable {
    /// The pid at the other end of a connected Unix socket.
    func peerPID(ofSocket fd: Int32) -> pid_t?
    /// The process and its ancestors, nearest first.
    func chain(from pid: pid_t) -> [ProcessSnapshot]
    /// The process the platform holds responsible for `pid`, when it tracks one; for a command
    /// that detached from its parent, still its agent.
    func responsiblePID(of pid: pid_t) -> pid_t?
    /// The process's current directory.
    func workingDirectory(of pid: pid_t) -> String?
}

extension ProcessIntrospection {
    /// The agent behind a connected socket, recognized from its process ancestry.
    public func identifyPeer(_ fd: Int32) -> CallerIdentity {
        guard let peer = peerPID(ofSocket: fd) else { return AgentClassifier.identify(chain: []) }
        let chain = chain(from: peer)
        var identity = AgentClassifier.identify(chain: chain)
        if !AgentClassifier.recognized(identity), let responsible = responsiblePID(of: peer),
           !chain.contains(where: { $0.pid == responsible }) {
            let fallback = AgentClassifier.identify(chain: [chain.first].compactMap { $0 } + self.chain(from: responsible))
            if AgentClassifier.recognized(fallback) { identity = fallback }
        }
        identity.workingDirectory = identity.agentPID.flatMap(workingDirectory(of:))
        return identity
    }
}
