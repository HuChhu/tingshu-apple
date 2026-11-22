import Foundation
import WebKit

/// 在喜马拉雅官网里做搜索并抓结构化结果。
///
/// 为什么不用引擎直连（SharedBridge.search）：
///   引擎走 /revision/search 会返回 {"ret":200,"data":{"reason":"risk invalid","riskLevel":5}}，
///   专辑接口返回 {"ret":407,"msg":"webtk缺失"}。webtk 由页面 JS 运行时算出，
///   必须真实浏览器环境 + 登录态才有。所以这里用 WKWebView 当执行环境：
///   页面自己算 webtk、自己过风控，我们只负责读结果。
///
/// 纪律：
///   ① 主线程创建 WebView，持久 dataStore（复用登录 cookie）
///   ② 打开前把 HTTPCookieStorage 的 cookie 回灌进 WebView
///   ③ 用 WKScriptMessageHandler 收结构化 JSON，不轮询 evaluateJavaScript
///   ④ 一次一个搜索，并发抛 busy
///   ⑤ 超时 20s，超时即失败不猜
@MainActor
final class WebSearchBridge: NSObject {
    static let shared = WebSearchBridge()

    enum BridgeError: Error, LocalizedError {
        case busy, badURL, timeout, pageFailed, parseFailed
        var errorDescription: String? {
            switch self {
            case .busy: return "上一个搜索还没结束"
            case .badURL: return "搜索地址无效"
            case .timeout: return "搜索超时（30 秒）"
            case .pageFailed: return "页面加载失败"
            case .parseFailed: return "页面结构解析失败"
            }
        }
    }

    private var webView: WKWebView?
    private var pending: CheckedContinuation<[[String: Any]], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var collected: [[String: Any]] = []

    private static let handlerName = "tingshuSearch"

    /// 搜索关键词，返回原始字典数组（字段：albumId/title/author/cover/playCount/trackCount/isFinished）
    func search(keyword: String, page: Int = 1) async throws -> [[String: Any]] {
        guard pending == nil else { throw BridgeError.busy }
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://www.ximalaya.com/search/album/\(q)?page=\(page)") else {
            throw BridgeError.badURL
        }

        return try await withCheckedThrowingContinuation { cont in
            pending = cont
            collected = []

            let view = makeWebView()
            webView = view

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self, self.pending != nil else { return }
                self.finish(.failure(BridgeError.timeout))
            }

            view.load(URLRequest(url: url))
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 持久：复用登录态

