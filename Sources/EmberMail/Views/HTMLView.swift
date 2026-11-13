import AppKit
import SwiftUI
import WebKit

/// WKWebView that hands scroll-wheel events to the enclosing SwiftUI ScrollView when it's
/// sized to fit its content (so a thread of messages scrolls as one page).
final class PassthroughWebView: WKWebView {
    var forwardsScroll = true

    override func scrollWheel(with event: NSEvent) {
        if forwardsScroll, let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Renders one email body. Locked down: page JavaScript off, strict CSP, links open in the browser.
/// Reports its content height so it can sit inside a ScrollView, and can hide quoted history.
struct MessageBodyView: NSViewRepresentable {
    let html: String
    var isPlainText: Bool
    var allowRemoteContent: Bool
    var stripQuotes: Bool = false
    @Binding var height: CGFloat
    /// Number of quoted-history blocks hidden (0 = nothing to show/hide).
    var onQuotesHidden: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()

        // Our own script runs in an isolated world, so it works even though page JS is disabled.
        let controller = config.userContentController
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "ember")
        let strip = stripQuotes && !isPlainText
        let source = """
        (function () {
          var hidden = \(strip ? QuoteStripper.htmlScript : "0");
          var post = function (msg) { try { window.webkit.messageHandlers.ember.postMessage(msg); } catch (e) {} };
          post({ quotes: hidden });
          // Height of the actual content (scrollHeight never shrinks below the view's own height).
          var report = function () {
            var body = document.body;
            if (!body) return;
            var bottom = 0;
            Array.prototype.forEach.call(body.children, function (el) {
              var r = el.getBoundingClientRect();
              if (r.height > 0 && r.bottom > bottom) bottom = r.bottom;
            });
            var cs = getComputedStyle(body);
            var h = bottom > 0
              ? bottom + window.scrollY + parseFloat(cs.paddingBottom || 0) + parseFloat(cs.marginBottom || 0) + 4
              : body.scrollHeight;
            post({ height: Math.ceil(h) });
          };
          if (window.ResizeObserver && document.body) { new ResizeObserver(report).observe(document.body); }
          window.addEventListener('load', report);
          Array.from(document.images).forEach(function (img) { img.addEventListener('load', report); });
          report();
        })();
        """
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))

        let view = PassthroughWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        context.coordinator.webView = view
        return view
    }

    func updateNSView(_ view: PassthroughWebView, context: Context) {
        context.coordinator.parent = self
        let document = Self.wrap(html, plain: isPlainText, remote: allowRemoteContent)
        guard context.coordinator.loaded != document else { return }
        context.coordinator.loaded = document
        context.coordinator.receivedHeight = false
        view.loadHTMLString(document, baseURL: nil)
        context.coordinator.startFallbackTimer()
    }

    static func dismantleNSView(_ view: PassthroughWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    static func wrap(_ body: String, plain: Bool, remote: Bool) -> String {
        let remoteSources = remote ? " https: http:" : ""
        let csp = "default-src 'none'; img-src data: cid:\(remoteSources); style-src 'unsafe-inline'\(remoteSources); font-src data:\(remoteSources); media-src data:"
        let base = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html { -webkit-text-size-adjust: 100%; }
          body { font: 14px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 16px 20px;
                 word-wrap: break-word; overflow-wrap: anywhere; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100% !important; }
          blockquote { margin: 8px 0; padding-left: 12px; border-left: 3px solid rgba(128,128,128,.35); color: #666; }
          pre { white-space: pre-wrap; font: inherit; margin: 0; }
          a { color: #d4581e; }
        </style>
        """
        if plain {
            let themed = """
            <style>
              body { color: #1d1d1f; background: transparent; }
              @media (prefers-color-scheme: dark) { body { color: #e8e6e3; } a { color: #ff9a62; } blockquote { color: #aaa; } }
            </style>
            """
            return base + themed + "<pre>\(HTMLText.fromPlainText(body))</pre>"
        }
        // HTML mail is designed for a light background: render it on white "paper".
        return base + "<style>html, body { background: #ffffff; color: #1d1d1f; }</style>" + body
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MessageBodyView
        var loaded: String?
        weak var webView: PassthroughWebView?
        var receivedHeight = false

        init(_ parent: MessageBodyView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let h = body["height"] as? Double, h > 0 {
                receivedHeight = true
                webView?.forwardsScroll = true
                let newHeight = CGFloat(ceil(h))
                if abs(newHeight - parent.height) > 1 {
                    DispatchQueue.main.async { self.parent.height = newHeight }
                }
            }
            if let q = body["quotes"] as? Int {
                DispatchQueue.main.async { self.parent.onQuotesHidden?(q) }
            }
        }

        /// If the size script never reports (shouldn't happen), fall back to a scrollable fixed height.
        func startFallbackTimer() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, !self.receivedHeight else { return }
                self.webView?.forwardsScroll = false
                if self.parent.height < 100 { self.parent.height = 520 }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
