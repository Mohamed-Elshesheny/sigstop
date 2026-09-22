import Foundation
import SigstopCore

public enum BundleIDs {
    public static let vscode = "com.microsoft.VSCode"
    public static let vscodeInsiders = "com.microsoft.VSCodeInsiders"
    public static let vscodium = "com.vscodium"
    public static let cursor = "com.todesktop.230313mzl4w4u92"
    public static let zedPrefix = "dev.zed."
    public static let jetbrainsPrefix = "com.jetbrains."
    public static let androidStudio = "com.google.android.studio"
    public static let xcode = "com.apple.dt.Xcode"
    public static let antigravity = "com.google.antigravity"

    public static let terminal = "com.apple.Terminal"
    public static let iterm2 = "com.googlecode.iterm2"
    public static let warp = "dev.warp.Warp-Stable"
    public static let ghostty = "com.mitchellh.ghostty"
    public static let alacritty = "org.alacritty"
    public static let kitty = "net.kovidgoyal.kitty"
    public static let termius = "com.termius-dmg.mac"

    public static let chrome = "com.google.Chrome"
    public static let arc = "company.thebrowser.Browser"
    public static let safari = "com.apple.Safari"
    public static let brave = "com.brave.Browser"
    public static let firefox = "org.mozilla.firefox"
    public static let edge = "com.microsoft.edgemac"

    public static let slack = "com.tinyspeck.slackmacgap"
    public static let discord = "com.hnc.Discord"
    public static let zoom = "us.zoom.xos"
    public static let teams = "com.microsoft.teams2"
    public static let mail = "com.apple.mail"
    public static let messages = "com.apple.MobileSMS"

    public static let figma = "com.figma.Desktop"
    public static let postman = "com.postmanlabs.mac"
    public static let docker = "com.docker.docker"
    public static let dockerElectronHelper = "com.electron.dockerdesktop"
    public static let claude = "com.anthropic.claudefordesktop"
    public static let chatgpt = "com.openai.codex"
    public static let chatgptLegacy = "com.openai.chat"
    public static let gemini = "com.google.GeminiMacOS"
    public static let notion = "notion.id"
    public static let linear = "com.linear"
    public static let obsidian = "md.obsidian"

    public static let conferencing: Set<String> = [zoom, teams, slack, discord]

    public static let editors: Set<String> = [
        vscode, vscodeInsiders, vscodium, cursor, xcode, androidStudio, antigravity,
    ]
    public static let editorPrefixes: [String] = [zedPrefix, jetbrainsPrefix]
    public static let terminals: Set<String> = [terminal, iterm2, warp, ghostty, alacritty, kitty]

    public static func isEditorOrTerminal(_ app: AppIdentity) -> Bool {
        guard let id = app.bundleID else { return false }
        if editors.contains(id) || terminals.contains(id) { return true }
        return editorPrefixes.contains { id.hasPrefix($0) }
    }
}

public enum CallCapableApps {

    static let table: [(prefix: String, app: CallCapableApp)] = [
        (BundleIDs.slack, CallCapableApp(bundleID: BundleIDs.slack, name: "Slack", isConferencing: true)),
        (BundleIDs.teams, CallCapableApp(bundleID: BundleIDs.teams, name: "Microsoft Teams", isConferencing: true)),
        ("com.microsoft.vcxpc", CallCapableApp(bundleID: BundleIDs.teams, name: "Microsoft Teams", isConferencing: true)),
        ("us.zoom.", CallCapableApp(bundleID: BundleIDs.zoom, name: "Zoom", isConferencing: true)),
        (BundleIDs.discord, CallCapableApp(bundleID: BundleIDs.discord, name: "Discord", isConferencing: true)),
        (BundleIDs.chrome, CallCapableApp(bundleID: BundleIDs.chrome, name: "Google Chrome", isConferencing: false)),
        (BundleIDs.arc, CallCapableApp(bundleID: BundleIDs.arc, name: "Arc", isConferencing: false)),
        (BundleIDs.brave, CallCapableApp(bundleID: BundleIDs.brave, name: "Brave", isConferencing: false)),
        (BundleIDs.safari, CallCapableApp(bundleID: BundleIDs.safari, name: "Safari", isConferencing: false)),
        (BundleIDs.edge, CallCapableApp(bundleID: BundleIDs.edge, name: "Microsoft Edge", isConferencing: false)),
        (BundleIDs.firefox, CallCapableApp(bundleID: BundleIDs.firefox, name: "Firefox", isConferencing: false)),
    ]

    static let neverAMeetingPrefixes: [String] = [
        "com.apple.CoreSpeech",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.speech.",
        "com.apple.SpeechRecognitionCore",
        "com.apple.universalaccessd",
        "dev.sigstop.app",
    ]

