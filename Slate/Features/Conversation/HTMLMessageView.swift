import SwiftUI
import WebKit

/// Renders untrusted HTML mail: no JavaScript, no persistent storage, no navigation inside the view,
/// and remote resources (images, tracking pixels, fonts, CSS) blocked by a Content-Security-Policy unless the user allows them.
struct HTMLMessageView: View {
    var html: String
    var allowRemote: Bool
    var inlineImages: [String: Data]
    var linksEnabled: Bool

    @State private var height: CGFloat = 80
    @Environment(\.colorScheme) private var colorScheme

    static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: "(?i)(src|background)\\s*=\\s*[\"']?https?:", options: .regularExpression) != nil
            || html.range(of: "(?i)url\\(\\s*['\"]?https?:", options: .regularExpression) != nil
    }

    /// Designed newsletters keep their own light canvas; simple HTML adapts to dark appearance.
    static func isStyled(_ html: String) -> Bool {
        html.range(of: "(?i)(bgcolor\\s*=|background(-color)?\\s*:|<table)", options: .regularExpression) != nil
    }

    var body: some View {
        let styled = Self.isStyled(html)
        HTMLWebView(document: Self.document(html, inlineImages: inlineImages, adaptive: !styled, allowRemote: allowRemote),
                    linksEnabled: linksEnabled, height: $height)
            .frame(height: height)
            .background(styled ? Color.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: styled && colorScheme == .dark ? 10 : 0, style: .continuous))
            .accessibilityElement(children: .contain)
    }

    static func document(_ html: String, inlineImages: [String: Data], adaptive: Bool, allowRemote: Bool) -> String {
        var body = html.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: "(?i)<meta[^>]+http-equiv[^>]*>", with: "", options: .regularExpression)
        for (cid, data) in inlineImages {
            let mime = data.starts(with: [0x89, 0x50]) ? "image/png" : (data.starts(with: [0x47, 0x49]) ? "image/gif" : "image/jpeg")
            body = body.replacingOccurrences(of: "cid:\(cid)", with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        let scheme = adaptive ? ":root{color-scheme:light dark}" : ":root{color-scheme:light}"
        // Our policy comes first and senders' own http-equiv tags are stripped above, so mail can only be more restricted.
        let csp = allowRemote
            ? "default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline' https:; font-src https: data:; media-src https: data:"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src data:"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(scheme)
        html,body{margin:0;padding:0;font:-apple-system-body;line-height:1.4;word-wrap:break-word;overflow-wrap:anywhere;-webkit-text-size-adjust:100%}
        img{max-width:100%;height:auto} table{max-width:100%!important} pre{white-space:pre-wrap}
        blockquote{margin:0 0 0 .6em;padding-left:.6em;border-left:2px solid rgba(128,128,128,.4)}
        a{color:#A9401C}\(adaptive ? " @media (prefers-color-scheme: dark){a{color:#F2A07E}}" : "")
        </style></head><body dir="auto">\(body)</body></html>
        """
    }
}

private struct HTMLWebView: UIViewRepresentable {
    var document: String
    var linksEnabled: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.dataDetectorTypes = []
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        web.allowsLinkPreview = false
        context.coordinator.observe(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        let key = document.hashValue
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        web.loadHTMLString(document, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLWebView
        var loadedKey: Int?
        private var observation: NSKeyValueObservation?

        init(_ parent: HTMLWebView) { self.parent = parent }

        func observe(_ web: WKWebView) {
            observation = web.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, change in
                guard let h = change.newValue?.height, h > 0 else { return }
                Task { @MainActor [weak self] in
                    if let self, abs(self.parent.height - h) > 1 { self.parent.height = h }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the document we loaded ourselves (about:blank base) may load in place.
            if action.navigationType == .other, action.request.url?.scheme == "about" { return .allow }
            if action.navigationType == .linkActivated, parent.linksEnabled, let url = action.request.url,
               ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                await UIApplication.shared.open(url)
            }
            return .cancel
        }
    }
}
