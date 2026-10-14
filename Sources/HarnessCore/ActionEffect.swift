import Foundation
import HarnessProtocol

/// Whether an action visibly did something, and what to try when it didn't.
enum ActionEffect {
    enum Step: Equatable {
        case element(ElementAction)
        case pointer(PointerAction)
        case menu
    }

    /// Sets the result's effect and suggestion from what it saw; `checked` is false when the
    /// result wasn't diffed.
    static func judge(_ result: inout ActionResult, step: Step, checked: Bool) {
        let changed = !result.changes.isEmpty || result.moreChanges > 0 || !(result.destination?.changes.isEmpty ?? true)
        let assessed = assess(step: step, via: result.via, changed: changed, notices: result.notices.map(\.kind), checked: checked)
        result.effect = assessed.effect
        result.suggestion = assessed.suggestion
    }

    static func assess(step: Step, via: String, changed: Bool, notices: [String], checked: Bool) -> (effect: String, suggestion: String?) {
        guard checked else { return ("unverifiable", "The result wasn't checked; take a snapshot to see it.") }
        if changed || notices.contains(where: ["windowOpened", "windowClosed", "pixelsOnly"].contains) {
            return ("confirmed", nil)
        }
        let realMouse = via == "real input"
        switch step {
        case .element(.key):
            return ("unverifiable", "Keys can do things the tree doesn't show, like saving or copying; take a screenshot if it matters. A shortcut that needs the app in front works after `window activate`, or with real=true.")
        case .menu:
            return ("unverifiable", "Menu commands can change things the tree doesn't show, like the clipboard or files; check another way if it matters.")
        case .pointer(.hover):
            return ("unverifiable", "Hover effects such as tooltips are often not in the tree; take a screenshot to see them.")
        case .element(.scrollTo), .pointer(.scroll), .pointer(.swipe):
            return ("unverifiable", "Scrolling moves elements without changing them, so the tree can't show it; `snapshot --since last` lists what came into view.")
        case .element(.press) where !realMouse:
            return ("noChange", "The app took the press but nothing visible in the window changed (elements scrolled out of view aren't compared). Look for a sheet or another window (`windows`), check it's the right element, or try `click` on it.")
        case .element(.setValue):
            return ("noChange", "The field may already hold that value, or save only when editing ends: send `key tab` or `key return`.")
        case .element(.type):
            return ("noChange", "If the text didn't appear, give the field focus first (`focus`) or type with real=true.")
        case .element(.focus):
            return ("noChange", "It may already have had focus.")
        case .element(.select):
            return ("noChange", "It may already have been selected.")
        case .element(.increment), .element(.decrement):
            return ("noChange", "It may be at its limit.")
        case .pointer(.drag):
            return ("noChange", "Nothing changed where the drag started or ended. The drop may need a longer hold (hold) or another spot; take a snapshot of the destination.")
        case .element(.press), .pointer(.click), .pointer(.doubleClick), .pointer(.rightClick), .pointer(.longPress):
            return ("noChange", "Nothing changed after clicking. Check the point with `screenshot --grid 100`, find the target with `find --ocr`, or make sure nothing covers it.")
        }
    }
}
