import AppKit
import SigstopCore
import SwiftUI

/// The backdrop of the disk image people download, drawn by the app itself.
///
/// Rendered from `Brand` rather than exported from a design tool, for the same reason the
/// badge sheet is: a picture kept in a second place drifts from the thing it is a picture
/// of, and this one would be seen before anything else in the product. The window it sits
/// behind is 600 by 400 at 1x, so this renders at 2x for the retina layer that Finder
/// picks up from the `@2x` file beside it.
///
/// Deliberately almost empty. The whole instruction is one arrow between two icons that
/// Finder draws on top, and anything else competes with the only thing the window is for.
struct InstallerBackdrop: View {

    /// Where Finder is told to put the two icons, in the window's own coordinates. The
    /// arrow is drawn between them, so the two have to agree.
    static let appIcon = CGPoint(x: 165, y: 205)
    static let applicationsIcon = CGPoint(x: 435, y: 205)
    static let size = CGSize(width: 600, height: 400)

    var body: some View {
        ZStack {
            Brand.Dark.surfaceBehindInstaller

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    BrandMark(size: 18, fill: 0.5)
                    Text("sigstop")
                        .font(Brand.mono(15, weight: .semibold))
                        .foregroundStyle(Brand.Dark.fg)
                }
                .padding(.top, 44)

                Text("Drag it across. That is the whole installer.")
                    .font(Brand.mono(11))
                    .foregroundStyle(Brand.Dark.fgMuted)
                    .padding(.top, 10)

                Spacer()

                Text("First launch needs one command. It is in the README.")
                    .font(Brand.mono(9.5))
                    .foregroundStyle(Brand.Dark.fgFaint)
                    .padding(.bottom, 26)
            }

            Arrow()
                .stroke(Brand.Dark.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 96, height: 16)
                .position(
                    x: (Self.appIcon.x + Self.applicationsIcon.x) / 2,
                    y: Self.appIcon.y
                )
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// A shaft and a head, pointing at Applications.
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

extension Brand.Dark {
    /// The disk image window is its own surface and never follows the system appearance,
    /// because Finder does not repaint a background when the theme changes.
    static let surfaceBehindInstaller = Color(red: 0x10/255, green: 0x13/255, blue: 0x17/255)
}

/// Writes the backdrop at 1x and 2x, which is the pair Finder expects.
enum InstallerBackdropRenderer {

    @MainActor
    static func runAndExit(stem: String) -> Never {
        let base = stem.hasSuffix(".png") ? String(stem.dropLast(4)) : stem
        for (suffix, scale) in [("", 1.0), ("@2x", 2.0)] {
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
