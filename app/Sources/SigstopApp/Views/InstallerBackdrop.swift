import AppKit
import SwiftUI

struct InstallerBackdrop: View {

    static let appIcon = CGPoint(x: 165, y: 195)
    static let applicationsIcon = CGPoint(x: 435, y: 195)
    static let size = CGSize(width: 600, height: 320)

    static let paper = Color(red: 0xFB / 255, green: 0xFB / 255, blue: 0xF9 / 255)
    static let ink = Color(red: 0x17 / 255, green: 0x19 / 255, blue: 0x1C / 255)
    static let inkMuted = Color(red: 0x53 / 255, green: 0x58 / 255, blue: 0x5E / 255)
    static let accent = Color(red: 0x8A / 255, green: 0x4E / 255, blue: 0x00 / 255)

    var body: some View {
        ZStack {
            Self.paper

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    BrandMark(size: 18, fill: 0.5)
                    Text("sigstop")
                        .font(Brand.mono(15, weight: .semibold))
                        .foregroundStyle(Self.ink)
                }
                .padding(.top, 44)

                Text("Drag it onto Applications")
                    .font(Brand.mono(12.5))
                    .foregroundStyle(Self.inkMuted)
                    .padding(.top, 12)

                Spacer()
            }

            Arrow()
                .stroke(Self.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 96, height: 16)
                .position(
                    x: (Self.appIcon.x + Self.applicationsIcon.x) / 2,
                    y: Self.appIcon.y
                )
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private struct Arrow: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let midY = rect.midY
            path.move(to: CGPoint(x: rect.minX, y: midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: midY))
            let head = rect.height * 0.5
            path.move(to: CGPoint(x: rect.maxX - head, y: midY - head))
            path.addLine(to: CGPoint(x: rect.maxX, y: midY))
            path.addLine(to: CGPoint(x: rect.maxX - head, y: midY + head))
            return path
        }
    }
}

enum InstallerBackdropRenderer {

    @MainActor
    static func runAndExit(stem: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        for (suffix, scale) in [("", 2.0)] {
            let url = URL(fileURLWithPath: "\(base)\(suffix).png")
            do {
                try write(scale: scale, to: url)
                FileHandle.standardOutput.write(Data("\(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }

    @MainActor
    private static func write(scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: InstallerBackdrop())
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
