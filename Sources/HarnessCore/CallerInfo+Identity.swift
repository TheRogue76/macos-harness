import HarnessProtocol

extension CallerInfo {
    public init(_ identity: CallerIdentity, paired: Bool, stopped: Bool = false) {
        self.init(
            displayName: identity.displayName,
            identityKey: identity.key,
            paired: paired,
            chain: identity.chain.map(\.summary),
            stopped: stopped
        )
    }
}
