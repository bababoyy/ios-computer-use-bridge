import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UINavigationController(rootViewController: WebViewController())
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Native gezinme çubuğu + tam ekran WKWebView. Sayfa yerel HTML'dir (ağ gerekmez).
final class WebViewController: UIViewController {
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "WebView Sample"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Reload", primaryAction: UIAction { [weak self] _ in self?.load() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "reloadButton"
        webView.accessibilityIdentifier = "webView"
        webView.isInspectable = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        load()
    }

    private func load() {
        webView.loadHTMLString(Self.html, baseURL: nil)
    }

    private static let html = """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Sample Page</title>
      <style>
        body { font: -apple-system-body; font-family: -apple-system; padding: 24px; }
        button { font-size: 20px; padding: 12px 24px; margin: 8px 0; border-radius: 10px; }
        #increment { background: #0a84ff; color: white; border: 0; }
        h1 { font-size: 34px; }
        section { margin-bottom: 32px; }
        input[type=text] { font-size: 18px; padding: 8px; width: 80%; }
      </style>
    </head>
    <body>
      <section>
        <h1 id="counterLabel">Count: 0</h1>
        <button id="increment" onclick="setCount(count + 1)">Increment</button>
        <button id="reset" onclick="setCount(0)">Reset</button>
      </section>
      <section>
        <label><input type="checkbox" id="feature" onchange="statusLabel.textContent = 'Feature: ' + (this.checked ? 'on' : 'off')"> Feature</label>
        <p id="status">Feature: off</p>
      </section>
      <section>
        <input type="text" id="name" placeholder="Name">
        <button id="submit" onclick="greeting.textContent = 'Hello, ' + (nameInput.value || 'anonymous')">Submit</button>
        <p id="greeting">-</p>
      </section>
      <script>
        let count = 0;
        const counter = document.getElementById('counterLabel');
        const statusLabel = document.getElementById('status');
        const greeting = document.getElementById('greeting');
        const nameInput = document.getElementById('name');
        function setCount(n) { count = n; counter.textContent = 'Count: ' + n; }
      </script>
    </body>
    </html>
    """
}
