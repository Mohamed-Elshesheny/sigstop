import AppKit
import SigstopCore
import SwiftUI

struct PromptCardView: View {
    let request: PromptRequest
    let message: RenderedMessage
    var skipQuiet: TimeInterval = 20 * 60
    var quietAfterLast: TimeInterval = 25 * 60
    var skipArmsAfter: TimeInterval = 3
    let onTake: () -> Void
    var onSnooze: () -> Void = {}
    let onIgnore: () -> Void
    let onSkip: () -> Void

    @State private var skipArmed = false

    private static let corner = RoundedRectangle(cornerRadius: 10, style: .continuous)

    private var skipEnabled: Bool { skipArmed || skipArmsAfter <= 0 }

    private var isIncident: Bool { request.level == .incident }

    private var standsInForNotification: Bool {
        request.channel == .notification || request.channel == .notificationWithSound
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                FaceMark(mood: FaceMood(level: request.level, tone: message.tone), size: 40)
                    .equatable()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StateDot(state: isIncident ? .alert : .suspend)
                        Text(request.signal)
                            .font(Brand.mono(11, weight: .semibold))
                            .tracking(2)
                            .foregroundStyle(isIncident ? Brand.alert : Brand.Dark.amber)
                        Text("L\(request.level.rawValue)")
                            .font(Brand.mono(10))
                            .foregroundStyle(Brand.Dark.fgFaint)
                    }
                    Text("\(DurationText.short(request.continuousWork)) continuous")
                        .font(Brand.mono(10))
                        .foregroundStyle(Brand.Dark.fgFaint)
                }
                Spacer(minLength: 0)
            }

            if let title = message.title {
                Text(title)
                    .font(Brand.sans(12, weight: .semibold))
                    .foregroundStyle(Brand.Dark.fgMuted)
                    .padding(.top, 14)
            }

            Text(message.text)
                .font(Brand.sans(15, weight: .medium))
                .foregroundStyle(Brand.Dark.fg)
                .lineSpacing(3)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, message.title == nil ? 14 : 6)

            WrappingRow(spacing: 8) {
                TerminalButton("Take it", style: .filled, action: onTake)
                    .fixedSize()
                if standsInForNotification {
                    if !request.snoozeOffered.isEmpty {
                        TerminalButton("Snooze (SIGALRM)", action: onSnooze)
                            .fixedSize()
                    }
                    TerminalButton(
                        "Skip, quiet for \(DurationText.short(skipQuiet))",
                        enabled: skipEnabled,
                        action: onSkip
                    )
                    .fixedSize()
                }
                TerminalButton("Ignore it", action: onIgnore)
                    .fixedSize()
            }
            .padding(.top, 18)

            Text(PromptFooter.text(for: request, quietAfterLast: quietAfterLast))
                .font(Brand.mono(10))
                .foregroundStyle(Brand.Dark.fgFaint)
                .padding(.top, 12)
        }
        .padding(18)
        .background(Brand.bgRaised, in: Self.corner)
        .overlay(Self.corner.strokeBorder(Brand.Dark.line, lineWidth: 1))
        .task {
            guard skipArmsAfter > 0, !skipArmed else { return }
            try? await Task.sleep(for: .seconds(skipArmsAfter))
            guard !Task.isCancelled else { return }
            skipArmed = true
        }
    }
}

enum PromptFooter {
    static func text(for request: PromptRequest, quietAfterLast: TimeInterval) -> String {
        switch request.ifIgnored {
        case .anotherRung:
            return "ignore it, and it asks again in a few minutes"
        case .cooldown:
            return "ignore it, and it leaves you alone for \(DurationText.short(quietAfterLast))"
        case .quietForTheDay:
            return "ignore it, and that is the last one today: the daily cap is spent"
        }
    }
}

struct WrappingRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, within: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(subviews, within: bounds.width)
        for (view, offset) in zip(subviews, arranged.offsets) {
            view.place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(_ subviews: Subviews, within width: CGFloat) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (offsets, CGSize(width: widest, height: y + rowHeight))
    }
}
