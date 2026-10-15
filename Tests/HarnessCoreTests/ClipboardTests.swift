import AppKit
import Foundation
import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore

@MainActor
struct ClipboardTests {
    private func privateBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("macos-harness-test-\(UUID().uuidString)"))
    }

    private func copy(_ text: String, html: String? = nil, concealed: Bool = false, to board: NSPasteboard) {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let html { item.setString(html, forType: .html) }
        if concealed { item.setData(Data(), forType: Clipboard.concealed) }
        board.writeObjects([item])
    }

    @Test func pastingPutsTheUsersClipboardBack() throws {
        let board = privateBoard()
        defer { board.releaseGlobally() }
        copy("the user's text", html: "<b>the user's text</b>", to: board)
        let saved = try Clipboard.save(board)
        let count = Clipboard.put("pasted by the agent", on: board)
        #expect(board.string(forType: .string) == "pasted by the agent")
        #expect(board.types?.contains(Clipboard.transient) == true)
        #expect(Clipboard.restore(saved, ifStill: count, on: board))
        #expect(board.string(forType: .string) == "the user's text")
        #expect(board.string(forType: .html) == "<b>the user's text</b>")
    }

    @Test func aClipboardChangedMeanwhileIsLeftAlone() throws {
        let board = privateBoard()
        defer { board.releaseGlobally() }
        copy("old", to: board)
        let saved = try Clipboard.save(board)
        let count = Clipboard.put("agent", on: board)
        copy("copied by the user meanwhile", to: board)
        #expect(!Clipboard.restore(saved, ifStill: count, on: board))
        #expect(board.string(forType: .string) == "copied by the user meanwhile")
    }

    @Test func concealedTextIsNotGiven() throws {
        let board = privateBoard()
        defer { board.releaseGlobally() }
        copy("hunter2", concealed: true, to: board)
        let result = try Clipboard.read(board)
        #expect(result.concealed)
        #expect(result.text == nil)
        copy("plain", to: board)
        #expect(try Clipboard.read(board).text == "plain")
    }
}

struct PasteStepTests {
    @Test func flowsPaste() throws {
        let flow = try FlowParser.parse("name: x\napp: TextEdit\nsteps:\n  - paste: { text: hello, id: body }\n  - paste: world\n")
        guard case let .act(action, selector, value, _, _) = flow.steps.first?.action else {
            Issue.record("expected an act step")
            return
        }
        #expect(action == .paste)
        #expect(selector?.identifier == "body")
        #expect(value == "hello")
    }
}
