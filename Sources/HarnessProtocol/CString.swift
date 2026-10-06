extension String {
    /// Decodes a NUL-terminated C buffer as UTF-8.
    public init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
