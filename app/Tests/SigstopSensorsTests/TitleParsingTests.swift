import Foundation
import Testing

@testable import SigstopSensors

struct TitleParsingTests {

    @Test("an editor title gives the file and the folder")
    func ordinaryTitles() {
        let parsed = TitleParsing.fileFirst("AppModel.swift — sigstop — Visual Studio Code")
        #expect(parsed?.fileName == "AppModel.swift")
        #expect(parsed?.projectName == "sigstop")

        let remote = TitleParsing.fileFirst("main.go — payments [SSH: prod-db-01.corp.example] — Visual Studio Code")
        #expect(remote?.projectName == "payments")

        let welcome = TitleParsing.fileFirst("Welcome — acme-web — Visual Studio Code")
        #expect(welcome?.projectName == "acme-web")
    }

    @Test("the first line of an untitled buffer is never taken for a project")
    func untitledBufferIsNotAProject() {
        let secret = TitleParsing.fileFirst("● postgres://admin:S3cr3t@db.prod.int • Untitled-1 — Visual Studio Code")
        #expect(secret?.projectName == nil)

        let prose = TitleParsing.fileFirst("● Dear Sam, the acquisition closes Fri • Untitled-1 — acme-web — Visual Studio Code")
        #expect(prose?.projectName == "acme-web")

        let alone = TitleParsing.fileFirst("Dear Sam the deal closes Friday — Visual Studio Code")
        #expect(alone?.projectName == nil, "one component with no file is a buffer's text as often as a folder")
    }

    @Test("a component that looks like a URL, an address or an assignment is not a project")
    func implausibleProjects() {
        for bad in ["https://example.com", "me@example.com", "TOKEN=abc123", String(repeating: "x", count: 61)] {
            #expect(TitleParsing.plausibleProject(bad) == nil, "\(bad)")
        }
        #expect(TitleParsing.plausibleProject("sigstop-web") == "sigstop-web")
    }
}
