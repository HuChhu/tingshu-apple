import Foundation
import WebKit

/// 触点 1/5：WebView 嗅探级提取器（五级提取器第 5 级，契约 Sniffer）。
/// 纪律：
/// ① @MainActor + 实例强引用（WKWebView 无人引用即释放，嗅探静默失败）
/// ② WKUserScript documentStart 注入五路 hook：媒体 src 原型拦截 / loadstart 捕获 /
///    DOMContentLoaded 扫描 / XHR open / fetch（含 content-type 确认通道），
///    命中经 WKScriptMessageHandler 回传——禁 evaluateJavaScript 轮询
/// ③ 超时默认 15s；超时无媒体 URL 即失败不猜（对齐「失败要快，不硬冲」）
/// ④ 结束必 teardown：摘 messageHandler、断 navigationDelegate、清强引用，
///    防 contentController→handler→webView 引用环；单例可复用开下一场
/// ⑤ 一次只跑一个嗅探会话，并发请求抛 busy
@MainActor
final class WebViewSniffer: NSObject {
    static let shared = WebViewSniffer()

    enum SniffError: Error { case busy, badURL, timeout, pageFailed }

    private var webView: WKWebView?
    private var pending: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var candidates: [String] = []

    /// 契约：sniff(url, timeoutMs 默认 15_000) → 媒体直链。
    func sniff(url: String, timeoutMs: Int = 15_000) async throws -> String {
        guard pending == nil else { throw SniffError.busy }
        guard let target = URL(string: url),
              target.scheme == "http" || target.scheme == "https" else {
            throw SniffError.badURL
        }
        return try await withCheckedThrowingContinuation { cont in
            pending = cont
            candidates = []
            let view = makeWebView()
            webView = view                       // 强引用保命：嗅探期间不得释放
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                guard let self, self.pending != nil else { return }
                if let hit = self.bestMediaCandidate() {
                    self.finish(.success(hit))
                } else {
                    self.finish(.failure(SniffError.timeout))
                }
            }
            view.load(URLRequest(url: target))
        }
    }

    // MARK: - 会话装配与收尾

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()     // 持久存储：复用已拷入的登录态
        let uc = config.userContentController
        uc.addUserScript(WKUserScript(source: Self.hookScript,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false))
        uc.add(self, name: "tingshuSniffer")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 1), configuration: config)
        view.navigationDelegate = self
        return view
    }

    private func finish(_ result: Result<String, Error>) {
        guard let cont = pending else { return } // continuation 只 resume 一次
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        teardown()
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    private func teardown() {
        webView?.stop()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "tingshuSniffer")
        webView?.navigationDelegate = nil
        webView = nil                            // 解除强引用，单例可复用
    }

    // MARK: - 媒体 URL 判定

    /// 媒体特征：扩展名白名单（查询串不影响 pathExtension）
    private static let mediaExtensions: Set<String> =
        ["m3u8", "mp4", "mp3", "aac", "m4a", "flv", "ogg", "wav", "webm"]

    private func mediaURL(_ raw: String) -> Bool {
        guard let u = URL(string: raw) else { return false }
        return Self.mediaExtensions.contains(u.pathExtension.lowercased())
    }

    private func bestMediaCandidate() -> String? {
        candidates.first(where: { mediaURL($0) })
    }
}

// MARK: - WKScriptMessageHandler：页面 hook 命中的 URL 回传入口
extension WebViewSniffer: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "tingshuSniffer", let body = message.body as? String else { return }
        if body.hasPrefix("confirm|") {          // fetch content-type 确认的音视频流：直接收
            let u = String(body.dropFirst("confirm|".count))
            if !candidates.contains(u) { candidates.append(u) }
            finish(.success(u))
            return
        }
        guard body.hasPrefix("http") else { return }
        if candidates.contains(body) { return }  // JS 侧已去重，双保险
        candidates.append(body)
        if mediaURL(body) { finish(.success(body)) }  // 命中媒体特征即收，不等页面继续跑
    }
}

// MARK: - WKNavigationDelegate：页面失败即终局
extension WebViewSniffer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SniffError.pageFailed))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SniffError.pageFailed))
    }
}

// MARK: - 注入脚本（documentStart）
extension WebViewSniffer {
    static let hookScript = """
    (function(){
      if (window.__tingshuSnifferInstalled) return;
      window.__tingshuSnifferInstalled = true;
      var seen = {};
      var post = function(u){
        if (!u || typeof u !== 'string') return;
        if (u.indexOf('http') !== 0) return;
        if (seen[u]) return;
        seen[u] = 1;
        try { window.webkit.messageHandlers.tingshuSniffer.postMessage(u); } catch(e){}
      };
      // 1) 媒体元素 src 原型拦截（覆盖 createElement 与脚本赋值两条路）
      try {
        var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (d && d.set) {
          Object.defineProperty(HTMLMediaElement.prototype, 'src', {
            set: function(v){ post(String(v)); d.set.call(this, v); },
            get: d.get, configurable: true
          });
        }
      } catch(e){}
      // 2) loadstart 捕获：HTML 解析出的媒体元素开始加载必经（不冒泡但走捕获）
      document.addEventListener('loadstart', function(e){
        var t = e.target;
        if (t && (t.tagName === 'AUDIO' || t.tagName === 'VIDEO' || t.tagName === 'SOURCE')) {
          post(t.src || t.getAttribute('src') || '');
        }
      }, true);
      // 3) DOMContentLoaded 扫描已存在媒体元素
      document.addEventListener('DOMContentLoaded', function(){
        document.querySelectorAll('audio,video,source').forEach(function(el){
          post(el.src || el.getAttribute('src') || '');
        });
      });
      // 4) XHR open
      var open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u){ post(String(u)); return open.apply(this, arguments); };
      // 5) fetch：URL 立报 + content-type 为 audio/video 时补发 confirm| 通道
      var of = window.fetch;
      if (of) window.fetch = function(input){
        var u = typeof input === 'string' ? input : (input && input.url) || '';
        post(u);
        return of.apply(this, arguments).then(function(res){
          try {
            var ct = res && res.headers && res.headers.get ? res.headers.get('content-type') : null;
            if (ct && (ct.indexOf('audio') === 0 || ct.indexOf('video') === 0)) post('confirm|' + u);
          } catch(e){}
          return res;
        });
      };
    })();
    """
}
