import Foundation

extension Double {
    /// The value with `digits` digits after a "." whatever the locale, rounded half to even as
    /// `String(format: "%.<digits>f")` prints it.
    public func fixed(_ digits: Int) -> String {
        guard isFinite else { return "\(self)" }
        let divisor = (0..<Swift.max(digits, 0)).reduce(1) { value, _ in value * 10 }
        let units = Int((Swift.abs(self) * Double(divisor)).rounded(.toNearestOrEven))
        let sign = self < 0 && units != 0 ? "-" : ""
        guard digits > 0 else { return "\(sign)\(units)" }
        let fraction = String(units % divisor)
        return "\(sign)\(units / divisor).\(String(repeating: "0", count: digits - fraction.count))\(fraction)"
    }
}