    public static func match(_ bundleID: String) -> CallCapableApp? {
        var bestLength = -1
        var bestApp: CallCapableApp?
        for entry in table where bundleID.hasPrefix(entry.prefix) {
            if entry.prefix.count > bestLength {
                bestLength = entry.prefix.count
                bestApp = entry.app
            }
        }
        return bestApp
    }

    public static func isNeverAMeeting(_ bundleID: String) -> Bool {
        neverAMeetingPrefixes.contains { bundleID.hasPrefix($0) }
    }

    public static func resolve(_ bundleIDs: some Sequence<String>) -> [CallCapableApp] {
        var seen: Set<String> = []
        var out: [CallCapableApp] = []
        for id in bundleIDs.sorted() {
            guard let app = match(id), seen.insert(app.bundleID).inserted else { continue }
            out.append(app)
        }
        return out
    }
}

public struct ParsedTitle: Sendable, Hashable {
    public var projectName: String?
    public var fileName: String?
    public var fileExtension: String?

    public init(projectName: String? = nil, fileName: String? = nil, fileExtension: String? = nil) {
        self.projectName = projectName
        self.fileName = fileName
        self.fileExtension = fileExtension
    }

    public var isEmpty: Bool { projectName == nil && fileName == nil }
}

public enum TitleParsing {
    static let separators = [", ", " — ", " – ", " - ", " | "]

    static let dirtyMarkers: Set<Character> = ["●", "*", "•"]

    static let appNameSuffixes: Set<String> = [
        "visual studio code", "visual studio code - insiders", "code", "code - oss",
        "cursor", "zed", "xcode", "antigravity", "windsurf",
        "intellij idea", "webstorm", "pycharm", "goland", "clion", "rubymine",
        "phpstorm", "datagrip", "rider", "android studio",
    ]

    public static let codeExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java",
        "kt", "kts", "c", "h", "cc", "cpp", "hpp", "cxx", "m", "mm", "cs", "php", "scala",
        "sh", "zsh", "bash", "fish", "sql", "html", "htm", "css", "scss", "sass", "less",
        "vue", "svelte", "yml", "yaml", "json", "toml", "ini", "lua", "dart", "ex", "exs",
        "erl", "hs", "clj", "cljs", "r", "pl", "pm", "ps1", "gradle", "cmake", "tf",
        "proto", "graphql", "gql", "zig", "nim", "jl", "f90", "asm", "s", "mk", "bzl",
    ]

    public static let documentExtensions: Set<String> = ["md", "mdx", "rst", "adoc", "txt", "org", "tex"]

    public static func isCodeFile(_ ext: String?) -> Bool {
        guard let ext else { return false }
        return codeExtensions.contains(ext.lowercased())
    }

    public static func isDocumentFile(_ ext: String?) -> Bool {
        guard let ext else { return false }
        return documentExtensions.contains(ext.lowercased())
    }

    public static func looksLikeTestFile(_ fileName: String?) -> Bool {
        guard let name = fileName?.lowercased() else { return false }
        if name.contains(".test.") || name.contains(".spec.") { return true }
        if name.hasSuffix("_test.go") || name.hasSuffix("_test.py") || name.hasSuffix("_spec.rb") { return true }
        if name.hasPrefix("test_") && name.hasSuffix(".py") { return true }
        if name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") { return true }
        if name.hasSuffix("test.java") || name.hasSuffix("tests.cs") { return true }
        return false
    }

    public static func components(_ title: String) -> [String] {
        var parts = [title]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map(stripDirtyMarker(_:))
            .filter { !$0.isEmpty }
    }

    static func stripDirtyMarker(_ value: String) -> String {
        var result = Substring(value)
        while let first = result.first, dirtyMarkers.contains(first) || first == " " {
            result = result.dropFirst()
        }
        return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func fileComponent(_ value: String) -> (name: String, ext: String)? {
        guard !value.contains("/"), !value.contains("\\"), value.count <= 120 else { return nil }
        guard let dot = value.lastIndex(of: "."), dot != value.startIndex else { return nil }
        let ext = String(value[value.index(after: dot)...])
        guard (1...10).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return (value, ext.lowercased())
    }

    public static func droppingAppName(_ parts: [String]) -> [String] {
        guard let last = parts.last, appNameSuffixes.contains(last.lowercased()) else { return parts }
        return Array(parts.dropLast())
    }

    public static func fileFirst(_ title: String) -> ParsedTitle? {
        let parts = droppingAppName(components(title))
        guard !parts.isEmpty else { return nil }
        var parsed = ParsedTitle()
        if let first = parts.first, let file = fileComponent(first) {
            parsed.fileName = file.name
            parsed.fileExtension = file.ext
            parsed.projectName = parts.dropFirst().first
        } else {
            parsed.projectName = parts.count > 1 ? parts[1] : parts[0]
        }
        return parsed.isEmpty ? nil : parsed
    }

    public static func projectFirst(_ title: String) -> ParsedTitle? {
        let parts = droppingAppName(components(title))
        guard !parts.isEmpty else { return nil }
        var parsed = ParsedTitle()
        if let first = parts.first {
            let withoutPath = first.components(separatedBy: " [").first ?? first
            parsed.projectName = withoutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for part in parts.dropFirst() {
            if let file = fileComponent(part) {
                parsed.fileName = file.name
                parsed.fileExtension = file.ext
                break
            }
        }
        return parsed.isEmpty ? nil : parsed
    }

    public static func looksLikeDocsProject(_ projectName: String?) -> Bool {
        guard let name = projectName?.lowercased() else { return false }
        return name.contains("docs") || name.contains("documentation") || name.contains("wiki")
    }
}

public enum BrowserTitlePatterns {
    static let reviewPatterns = [
        #"Pull [Rr]equest #\d+"#,
        #"Merge request !\d+"#,
        #"\(!\d+\)"#,
        #"Files changed"#,
        #"Review changes"#,
        #"Reviewing \d+ files"#,
    ]

    static let diffPatterns = [
        #"Comparing .+ · "#,
        #"Commit .{7,40} ·"#,
        #"Changes from .+ to .+"#,
    ]

    static let meetingPatterns = [
        #"Meet - "#,
        #"\| Microsoft Teams"#,
        #"Zoom Meeting"#,
        #"Google Meet"#,
    ]

    public static let forgeHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]

    public static func isReview(_ title: String) -> Bool {
        reviewPatterns.contains { RegexCache.shared.matches($0, title) }
    }

    public static func isDiff(_ title: String) -> Bool {
        diffPatterns.contains { RegexCache.shared.matches($0, title) }
    }

    public static func isMeeting(_ title: String) -> Bool {
        meetingPatterns.contains { RegexCache.shared.matches($0, title) }
    }

    public static func isForge(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return forgeHosts.contains(bare)
    }
}

