import Foundation
import Testing

@testable import SigstopCore
@testable import SigstopSensors

/// The Access pane and `--doctor` both draw `PermissionStatus.signals`. These pin the
/// shape the pane relies on: five rows, always, in one order, with only the state moving,
/// so nothing appears or disappears as switches are flipped, and a switch that is on but
/// cannot read says what is in its way rather than "off".
struct PermissionStatusTests {

    private func status(_ settings: SigstopSettings, trusted: Bool) -> PermissionStatus {
        PermissionBroker(settings: settings, trustCheck: { trusted }).status()
    }

    private var everythingOn: SigstopSettings {
        var settings = SigstopSettings.default
        settings.accessibilityEnabled = true
        settings.browserHostEnabled = true
        settings.gitContextEnabled = true
        settings.processContextEnabled = true
        settings.projectFolders = ["/tmp/repo"]
        return settings
    }

    @Test("every state draws the same five rows in the same order")
    func rowsAreStable() {
        let kinds: [PermissionStatus.Kind] = [.osFacts, .windowTitles, .browserHost, .branchName, .toolNames]
        for (settings, trusted) in [(SigstopSettings.default, false), (everythingOn, false), (everythingOn, true)] {
            let signals = status(settings, trusted: trusted).signals
            #expect(signals.map(\.kind) == kinds)
            #expect(signals.map(\.cost) == [.alwaysOn, .needsAccessibility, .needsAccessibility, .offByDefault, .offByDefault])
        }
    }

    @Test("at zero permissions everything but the OS facts is off, and nothing is held")
    func defaultsAreOffNotHeld() {
        let fresh = status(.default, trusted: false)
        #expect(fresh[.osFacts].state == .reading)
        for kind in [PermissionStatus.Kind.windowTitles, .browserHost, .branchName, .toolNames] {
            #expect(fresh[kind].state == .off, "\(kind) should be off, not held, when nothing was switched on")
        }
    }

    @Test("a switch that is on but cannot read names the obstacle")
    func heldStatesNameTheObstacle() {
        var settings = everythingOn
        settings.projectFolders = []
        let held = status(settings, trusted: false)
        #expect(held[.windowTitles].state == .held("not granted"))
        #expect(held[.browserHost].state == .held("needs window titles"))
        #expect(held[.branchName].state == .held("no project folder added"))
        #expect(held[.toolNames].state == .reading)

        let reading = status(everythingOn, trusted: true)
        #expect(reading[.windowTitles].state == .reading)
        #expect(reading[.browserHost].state == .reading)
        #expect(reading[.branchName].state == .reading)
    }

    @Test("the browser host rides on titles: on with titles off is held, not reading")
    func browserHostNeedsTitles() {
        var settings = SigstopSettings.default
        settings.browserHostEnabled = true
        #expect(status(settings, trusted: true)[.browserHost].state == .held("needs window titles"))
        settings.accessibilityEnabled = true
        #expect(status(settings, trusted: true)[.browserHost].state == .reading)
        #expect(status(settings, trusted: false)[.browserHost].state == .held("needs window titles"))
    }

    @Test("the doctor line starts with the cost and the name, and says ON or OFF")
    func doctorLinesKeepTheirShape() {
        for (settings, trusted) in [(SigstopSettings.default, false), (everythingOn, false), (everythingOn, true)] {
            let report = status(settings, trusted: trusted)
            let lines = report.explanation
            #expect(lines.count == report.signals.count)
            for (line, signal) in zip(lines, report.signals) {
                #expect(line.hasPrefix("\(signal.cost.label), \(signal.name): "))
                #expect(line.contains(": ON") || line.contains(": OFF"), Comment(rawValue: line))
                #expect(line.hasSuffix(signal.reads))
            }
        }
    }

    @Test("a held row prints as OFF in the doctor, with the reason")
    func heldPrintsAsOffWithReason() {
        var settings = SigstopSettings.default
        settings.accessibilityEnabled = true
        let line = status(settings, trusted: false)[.windowTitles].line
        #expect(line.contains(": OFF, switched on here but not granted."))
    }
}
