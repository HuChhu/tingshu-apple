import Foundation
import UIKit
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
            Self.lastPageRet = ""
            let view = makeWebView()
            webView = view                       // 强引用保命：嗅探期间不得释放
            attachToWindow(view)                 // 挂进视图层，否则 JS 定时器被节流
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

    /// 【2026-11-28】把 WKWebView 挂进 key window 的屏幕外角落。
    ///
    /// 原因：脱离视图层的 WKWebView 里 setTimeout / 网络回调会被系统节流，
    /// 而喜马会员集的地址必须靠**页面自己的 JS**去请求 play/v1/audio（签名在它那边算）。
    /// 挂上去 + alpha 0.01 既能正常跑 JS，也不影响用户看到的东西。
    private func attachToWindow(_ view: WKWebView) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let win = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.flatMap { $0.windows }.first
        guard let win else { return }
        view.frame = CGRect(x: -420, y: -420, width: 390, height: 700)
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        win.addSubview(view)
    }

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

    /// 网页播放接口最后一次返回的 ret 码（诊断用：判断网页端到底有没有权限）
    static private(set) var lastPageRet: String = ""

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
        webView?.removeFromSuperview()
        webView?.stopLoading()
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
        // 【2026-11-28】direct| = 播放接口响应体里直接挖出来的音频地址（喜马 VIP 走这条）
        // 不做扩展名校验：xmcdn 的 redirect 链末尾可能是 /1、/0 这种数字
        if body.hasPrefix("pageret|") {
            Self.lastPageRet = String(body.dropFirst("pageret|".count))
            return
        }
        if body.hasPrefix("direct|") {
            let u = String(body.dropFirst("direct|".count))
            guard u.hasPrefix("http://") || u.hasPrefix("https://") else { return }
            if !candidates.contains(u) { candidates.append(u) }
            finish(.success(u))
            return
        }
        if body.hasPrefix("confirm|") {          // fetch content-type 确认的音视频流
            let u = String(body.dropFirst("confirm|".count))
            // 安全：必须 http(s)，且必须是已知媒体扩展名，防止恶意页面塞 javascript: 或任意 URL
            guard u.hasPrefix("http://") || u.hasPrefix("https://"), mediaURL(u) else { return }
            if !candidates.contains(u) { candidates.append(u) }
            finish(.success(u))
            return
        }
        guard body.hasPrefix("http://") || body.hasPrefix("https://") else { return }
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
      // 4b) 【2026-11-28】抓「播放接口的响应体」——喜马 VIP 的地址只在这里出现。
      //     网页播放器自己算 xm-sign（浏览器指纹），我们复刻不了，但可以把它算完的结果截下来。
      //     命中后走 direct| 通道，优先级高于普通候选。
      var send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(){
        var xhr = this;
        try {
          xhr.addEventListener("load", function(){
            try {
              var ru = (xhr.responseURL || "");
              var txt = "";
              try { txt = xhr.responseText || ""; } catch(e){ return; }
              if (!txt || txt.length > 200000) return;
              // 只看播放类响应，避免误捡普通接口里的封面/头像地址
              if (ru.indexOf("/play/") < 0 && txt.indexOf("playUrl") < 0 && txt.indexOf("playPath") < 0) return;
              var re = /"(src|playUrl64|playPathAacv164|playPathAacv224|playUrl32)"\\s*:\\s*"([^"]{8,})"/;
              var m = re.exec(txt);
              if (!m || !m[2]) {
                var rr = /"ret"\\s*:\\s*(-?[0-9]+)/.exec(txt);
                if (rr) post("pageret|" + rr[1]);
              }
              if (m && m[2]) {
                var u2 = ""; try { u2 = JSON.parse(String.fromCharCode(34) + m[2] + String.fromCharCode(34)); } catch(e) { u2 = m[2]; }
                if (u2.indexOf("//") === 0) u2 = "https:" + u2;
                if (u2.indexOf("http") === 0) post("direct|" + u2);
              }
            } catch(e){}
          });
        } catch(e){}
        return send.apply(this, arguments);
      };
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
      // 6) 页面不会自己起播时，替它点一下播放键 —— 点了才会去请求 play/v1/audio
      var tries = 0;
      var poke = function(){
        tries++;
        try {
          var sels = [".play-btn", ".player-btn", "[class*=playBtn]", "[class*=play-btn]",
                      "[class*=player] [class*=play]", ".audio-player", "button[aria-label*=播放]"];
          for (var i = 0; i < sels.length; i++) {
            var el = document.querySelector(sels[i]);
            if (el && el.click) { el.click(); return; }
          }
          var au = document.querySelector("audio");
          if (au && au.play) { au.play().catch(function(){}); return; }
        } catch(e){}
      };
      document.addEventListener("DOMContentLoaded", function(){
        setTimeout(poke, 1200);
        setTimeout(poke, 3000);
      });
    })();
    """
}
