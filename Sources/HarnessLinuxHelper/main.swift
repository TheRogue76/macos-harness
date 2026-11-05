import Foundation
import HarnessProtocol

let helper = LinuxHelper()
do {
    try helper.start()
} catch {
    FileHandle.standardError.write(Data("\(HarnessProduct.linuxHelperName) couldn't start: \(error)\n".utf8))
    exit(1)
}
dispatchMain()