enum Ev {
    static func make(_ id: String, _ tier: SignalTier, _ logOdds: Double, _ summary: String) -> Evidence {
        Evidence(id: EvidenceID(id), tier: tier, logOdds: logOdds, summary: summary)
    }

    static func editorFrontmost(_ name: String) -> Evidence {
        make("editor.frontmost", .tier0, 1.6, "\(name) is the frontmost app")
    }
    static func terminalFrontmost(_ name: String) -> Evidence {
        make("terminal.frontmost", .tier0, 2.0, "\(name) is the frontmost app")
    }
    static func browserFrontmost(_ name: String) -> Evidence {
        make("browser.frontmost", .tier0, 1.8, "\(name) is the frontmost app")
    }
    static func communicationFrontmost(_ name: String) -> Evidence {
        make("communication.frontmost", .tier0, 2.0, "\(name) is the frontmost app")
    }
    static func notesAppFrontmost(_ name: String) -> Evidence {
        make("notes.frontmost", .tier0, 1.5, "\(name) is the frontmost app")
    }
    static func designAppFrontmost(_ name: String) -> Evidence {
        make("design.frontmost", .tier0, 1.5, "\(name) is the frontmost app")
    }
    static func genericAppFrontmost(_ name: String, _ logOdds: Double, _ what: String) -> Evidence {
        make("generic.frontmost", .tier0, logOdds, "\(name) is the frontmost app, and it is \(what)")
    }
    static func recentInput(_ seconds: TimeInterval, _ logOdds: Double = 0.7) -> Evidence {
        make("input.recent", .tier0, logOdds, "you touched the keyboard or trackpad \(Int(seconds))s ago")
    }
    static func aiAppFrontmost(_ name: String) -> Evidence {
        make("ai.frontmost", .tier0, 1.0, "\(name) is the frontmost app")
    }
    static func aiCorroborated(_ minutes: Int) -> Evidence {
        make("ai.corroborated", .tier0, 1.2, "an editor or terminal was frontmost in the last \(minutes) minutes")
    }
    static func rapidAlternation(_ count: Int) -> Evidence {
        make(
            "switching.rapid", .tier0, 0.5,
            "you bounced between apps \(count) times in the last minute, weak, and it is "
                + "treated as weak"
        )
    }

