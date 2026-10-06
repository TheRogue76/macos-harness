import HarnessProtocol

extension CallerInfo {
    public init(_ identity: CallerIdentity, paired: Bool) {
        self.init(
            displayName: identity.displayName,
            identityKey: identity.key,
            paired: paired,
            chain: identity.chain.map(\.summary)
        )
    }
}
