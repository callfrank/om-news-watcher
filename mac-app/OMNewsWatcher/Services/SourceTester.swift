import Foundation
import WebKit

@MainActor
final class SourceTester: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<SourceTestResult, Never>?
    private var source: SourceRecord?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func test(_ source: SourceRecord) async -> SourceTestResult {
        if source.fetchMode == "html" {
            return await testViaHTTP(source)
        }

        guard let url = URL(string: source.url) else {
            return failure(source, message: "Die URL ist ungültig.")
        }

        self.source = source
        self.finished = false

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            var request = URLRequest(url: url)
            request.timeoutInterval = 18
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 OM-News-Watcher-Mac/1.1",
                forHTTPHeaderField: "User-Agent"
            )

            webView.load(request)

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.finish(
                    self.failure(source, message: "Zeitüberschreitung nach 20 Sekunden.")
                )
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let source else { return }

        Task { [weak self] in
            let wait = min(max(source.waitMs, 0), 5000)
            if wait > 0 {
                try? await Task.sleep(for: .milliseconds(Int64(wait)))
            }
            await self?.extractAndFinish(source)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard let source else { return }
        finish(failure(source, message: error.localizedDescription))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard let source else { return }
        finish(failure(source, message: error.localizedDescription))
    }

    private func extractAndFinish(_ source: SourceRecord) async {
        guard let webView else { return }

        do {
            let script = try javascript(for: source)
            let value = try await webView.evaluateJavaScript(script)

            guard let payload = value as? [String: Any] else {
                finish(failure(source, message: "Die Seite lieferte keine auswertbaren DOM-Daten."))
                return
            }

            if let jsError = payload["error"] as? String, !jsError.isEmpty {
                finish(failure(source, message: jsError))
                return
            }

            let rawRows = payload["rows"] as? [[String: Any]] ?? []
            let rows = rawRows.compactMap { row -> Candidate? in
                let title = (row["title"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let href = (row["href"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return Candidate(title: title, href: href)
            }

            finish(classify(source, rows: rows))
        } catch {
            finish(failure(source, message: error.localizedDescription))
        }
    }

    private func testViaHTTP(_ source: SourceRecord) async -> SourceTestResult {
        guard let url = URL(string: source.url) else {
            return failure(source, message: "Die URL ist ungültig.")
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 OM-News-Watcher-Mac/1.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                return failure(source, message: "HTTP-Fehler \(http.statusCode).")
            }

            guard let html = String(data: data, encoding: .utf8) else {
                return failure(source, message: "HTML konnte nicht gelesen werden.")
            }

            let rows = extractAnchors(from: html)
            return classify(source, rows: rows)
        } catch {
            return failure(source, message: error.localizedDescription)
        }
    }

    private func classify(_ source: SourceRecord, rows: [Candidate]) -> SourceTestResult {
        let filtered = filter(rows, for: source)
        let count = filtered.count
        let examples = filtered.prefix(5).map {
            SourceTestHit(title: $0.title, url: $0.href.isEmpty ? nil : $0.href)
        }

        if count == 0 {
            return SourceTestResult(
                sourceID: source.id,
                kind: .zeroHits,
                hitCount: 0,
                examples: [],
                message: "Keine möglichen Artikel erkannt. Die Quelle benötigt wahrscheinlich eine spezielle Erkennungsregel.",
                testedAt: Date()
            )
        }

        let threshold = max(source.maxDetectedItems ?? 0, 80)
        if count > threshold {
            return SourceTestResult(
                sourceID: source.id,
                kind: .tooManyHits,
                hitCount: count,
                examples: examples,
                message: "\(count) Treffer erkannt. Das ist ungewöhnlich viel; vermutlich sind Navigation oder Kategorien enthalten.",
                testedAt: Date()
            )
        }

        return SourceTestResult(
            sourceID: source.id,
            kind: .success,
            hitCount: count,
            examples: examples,
            message: "\(count) mögliche Artikel erkannt.",
            testedAt: Date()
        )
    }

    private func filter(_ rows: [Candidate], for source: SourceRecord) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []

        for row in rows {
            let title = normalizeWhitespace(row.title)
            guard title.count >= source.minTitleLength else { continue }

            if let pattern = source.includeTitleRegex,
               !matches(title, pattern: pattern) {
                continue
            }

            if let pattern = source.excludeTitleRegex,
               matches(title, pattern: pattern) {
                continue
            }

            if source.allowTitleOnly && row.href.isEmpty {
                let key = "title:\(title.lowercased())"
                guard seen.insert(key).inserted else { continue }
                result.append(Candidate(title: title, href: ""))
                continue
            }

            guard let resolved = resolve(row.href, relativeTo: source.url) else { continue }

            if !source.allowExternal && !isInternal(resolved, sourceURL: source.url) {
                continue
            }

            if let pattern = source.includeRegex,
               !matches(resolved, pattern: pattern) {
                continue
            }

            if let pattern = source.excludeRegex,
               matches(resolved, pattern: pattern) {
                continue
            }

            if source.includeRegex == nil && !looksLikeArticle(title: title, url: resolved, sourceURL: source.url) {
                continue
            }

            let key = resolved.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(Candidate(title: title, href: resolved))
        }

        return result
    }

    private func looksLikeArticle(title: String, url: String, sourceURL: String) -> Bool {
        guard title.count >= 10, title.count <= 320 else { return false }

        let badTitles = [
            "home", "startseite", "kontakt", "contact", "about", "über uns",
            "impressum", "datenschutz", "privacy", "login", "jobs", "karriere",
            "mehr erfahren", "read more", "weiterlesen", "menu", "navigation"
        ]

        let lower = title.lowercased()
        if badTitles.contains(where: { lower == $0 || lower.hasPrefix("\($0) ") }) {
            return false
        }

        guard let parsed = URL(string: url) else { return false }
        let path = parsed.path
        let components = path.split(separator: "/")

        if components.count >= 2 { return true }

        let hints = ["news", "press", "presse", "blog", "article", "story", "report", "event", "2026", "2025"]
        return hints.contains(where: { path.lowercased().contains($0) })
    }

    private func javascript(for source: SourceRecord) throws -> String {
        let config: [String: Any] = [
            "candidateSelector": source.candidateSelector ?? "",
            "itemSelector": source.itemSelector ?? "",
            "titleSelector": source.titleSelector ?? "",
            "linkSelector": source.linkSelector ?? "",
            "allowTitleOnly": source.allowTitleOnly
        ]

        let data = try JSONSerialization.data(withJSONObject: config)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        return """
        (() => {
          const cfg = \(json);
          const clean = (text) => (text || '').replace(/\\s+/g, ' ').trim();
          const rows = [];

          try {
            if (cfg.allowTitleOnly && cfg.itemSelector) {
              document.querySelectorAll(cfg.itemSelector).forEach((item) => {
                const titleEl = cfg.titleSelector
                  ? (item.matches(cfg.titleSelector) ? item : item.querySelector(cfg.titleSelector))
                  : item;
                const title = clean(titleEl ? titleEl.textContent : item.textContent);
                if (title) rows.push({ title, href: '' });
              });
            } else if (cfg.itemSelector) {
              document.querySelectorAll(cfg.itemSelector).forEach((item) => {
                let linkEl = null;
                if (cfg.linkSelector) {
                  linkEl = item.matches(cfg.linkSelector) ? item : item.querySelector(cfg.linkSelector);
                } else {
                  linkEl = item.matches('a[href]') ? item : item.querySelector('a[href]');
                }

                if (!linkEl) return;

                const titleEl = cfg.titleSelector
                  ? (item.matches(cfg.titleSelector) ? item : item.querySelector(cfg.titleSelector))
                  : item;
                const title = clean(titleEl ? titleEl.textContent : linkEl.textContent);
                const href = linkEl.href || linkEl.getAttribute('href') || '';
                if (title && href) rows.push({ title, href });
              });
            } else {
              const selector = cfg.candidateSelector || 'main article a[href], article a[href], main a[href]';
              document.querySelectorAll(selector).forEach((a) => {
                const title = clean(a.textContent || a.getAttribute('aria-label') || a.title || '');
                const href = a.href || a.getAttribute('href') || '';
                if (title && href) rows.push({ title, href });
              });

              if (rows.length === 0) {
                document.querySelectorAll('a[href]').forEach((a) => {
                  const title = clean(a.textContent || a.getAttribute('aria-label') || a.title || '');
                  const href = a.href || a.getAttribute('href') || '';
                  if (title && href) rows.push({ title, href });
                });
              }
            }

            return { rows: rows.slice(0, 500), error: '' };
          } catch (error) {
            return { rows: [], error: String(error) };
          }
        })();
        """
    }

    private func extractAnchors(from html: String) -> [Candidate] {
        let pattern = #"<a\b[^>]*?href\s*=\s*[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)

        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let href = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            let title = stripHTML(inner)
            guard !title.isEmpty else { return nil }
            return Candidate(title: title, href: href)
        }
    }

    private func stripHTML(_ value: String) -> String {
        let noTags = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )

        return normalizeWhitespace(
            noTags
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
        )
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolve(_ href: String, relativeTo sourceURL: String) -> String? {
        guard !href.isEmpty,
              let base = URL(string: sourceURL),
              let url = URL(string: href, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }

        return url.absoluteString
    }

    private func isInternal(_ urlString: String, sourceURL: String) -> Bool {
        guard let urlHost = URL(string: urlString)?.host?.lowercased(),
              let sourceHost = URL(string: sourceURL)?.host?.lowercased()
        else { return false }

        return urlHost == sourceHost ||
            urlHost.hasSuffix(".\(sourceHost)") ||
            sourceHost.hasSuffix(".\(urlHost)")
    }

    private func matches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    private func failure(_ source: SourceRecord, message: String) -> SourceTestResult {
        SourceTestResult(
            sourceID: source.id,
            kind: .technicalError,
            hitCount: 0,
            examples: [],
            message: message,
            testedAt: Date()
        )
    }

    private func finish(_ result: SourceTestResult) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        source = nil

        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    private struct Candidate {
        let title: String
        let href: String
    }
}
