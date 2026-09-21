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
///
/// It carried a paragraph about the first launch being blocked and it is gone. The same
/// thing is said on the release page and in the README, where someone who wants it will
/// look, and four lines of small print under a drag target is not where anybody reads.
struct InstallerBackdrop: View {

    /// Where Finder is told to put the two icons, in the window's own coordinates. The
    /// arrow is drawn between them, so the two have to agree.
    static let appIcon = CGPoint(x: 165, y: 148)
    static let applicationsIcon = CGPoint(x: 435, y: 148)
    static let size = CGSize(width: 600, height: 400)

    /// The light palette, fixed rather than resolved.
    ///
    /// Finder paints a disk image background once and never repaints it when the system
    /// theme changes, so this cannot follow the appearance the way the rest of the app
    /// does. It is the site's paper white, which is warm rather than clinical, and the
    /// accent is the dark amber the palette uses on light surfaces: the bright one is
    /// about 1.9 to 1 on white and would be the glare rather than the mark.
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

                /// The sentence that decides whether this install succeeds, and the
                /// command that ends it.
                ///
                /// Here, on the window somebody is looking at while they drag, and not
                /// only in a README they reached the app without reading. A real
                /// downloader followed every documented step, including Open Anyway, and
                /// still got nothing: an ad-hoc signed bundle carrying the quarantine
                /// attribute is sent SIGKILL before `main()`, so there is no dialog and
                /// nothing appears anywhere.
                ///
                /// Everything below the icon row, with the row and its Finder-drawn
                /// labels given a reserved band above. Finder paints those labels on top
                /// of this image and does not know it is here, so the space has to be
                /// left rather than negotiated.
                VStack(spacing: 8) {
                    Text("It will not open the first time")
                        .font(Brand.mono(13, weight: .semibold))
                        .foregroundStyle(Self.accent)

                    Text("Not broken, and not a virus. macOS blocks apps that are not signed by\na paid Apple account. Paste this in Terminal once, then open it normally.")
                        .font(Brand.mono(10.5))
                        .foregroundStyle(Self.inkMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)

                    Text("xattr -dr com.apple.quarantine /Applications/sigstop.app")
                        .font(Brand.mono(11, weight: .medium))
                        .foregroundStyle(Self.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.black.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
                        )
                        .padding(.top, 4)
                }
                .padding(.bottom, 34)
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

/// Writes one backdrop at twice the size.
///
/// Not a 1x and an `@2x` pair. Finder does not look for the `@2x` file behind a disk
/// image background, so the pair meant it scaled the small one up and the type came out
/// soft. One image at 1200 by 800 is written instead, and `dmg.sh` stamps it 144 dpi so
/// its natural size is the 600 by 400 the window actually is.
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
