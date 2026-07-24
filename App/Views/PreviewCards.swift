import SwiftUI
import WebKit
import CygnusKit

// Dashboard preview cards: fastlane screenshots and the GitHub Pages
// site. Both are previews, sized as such — thumbnails are downsampled
// on load (never full-resolution NSImages; a 6.7" App Store PNG is
// ~20 MB decoded and a strip of them would blow the memory budget),
// and the web preview is one small non-interactive WKWebView.

/// Horizontal strip of fastlane screenshots. Click opens the file.
struct ScreenshotsCard: View {
    let repoRoot: URL
    let screenshots: [String]

    private static let thumbnailHeight: CGFloat = 150

    var body: some View {
        OpsCard(title: "Screenshots", systemImage: "photo.on.rectangle") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(screenshots, id: \.self) { path in
                        ScreenshotThumbnail(
                            url: repoRoot.appendingPathComponent(path),
                            height: Self.thumbnailHeight)
                    }
                }
            }
            .frame(height: Self.thumbnailHeight)
        }
    }
}

private struct ScreenshotThumbnail: View {
    let url: URL
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help(url.lastPathComponent)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: height * 0.5)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .frame(height: height)
        .task(id: url) {
            image = await Self.thumbnail(at: url, maxPixel: 2 * height)
        }
    }

    /// Downsample via ImageIO — decodes at thumbnail size, never the
    /// full bitmap.
    private static func thumbnail(at url: URL, maxPixel: CGFloat) async -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}

/// Preview of the repo's GitHub Pages site as a portrait page
/// thumbnail (letter proportions — it reads as a document, not a
/// letterboxed strip), with a button to open it properly. The web
/// view is display-only — interaction belongs in the browser.
struct PagesPreviewCard: View {
    let pagesURL: String

    var body: some View {
        OpsCard(title: "Pages Site", systemImage: "globe") {
            HStack(alignment: .top, spacing: 12) {
                if let url = URL(string: pagesURL) {
                    PageThumbnail(url: url)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(pagesURL).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                    Button("Open") {
                        if let url = URL(string: pagesURL) { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
        }
    }
}

/// A site rendered at a real desktop viewport, scaled down into a
/// portrait letter-proportioned thumbnail — the page lays out as a
/// page, then shrinks, instead of reflowing into a 160-pt viewport.
private struct PageThumbnail: View {
    let url: URL

    /// Layout viewport the site renders at.
    private static let renderWidth: CGFloat = 800
    /// Letter portrait: height = width × 11 / 8.5.
    private static let renderHeight: CGFloat = renderWidth * 11 / 8.5
    /// On-screen thumbnail width.
    private static let thumbWidth: CGFloat = 300
    private static let scale = thumbWidth / renderWidth

    var body: some View {
        PagesWebPreview(url: url)
            .frame(width: Self.renderWidth, height: Self.renderHeight)
            .scaleEffect(Self.scale, anchor: .topLeading)
            .frame(width: Self.thumbWidth,
                   height: Self.renderHeight * Self.scale,
                   alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            // Display-only: swallow scrolls/clicks.
            .overlay { Color.clear.contentShape(Rectangle()) }
            .onTapGesture { NSWorkspace.shared.open(url) }
    }
}

private struct PagesWebPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }
}
