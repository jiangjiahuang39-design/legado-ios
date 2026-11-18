import Foundation
import JavaScriptCore
#if canImport(WebKit)
import WebKit
#endif

/// 书源 JS 里的 WebView 类函数：`java.webView`、`webViewGetSource`、`webViewGetOverrideUrl`、
/// `startBrowserAwait`（后台加载，不弹界面）。`startBrowser`、`showBrowser`、`getVerificationCode`、
/// `open`、`refreshExplore`、`reLoginView` 这类必须有界面交互的函数目前只记录日志并返回空，
/// 让书源里 `try { ... } catch` 式的探测与可选交互不至于中断主流程。
enum LegadoWebViewBridge {
    static func install(on java: JSValue?, in context: JSContext) {
        guard let java else { return }
        let run: @convention(block) (String, String, String, String, String, Double) -> Any? = {
            mode, html, url, script, regex, timeoutMs in
            let seconds = timeoutMs > 0 ? min(max(timeoutMs / 1_000, 3), 120) : 20
            let job = WebViewJob(mode: mode, html: html, url: url, script: script, regex: regex, timeout: seconds)
            guard let value = WebViewRunner.run(job) else {
                DiagnosticLog.shared.record(.error, category: "JS", message: "WebView 未返回结果（\(mode)，\(url)）")
                return nil
            }
            return value
        }
        java.setObject(run, forKeyedSubscript: "__legadoWebView" as NSString)
        context.evaluateScript(bootstrap)
    }

