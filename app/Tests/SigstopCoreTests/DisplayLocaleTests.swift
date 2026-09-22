import Foundation
import Testing

@testable import SigstopCore

@Suite("English text, Latin digits, the user's clock")
struct DisplayLocaleTests {

    private static let quarterPastThree = Date(timeIntervalSince1970: 1_758_554_100)

    private func render(_ identifier: String) -> (number: String, time: String) {
        let locale = DisplayLocale.english(from: Locale(identifier: identifier))
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return (45.formatted(.number.locale(locale)), Self.quarterPastThree.formatted(style))
    }

    private func onlyLatinDigits(_ text: String) -> Bool {
        text.allSatisfy { !$0.isNumber || ("0"..."9").contains($0) }
    }

    @Test("an Arabic, Persian or Thai Mac gets Latin digits", arguments: ["ar_EG", "ar_SA", "fa_IR", "th_TH"])
    func latinDigits(_ identifier: String) {
        let out = render(identifier)
        #expect(out.number == "45", "\(identifier) number: \(out.number)")
        #expect(onlyLatinDigits(out.time), "\(identifier) time: \(out.time)")
    }

    @Test("a 24-hour region keeps its 24-hour clock", arguments: ["en_GB", "de_DE", "fa_IR"])
    func twentyFourHour(_ identifier: String) {
        #expect(render(identifier).time.hasPrefix("15:15"), "\(identifier): \(render(identifier).time)")
    }

    @Test("a 12-hour region keeps its 12-hour clock", arguments: ["en_US", "ar_EG"])
    func twelveHour(_ identifier: String) {
        let time = render(identifier).time
        #expect(time.hasPrefix("3:15") && time.contains("PM"), "\(identifier): \(time)")
    }

    @Test("a clock the user forced to 24 hours stays forced")
    func forcedCycleSurvives() {
        #expect(render("en_US@hours=h23").time.hasPrefix("15:15"))
        #expect(render("ar_EG@hours=h23").time.hasPrefix("15:15"))
    }
}
