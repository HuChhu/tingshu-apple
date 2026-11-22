import SwiftUI
import WebKit

/// 在 App 内置浏览器里打开喜马拉雅，用户自己搜、自己点。
///
/// 为什么要有这个：
///   引擎直连会被风控拦（riskLevel=5），WebView 自动抓取在未登录时页面也是空的。
///   但用户手动操作时 —— 真人点击、真人登录、页面自己算 webtk —— 一切都能走通。
///   所以提供这条手动通道：用户搜到专辑，点「使用此专辑」，我们只取 albumId。
///
/// 取到 albumId 之后，曲目列表和播放都走我们已有的链路。
struct BrowseView: View {
    let initialKeyword: String
    var onPick: (Int64, String) -> Void
    var onCancel: () -> Void

    @State private var pickedId: Int64?
    @State private var pickedTitle: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if let id = pickedId {
                    ConfirmView(
                        albumId: id,
                        title: pickedTitle.isEmpty ? "专辑 \(id)" : pickedTitle,
                        onUse: { onPick(id, pickedTitle) },
                        onBack: { pickedId = nil }
                    )
                } else {
                    XimalayaBrowseWebView(
                        initialKeyword: initialKeyword,
                        onPickAlbum: { id, title in
                            pickedId = id
                            pickedTitle = title
                        }
                    )
                }
            }
            .navigationTitle(pickedId == nil ? "在网页里找专辑" : "确认专辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
            }
        }
    }
}

private struct ConfirmView: View {
    let albumId: Int64
    let title: String
    var onUse: () -> Void
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle").font(.system(size: 48)).foregroundStyle(.tint)
            Text("已选中专辑").font(.headline)
            Text(title).font(.subheadline).multilineTextAlignment(.center).lineLimit(3)
            Text("专辑 ID：\(albumId)").font(.caption).foregroundStyle(.secondary)

            Button("使用此专辑", action: onUse)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Button("重新选择", action: onBack)
                .buttonStyle(.bordered)
        }
        .padding(28)
    }
}

private struct XimalayaBrowseWebView: UIViewRepresentable {
    let initialKeyword: String
    var onPickAlbum: (Int64, String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // 复用登录态
        let uc = config.userContentController
        uc.add(context.coordinator, name: "tingshuPick")

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        // 回灌已登录 cookie
        Task {
            for host in CookieStore.hosts {
                await CookieStore.restore(into: view, host: host)
            }
        }

        let q = initialKeyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // 移动端搜索页：在移动 UA 下渲染更完整，且专辑链接同样是 /album/{id}
        if let url = URL(string: "https://m.ximalaya.com/search?keyword=\(q)") {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPickAlbum: onPickAlbum) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onPickAlbum: (Int64, String) -> Void
        private var fired = false

        init(onPickAlbum: @escaping (Int64, String) -> Void) { self.onPickAlbum = onPickAlbum }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 页面加载完挂点击拦截：点到 /album/{id} 链接就回传，不跳走
            webView.evaluateJavaScript(Self.pickScript, completionHandler: nil)
        }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "tingshuPick",
                  let body = message.body as? [String: Any],
                  let idStr = body["albumId"] as? String, let id = Int64(idStr) else { return }
            if fired { return }
            fired = true
            onPickAlbum(id, (body["title"] as? String) ?? "")
        }

        /// 拦截专辑链接：阻止默认跳转，把 albumId 和标题回传 Swift
        static let pickScript = #"""
        (function(){
          if (window.__tingshuPickInstalled) return;
          window.__tingshuPickInstalled = true;
          document.addEventListener('click', function(e){
            var a = e.target.closest('a[href*="/album/"]');
            if (!a) return;
            var m = (a.getAttribute('href')||'').match(/\/album\/(\d+)/);
            if (!m) return;
            e.preventDefault();
            e.stopPropagation();
            var card = a.closest('li, div[class*="item"], div[class*="card"]') || a;
            var txt = (card.innerText||'').split('\n').map(function(s){return s.trim();}).filter(Boolean);
            try {
              window.webkit.messageHandlers.tingshuPick.postMessage({
                albumId: m[1],
                title: txt[0] || a.getAttribute('title') || ''
              });
            } catch(err){}
          }, true);
        })();
        """#
    }
}