    static func titleParsed(_ file: String, _ project: String?) -> Evidence {
        let where_ = project.map { " in \($0)" } ?? ""
        return make("title.parsed", .tier1, 1.1, "the window title names a file, \(file)\(where_)")
    }
    static func titleProjectOnly(_ project: String) -> Evidence {
        make("title.project", .tier1, 0.5, "the window title names a project, \(project)")
    }
    static func codeExtension(_ ext: String) -> Evidence {
        make("title.codeExtension", .tier1, 0.9, ".\(ext) is a code file extension")
    }
    static func documentExtension(_ ext: String) -> Evidence {
        make("title.docExtension", .tier1, 2.4, ".\(ext) is a prose file, not code")
    }
    static func docsProject(_ name: String) -> Evidence {
        make("title.docsProject", .tier1, 0.7, "the project is called \(name)")
    }
    static func testFileName(_ name: String) -> Evidence {
        make("title.testFile", .tier1, 1.5, "\(name) is named like a test file")
    }
    static func editingNotRunningTests() -> Evidence {
        make(
            "title.testFileEditingCaveat", .tier1, -0.5,
            "but having a test file open is not the same as running the tests"
        )
    }
    static func documentResolved(_ name: String) -> Evidence {
        make("ax.document", .tier1, 1.3, "the editor reported an actual file path for \(name)")
    }
    static func reviewTitle() -> Evidence {
        make("browser.reviewTitle", .tier1, 2.4, "the page title looks like a pull request review")
    }
    static func diffTitle() -> Evidence {
        make("browser.diffTitle", .tier1, 1.4, "the page title looks like a commit or a diff")
    }
    static func forgeHost(_ host: String) -> Evidence {
        make("browser.forgeHost", .tier1, 0.6, "you are on \(host), which is also an issue tracker and a docs site")
    }
    static func communicationTitle() -> Evidence {
        make("communication.title", .tier1, 1.0, "the window title names a channel or a conversation")
    }

    static func tracedUnderFrontmost() -> Evidence {
        make(
            "process.traced", .tier2, 3.0,
            "a process this app started is under a debugger right now"
        )
    }
    static func tracedElsewhere() -> Evidence {
        make(
            "process.tracedElsewhere", .tier2, 1.8,
            "something on this Mac is under a debugger, though not started by this app"
        )
    }

    static func debuggerProcess(_ tool: ToolToken, childOfFrontmost: Bool) -> Evidence {
        let weight = tool == .debugserver ? 3.0 : 2.2
        let suffix = childOfFrontmost ? ", started by the app you are in" : ""
        return make("process.debugger", .tier2, weight, "\(tool.displayName) is running\(suffix)")
    }
    static func testRunnerProcess(_ tool: ToolToken, childOfFrontmost: Bool) -> Evidence {
        let suffix = childOfFrontmost ? ", started by the app you are in" : ""
        return make("process.testRunner", .tier2, 2.6, "\(tool.displayName) is running\(suffix)")
    }
    static func childOfFrontmost() -> Evidence {
        make("process.childOfFrontmost", .tier2, 0.8, "that process was started by the app you are in")
    }
    static func terminalEditorProcess(_ tool: ToolToken, childOfFrontmost: Bool) -> Evidence {
        childOfFrontmost
            ? make("process.terminalEditor", .tier2, 1.8, "\(tool.displayName) is running in this terminal")
            : make(
                "process.terminalEditorElsewhere", .tier2, 0.3,
                "\(tool.displayName) is running, but not in this terminal"
            )
    }
    static func aiCLIProcess(_ tool: ToolToken, childOfFrontmost: Bool) -> Evidence {
        childOfFrontmost
            ? make("process.aiCLI", .tier2, 3.0, "\(tool.displayName) is running in this terminal")
            : make(
                "process.aiCLIElsewhere", .tier2, 0.4,
                "\(tool.displayName) is running, but not in this terminal"
            )
    }
    static func remoteShellProcess(_ tool: ToolToken) -> Evidence {
        make("process.remoteShell", .tier2, 0.9, "\(tool.displayName) is running in this terminal")
    }
    static func debuggerElsewhere(_ tool: ToolToken) -> Evidence {
        make(
            "process.debuggerElsewhere", .tier2, 0.3,
            "\(tool.displayName) is running, but not under the app you are in"
        )
    }
    static func repoState(_ state: RepoState) -> Evidence {
        make("git.repoState", .tier2, 0.6, "the repository is mid-\(state.rawValue)")
    }

    static func micRunning() -> Evidence {
        make("meeting.mic", .tier0, 1.8, "an audio input device is running, though we cannot tell which app has it")
    }
    static func conferencingRunning(_ name: String) -> Evidence {
        make("meeting.appRunning", .tier0, 1.0, "\(name) is running")
    }
    static func conferencingFrontmost(_ name: String) -> Evidence {
        make("meeting.appFrontmost", .tier0, 0.8, "\(name) is the app you are looking at")
    }
    static func meetingTitle(_ what: String) -> Evidence {
        make("meeting.title", .tier1, 1.6, "the window title says \(what)")
    }
}

