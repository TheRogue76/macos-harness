import Foundation
#if canImport(os)
import os
#endif

/// The helper's diagnostic log: the unified log on macOS, standard error elsewhere.
package struct HelperLog: Sendable {
    #if canImport(os)
    private let logger: Logger
    #else
    private let category: String
    #endif

    package init(category: String) {
        #if canImport(os)
        logger = Logger(subsystem: HarnessVariant.signingIdentifierPrefix, category: category)
        #else
        self.category = category
        #endif
    }

    /// Records a routine event.
    package func info(_ message: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #else
        FileHandle.standardError.write(Data("[\(category)] \(message)\n".utf8))
        #endif
    }
}