    private static let bootstrap = #"""
    (function () {
      var run = java.__legadoWebView;
      function s(v) { return v === null || v === undefined ? '' : String(v); }
      function result(value) { return value === undefined ? null : value; }
      function unsupported(name, detail) {
        try { java.log('[暂不支持] java.' + name + '：' + detail); } catch (e) {}
      }
      java.webView = function (html, url, js) { return result(run('html', s(html), s(url), s(js), '', 0)); };
      java.webViewGetSource = function (html, url, js, regex) {
        return result(run('source', s(html), s(url), s(js), s(regex), 0));
      };
      java.webViewGetOverrideUrl = function (html, url, js, regex) {
        return result(run('override', s(html), s(url), s(js), s(regex), 0));
      };
      java.startBrowserAwait = function (url, title) {
        var body = run('html', '', s(url), '', '', 0);
        var text = body === null || body === undefined ? '' : String(body);
        var ok = text.length > 0;
        return {
          statusCode: function () { return ok ? 200 : 0; },
          code: function () { return ok ? 200 : 0; },
          body: function () { return text; },
          header: function () { return null; },
          headers: function () { return {}; },
          isSuccessful: function () { return ok; },
          url: function () { return { toString: function () { return s(url); } }; },
          toString: function () { return text; }
        };
      };
      java.startBrowser = function (url, title) { unsupported('startBrowser', s(url)); };
      java.showBrowser = function (url) { unsupported('showBrowser', s(url)); };
      java.showReadingBrowser = function (url) { unsupported('showReadingBrowser', s(url)); };
      java.getVerificationCode = function (imageUrl) { unsupported('getVerificationCode', s(imageUrl)); return ''; };
      java.open = function (type, value) { unsupported('open', s(type) + ' ' + s(value)); };
      java.refreshExplore = function () { unsupported('refreshExplore', ''); };
      java.reLoginView = function () { unsupported('reLoginView', ''); };
      java.reUiView = function () { unsupported('reUiView', ''); };
    })();
    """#
}

private struct WebViewJob: Sendable {
    let mode: String
    let html: String
    let url: String
    let script: String
    let regex: String
    let timeout: TimeInterval
}

private final class WebViewResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var stored: String?

    var isFinished: Bool { lock.withLock { finished } }
    var value: String? { lock.withLock { stored } }

    func finish(_ result: String?) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            stored = result
        }
    }
}

private enum WebViewRunner {
    /// 在后台线程调用：把 WebView 放到主线程执行，当前线程等待结果。
    /// 若恰好在主线程调用，则用 RunLoop 空转等待，避免死锁。
    static func run(_ job: WebViewJob) -> String? {
        #if canImport(WebKit)
        let box = WebViewResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let session = WebViewSession(job: job) { value in
                box.finish(value)
                semaphore.signal()
            }
            session.start()
        }
        if Thread.isMainThread {
            let deadline = Date().addingTimeInterval(job.timeout + 3)
            while !box.isFinished, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            _ = semaphore.wait(timeout: .now() + job.timeout + 3)
        }
        return box.value
        #else
        return nil
        #endif
    }
}

#if canImport(WebKit)
@MainActor
private final class WebViewSession: NSObject, WKNavigationDelegate {
    private static var live: [ObjectIdentifier: WebViewSession] = [:]

    private let job: WebViewJob
    private let finish: @Sendable (String?) -> Void
    private var webView: WKWebView?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(job: WebViewJob, finish: @escaping @Sendable (String?) -> Void) {
        self.job = job
        self.finish = finish
        super.init()
    }

    func start() {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: WKWebViewConfiguration())
        view.navigationDelegate = self
        webView = view
        Self.live[ObjectIdentifier(self)] = self
        let seconds = job.timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.complete(nil)
        }
        if !job.html.isEmpty {
            view.loadHTMLString(job.html, baseURL: URL(string: job.url))
        } else if let url = URL(string: job.url) {
            view.load(URLRequest(url: url))
        } else {
            complete(nil)
        }
    }

    private func complete(_ value: String?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        pollTask?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        Self.live[ObjectIdentifier(self)] = nil
        finish(value)
    }

    // MARK: - 取值

    private func expression() -> String {
        switch job.mode {
        case "source":
            let pattern = Self.jsonString(job.regex)
            return """
            (function(){var re;try{re=new RegExp(\(pattern));}catch(e){return '';}
            var urls=[];
            try{performance.getEntriesByType('resource').forEach(function(e){urls.push(e.name);});}catch(e){}
            try{document.querySelectorAll('[src],[href],[data-src]').forEach(function(n){
              ['src','href','data-src','currentSrc'].forEach(function(a){
                var v=n[a]||(n.getAttribute&&n.getAttribute(a)); if(v)urls.push(String(v));});});}catch(e){}
            for(var j=0;j<urls.length;j++){if(re.test(urls[j]))return urls[j];}
            return '';})()
            """
        default:
            return job.script.isEmpty ? "document.documentElement.outerHTML" : job.script
        }
    }

    private func evaluate() {
        guard !finished, let webView else { return }
        webView.evaluateJavaScript(expression()) { [weak self] value, _ in
            guard let self, !self.finished else { return }
            if let text = Self.string(from: value), !text.isEmpty, text != "null", text != "undefined" {
                self.complete(text)
            } else {
                self.pollTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self?.evaluate()
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        if job.mode == "override" {
            // 只等待跳转命中；脚本（如有）执行一次，用来触发跳转。
            if !job.script.isEmpty { webView.evaluateJavaScript(job.script, completionHandler: nil) }
            return
        }
        // 给动态内容一点时间；有脚本/嗅探时直接取值并轮询。
        let delay: UInt64 = (job.mode == "html" && job.script.isEmpty) ? 300_000_000 : 0
        pollTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            self?.evaluate()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if job.mode == "override", !finished,
           let target = navigationAction.request.url?.absoluteString,
           let expression = try? NSRegularExpression(pattern: job.regex),
           expression.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil {
            decisionHandler(.cancel)
            complete(target)
            return
        }
        decisionHandler(.allow)
    }

    // MARK: - 工具

    private static func string(from value: Any?) -> String? {
        switch value {
        case nil, is NSNull: return nil
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let object? where JSONSerialization.isValidJSONObject(object):
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    private static func jsonString(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }
}
#endif
