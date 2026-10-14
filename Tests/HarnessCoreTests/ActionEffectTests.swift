import Foundation
import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore

struct ActionEffectTests {
    private func assess(_ step: ActionEffect.Step, via: String = "AX", changed: Bool = false, notices: [String] = [], checked: Bool = true) -> String {
        ActionEffect.assess(step: step, via: via, changed: changed, notices: notices, checked: checked).effect
    }

    @Test func aSeenChangeConfirms() {
        #expect(assess(.element(.press), changed: true) == "confirmed")
        #expect(assess(.element(.key), notices: ["windowOpened"]) == "confirmed")
        #expect(assess(.pointer(.click), via: "background click", notices: ["pixelsOnly"]) == "confirmed")
    }

    @Test func invisibleKindsOfWorkAreUnverifiable() {
        #expect(assess(.element(.key)) == "unverifiable")
        #expect(assess(.menu) == "unverifiable")
        #expect(assess(.pointer(.hover)) == "unverifiable")
        #expect(assess(.pointer(.scroll)) == "unverifiable")
        #expect(assess(.element(.scrollTo)) == "unverifiable")
        #expect(assess(.element(.press), changed: true, checked: false) == "unverifiable")
    }

    @Test func otherStepsWithoutChangesSawNone() {
        #expect(assess(.element(.press)) == "noChange")
        #expect(assess(.element(.setValue)) == "noChange")
        #expect(assess(.pointer(.click), via: "real input") == "noChange")
        #expect(assess(.pointer(.drag), via: "real input") == "noChange")
    }

    @Test func suggestionsFitTheRoute() {
        let pressed = ActionEffect.assess(step: .element(.press), via: "AX", changed: false, notices: [], checked: true)
        #expect(pressed.suggestion?.contains("`click`") == true)
        let clicked = ActionEffect.assess(step: .element(.press), via: "real input", changed: false, notices: [], checked: true)
        #expect(clicked.suggestion?.contains("--ocr") == true)
        #expect(ActionEffect.assess(step: .element(.press), via: "AX", changed: true, notices: [], checked: true).suggestion == nil)
    }

    @Test func resultsSayWhatTheEffectWas() {
        let app = AppRef(name: "Fixture", bundleIdentifier: nil, pid: 9)
        var result = ActionResult(app: app, window: nil, element: nil, performed: "pressed button “OK” (k3)", via: "AX", settledMilliseconds: 300)
        ActionEffect.judge(&result, step: .element(.press), checked: true)
        #expect(result.effect == "noChange")
        #expect(Render.action(result).contains("No change seen. The app took the press"))

        result.effect = "unverifiable"
        result.suggestion = "Take a screenshot."
        #expect(Render.action(result).contains("Can't tell from the tree whether it worked. Take a screenshot."))

        result.notices = [Notice(kind: "pixelsOnly", message: "Only the window's pixels changed; its accessibility tree shows no change.")]
        ActionEffect.judge(&result, step: .pointer(.click), checked: true)
        #expect(result.effect == "confirmed")
        #expect(!Render.action(result).contains("No visible change"))
        #expect(!Render.action(result).contains("No change seen"))
    }
}

struct PressActionTests {
    @Test func pressLikeActionsComeFirst() {
        #expect(ActionService.pressActionName(actions: ["AXShowMenu", "AXPress"], role: "AXButton") == "AXPress")
        #expect(ActionService.pressActionName(actions: ["AXOpen"], role: "AXCell") == "AXOpen")
    }

    @Test func showingAMenuOnlyPressesMenuButtons() {
        #expect(ActionService.pressActionName(actions: ["AXShowMenu"], role: "AXPopUpButton") == "AXShowMenu")
        #expect(ActionService.pressActionName(actions: ["AXShowMenu"], role: "AXMenuButton") == "AXShowMenu")
        #expect(ActionService.pressActionName(actions: ["AXShowMenu", "AXScrollToVisible"], role: "AXButton") == nil)
        #expect(ActionService.pressActionName(actions: ["AXShowMenu"], role: "AXLink") == nil)
    }
}
