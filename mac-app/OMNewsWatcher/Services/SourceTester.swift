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
        let startedAt = Date()
        let result = await performTest(source)
        let duration = Int(
            max(0, Date().timeIntervalSince(startedAt) * 1000)
        )
        return result.withDuration(duration)
    }

    private func performTest(_ source: SourceRecord) async -> SourceTestResult {
        if source.fetchMode == "feed" {
            return await testViaFeed(source)
        }
        if source.fetchMode == "html" {
            return await testViaHTTP(source)
        }

        let browserResult = await testViaWebKit(source)

        guard browserResult.kind == .technicalError || browserResult.kind == .timeout else {
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
            kind: browserResult.kind,
            hitCount: httpResult.hitCount,
            examples: httpResult.examples,
            message:
                "Der Browserabruf ist fehlgeschlagen. Ein direkter HTML-Abruf funktioniert; " +
                "die App kann die Quelle automatisch umstellen.",
            testedAt: Date(),
            repairProposal: repair
        )
    }

    private func testViaFeed(_ source: SourceRecord) async -> SourceTestResult {
        guard let url = URL(string: source.url) else { return failure(source, message: "Die Feed-URL ist ungültig.") }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 18
            request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return failure(source, message: "Feed konnte nicht geladen werden.")
            }
            let xml = String(data: data, encoding: .utf8) ?? ""
            let rows = feedCandidates(xml).prefix(150).map { $0 }
            return classify(source, rows: Array(rows), allRows: Array(rows))
        } catch {
            return failure(source, message: "Feed-Fehler: \(error.localizedDescription)")
        }
    }

    private func feedCandidates(_ xml: String) -> [Candidate] {
        func decode(_ value: String) -> String {
            value.replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let blockPattern = #"(?is)<(?:item|entry)\\b[^>]*>(.*?)</(?:item|entry)>"#
        guard let regex = try? NSRegularExpression(pattern: blockPattern) else { return [] }
        let ns = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let block = ns.substring(with: match.range(at: 1))
            let title = firstMatch(block, pattern: #"(?is)<title\\b[^>]*>(.*?)</title>"#).map(decode) ?? ""
            var link = firstMatch(block, pattern: #"(?is)<link\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*/?>"#) ?? ""
            if link.isEmpty { link = firstMatch(block, pattern: #"(?is)<link\\b[^>]*>(.*?)</link>"#).map(decode) ?? "" }
            let date = firstMatch(block, pattern: #"(?is)<(?:pubDate|published|updated)\\b[^>]*>(.*?)</(?:pubDate|published|updated)>"#).map(decode) ?? ""
            guard !title.isEmpty, !link.isEmpty else { return nil }
            return Candidate(title: title, href: link, date: date)
        }
    }

    private func firstMatch(_ value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private func testViaWebKit(_ source: SourceRecord) async -> SourceTestResult {
        guard let url = URL(string: source.url) else {
            return failure(source, message: "Die URL ist ungültig.")
        }

        self.source = source
        self.finished = false

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            var request = URLRequest(url: url)
            request.timeoutInterval = 18
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 OM-News-Watcher-Mac/3.0",
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
            let wait = min(max(source.waitMs, 0), 8000)
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
            let rawTitle = (row["title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let href = (row["href"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var date = (row["date"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !rawTitle.isEmpty else { return nil }

            if date.isEmpty, let extracted = extractPublicationDate(from: rawTitle) {
                date = extracted
            }

            let title = cleanExtractedTitle(rawTitle)
            guard !title.isEmpty else { return nil }

            return Candidate(title: title, href: href, date: date)
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
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 OM-News-Watcher-Mac/3.0",
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
        let baseFiltered = filter(rows, for: source)
        let filtered = refineSemanticScope(baseFiltered, for: source)
        let count = filtered.count
        let examples = hits(from: filtered)

        if count == 0 {
            let repair = source.visualLearned ? nil : makeRepairProposal(
                source,
                rawRows: allRows.isEmpty ? rows : allRows,
                currentRows: filtered
            )

            let visualNote = source.visualLearned
                ? " Die gespeicherte Einlernregel ist nach einem vollständigen Neuladen nicht reproduzierbar."
                : ""

            return SourceTestResult(
                sourceID: source.id,
                kind: .zeroHits,
                hitCount: 0,
                examples: [],
                message:
                    (repair == nil
                     ? "Keine möglichen Artikel erkannt."
                     : "Keine Treffer mit der aktuellen Regel. Die App hat eine mögliche Artikelstruktur gefunden.") + visualNote,
                testedAt: Date(),
                repairProposal: repair
            )
        }

        let threshold = max(source.maxDetectedItems ?? 0, 80)
        if count > threshold {
            if archiveLooksPlausible(filtered, source: source) {
                return SourceTestResult(
                    sourceID: source.id,
                    kind: .largeArchive,
                    hitCount: count,
                    examples: examples,
                    message: "\(count) strukturell plausible Artikel erkannt. Die hohe Zahl allein wird nicht als Fehler gewertet.",
                    testedAt: Date()
                )
            }

            let repair = source.visualLearned ? nil : makeRepairProposal(
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
                    ? "\(count) Treffer erkannt; darunter sind vermutlich Navigation, fremde Dokumente oder unpassende Bereiche."
                    : "\(count) Treffer erkannt. Ein strukturell passenderer Artikelbereich wurde gefunden.",
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

    private func archiveLooksPlausible(
        _ rows: [Candidate],
        source: SourceRecord
    ) -> Bool {
        guard rows.count >= 20 else { return false }

        let generic = rows.filter { isGenericNavigationTitle($0.title) }.count
        guard Double(generic) / Double(rows.count) < 0.08 else { return false }

        let sourceHost = URL(string: source.url)?.host?.lowercased()
        let hosts = rows.compactMap { URL(string: $0.href)?.host?.lowercased() }
        guard !hosts.isEmpty else { return false }

        let groupedHosts = Dictionary(grouping: hosts, by: { $0 }).mapValues(\.count)
        guard let dominant = groupedHosts.max(by: { $0.value < $1.value }) else { return false }
        let hostRatio = Double(dominant.value) / Double(hosts.count)
        guard hostRatio >= 0.80 else { return false }

        if source.visualLearned,
           let sourceHost,
           dominant.key != sourceHost,
           !dominant.key.hasSuffix(".\(sourceHost)"),
           !sourceHost.hasSuffix(".\(dominant.key)") {
            // Ein visuell eingelerntes Newsroom-Archiv darf nicht plötzlich
            // überwiegend auf einer fremden Asset-/PDF-Domain landen.
            return false
        }

        let paths = rows.compactMap { row -> String? in
            guard let url = URL(string: row.href) else { return nil }
            let parts = url.path.split(separator: "/")
            guard !parts.isEmpty else { return nil }
            return parts.prefix(min(2, parts.count)).joined(separator: "/").lowercased()
        }

        let groupedPaths = Dictionary(grouping: paths, by: { $0 }).mapValues(\.count)
        let bestPath = groupedPaths.values.max() ?? 0
        return Double(bestPath) / Double(max(paths.count, 1)) >= 0.55
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

        // Bei einem großen Ausgangsbestand ist eine Reduktion auf nur 2–3
        // Navigations-/Landingpages fast immer eine Fehlreparatur.
        if currentRows.count >= 80, preview.count < 5 {
            return nil
        }

        let landingCount = preview.filter {
            looksLikeSectionLandingTitle($0.title) || isGenericNavigationTitle($0.title)
        }.count
        if !preview.isEmpty, Double(landingCount) / Double(preview.count) > 0.25 {
            return nil
        }

        // Reparaturvorschläge müssen zum ursprünglichen Quellentyp passen.
        // Newsroom -> fremde PDF-Factsheets ist z. B. keine Reparatur.
        let sourceHost = URL(string: source.url)?.host?.lowercased()
        let previewHosts = preview.compactMap { URL(string: $0.href)?.host?.lowercased() }
        if let sourceHost, !previewHosts.isEmpty {
            let internalCount = previewHosts.filter { host in
                host == sourceHost || host.hasSuffix(".\(sourceHost)") || sourceHost.hasSuffix(".\(host)")
            }.count
            if Double(internalCount) / Double(previewHosts.count) < 0.80 && !source.allowExternal {
                return nil
            }
        }

        let previewPDFs = preview.filter { $0.href.lowercased().contains(".pdf") }.count
        let currentPDFs = currentRows.filter { $0.href.lowercased().contains(".pdf") }.count
        if !currentRows.isEmpty,
           Double(previewPDFs) / Double(preview.count) > 0.70,
           Double(currentPDFs) / Double(currentRows.count) < 0.20 {
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
            guard !looksLikeSectionLandingTitle(title) else { continue }
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
                    $0.date.isEmpty
                    ? nil
                    : displayPublicationDate($0.date)
            )
        }
    }

    private func isGenericNavigationTitle(_ title: String) -> Bool {
        let lower = normalizeWhitespace(title).lowercased()

        let exact = [
            "home", "startseite", "kontakt", "contact", "about", "über uns",
            "impressum", "datenschutz", "privacy", "login", "jobs", "karriere",
            "services", "service", "governance", "unsere werte", "unsere talente",
            "auszeichnungen", "standorte", "locations", "media", "stories",
            "publications", "news", "presse", "press", "menu", "navigation",
            "newsroom", "press releases", "pressemitteilungen", "events",
            "media & resources", "news & resources", "unternehmensnews",
            "unternehmensmitteilungen", "company news", "company updates"
        ]

        if exact.contains(lower) {
            return true
        }

        let prefixes = [
            "mehr erfahren", "read more", "read article", "learn more",
            "weiterlesen", "download", "download for free",
            "zurück", "back", "alle themen", "all topics"
        ]

        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if lower.range(of: #"^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$"#, options: .regularExpression) != nil { return true }
        return false
    }


    private func looksLikeSectionLandingTitle(_ title: String) -> Bool {
        let lower = normalizeWhitespace(title).lowercased()
        let starts = [
            "storys", "stories", "kontakt", "contact", "pressematerial",
            "press material", "media resources", "media & resources",
            "über uns", "about us", "unternehmen", "company"
        ]

        return starts.contains { prefix in
            lower == prefix || lower.hasPrefix(prefix + " ") || lower.hasPrefix(prefix + ":")
        }
    }

    private func isSamePage(_ candidate: String, sourceURL: String) -> Bool {
        guard let a = URL(string: candidate), let b = URL(string: sourceURL) else {
            return false
        }

        func normalizedPath(_ url: URL) -> String {
            let path = url.path.isEmpty ? "/" : url.path
            return path.count > 1 && path.hasSuffix("/")
                ? String(path.dropLast())
                : path
        }

        return a.host?.lowercased() == b.host?.lowercased() &&
            normalizedPath(a) == normalizedPath(b) &&
            (a.query ?? "").isEmpty == (b.query ?? "").isEmpty
    }

    private func matchesVisualSampleShape(
        _ candidate: String,
        source: SourceRecord
    ) -> Bool {
        let samples = source.visualSampleURLs.compactMap { URL(string: $0) }
        guard samples.count >= 2, let url = URL(string: candidate) else {
            return true
        }

        let sampleHosts = Set(samples.compactMap { $0.host?.lowercased() })
        if sampleHosts.count == 1, let host = sampleHosts.first {
            let candidateHost = url.host?.lowercased() ?? ""
            guard candidateHost == host ||
                    candidateHost.hasSuffix(".\(host)") ||
                    host.hasSuffix(".\(candidateHost)") else {
                return false
            }
        }

        let allQueryless = samples.allSatisfy { ($0.query ?? "").isEmpty }
        if allQueryless, !(url.query ?? "").isEmpty {
            return false
        }

        let sampleExtensions = Set(samples.map { $0.pathExtension.lowercased() })
        if sampleExtensions.count == 1, let ext = sampleExtensions.first {
            if ext.isEmpty {
                if ["pdf", "doc", "docx", "xls", "xlsx", "zip"].contains(url.pathExtension.lowercased()) {
                    return false
                }
            } else if url.pathExtension.lowercased() != ext {
                return false
            }
        }

        let sampleParts = samples.map { $0.path.split(separator: "/").map(String.init) }
        let depths = sampleParts.map(\.count)
        if let minDepth = depths.min(), let maxDepth = depths.max(), maxDepth - minDepth <= 1 {
            let depth = url.path.split(separator: "/").count
            if depth < minDepth || depth > maxDepth { return false }
        }

        let leaves = sampleParts.compactMap { $0.last }
        if leaves.count == samples.count, let shortest = leaves.map(\.count).min() {
            let threshold = max(10, min(40, Int(Double(shortest) * 0.45)))
            let candidateLeaf = url.path.split(separator: "/").last.map(String.init) ?? ""
            if candidateLeaf.count < threshold { return false }
        }

        // Gemeinsame Verzeichnisse der Beispiele als semantischen Pfad verwenden.
        if let first = sampleParts.first {
            var common: [String] = []
            let limit = max(0, (sampleParts.map(\.count).min() ?? 0) - 1)
            for index in 0..<limit {
                let component = first[index]
                if sampleParts.allSatisfy({ $0[index] == component }) {
                    common.append(component)
                } else {
                    break
                }
            }

            if !common.isEmpty {
                let candidateParts = url.path.split(separator: "/").map(String.init)
                guard candidateParts.count >= common.count else { return false }
                for (index, component) in common.enumerated() where candidateParts[index] != component {
                    return false
                }
            }
        }

        return true
    }

    private func refineSemanticScope(
        _ rows: [Candidate],
        for source: SourceRecord
    ) -> [Candidate] {
        guard rows.count >= 8, let sourceURL = URL(string: source.url) else {
            return rows
        }

        var sourcePath = sourceURL.path
        if sourcePath.count > 1 && !sourcePath.hasSuffix("/") {
            sourcePath += "/"
        }

        let finalComponent = sourceURL.path
            .split(separator: "/")
            .last?
            .lowercased() ?? ""

        let semanticDirectories: Set<String> = [
            "newsroom", "news", "presse", "press", "press-releases",
            "pressemitteilungen", "stories", "reports", "events"
        ]

        guard semanticDirectories.contains(finalComponent) else {
            return rows
        }

        let scoped = rows.filter { row in
            guard let url = URL(string: row.href) else { return false }
            return isInternal(row.href, sourceURL: source.url) &&
                url.path.hasPrefix(sourcePath) &&
                !isSamePage(row.href, sourceURL: source.url)
        }

        guard scoped.count >= 5 else { return rows }
        let ratio = Double(scoped.count) / Double(rows.count)
        return ratio >= 0.35 ? scoped : rows
    }

    private func cleanExtractedTitle(_ value: String) -> String {
        var result = normalizeWhitespace(value)
        guard !result.isEmpty else { return result }

        // CTA am Ende entfernen.
        result = result.replacingOccurrences(
            of: #"(?i)\s*(?:mehr erfahren|mehr anzeigen|weiterlesen|read article|read more|learn more|download(?: for free)?|zur konferenz)\s*[›>…\.]*\s*$"#,
            with: "",
            options: .regularExpression
        )

        // Typ-Bezeichnungen und doppelte „Presse“-Präfixe entfernen.
        for _ in 0..<3 {
            let cleaned = result.replacingOccurrences(
                of: #"(?i)^(?:presseinformation|pressemitteilung|press release|company update|company updates|presse)\s*[:\-–—]?\s*"#,
                with: "",
                options: .regularExpression
            )
            if cleaned == result { break }
            result = cleaned
        }

        // Datum am Titelanfang abtrennen.
        let datePatterns = [
            #"(?i)^\d{1,2}\.?\s+(?:jan(?:uar)?|feb(?:ruar)?|mär(?:z)?|mrz|apr(?:il)?|mai|jun(?:i)?|jul(?:i)?|aug(?:ust)?|sep(?:tember)?|okt(?:ober)?|nov(?:ember)?|dez(?:ember)?|january|february|march|april|may|june|july|august|september|october|november|december)\.?\s+20\d{2}\s*[:\-–—]?\s*"#,
            #"^20\d{2}-\d{2}-\d{2}(?:T[^\s]+)?\s*[:\-–—]?\s*"#
        ]
        for pattern in datePatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        return normalizeWhitespace(result)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:|· "))
    }

    private func extractPublicationDate(from value: String) -> String? {
        let text = normalizeWhitespace(value)
        let patterns = [
            #"\b\d{1,2}\.?\s+(?:Jan(?:uar)?|Feb(?:ruar)?|Mär(?:z)?|Mrz|Apr(?:il)?|Mai|Jun(?:i)?|Jul(?:i)?|Aug(?:ust)?|Sep(?:tember)?|Okt(?:ober)?|Nov(?:ember)?|Dez(?:ember)?|January|February|March|April|May|June|July|August|September|October|November|December)\.?\s+20\d{2}\b"#,
            #"\b20\d{2}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?(?:[+\-]\d{2}:?\d{2}|Z)?)?\b"#
        ]

        for pattern in patterns {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return String(text[range])
            }
        }
        return nil
    }

    private func displayPublicationDate(_ value: String) -> String {
        let text = normalizeWhitespace(value)

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.dateFormat = "dd.MM.yyyy"
            return formatter.string(from: date)
        }

        let formats = [
            "d. MMM. yyyy", "d. MMM yyyy", "d MMMM yyyy", "d. MMMM yyyy",
            "MMMM d, yyyy", "MMM d, yyyy", "yyyy-MM-dd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = format.contains(",")
                ? Locale(identifier: "en_US_POSIX")
                : Locale(identifier: "de_DE")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                let output = DateFormatter()
                output.locale = Locale(identifier: "de_DE")
                output.dateFormat = "dd.MM.yyyy"
                return output.string(from: date)
            }
        }

        return text
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
            let title = cleanExtractedTitle(row.title)
            guard title.count >= source.minTitleLength else { continue }
            guard !isGenericNavigationTitle(title) else { continue }

            if let pattern = source.includeTitleRegex,
               !matches(title, pattern: pattern) {
                continue
            }

            if let pattern = source.excludeTitleRegex,
               matches(title, pattern: pattern) {
                continue
            }

            let lowerTitle = title.lowercased()
            if !source.includeKeywords.isEmpty &&
               !source.includeKeywords.contains(where: { lowerTitle.contains($0.lowercased()) }) {
                continue
            }
            if source.excludeKeywords.contains(where: { lowerTitle.contains($0.lowercased()) }) {
                continue
            }

            if source.allowTitleOnly && row.href.isEmpty {
                let key = "title:\(title.lowercased())"
                guard seen.insert(key).inserted else { continue }
                result.append(Candidate(title: title, href: "", date: row.date))
                continue
            }

            guard let resolved = resolve(row.href, relativeTo: source.url) else { continue }
            guard !isSamePage(resolved, sourceURL: source.url) else { continue }

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

            if source.visualLearned,
               !matchesVisualSampleShape(resolved, source: source) {
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
            result.append(Candidate(title: title, href: resolved, date: row.date))
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
            "allowTitleOnly": source.allowTitleOnly,
            "smart": source.visualSmartExtraction || source.visualLearned
        ]

        let data = try JSONSerialization.data(withJSONObject: config)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        return #"""
        (() => {
          const cfg = \#(json);
          const clean = text => (text || '').replace(/\s+/g, ' ').trim();
          const rows = [];
          const allRows = [];
          const clickableSelector = 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick]';
          const cardSelector = 'article,li,tr,section,[class*="card" i],[class*="teaser" i],[class*="news" i],[class*="press" i],[class*="event" i],[class*="story" i],[class*="result" i],[class*="item" i],[class*="report" i],[class*="post" i]';

          const generic = value => {
            const lower = clean(value).toLowerCase();
            if (!lower) return true;
            if (/^(mehr erfahren|read more|read article|learn more|weiterlesen|download(?: for free)?|details|more|link öffnet|opens in)/i.test(lower)) return true;
            if (/^pdf\s*[-–—:]?\s*\d+(?:[.,]\d+)?\s*(kb|mb)?$/i.test(lower)) return true;
            return false;
          };

          const pick = (root, selector, fallbackToRoot = false) => {
            if (!root) return null;
            if (!selector) return fallbackToRoot ? root : null;
            try {
              if (root.matches?.(selector)) return root;
              return root.querySelector?.(selector) || null;
            } catch { return null; }
          };

          const cardFor = el => el?.closest?.(cardSelector) || el?.parentElement || el;

          const hrefFrom = (el, root = null) => {
            if (!el && !root) return '';
            const candidates = [el, el?.closest?.('a[href]'), root];
            for (const node of candidates) {
              if (!node?.getAttribute) continue;
              const raw = node.href || node.getAttribute('href') || node.getAttribute('data-href') || node.getAttribute('data-url') || node.getAttribute('data-link') || '';
              if (raw) return raw;
              const onclick = node.getAttribute('onclick') || '';
              const match = onclick.match(/(?:location(?:\.href)?\s*=|window\.open\s*\()\s*['"]([^'"]+)['"]/i);
              if (match?.[1]) return match[1];
            }
            const card = root || cardFor(el);
            const link = card?.querySelector?.('a[href]');
            return link?.href || link?.getAttribute?.('href') || '';
          };

          const smartTitle = (el, root = null) => {
            const card = root || cardFor(el);
            const selectors = [
              'h1','h2','h3','h4','h5','h6',
              '[class*="headline" i]','[class*="heading" i]','[class*="title" i]',
              '[data-testid*="title" i]','strong'
            ];
            for (const selector of selectors) {
              const nodes = Array.from(card?.querySelectorAll?.(selector) || []);
              for (const node of nodes) {
                const value = clean(node.textContent || node.getAttribute?.('aria-label') || node.title || '');
                if (value.length >= 5 && value.length <= 320 && !generic(value)) return value;
              }
            }

            const own = clean(el?.textContent || el?.getAttribute?.('aria-label') || el?.title || '');
            if (own && !generic(own) && own.length <= 320) return own;

            const imgAlt = clean(card?.querySelector?.('img[alt]')?.getAttribute?.('alt') || '');
            if (imgAlt.length >= 8 && !generic(imgAlt)) return imgAlt;
            return own;
          };

          const smartDate = root => {
            const card = root || document;
            const el = card?.querySelector?.('time[datetime],time,[class*="date" i],[class*="datum" i],[class*="published" i],[class*="time" i]');
            return clean(el?.getAttribute?.('datetime') || el?.textContent || '');
          };

          const rowFor = (el, root = null) => {
            const card = root || cardFor(el);
            return {
              title: smartTitle(el, card),
              href: hrefFrom(el, card),
              date: smartDate(card)
            };
          };

          try {
            document.querySelectorAll(clickableSelector).forEach(el => {
              const row = rowFor(el);
              if (row.title && row.href) allRows.push(row);
            });

            if (cfg.allowTitleOnly && cfg.itemSelector) {
              document.querySelectorAll(cfg.itemSelector).forEach(item => {
                const titleEl = pick(item, cfg.titleSelector, !cfg.titleSelector);
                const title = clean(titleEl?.textContent || titleEl?.getAttribute?.('aria-label') || '');
                const dateEl = cfg.dateSelector ? pick(item, cfg.dateSelector) : null;
                const date = clean(dateEl?.getAttribute?.('datetime') || dateEl?.textContent || '');
                if (title) rows.push({ title, href: '', date });
              });
            } else if (cfg.itemSelector) {
              document.querySelectorAll(cfg.itemSelector).forEach(item => {
                let linkEl = cfg.linkSelector ? pick(item, cfg.linkSelector) : null;
                if (!linkEl) linkEl = item.matches?.(clickableSelector) ? item : item.querySelector?.(clickableSelector);
                let titleEl = cfg.titleSelector ? pick(item, cfg.titleSelector) : null;
                let title = clean(titleEl?.textContent || titleEl?.getAttribute?.('aria-label') || '');
                if (!title || generic(title)) title = smartTitle(linkEl || item, item);
                const href = hrefFrom(linkEl || item, item);
                const dateEl = cfg.dateSelector ? pick(item, cfg.dateSelector) : null;
                const date = clean(dateEl?.getAttribute?.('datetime') || dateEl?.textContent || smartDate(item));
                if (title && href) rows.push({ title, href, date });
              });
            }

            if (rows.length === 0 || (cfg.smart && !cfg.itemSelector)) {
              const selector = cfg.candidateSelector || clickableSelector;
              document.querySelectorAll(selector).forEach(el => {
                const row = rowFor(el);
                if (row.title && row.href) rows.push(row);
              });
            }

            return {
              rows: rows.slice(0, 900),
              allRows: allRows.slice(0, 1600),
              error: ''
            };
          } catch (error) {
            return { rows: [], allRows: [], error: String(error) };
          }
        })();
        """#
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
        let lower = message.lowercased()
        let kind: SourceTestKind =
            (lower.contains("zeitüberschreitung") || lower.contains("timed out") || lower.contains("timeout"))
            ? .timeout
            : .technicalError

        return SourceTestResult(
            sourceID: source.id,
            kind: kind,
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