enum EditorClassifier {
    static func verdict(
        _ signals: SignalContext,
        editorName: String,
        parse: (String) -> ParsedTitle?
    ) -> ProviderVerdict {
        var evidence: [Evidence] = [Ev.editorFrontmost(editorName)]
        var context = ActivityContext()

        if let idle = signals.input.knownIdleSeconds, idle < 60 {
            evidence.append(Ev.recentInput(idle))
        }

        var parsed: ParsedTitle?
        if let title = signals.titleIfPermitted {
            parsed = parse(title)
            if let parsed {
                context.projectName = parsed.projectName
                context.fileName = parsed.fileName
                context.fileExtension = parsed.fileExtension
                if let file = parsed.fileName {
                    evidence.append(Ev.titleParsed(file, parsed.projectName))
                } else if let project = parsed.projectName {
                    evidence.append(Ev.titleProjectOnly(project))
                }
            }
        }

        if let url = signals.documentURLIfPermitted {
            context.documentURL = url
            context.fileName = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if !ext.isEmpty { context.fileExtension = ext }
            evidence.append(Ev.documentResolved(url.lastPathComponent))
        }

        if TitleParsing.isCodeFile(context.fileExtension), let ext = context.fileExtension {
            evidence.append(Ev.codeExtension(ext))
        }

        if let git = signals.gitIfPermitted {
            context.branch = git.branch
            context.repoState = git.repoState
            if let state = git.repoState, state != .clean { evidence.append(Ev.repoState(state)) }
        }

        let processes = signals.processesIfPermitted

        if processes?.tracedUnderFrontmost == true {
            evidence.append(Ev.tracedUnderFrontmost())
            if let tool = processes?.firstMatch(in: ToolToken.debuggers) {
                evidence.append(Ev.debuggerProcess(
                    tool, childOfFrontmost: processes?.childrenOfFrontmost.contains(tool) ?? false
                ))
            }
            return ProviderVerdict(activity: .debugging, evidence: evidence, context: context)
        }

        if let tool = processes?.firstChildMatch(in: ToolToken.debuggers) {
            evidence.append(Ev.debuggerProcess(tool, childOfFrontmost: true))
            evidence.append(Ev.childOfFrontmost())
            if processes?.tracedElsewhere == true { evidence.append(Ev.tracedElsewhere()) }
            return ProviderVerdict(activity: .debugging, evidence: evidence, context: context)
        }

        let looseDebugger = processes?.firstMatch(in: ToolToken.debuggers)

        if let tool = processes?.firstChildMatch(in: ToolToken.testRunners)
            ?? processes?.firstMatch(in: ToolToken.testRunners) {
            let isChild = processes?.childrenOfFrontmost.contains(tool) ?? false
            evidence.append(Ev.testRunnerProcess(tool, childOfFrontmost: isChild))
            if isChild { evidence.append(Ev.childOfFrontmost()) }
            return ProviderVerdict(activity: .testing, evidence: evidence, context: context)
        }

        if TitleParsing.isDocumentFile(context.fileExtension), let ext = context.fileExtension {
            evidence.append(Ev.documentExtension(ext))
            if TitleParsing.looksLikeDocsProject(context.projectName), let project = context.projectName {
                evidence.append(Ev.docsProject(project))
            }
            return ProviderVerdict(activity: .documentation, evidence: evidence, context: context)
        }

        if TitleParsing.looksLikeTestFile(context.fileName), let file = context.fileName {
            evidence.append(Ev.testFileName(file))
            evidence.append(Ev.editingNotRunningTests())
            return ProviderVerdict(
                activity: .testing, evidence: evidence, context: context, maximumConfidence: 0.72
            )
        }

        if let tool = looseDebugger {
            if processes?.tracedElsewhere == true {
                evidence.append(Ev.debuggerProcess(tool, childOfFrontmost: false))
                evidence.append(Ev.tracedElsewhere())
                return ProviderVerdict(
                    activity: .debugging,
                    evidence: evidence,
                    context: context,
                    maximumConfidence: ConfidenceEngine.debuggerElsewhereCeiling
                )
            }
            evidence.append(Ev.debuggerElsewhere(tool))
        }

        let switches = signals.switchCount(within: 60)
        let alternating = switches >= 4
        let cannotSeeProcesses = processes == nil
        if alternating {
            evidence.append(Ev.rapidAlternation(switches))
        }
        return ProviderVerdict(
            activity: .coding,
            evidence: evidence,
            context: context,
            degradedFromAmbiguity: cannotSeeProcesses && alternating
        )
    }
}

public struct VSCodeProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.vscode")
    public let claims = [
        AppClaim(.bundleID(BundleIDs.vscode)),
        AppClaim(.bundleID(BundleIDs.vscodeInsiders)),
        AppClaim(.bundleID(BundleIDs.vscodium)),
        AppClaim(.executableName("Visual Studio Code")),
    ]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        EditorClassifier.verdict(context, editorName: context.frontmost.localizedName, parse: TitleParsing.fileFirst)
    }
}

