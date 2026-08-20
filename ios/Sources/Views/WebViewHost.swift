import SwiftUI
import WebKit

/// Показывает уже созданный WKWebView внутри SwiftUI.
/// WebView должен жить в иерархии — иначе система душит его таймеры и JS.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
