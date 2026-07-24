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

/// Small live preview of the repo's GitHub Pages site, with a button
/// to open it properly. The web view is display-only — interaction
/// belongs in the browser.
struct PagesPreviewCard: View {
    let pagesURL: String

    var body: some View {
        OpsCard(title: "Pages Site", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 8) {
                if let url = URL(string: pagesURL) {
                    PagesWebPreview(url: url)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        // Display-only: swallow scrolls/clicks.
                        .overlay { Color.clear.contentShape(Rectangle()) }
                }
                HStack {
                    Text(pagesURL).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Open") {
                        if let url = URL(string: pagesURL) { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct PagesWebPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.pageZoom = 0.5
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }
}