public struct CursorProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.cursor")
    public let claims = [
        AppClaim(.bundleID(BundleIDs.cursor)),
        AppClaim(.executableName("Cursor")),
    ]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        var verdict = EditorClassifier.verdict(
            context, editorName: "Cursor", parse: TitleParsing.fileFirst
        )
        if let processes = context.processesIfPermitted,
           let tool = processes.firstChildMatch(in: ToolToken.aiCLIs) {
            var evidence = verdict.evidence
            evidence.append(Ev.aiCLIProcess(tool, childOfFrontmost: true))
            verdict = ProviderVerdict(
                activity: .aiCoding, evidence: evidence, context: verdict.context
            )
        }
        return verdict
    }
}

public struct ZedProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.zed")
    public let claims = [AppClaim(.bundleIDPrefix(BundleIDs.zedPrefix)), AppClaim(.executableName("Zed"))]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        EditorClassifier.verdict(context, editorName: "Zed", parse: TitleParsing.fileFirst)
    }
}

public struct JetBrainsProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.jetbrains")
    public let claims = [
        AppClaim(.bundleIDPrefix(BundleIDs.jetbrainsPrefix)),
        AppClaim(.bundleID(BundleIDs.androidStudio)),
    ]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        EditorClassifier.verdict(
            context, editorName: context.frontmost.localizedName, parse: TitleParsing.projectFirst
        )
    }
}

public struct XcodeProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.xcode")
    public let claims = [AppClaim(.bundleID(BundleIDs.xcode))]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        EditorClassifier.verdict(context, editorName: "Xcode", parse: TitleParsing.projectFirst)
    }
}

public struct TerminalProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.terminal")
    public let claims = [
        AppClaim(.bundleID(BundleIDs.terminal)),
        AppClaim(.bundleID(BundleIDs.iterm2)),
        AppClaim(.bundleID(BundleIDs.warp)),
        AppClaim(.bundleID(BundleIDs.ghostty)),
        AppClaim(.bundleID(BundleIDs.alacritty)),
        AppClaim(.bundleID(BundleIDs.kitty)),
        AppClaim(.bundleID(BundleIDs.termius)),
    ]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        let name = context.frontmost.localizedName
        var evidence: [Evidence] = [Ev.terminalFrontmost(name)]
        if let idle = context.input.knownIdleSeconds, idle < 60 {
            evidence.append(Ev.recentInput(idle, 0.6))
        }

        var activityContext = ActivityContext()
        if let git = context.gitIfPermitted {
            activityContext.branch = git.branch
            activityContext.repoState = git.repoState
            if let state = git.repoState, state != .clean { evidence.append(Ev.repoState(state)) }
        }

        guard let processes = context.processesIfPermitted else {
            return ProviderVerdict(activity: .terminalWork, evidence: evidence, context: activityContext)
        }

        if let tool = processes.firstChildMatch(in: ToolToken.aiCLIs) {
            evidence.append(Ev.aiCLIProcess(tool, childOfFrontmost: true))
            return ProviderVerdict(activity: .aiCoding, evidence: evidence, context: activityContext)
        }
        if processes.tracedUnderFrontmost {
            evidence.append(Ev.tracedUnderFrontmost())
            if let tool = processes.firstMatch(in: ToolToken.debuggers) {
                evidence.append(Ev.debuggerProcess(
                    tool, childOfFrontmost: processes.childrenOfFrontmost.contains(tool)
                ))
            }
            return ProviderVerdict(activity: .debugging, evidence: evidence, context: activityContext)
        }
        if let tool = processes.firstChildMatch(in: ToolToken.debuggers) {
            evidence.append(Ev.debuggerProcess(tool, childOfFrontmost: true))
            evidence.append(Ev.childOfFrontmost())
            if processes.tracedElsewhere { evidence.append(Ev.tracedElsewhere()) }
            return ProviderVerdict(activity: .debugging, evidence: evidence, context: activityContext)
        }
        if let tool = processes.firstMatch(in: ToolToken.debuggers), processes.tracedElsewhere {
            evidence.append(Ev.debuggerProcess(tool, childOfFrontmost: false))
            evidence.append(Ev.tracedElsewhere())
            return ProviderVerdict(
                activity: .debugging,
                evidence: evidence,
                context: activityContext,
                maximumConfidence: ConfidenceEngine.debuggerElsewhereCeiling
            )
        }
        if let tool = processes.firstChildMatch(in: ToolToken.testRunners)
            ?? processes.firstMatch(in: ToolToken.testRunners) {
            let isChild = processes.childrenOfFrontmost.contains(tool)
            evidence.append(Ev.testRunnerProcess(tool, childOfFrontmost: isChild))
            return ProviderVerdict(activity: .testing, evidence: evidence, context: activityContext)
        }
        if let tool = processes.firstChildMatch(in: ToolToken.terminalEditors) {
            evidence.append(Ev.terminalEditorProcess(tool, childOfFrontmost: true))
            return ProviderVerdict(activity: .coding, evidence: evidence, context: activityContext)
        }
        if let tool = processes.firstChildMatch(in: ToolToken.remoteShells) {
            evidence.append(Ev.remoteShellProcess(tool))
        }
        if let tool = processes.firstMatch(in: ToolToken.debuggers) {
            evidence.append(Ev.debuggerElsewhere(tool))
        }
        if let tool = processes.firstMatch(in: ToolToken.aiCLIs) {
            evidence.append(Ev.aiCLIProcess(tool, childOfFrontmost: false))
        }
        if let tool = processes.firstMatch(in: ToolToken.terminalEditors) {
            evidence.append(Ev.terminalEditorProcess(tool, childOfFrontmost: false))
        }
        return ProviderVerdict(activity: .terminalWork, evidence: evidence, context: activityContext)
    }
}