        let uc = config.userContentController
        uc.add(self, name: Self.handlerName)
        // documentStart 注入：页面脚本跑之前先挂好 MutationObserver，避免结果渲染完才注入
        uc.addUserScript(WKUserScript(source: Self.extractScript,
                                      injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: true))

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        view.navigationDelegate = self
        // 桌面 UA：搜索结果页在 PC 版结构更稳定
        view.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        return view
    }

    fileprivate func finish(_ result: Result<[[String: Any]], Error>) {
        guard let cont = pending else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        teardown()
        switch result {
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView?.navigationDelegate = nil
        webView = nil
    }

    /// 从页面提取搜索结果。
    /// 喜马拉雅搜索结果页结构随版本变化，所以这里做多路兜底：
    ///   ① 先找 __NUXT__ / window.__INITIAL_STATE__ 里的数据
    ///   ② 再退回 DOM 解析（a[href*="/album/"] 卡片）
    static let extractScript = #"""
    (function(){
      if (window.__tingshuSearchInstalled) return;
      window.__tingshuSearchInstalled = true;

      function post(list){
        try {
          window.webkit.messageHandlers.tingshuSearch.postMessage({ items: list });
        } catch(e) {}
      }

      function pick(obj, keys){
        for (var i=0;i<keys.length;i++){
          var v = obj[keys[i]];
          if (v !== undefined && v !== null && v !== '') return v;
        }
        return null;
      }

      function norm(raw){
        var id = pick(raw, ['albumId','id','album_id']);
        if (!id) {
          var u = pick(raw, ['albumUrl','url','link']) || '';
          var m = String(u).match(/\/album\/(\d+)/);
          if (m) id = m[1];
        }
        if (!id) return null;
        return {
          albumId: String(id),
          title: String(pick(raw, ['title','albumTitle','name','album_title']) || ''),
          author: String(pick(raw, ['author','nickname','announcer','anchorName','userName']) || ''),
          cover: String(pick(raw, ['cover','coverUrl','coverPath','img','imageUrl']) || ''),
          playCount: Number(pick(raw, ['playCount','play_count','playsCount','play']) || 0),
          trackCount: Number(pick(raw, ['trackCount','track_count','trackNum','sections']) || 0),
          isFinished: (pick(raw, ['isFinished','finished','is_finish']) === 1 ||
                       pick(raw, ['isFinished','finished','is_finish']) === true)
        };
      }

      function fromState(){
        var out = [];
        var roots = [window.__INITIAL_STATE__, window.__NUXT__];
        function walk(node, depth){
          if (!node || depth > 6 || out.length > 60) return;
          if (Array.isArray(node)) {
            for (var i=0;i<node.length && i<80;i++) walk(node[i], depth+1);
            return;
          }
          if (typeof node === 'object') {
            if (node.albumId || node.albumUrl) {
              var n = norm(node);
              if (n) out.push(n);
            }
            for (var k in node) {
              if (out.length > 60) break;
              var v = node[k];
              if (v && typeof v === 'object') walk(v, depth+1);
            }
          }
        }
        for (var i=0;i<roots.length;i++) {
          try { walk(roots[i], 0); } catch(e) {}
          if (out.length) break;
        }
        return out;
      }

      function fromDom(){
        var out = [];
        var seen = {};
        var links = document.querySelectorAll('a[href*="/album/"]');
        for (var i=0;i<links.length;i++){
          var a = links[i];
          var m = (a.getAttribute('href')||'').match(/\/album\/(\d+)/);
          if (!m) continue;
          var id = m[1];
          if (seen[id]) continue;
          seen[id] = 1;

          var card = a.closest('li, div.album-item, div[class*="item"], div[class*="card"]') || a;
          var txt = (card.innerText || a.innerText || '').trim();
          var lines = txt.split('\n').map(function(s){return s.trim();}).filter(Boolean);

          var title = lines[0] || (a.getAttribute('title') || '');
          var author = '';
          for (var j=1;j<lines.length;j++){
            if (/作者|主播|播讲|演播/.test(lines[j])) { author = lines[j].replace(/^(作者|主播|播讲|演播)[:：]?\s*/, ''); break; }
          }
          var img = card.querySelector('img');
          var cover = img ? (img.getAttribute('src') || img.getAttribute('data-src') || '') : '';

          if (title && !/^(首页|排行|分类|登录|注册)$/.test(title)) {
            out.push({ albumId:id, title:title, author:author, cover:cover, playCount:0, trackCount:0, isFinished:false });
          }
          if (out.length >= 60) break;
        }
        return out;
      }

      function attempt(){
        var items = fromState();
        if (!items.length) items = fromDom();
        if (items.length) { post(items); return true; }
        return false;
      }

      if (!attempt()) {
        var tries = 0;
        var timer = setInterval(function(){
          tries++;
          if (attempt() || tries > 40) clearInterval(timer);
        }, 400);
      }
    })();
    """#
}

extension WebSearchBridge: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let items = body["items"] as? [[String: Any]] else { return }
        if items.isEmpty { return }
        collected = items
        finish(.success(items))
    }
}

extension WebSearchBridge: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面加载完再补跑一次提取（脚本可能在 DOM 就绪前执行过）
        webView.evaluateJavaScript(WebSearchBridge.extractScript, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if pending != nil { finish(.failure(WebSearchBridge.BridgeError.pageFailed)) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if pending != nil { finish(.failure(WebSearchBridge.BridgeError.pageFailed)) }
    }
}
