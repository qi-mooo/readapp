import SwiftUI
import WebKit

// MARK: - HTML Content View with SVG support
struct HTMLContentView: UIViewRepresentable {
    let content: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false // 禁用WebView内部滚动
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let htmlContent = generateHTML(content: content, fontSize: fontSize, lineSpacing: lineSpacing)
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }
    
    private func generateHTML(content: String, fontSize: CGFloat, lineSpacing: CGFloat) -> String {
        // 获取当前主题颜色
        let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
        let textColor = isDarkMode ? "#FFFFFF" : "#000000"
        let backgroundColor = isDarkMode ? "#000000" : "#FFFFFF"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <meta charset="UTF-8">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                body {
                    font-size: \(fontSize)px;
                    line-height: \(lineSpacing / fontSize + 1.5);
                    color: \(textColor);
                    background-color: \(backgroundColor);
                    padding: 0;
                    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                }
                p {
                    margin-bottom: 1em;
                    text-align: justify;
                    text-indent: 2em;
                }
                svg {
                    max-width: 100%;
                    height: auto;
                    display: block;
                    margin: 10px auto;
                }
                img {
                    max-width: 100%;
                    height: auto;
                    display: block;
                    margin: 10px auto;
                }
                pre {
                    white-space: pre-wrap;
                    word-wrap: break-word;
                }
                br {
                    display: block;
                    content: "";
                    margin: 0.5em 0;
                }
            </style>
        </head>
        <body>
            \(content)
        </body>
        </html>
        """
    }
}

// MARK: - Dynamic Height WebView
struct DynamicHeightWebView: UIViewRepresentable {
    let content: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    @Binding var dynamicHeight: CGFloat
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let htmlContent = generateHTML(content: content, fontSize: fontSize, lineSpacing: lineSpacing)
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }
    
    private func generateHTML(content: String, fontSize: CGFloat, lineSpacing: CGFloat) -> String {
        let isDarkMode = UITraitCollection.current.userInterfaceStyle == .dark
        let textColor = isDarkMode ? "#FFFFFF" : "#000000"
        let backgroundColor = isDarkMode ? "#000000" : "#FFFFFF"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <meta charset="UTF-8">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                body {
                    font-size: \(fontSize)px;
                    line-height: \(lineSpacing / fontSize + 1.5);
                    color: \(textColor);
                    background-color: \(backgroundColor);
                    padding: 0;
                    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
                    word-wrap: break-word;
                    overflow-wrap: break-word;
                }
                p {
                    margin-bottom: 1em;
                    text-align: justify;
                    text-indent: 2em;
                }
                svg {
                    max-width: 100%;
                    height: auto;
                    display: block;
                    margin: 10px auto;
                }
                img {
                    max-width: 100%;
                    height: auto;
                    display: block;
                    margin: 10px auto;
                }
                pre {
                    white-space: pre-wrap;
                    word-wrap: break-word;
                }
                br {
                    display: block;
                    content: "";
                    margin: 0.5em 0;
                }
            </style>
        </head>
        <body>
            \(content)
        </body>
        </html>
        """
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DynamicHeightWebView
        
        init(_ parent: DynamicHeightWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { (height, error) in
                if let height = height as? CGFloat {
                    DispatchQueue.main.async {
                        self.parent.dynamicHeight = height
                    }
                }
            }
        }
    }
}