public struct BrowserProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.browser")
    public let claims = [
        AppClaim(.bundleID(BundleIDs.chrome)),
        AppClaim(.bundleID(BundleIDs.arc)),
        AppClaim(.bundleID(BundleIDs.safari)),
        AppClaim(.bundleID(BundleIDs.brave)),
        AppClaim(.bundleID(BundleIDs.firefox)),
        AppClaim(.bundleID(BundleIDs.edge)),
    ]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        let name = context.frontmost.localizedName
        var evidence: [Evidence] = [Ev.browserFrontmost(name)]
        var activityContext = ActivityContext()
        var meetingEvidence: [Evidence] = []

        if let host = context.browserHostIfPermitted {
            activityContext.browserHost = host
        }

        guard let title = context.titleIfPermitted else {
            return ProviderVerdict(activity: .browsing, evidence: evidence, context: activityContext)
        }

        if BrowserTitlePatterns.isMeeting(title) {
            meetingEvidence.append(Ev.meetingTitle("a video call"))
        }

        if BrowserTitlePatterns.isReview(title) {
            evidence.append(Ev.reviewTitle())
            if let host = activityContext.browserHost, BrowserTitlePatterns.isForge(host) {
                evidence.append(Ev.forgeHost(host))
            }
            return ProviderVerdict(
                activity: .codeReview, evidence: evidence, context: activityContext,
                concurrentHints: ConcurrentHints(meetingEvidence: meetingEvidence)
            )
        }

        if BrowserTitlePatterns.isDiff(title) {
            evidence.append(Ev.diffTitle())
            if let host = activityContext.browserHost, BrowserTitlePatterns.isForge(host) {
                evidence.append(Ev.forgeHost(host))
            }
            return ProviderVerdict(
                activity: .codeReview, evidence: evidence, context: activityContext,
                concurrentHints: ConcurrentHints(meetingEvidence: meetingEvidence)
            )
        }

        if let host = activityContext.browserHost, BrowserTitlePatterns.isForge(host) {
            evidence.append(Ev.forgeHost(host))
        }

        return ProviderVerdict(
            activity: .browsing, evidence: evidence, context: activityContext,
            concurrentHints: ConcurrentHints(meetingEvidence: meetingEvidence)
        )
    }
}

public struct CommunicationProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.communication")
    public let claims = [
        AppClaim(.bundleID(BundleIDs.slack)),
        AppClaim(.bundleID(BundleIDs.discord)),
        AppClaim(.bundleID(BundleIDs.zoom)),
        AppClaim(.bundleID(BundleIDs.teams)),
        AppClaim(.bundleID(BundleIDs.mail)),
        AppClaim(.bundleID(BundleIDs.messages)),
    ]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        let name = context.frontmost.localizedName
        var evidence: [Evidence] = [Ev.communicationFrontmost(name)]
        var meetingEvidence: [Evidence] = [Ev.conferencingFrontmost(name)]

        if let title = context.titleIfPermitted {
            if BrowserTitlePatterns.isMeeting(title) || title.caseInsensitiveCompare("Zoom Meeting") == .orderedSame {
                meetingEvidence.append(Ev.meetingTitle("a meeting is in progress"))
            } else if title.contains("#") || title.localizedCaseInsensitiveContains("DM") {
                evidence.append(Ev.communicationTitle())
            }
        }

        return ProviderVerdict(
            activity: .communication,
            evidence: evidence,
            concurrentHints: ConcurrentHints(meetingEvidence: meetingEvidence)
        )
    }
}

public struct DesignProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.design")
    public let claims = [AppClaim(.bundleID(BundleIDs.figma))]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        ProviderVerdict(activity: .browsing, evidence: [Ev.designAppFrontmost("Figma")])
    }
}

public struct APIToolProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.apitool")
    public let claims = [AppClaim(.bundleID(BundleIDs.postman))]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        var evidence = [Ev.genericAppFrontmost("Postman", 1.4, "an API client")]
        if let idle = context.input.knownIdleSeconds, idle < 60 { evidence.append(Ev.recentInput(idle, 0.5)) }
        return ProviderVerdict(activity: .coding, evidence: evidence, degradedFromAmbiguity: true)
    }
}

