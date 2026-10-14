import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct Steps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run several steps in one call, written like a flow's steps, and report each step and the changes they made.",
        discussion: """
        Steps are a YAML list, e.g. '[{press: {id: Seven}}, {press: {id: Multiply}}, {press: {id: Six}}, {press: {id: Equals}}]', \
        or - to read them from standard input. They run in order and stop at the first failure; each goes through the \
        same checks as its own command. Up to 64 steps. Shell, build, launch, quit, screenshot, sim and android steps \
        aren't allowed here; put those in a flow.
        """
    )

    @Argument(help: "The steps as a YAML list, or - to read them from standard input.")
    var steps: String

    @OptionGroup var target: TargetOptions

    @Option(help: "What to report afterwards: changes, snapshot or none.")
    var observe: String = Batch.Observe.changes.rawValue

    @Option(name: .customLong("max-nodes"), help: "Most elements in the snapshot.")
    var maxNodes = 250

    @OptionGroup var output: OutputOptions

    func run() throws {
        guard let observation = Batch.Observe(rawValue: observe) else {
            throw ValidationError("--observe takes \(Batch.Observe.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let text = steps == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : steps
        let flow: Flow
        do {
            flow = try Batch.flow(yaml: text, app: target.app, window: target.window)
        } catch let error as FlowError {
            throw ValidationError(error.description)
        }
        try reportingErrors(json: output.json) {
            let connection = try HarnessConnection.openAnnouncingPairing()
            let result = Batch.run(flow, observe: observation, window: target.window, maxNodes: maxNodes, caller: connection)
            if output.json {
                try Output.json(StepsReport(steps: result.flow, changes: result.changes, snapshot: result.snapshot))
            } else {
                print(Batch.render(result, observe: observation))
            }
            if !result.flow.passed { throw ExitCode.failure }
        }
    }
}

struct StepsReport: Encodable {
    var steps: FlowResult
    var changes: [UIChange]
    var snapshot: SnapshotMethod.Result?
}
