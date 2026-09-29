import SigstopCore
import SwiftUI

struct EyeShape: Shape {
    enum Kind: Equatable {
        case bar(height: CGFloat)
        case dash
        case arc
    }

    let kind: Kind

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .bar(let height):
            let h = rect.height * min(1, max(0.1, height))
            let frame = CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
            return Path(roundedRect: frame, cornerRadius: rect.width * 0.22, style: .continuous)
        case .dash:
            let h = rect.width * 0.45
            let frame = CGRect(
                x: rect.minX - rect.width * 0.25,
                y: rect.midY + rect.height * 0.12 - h / 2,
                width: rect.width * 1.5,
                height: h
            )
            return Path(roundedRect: frame, cornerRadius: h / 2, style: .continuous)
        case .arc:
            var path = Path()
            let y = rect.midY + rect.height * 0.15
            path.move(to: CGPoint(x: rect.minX - rect.width * 0.2, y: y))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX + rect.width * 0.2, y: y),
                control: CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.35)
            )
            return path
        }
    }
}

struct BrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height)
        )
        return path
    }
}

extension FaceMood {
    var leftEye: EyeShape.Kind {
        switch self {
        case .watching, .wink: return .bar(height: 1)
        case .eyebrow: return .bar(height: 0.8)
        case .level: return .bar(height: 0.6)
        case .welcomeBack: return .arc
        case .resting: return .dash
        }
    }

    var rightEye: EyeShape.Kind {
        switch self {
        case .watching, .eyebrow: return .bar(height: 1)
        case .level: return .bar(height: 0.6)
        case .wink, .resting: return .dash
        case .welcomeBack: return .arc
        }
    }
}

struct FaceMark: View, Equatable {
    let mood: FaceMood
    var size: CGFloat = 72

    @Environment(\.colorSchemeContrast) private var contrast

    nonisolated static func == (a: FaceMark, b: FaceMark) -> Bool {
        a.mood == b.mood && a.size == b.size
    }

    var body: some View {
        let eye = CGSize(width: size * 0.17, height: size * 0.40)
        let line = size * (contrast == .increased ? 0.075 : 0.055)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Brand.Dark.bg)
            HStack(alignment: .bottom, spacing: size * 0.16) {
                eyeView(mood.leftEye, line: line)
                    .frame(width: eye.width, height: eye.height)
                ZStack(alignment: .top) {
                    eyeView(mood.rightEye, line: line)
                        .frame(width: eye.width, height: eye.height)
                    if mood == .eyebrow {
                        BrowShape()
                            .stroke(Brand.Dark.amber, style: StrokeStyle(lineWidth: line, lineCap: .round))
                            .frame(width: eye.width * 1.5, height: eye.height * 0.14)
                            .offset(y: -eye.height * 0.34)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text(mood.spokenLabel))
    }

    @ViewBuilder
    private func eyeView(_ kind: EyeShape.Kind, line: CGFloat) -> some View {
        if kind == .arc {
            EyeShape(kind: kind)
                .stroke(Brand.Dark.amber, style: StrokeStyle(lineWidth: line, lineCap: .round))
        } else {
            EyeShape(kind: kind)
                .fill(Brand.Dark.amber)
        }
    }
}
