import Testing
@testable import HarnessCore
@testable import HarnessMac

struct MenuServiceTests {
    @Test func aDisabledItemInAFrontmostAppSaysJustThat() {
        #expect(MenuService.disabledMessage(["Edit", "Paste"], appName: "TextEdit", frontmost: true) == "Edit › Paste is disabled in TextEdit right now.")
    }

    @Test func inTheBackgroundItSaysWhyAndWhatWorksInstead() {
        let close = MenuService.disabledMessage(["File", "Close Window"], appName: "Google Chrome", frontmost: false)
        #expect(close.contains("isn't frontmost"))
        #expect(close.contains("`window close`"))
        let print = MenuService.disabledMessage(["File", "Print…"], appName: "Google Chrome", frontmost: false)
        #expect(print.contains("brought forward"))
        #expect(!print.contains("`window"))
    }

    @Test func extrasThatShowNothingPointToARealClick() {
        #expect(MenuExtras.realHint(false).contains("--real"))
        #expect(MenuExtras.realHint(true).isEmpty)
    }

    @Test func windowCommandsMapToWindowActions() {
        #expect(MenuService.windowAction(for: "Close Window") == "close")
        #expect(MenuService.windowAction(for: "Minimize") == "minimize")
        #expect(MenuService.windowAction(for: "Enter Full Screen") == "fullscreen")
        #expect(MenuService.windowAction(for: "Exit Full Screen") == "exit-fullscreen")
        #expect(MenuService.windowAction(for: "Close Tab") == nil)
    }
}
