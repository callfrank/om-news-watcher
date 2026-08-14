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

        let browserResult = await testViaWebKit(source)

        guard browserResult.kind == .technicalError else {
            return browserResult
        }

        // Automatischer Diagnose-Fallback:
        // Falls WebKit scheitert, prüfen wir, ob die Seite per normalem
        // HTML-Abruf funktioniert. Dann kann die App die passende Regel
        // direkt vorschlagen.
        let httpResult = await testViaHTTP(source)

        guard httpResult.kind != .technicalError else {
            return browserResult
        }

        let baseRepair = httpResult.repairProposal
        let repair = SourceRepairProposal(
            title: "Direkten HTML-Abruf verwenden",
            explanation:
                "Der Browserabruf ist fehlgeschlagen, der direkte HTML-Abruf liefert aber auswertbare Inhalte. " +
                (baseRepair?.explanation ?? "Die Quelle kann ohne Browser stabiler überwacht werden."),
            previewCount: httpResult.hitCount,
            examples: httpResult.examples,
            candidateSelector: baseRepair?.candidateSelector,
            includeRegex: baseRepair?.includeRegex,
            excludeRegex: baseRepair?.excludeRegex,
            fetchMode: "html",
            minTitleLength: baseRepair?.minTitleLength,
            allowExternal: baseRepair?.allowExternal
        )

        return SourceTestResult(
            sourceID: source.id,
            kind: .technicalError,
            hitCount: httpResult.hitCount,
            examples: httpResult.examples,
            message:
                "Der Browserabruf ist fehlgeschlagen. Ein direkter HTML-Abruf funktioniert; " +
                "die App kann die Quelle automatisch umstellen.",
            testedAt: Date(),
            repairProposal: repair
        )
    }

    private func testViaWebKit(_ source: SourceRecord) async -> SourceTestResult {
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
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 OM-News-Watcher-Mac/1.7",
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

            let rows = parseCandidates(payload["rows"])
            let allRows = parseCandidates(payload["allRows"])

            finish(classify(source, rows: rows, allRows: allRows))
        } catch {
            finish(failure(source, message: error.localizedDescription))
        }
    }

    private func parseCandidates(_ value: Any?) -> [Candidate] {
        let rawRows = value as? [[String: Any]] ?? []

        return rawRows.compactMap { row -> Candidate? in
            let title = (row["title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let href = (row["href"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let date = (row["date"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !title.isEmpty else { return nil }
            return Candidate(
                title: title,
                href: href,
                date: date
            )
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
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 OM-News-Watcher-Mac/1.7",
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
            return classify(source, rows: rows, allRows: rows)
        } catch {
            return failure(source, message: error.localizedDescription)
        }
    }

    private func classify(
        _ source: SourceRecord,
        rows: [Candidate],
        allRows: [Candidate]
    ) -> SourceTestResult {
        let filtered = filter(rows, for: source)
        let count = filtered.count
        let examples = hits(from: filtered)

        if count == 0 {
            let repair = makeRepairProposal(
                source,
                rawRows: allRows.isEmpty ? rows : allRows,
                currentRows: filtered
            )

            return SourceTestResult(
                sourceID: source.id,
                kind: .zeroHits,
                hitCount: 0,
                examples: [],
                message:
                    repair == nil
                    ? "Keine möglichen Artikel erkannt. Die Quelle benötigt wahrscheinlich eine spezielle Erkennungsregel."
                    : "Keine Treffer mit der aktuellen Regel. Die App hat eine mögliche Artikelstruktur auf der Seite gefunden.",
                testedAt: Date(),
                repairProposal: repair
            )
        }

        let threshold = max(source.maxDetectedItems ?? 0, 80)
        if count > threshold {
            let repair = makeRepairProposal(
                source,
                rawRows: allRows.isEmpty ? rows : allRows,
                currentRows: filtered
            )

            return SourceTestResult(
                sourceID: source.id,
                kind: .tooManyHits,
                hitCount: count,
                examples: examples,
                message:
                    repair == nil
                    ? "\(count) Treffer erkannt. Das ist ungewöhnlich viel; vermutlich sind Navigation oder Kategorien enthalten."
                    : "\(count) Treffer erkannt. Die App hat einen engeren Artikelbereich gefunden und kann daraus eine Regel erzeugen.",
                testedAt: Date(),
                repairProposal: repair
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

    // MARK: - Automatische Reparatur

    private func makeRepairProposal(
        _ source: SourceRecord,
        rawRows: [Candidate],
        currentRows: [Candidate]
    ) -> SourceRepairProposal? {
        let prepared = prepareForRepair(rawRows, source: source)

        guard prepared.count >= 2 else {
            return nil
        }

        var groups: [String: [Candidate]] = [:]

        for row in prepared {
            guard let url = URL(string: row.href) else { continue }
            let components = url.path
                .split(separator: "/")
                .map(String.init)

            guard components.count >= 2 else { continue }

            let lower = components.map { $0.lowercased() }

            // Bevorzugt werden typische News-/Presse-Pfade.
            for (index, component) in lower.enumerated() {
                guard articlePathHints.contains(where: {
                    component == $0 ||
                    component.contains($0)
                }) else {
                    continue
                }

                var end = index

                if components.indices.contains(index + 1),
                   components[index + 1].range(
                    of: #"^20\d{2}$"#,
                    options: .regularExpression
                   ) != nil {
                    end = index + 1
                }

                guard end < components.count - 1 else { continue }

                let prefix = "/" + components[0...end].joined(separator: "/") + "/"
                groups[prefix, default: []].append(row)
            }

            // Zusätzlich gemeinsame Elternordner prüfen.
            let parent = "/" + components.dropLast().joined(separator: "/") + "/"
            if parent.split(separator: "/").count >= 3 {
                groups[parent, default: []].append(row)
            }
        }

        let uniqueGroups = groups.mapValues(uniqueCandidates)

        var best: RepairCandidate?

        for (prefix, members) in uniqueGroups {
            guard members.count >= 2, members.count <= 70 else { continue }

            let prefixDepth = prefix.split(separator: "/").count
            guard prefixDepth >= 2 else { continue }

            let score = scoreGroup(
                prefix: prefix,
                members: members,
                totalRows: prepared.count,
                source: source
            )

            let candidate = RepairCandidate(
                prefix: prefix,
                members: members,
                score: score
            )

            if best == nil || candidate.score > best!.score {
                best = candidate
            }
        }

        guard let best else {
            return nil
        }

        guard let host = URL(string: source.url)?.host else {
            return nil
        }

        let escapedHost = NSRegularExpression.escapedPattern(for: host)
        let escapedPrefix = NSRegularExpression.escapedPattern(for: best.prefix)

        let includeRegex = #"^https?://"# + escapedHost + escapedPrefix

        var proposed = source
        proposed.includeRegex = includeRegex
        proposed.candidateSelector = #"a[href*=""# + best.prefix + #""]"#
        proposed.minTitleLength = max(source.minTitleLength, 12)

        let preview = filter(prepared, for: proposed)

        guard preview.count >= 2, preview.count <= 70 else {
            return nil
        }

        if !currentRows.isEmpty,
           preview.count >= currentRows.count {
            return nil
        }

        let reductionText: String
        if currentRows.count > 0 {
            let reduction = max(
                0,
                Int(
                    (1.0 - Double(preview.count) / Double(currentRows.count)) * 100.0
                )
            )
            reductionText =
                "Die Regel reduziert die Treffer von \(currentRows.count) auf \(preview.count) (\(reduction)% weniger)."
        } else {
            reductionText =
                "Die Regel erkennt \(preview.count) plausible Artikel innerhalb eines gemeinsamen URL-Bereichs."
        }

        return SourceRepairProposal(
            title: "Nur den erkannten Artikelbereich überwachen",
            explanation:
                "\(reductionText) Verwendeter Bereich: \(best.prefix). " +
                "Die Regel wird als URL-Filter in sources.json gespeichert und damit auch vom GitHub-Watcher verwendet.",
            previewCount: preview.count,
            examples: hits(from: preview),
            candidateSelector: proposed.candidateSelector,
            includeRegex: includeRegex,
            excludeRegex: nil,
            fetchMode: nil,
            minTitleLength: proposed.minTitleLength,
            allowExternal: nil
        )
    }

    private func prepareForRepair(
        _ rows: [Candidate],
        source: SourceRecord
    ) -> [Candidate] {
        var result: [Candidate] = []
        var seen = Set<String>()

        for row in rows {
            let title = normalizeWhitespace(row.title)
            guard title.count >= 8, title.count <= 320 else { continue }
            guard !isGenericNavigationTitle(title) else { continue }
            guard let resolved = resolve(row.href, relativeTo: source.url) else { continue }
            guard source.allowExternal || isInternal(resolved, sourceURL: source.url) else {
                continue
            }

            guard let url = URL(string: resolved) else { continue }
            guard url.path != URL(string: source.url)?.path else { continue }

            let key = resolved.lowercased()
            guard seen.insert(key).inserted else { continue }

            result.append(
                Candidate(
                    title: title,
                    href: resolved,
                    date: row.date
                )
            )
        }

        return result
    }

    private func scoreGroup(
        prefix: String,
        members: [Candidate],
        totalRows: Int,
        source: SourceRecord
    ) -> Int {
        let lower = prefix.lowercased()
        var score = 0

        if articlePathHints.contains(where: { lower.contains("/\($0)") }) {
            score += 70
        }

        if lower.contains("press") || lower.contains("presse") {
            score += 35
        }

        if lower.contains("news") || lower.contains("story") {
            score += 30
        }

        if lower.range(of: #"/20\d{2}/"#, options: .regularExpression) != nil {
            score += 15
        }

        score += min(members.count, 25)

        let longTitles = members.filter { $0.title.count >= 24 }.count
        score += min(longTitles * 2, 20)

        let depth = prefix.split(separator: "/").count
        score += min(depth * 3, 18)

        if members.count > 45 {
            score -= 20
        }

        if members.count > Int(Double(totalRows) * 0.8) {
            score -= 25
        }

        if let sourcePath = URL(string: source.url)?.deletingLastPathComponent().path,
           prefix == sourcePath + "/" {
            score -= 20
        }

        return score
    }

    private func uniqueCandidates(_ rows: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return rows.filter {
            seen.insert($0.href.lowercased()).inserted
        }
    }

    private func hits(from rows: [Candidate]) -> [SourceTestHit] {
        Array(rows.prefix(5)).map {
            SourceTestHit(
                title: $0.title,
                url: $0.href.isEmpty ? nil : $0.href,
                publicationDate:
                    $0.date.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                    ? nil
                    : $0.date
            )
        }
    }

    private func isGenericNavigationTitle(_ title: String) -> Bool {
        let normalized = normalizeWhitespace(title)
        let lower = normalized.lowercased()

        if normalized.range(
            of: #"<\s*(img|svg|picture|source|div|span|a)\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        let exact = [
            "home", "startseite", "kontakt", "contact", "about", "über uns",
            "impressum", "datenschutz", "privacy", "login", "jobs", "karriere",
            "services", "service", "governance", "unsere werte", "unsere talente",
            "auszeichnungen", "standorte", "locations", "media", "stories",
            "publications", "news", "presse", "press", "menu", "navigation",
            "alle akzeptieren", "alles akzeptieren", "akzeptieren",
            "accept all", "accept", "zustimmen", "allow all",
            "link öffnet in neuem tab", "opens in a new tab",
            "open in new tab", "mehr erfahren", "mehr erfahren >",
            "read more", "learn more", "weiterlesen"
        ]

        if exact.contains(lower) {
            return true
        }

        let prefixes = [
            "mehr erfahren", "read more", "learn more", "weiterlesen",
            "zurück", "back", "alle themen", "all topics",
            "link öffnet", "opens in", "open in new"
        ]

        if prefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        if lower.range(
            of: #"^pdf\s*[-–—:]\s*\d"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return false
    }

    private func isBadContentURL(
        _ urlString: String,
        sourceURL: String,
        title: String
    ) -> Bool {
        guard
            let url = URL(string: urlString),
            let source = URL(string: sourceURL)
        else {
            return true
        }

        let path = url.path.lowercased()

        let badPaths = [
            "/producttype/",
            "/products/",
            "/product/",
            "/warenkorb/",
            "/cart/",
            "/checkout/",
            "/search/"
        ]

        if badPaths.contains(where: { path.contains($0) }) {
            return true
        }

        var targetComponents = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        targetComponents?.fragment = nil

        var sourceComponents = URLComponents(
            url: source,
            resolvingAgainstBaseURL: false
        )
        sourceComponents?.fragment = nil

        let canonicalTarget =
            targetComponents?.url?.absoluteString ?? url.absoluteString
        let canonicalSource =
            sourceComponents?.url?.absoluteString ?? source.absoluteString

        if canonicalTarget == canonicalSource &&
           url.query?.contains("om_item=") != true {
            return true
        }

        if path.hasSuffix(".pdf") {
            let lowerTitle = title.lowercased()

            if lowerTitle.range(
                of: #"^pdf\b"#,
                options: .regularExpression
            ) != nil ||
               lowerTitle.contains("factsheet") ||
               lowerTitle.contains("fact sheet") {
                return true
            }
        }

        return false
    }

    private let articlePathHints = [
        "press-room",
        "press-releases",
        "pressrelease",
        "pressemitteilungen",
        "presse",
        "newsroom",
        "news",
        "stories",
        "story",
        "blog",
        "reports",
        "report",
        "insights",
        "article",
        "articles",
        "events",
        "event"
    ]

    // MARK: - Bestehende Filterlogik

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

            if isGenericNavigationTitle(title) {
                continue
            }

            if isBadContentURL(
                resolved,
                sourceURL: source.url,
                title: title
            ) {
                continue
            }

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

            if source.includeRegex == nil &&
               !looksLikeArticle(
                title: title,
                url: resolved,
                sourceURL: source.url
               ) {
                continue
            }

            let key = resolved.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(
                Candidate(
                    title: title,
                    href: resolved,
                    date: row.date
                )
            )
        }

        return result
    }

    private func looksLikeArticle(
        title: String,
        url: String,
        sourceURL: String
    ) -> Bool {
        guard title.count >= 10, title.count <= 320 else { return false }

        if isGenericNavigationTitle(title) {
            return false
        }

        guard let parsed = URL(string: url) else { return false }
        let path = parsed.path
        let components = path.split(separator: "/")

        if articlePathHints.contains(where: {
            path.lowercased().contains($0)
        }) {
            return true
        }

        if path.range(
            of: #"/20\d{2}/"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        return components.count >= 3 && title.count >= 18
    }

    private func javascript(for source: SourceRecord) throws -> String {
        let config: [String: Any] = [
            "candidateSelector": source.candidateSelector ?? "",
            "itemSelector": source.itemSelector ?? "",
            "titleSelector": source.titleSelector ?? "",
            "linkSelector": source.linkSelector ?? "",
            "dateSelector": source.dateSelector ?? "",
            "allowTitleOnly": source.allowTitleOnly
        ]

        let data = try JSONSerialization.data(withJSONObject: config)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        return """
        (() => {
          const cfg = \(json);
          const clean = (text) => (text || '').replace(/\\s+/g, ' ').trim();

          const genericTitle = (value) => {
            const title = clean(value);
            const lower = title.toLowerCase();

            if (!title) return true;
            if (/<\\s*(img|svg|picture|source|div|span|a)\\b/i.test(title)) {
              return true;
            }

            const exact = new Set([
              'home', 'startseite', 'kontakt', 'contact', 'about',
              'über uns', 'impressum', 'datenschutz', 'privacy',
              'login', 'jobs', 'karriere', 'services', 'service',
              'governance', 'unsere werte', 'unsere talente',
              'auszeichnungen', 'standorte', 'locations', 'media',
              'stories', 'publications', 'news', 'presse', 'press',
              'menu', 'navigation', 'alle akzeptieren', 'alles akzeptieren',
              'akzeptieren', 'accept all', 'accept', 'zustimmen',
              'allow all', 'link öffnet in neuem tab',
              'opens in a new tab', 'open in new tab',
              'mehr erfahren', 'mehr erfahren >', 'read more',
              'learn more', 'weiterlesen'
            ]);

            if (exact.has(lower)) return true;

            return [
              'mehr erfahren', 'read more', 'learn more', 'weiterlesen',
              'zurück', 'back', 'alle themen', 'all topics',
              'link öffnet', 'opens in', 'open in new'
            ].some(prefix => lower.startsWith(prefix));
          };

          const cardFor = (node) => {
            if (!node || !node.closest) return null;

            return node.closest(
              'article, li, section, [class*="card" i], [class*="teaser" i], ' +
              '[class*="news" i], [class*="press" i], [class*="event" i], ' +
              '[class*="story" i], [class*="result" i], [class*="item" i]'
            );
          };

          const headingFrom = (root) => {
            if (!root || !root.querySelector) return '';

            const selectors = [
              'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
              '[class*="headline" i]',
              '[class*="heading" i]',
              '[class*="title" i]'
            ];

            for (const selector of selectors) {
              const el = root.querySelector(selector);
              const value = clean(
                el?.textContent ||
                el?.getAttribute?.('aria-label') ||
                ''
              );

              if (value && !genericTitle(value)) {
                return value;
              }
            }

            return '';
          };

          const bestTitle = (link, root = null) => {
            const own = clean(
              link?.textContent ||
              link?.getAttribute?.('aria-label') ||
              link?.title ||
              ''
            );

            if (own && !genericTitle(own)) {
              return own;
            }

            const card = root || cardFor(link);
            const heading = headingFrom(card);

            if (heading) {
              return heading;
            }

            const imageAlt = clean(
              link?.querySelector?.('img[alt]')?.getAttribute('alt') ||
              ''
            );

            if (imageAlt && !genericTitle(imageAlt)) {
              return imageAlt;
            }

            return own;
          };

          const bestDate = (link, root = null) => {
            const card = root || cardFor(link);

            if (!card || !card.querySelector) {
              return '';
            }

            if (cfg.dateSelector) {
              const configured = card.querySelector(cfg.dateSelector);
              const configuredValue = clean(
                configured?.getAttribute?.('datetime') ||
                configured?.textContent ||
                ''
              );
              if (configuredValue) return configuredValue;
            }

            const selectors = [
              'time[datetime]',
              'time',
              '[class*="date" i]',
              '[class*="datum" i]',
              '[class*="time" i]',
              '[class*="published" i]'
            ];

            const datePattern =
              /(?:\\b\\d{1,2}[.\\/-]\\d{1,2}[.\\/-]20\\d{2}\\b|\\b20\\d{2}-\\d{2}-\\d{2}\\b|\\b\\d{1,2}\\.?\\s+(?:Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember|January|February|March|May|June|July|October|December)\\s+20\\d{2}\\b)/i;

            for (const selector of selectors) {
              const el = card.querySelector(selector);
              const value = clean(
                el?.getAttribute?.('datetime') ||
                el?.textContent ||
                ''
              );

              if (!value) continue;

              const match = value.match(datePattern);
              if (match) return match[0];

              if (/^20\\d{2}-\\d{2}-\\d{2}(?:T|$)/.test(value)) {
                return value;
              }
            }

            return '';
          };

          const rowForLink = (link, root = null) => ({
            title: bestTitle(link, root),
            href:
              link?.href ||
              link?.getAttribute?.('href') ||
              '',
            date: bestDate(link, root)
          });

          const rows = [];
          const allRows = [];

          try {
            document.querySelectorAll('a[href]').forEach((a) => {
              const row = rowForLink(a);
              if (row.title && row.href) {
                allRows.push(row);
              }
            });

            if (cfg.allowTitleOnly && cfg.itemSelector) {
              document.querySelectorAll(cfg.itemSelector).forEach((item) => {
                const titleEl = cfg.titleSelector
                  ? (item.matches(cfg.titleSelector)
                      ? item
                      : item.querySelector(cfg.titleSelector))
                  : item;

                const title = clean(
                  titleEl ? titleEl.textContent : item.textContent
                );

                const date = bestDate(null, item);

                if (title) {
                  rows.push({
                    title,
                    href: '',
                    date
                  });
                }
              });
            } else if (cfg.itemSelector) {
              document.querySelectorAll(cfg.itemSelector).forEach((item) => {
                let linkEl = null;

                if (cfg.linkSelector) {
                  linkEl = item.matches(cfg.linkSelector)
                    ? item
                    : item.querySelector(cfg.linkSelector);
                } else {
                  linkEl = item.matches('a[href]')
                    ? item
                    : item.querySelector('a[href]');
                }

                if (!linkEl) return;

                const configuredTitleEl = cfg.titleSelector
                  ? (item.matches(cfg.titleSelector)
                      ? item
                      : item.querySelector(cfg.titleSelector))
                  : null;

                const configuredTitle = clean(
                  configuredTitleEl?.textContent || ''
                );

                const title =
                  configuredTitle && !genericTitle(configuredTitle)
                    ? configuredTitle
                    : bestTitle(linkEl, item);

                const href =
                  linkEl.href ||
                  linkEl.getAttribute('href') ||
                  '';

                const date = bestDate(linkEl, item);

                if (title && href) {
                  rows.push({
                    title,
                    href,
                    date
                  });
                }
              });
            } else {
              const selector =
                cfg.candidateSelector ||
                'main article a[href], article a[href], ' +
                'main [class*="card" i] a[href], ' +
                'main [class*="teaser" i] a[href], ' +
                'main [class*="news" i] a[href], ' +
                'main [class*="press" i] a[href], ' +
                'main [class*="event" i] a[href], main a[href]';

              document.querySelectorAll(selector).forEach((a) => {
                const row = rowForLink(a);
                if (row.title && row.href) {
                  rows.push(row);
                }
              });

              if (rows.length === 0) {
                allRows.forEach((row) => rows.push(row));
              }
            }

            return {
              rows: rows.slice(0, 600),
              allRows: allRows.slice(0, 1200),
              error: ''
            };
          } catch (error) {
            return {
              rows: [],
              allRows: [],
              error: String(error)
            };
          }
        })();
        """
    }

    private func extractAnchors(from html: String) -> [Candidate] {
        let pattern = #"<a\b[^>]*?href\s*=\s*[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</a>"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)

        return regex.matches(
            in: html,
            options: [],
            range: range
        ).compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }

            let href = ns.substring(
                with: match.range(at: 1)
            )

            let inner = ns.substring(
                with: match.range(at: 2)
            )

            let title = stripHTML(inner)

            guard !title.isEmpty else { return nil }

            return Candidate(
                title: title,
                href: href,
                date: ""
            )
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
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

    private func resolve(
        _ href: String,
        relativeTo sourceURL: String
    ) -> String? {
        guard
            !href.isEmpty,
            let base = URL(string: sourceURL),
            let url = URL(
                string: href,
                relativeTo: base
            )?.absoluteURL,
            ["http", "https"].contains(
                url.scheme?.lowercased() ?? ""
            )
        else {
            return nil
        }

        return url.absoluteString
    }

    private func isInternal(
        _ urlString: String,
        sourceURL: String
    ) -> Bool {
        guard
            let urlHost =
                URL(string: urlString)?
                .host?
                .lowercased(),
            let sourceHost =
                URL(string: sourceURL)?
                .host?
                .lowercased()
        else {
            return false
        }

        return urlHost == sourceHost ||
            urlHost.hasSuffix(".\(sourceHost)") ||
            sourceHost.hasSuffix(".\(urlHost)")
    }

    private func matches(
        _ value: String,
        pattern: String
    ) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return false
        }

        let range = NSRange(
            value.startIndex..<value.endIndex,
            in: value
        )

        return regex.firstMatch(
            in: value,
            options: [],
            range: range
        ) != nil
    }

    private func failure(
        _ source: SourceRecord,
        message: String
    ) -> SourceTestResult {
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
        let date: String
    }

    private struct RepairCandidate {
        let prefix: String
        let members: [Candidate]
        let score: Int
    }
}
