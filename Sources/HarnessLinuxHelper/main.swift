import Foundation

let helper = LinuxHelper()
do {
    try helper.start()
} catch {
    FileHandle.standardError.write(Data("macos-harness-helper couldn't start: \(error)\n".utf8))
    exit(1)
}
dispatchMain()