public struct ContainerProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.container")
    public let claims = [
        AppClaim(.bundleID(BundleIDs.docker)),
        AppClaim(.bundleID(BundleIDs.dockerElectronHelper)),
    ]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        ProviderVerdict(
            activity: .terminalWork,
            evidence: [Ev.genericAppFrontmost("Docker", 1.2, "a container manager")]
        )
    }
}

public struct AIAssistantProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.ai")
    public let claims = [
        AppClaim(.bundleID(BundleIDs.claude)),
        AppClaim(.bundleID(BundleIDs.chatgpt)),
        AppClaim(.bundleID(BundleIDs.chatgptLegacy)),
        AppClaim(.bundleID(BundleIDs.gemini)),
    ]
    public static let corroborationWindow: TimeInterval = 5 * 60

    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        let name = context.frontmost.localizedName
        var evidence: [Evidence] = [Ev.aiAppFrontmost(name)]

        let corroborated = context.wasFrontmostRecently(within: Self.corroborationWindow) { app in
            BundleIDs.isEditorOrTerminal(app)
        }
        guard corroborated else {
            return ProviderVerdict(
                activity: .unknown,
                evidence: evidence,
                maximumConfidence: 0.35
            )
        }
        evidence.append(Ev.aiCorroborated(Int(Self.corroborationWindow / 60)))
        let label = context.available.contains(.tier2) ? nil : "AI assistant"
        return ProviderVerdict(activity: .aiCoding, evidence: evidence, labelOverride: label)
    }
}

public struct NotesProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.notes")
    public let claims = [
        AppClaim(.bundleID(BundleIDs.notion)),
        AppClaim(.bundleID(BundleIDs.obsidian)),
        AppClaim(.bundleID(BundleIDs.linear)),
    ]
    public init() {}

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        let name = context.frontmost.localizedName
        let isTracker = context.frontmost.bundleID == BundleIDs.linear
        if isTracker {
            return ProviderVerdict(
                activity: .browsing,
                evidence: [Ev.genericAppFrontmost(name, 1.2, "an issue tracker")]
            )
        }
        return ProviderVerdict(
            activity: .documentation,
            evidence: [Ev.notesAppFrontmost(name)],
            maximumConfidence: 0.55
        )
    }
}

public struct GenericProvider: ActivityProvider {
    public static let identifier = ProviderID("dev.sigstop.provider.generic")
    public let claims = [AppClaim(.bundleIDRegex(".*"))]
    public var priority: Int { Int.min }
    public init() {}

    static let categories: [String: (Activity, Double, String)] = [
        "com.apple.dt.Xcode":     (.coding, 1.2, "an IDE"),
        "com.apple.TextEdit":     (.documentation, 1.0, "a text editor"),
        "com.apple.Notes":        (.documentation, 1.0, "a notes app"),
        "com.apple.finder":       (.unknown, 0.2, "the Finder"),
        "com.apple.systempreferences": (.unknown, 0.2, "System Settings"),
        "com.apple.Music":        (.unknown, 0.2, "a music player"),
        "com.spotify.client":     (.unknown, 0.2, "a music player"),
        "com.apple.Preview":      (.browsing, 0.6, "a document viewer"),
        "com.readdle.PDFExpert-Mac": (.browsing, 0.6, "a document viewer"),
        "com.github.GitHubClient": (.codeReview, 1.0, "a git client"),
        "com.sublimemerge":       (.codeReview, 1.0, "a git client"),
        "com.torusknot.SourceTreeNotMAS": (.codeReview, 1.0, "a git client"),
        "com.sequelpro.SequelPro": (.terminalWork, 1.0, "a database client"),
        "com.beekeeperstudio.desktop": (.terminalWork, 1.0, "a database client"),
        "com.mongodb.compass":    (.terminalWork, 1.0, "a database client"),
    ]

    public func observe(_ context: SignalContext) -> ProviderVerdict? {
        let name = context.frontmost.localizedName
        guard let id = context.frontmost.bundleID, let entry = Self.categories[id] else {
            return ProviderVerdict(activity: .unknown, evidence: [], maximumConfidence: 0.2)
        }
        var evidence = [Ev.genericAppFrontmost(name, entry.1, entry.2)]
        if let idle = context.input.knownIdleSeconds, idle < 60 {
            evidence.append(Ev.recentInput(idle, 0.4))
        }
        return ProviderVerdict(activity: entry.0, evidence: evidence)
    }
}

public enum BuiltinProviders {
    public static let all: [any ActivityProvider] = [
        VSCodeProvider(),
        CursorProvider(),
        ZedProvider(),
        JetBrainsProvider(),
        XcodeProvider(),
        TerminalProvider(),
        BrowserProvider(),
        CommunicationProvider(),
        DesignProvider(),
        APIToolProvider(),
        ContainerProvider(),
        AIAssistantProvider(),
        NotesProvider(),
    ]
}
