from pathlib import Path

SOURCE_TESTER = Path("mac-app/OMNewsWatcher/Services/SourceTester.swift")
PROJECT = Path("mac-app/OMNewsWatcher.xcodeproj/project.pbxproj")

OLD_HTTP_ROWS = r'''            let rows = extractAnchors(from: html)
            return classify(source, rows: rows, allRows: rows)
'''

NEW_HTTP_ROWS = r'''            var rows = extractAnchors(from: html)

            // v5.3.9: Manche Newsrooms trennen Überschrift und eigentlichen
            // Pfeil-/Aktionslink so stark, dass selbst der Karten-Kontext im
            // Server-HTML keinen verwertbaren Titel liefert. Wenn die URL
            // bereits durch die eingelernte Regel eindeutig als Artikel
            // qualifiziert ist, laden wir die Zielseite kurz nach und holen
            // den Titel dort. Dadurch bleibt die Regel generisch und muss
            // nicht pro Newsroom mit Sonderselektoren versehen werden.
            if source.visualLearned || !(source.includeRegex ?? "").isEmpty {
                rows = await hydrateMatchingHTTPArticleTargets(
                    rows,
                    from: html,
                    source: source
                )
            }

            return classify(source, rows: rows, allRows: rows)
'''

INSERT_BEFORE_STRIP = r'''    private func stripHTML(_ value: String) -> String {
'''

HELPER = r'''    private func hydrateMatchingHTTPArticleTargets(
        _ rows: [Candidate],
        from html: String,
        source: SourceRecord
    ) async -> [Candidate] {
        let pattern = #"<a\\b[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return rows
        }

        let ns = html as NSString
        let matches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )

        var targets: [String] = []
        var seenTargets = Set<String>()

        for match in matches where match.numberOfRanges >= 2 {
            let rawHref = ns.substring(with: match.range(at: 1))

            guard let resolved = resolve(rawHref, relativeTo: source.url) else {
                continue
            }

            guard source.allowExternal || isInternal(resolved, sourceURL: source.url) else {
                continue
            }

            if let includeRegex = source.includeRegex,
               !includeRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard matches(resolved, pattern: includeRegex) else {
                    continue
                }
            } else if source.visualLearned {
                guard matchesVisualSampleShape(resolved, source: source) else {
                    continue
                }
            } else {
                continue
            }

            let key = resolved.lowercased()
            guard seenTargets.insert(key).inserted else { continue }
            targets.append(resolved)
        }

        guard !targets.isEmpty else {
            return rows
        }

        let limitedTargets = Array(targets.prefix(12))
        let targetKeys = Set(limitedTargets.map { $0.lowercased() })

        var existingByURL: [String: Candidate] = [:]
        for row in rows {
            guard let resolved = resolve(row.href, relativeTo: source.url) else {
                continue
            }
            existingByURL[resolved.lowercased()] = row
        }

        // Die matching Zeilen werden unten bevorzugt mit dem Titel der
        // Detailseite neu eingesetzt. Alle anderen bereits erkannten Links
        // bleiben unverändert erhalten.
        var result = rows.filter { row in
            guard let resolved = resolve(row.href, relativeTo: source.url) else {
                return true
            }
            return !targetKeys.contains(resolved.lowercased())
        }

        for target in limitedTargets {
            if let hydrated = await fetchHTTPArticleMetadata(target) {
                result.append(hydrated)
            } else if let fallback = existingByURL[target.lowercased()] {
                result.append(fallback)
            }
        }

        return result
    }

    private func fetchHTTPArticleMetadata(
        _ urlString: String
    ) async -> Candidate? {
        guard let url = URL(string: urlString) else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 OM-News-Watcher-Mac/3.0",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(
                "text/html,application/xhtml+xml",
                forHTTPHeaderField: "Accept"
            )

            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                return nil
            }

            guard let html = String(data: data, encoding: .utf8),
                  let title = preferredHTMLPageTitle(from: html)
            else {
                return nil
            }

            let pageText = stripHTML(html)
            let date = extractPublicationDate(from: pageText) ?? ""

            return Candidate(
                title: title,
                href: urlString,
                date: date
            )
        } catch {
            return nil
        }
    }

    private func preferredHTMLPageTitle(
        from html: String
    ) -> String? {
        // Der Dokumenttitel ist bei Headless-/Investor-Relations-Seiten
        // meist stabiler als die Kartenstruktur der Übersichtsseite.
        if let raw = firstMatch(
            html,
            pattern: #"(?is)<title\\b[^>]*>(.*?)</title>"#
        ) {
            var title = stripHTML(raw)
            title = title.replacingOccurrences(
                of: #"(?i)\\s*(?:[-–—|]\\s*)Delivery Hero\\s*$"#,
                with: "",
                options: .regularExpression
            )

            if title.count >= 8,
               title.count <= 320,
               !isGenericNavigationTitle(title) {
                return title
            }
        }

        // Generischer Fallback: längste plausible Überschrift der Zielseite.
        let headingPattern = #"(?is)<h[1-6]\\b[^>]*>(.*?)</h[1-6]>"#
        guard let regex = try? NSRegularExpression(
            pattern: headingPattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let ns = html as NSString
        let candidates = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ).compactMap { match -> String? in
            guard match.numberOfRanges >= 2 else { return nil }
            let raw = ns.substring(with: match.range(at: 1))
            let value = stripHTML(raw)
            guard value.count >= 8,
                  value.count <= 320,
                  !isGenericNavigationTitle(value)
            else {
                return nil
            }
            return value
        }

        return candidates.max(by: { $0.count < $1.count })
    }

'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new.strip() in text:
        print(f"{label}: already applied")
        return text
    if old not in text:
        raise SystemExit(f"{label}: expected source block not found")
    print(f"{label}: applied")
    return text.replace(old, new, 1)


def patch_source_tester() -> None:
    text = SOURCE_TESTER.read_text(encoding="utf-8")
    text = replace_once(
        text,
        OLD_HTTP_ROWS,
        NEW_HTTP_ROWS,
        "SourceTester HTTP hydration",
    )

    if "private func hydrateMatchingHTTPArticleTargets(" not in text:
        if INSERT_BEFORE_STRIP not in text:
            raise SystemExit("SourceTester helper insertion point not found")
        text = text.replace(
            INSERT_BEFORE_STRIP,
            HELPER + INSERT_BEFORE_STRIP,
            1,
        )
        print("SourceTester hydration helpers: applied")

    SOURCE_TESTER.write_text(text, encoding="utf-8")


def patch_version() -> None:
    text = PROJECT.read_text(encoding="utf-8")
    if "MARKETING_VERSION = 5.3.9;" in text:
        print("Project: version already 5.3.9")
        return

    old = "MARKETING_VERSION = 5.3.8;"
    count = text.count(old)
    if count == 0:
        raise SystemExit("Project: MARKETING_VERSION 5.3.8 not found")

    PROJECT.write_text(
        text.replace(old, "MARKETING_VERSION = 5.3.9;"),
        encoding="utf-8",
    )
    print(f"Project: bumped {count} version entries to 5.3.9")


if __name__ == "__main__":
    patch_source_tester()
    patch_version()
