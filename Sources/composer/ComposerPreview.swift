// ComposerPreview.swift — the live preview: a WKWebView on the generated page, plus the probe that
// reports what the page actually drew (the same probe the main app's tests use).

import SwiftUI
import WebKit

final class ProbeWebView: WKWebView, WKNavigationDelegate {

    var onProbe: ((String) -> Void)?
    var loadedToken = -1
    /// extra query for the URL, e.g. "t=300" to render a fixed moment
    var query: String?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")        // the page paints the sky
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func load(page: URL) {
        // Same reason the wallpaper host does this: a regenerated page keeps its path, so WebKit would
        // serve the previous HTML from its cache and the run would measure the old code.
        URLCache.shared.removeAllCachedResponses()
        var url = page
        if let query, var components = URLComponents(url: page, resolvingAgainstBaseURL: false) {
            components.query = query
            url = components.url ?? page
        }
        loadFileURL(url, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // sprites load asynchronously, so give the page a moment before asking what it drew
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.probe() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onProbe?("ERROR: load failed — \(error.localizedDescription)")
    }

    func probe() {
        evaluateJavaScript("typeof window.__lwTitleInfo === 'function' ? window.__lwTitleInfo() : ''") { [weak self] value, _ in
            guard let self else { return }
            let text = (value as? String) ?? ""
            self.evaluateJavaScript("document.title") { title, _ in
                if let title = title as? String, title.hasPrefix("LWERROR") {
                    self.onProbe?(title)
                } else {
                    self.onProbe?(text)
                }
            }
        }
    }
}

struct PreviewView: NSViewRepresentable {
    let url: URL?
    let token: Int
    var onProbe: (String) -> Void

    func makeNSView(context: Context) -> ProbeWebView {
        let view = ProbeWebView(frame: .zero, configuration: WKWebViewConfiguration())
        return view
    }

    func updateNSView(_ view: ProbeWebView, context: Context) {
        view.onProbe = onProbe
        guard let url, view.loadedToken != token else { return }
        view.loadedToken = token
        view.query = nil
        view.load(page: url)
    }
}

/// A window-sized preview that letterboxes the page on black (so the aspect is honest).
struct PreviewPane: View {
    @ObservedObject var composer: Composer

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let url = composer.previewURL {
                    PreviewView(url: url, token: composer.previewToken) { probe in
                        composer.probe = probe
                    }
                } else {
                    ProgressView("building the first preview…")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }
}
