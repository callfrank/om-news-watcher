from pathlib import Path

APP_VIEW_MODEL = Path("mac-app/OMNewsWatcher/ViewModels/AppViewModel.swift")
SOURCE_TESTER = Path("mac-app/OMNewsWatcher/Services/SourceTester.swift")
PROJECT = Path("mac-app/OMNewsWatcher.xcodeproj/project.pbxproj")

OLD_VALIDATION = r'''        guard let candidate = acceptedSource,
              let result = bestResult
        else {
            if let bestResult {
                testResults[sourceID] = bestResult
            }

            errorMessage =
                "Die neue Einlernregel wurde nicht gespeichert. " +
                "Die App hat URL-Muster und Kartenstruktur nach einem vollständigen Neuladen geprüft, " +
                "konnte die markierten Beispiele aber nicht stabil reproduzieren. " +
                "Die vorherige Regel bleibt unverändert."

            statusMessage = "\(original.name): Einlernregel nach Reload verworfen"
            return
        }

        sources[index] = candidate
        testResults[sourceID] = result
        isDirty = true
        statusMessage = "\(original.name): Einlernregel validiert – bitte speichern"
'''

NEW_VALIDATION = r'''        if let candidate = acceptedSource,
           let result = bestResult {
            sources[index] = candidate
            testResults[sourceID] = result
            isDirty = true
            statusMessage = "\(original.name): Einlernregel validiert – bitte speichern"
            return
        }

        // v5.3.8: Zweite Live-Validierung über das Server-HTML.
        // Wichtig: fetchMode=html wird NUR für die Prüfung benutzt. Die
        // gespeicherte Quelle bleibt im normalen Browser-/Auto-Modus, damit
        // der GitHub-Watcher weiterhin seine kartensensitive DOM-Auswertung
        // nutzen kann.
        testingSourceID = sourceID

        for variant in variants {
            guard let regex = variant.urlRegex,
                  !regex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }

            var htmlProbe = original
            htmlProbe.applyVisualTrainingRule(variant)
            htmlProbe.fetchMode = "html"

            statusMessage = "\(original.name): Browser-Reload leer – HTML-Live-Test läuft …"

            let htmlTester = SourceTester()
            activeTester = htmlTester
            let htmlResult = await htmlTester.test(htmlProbe)
            activeTester = nil

            if bestResult == nil ||
               htmlResult.hitCount > (bestResult?.hitCount ?? -1) {
                bestResult = htmlResult
            }

            let expectedCount = max(
                variant.previewCount,
                variant.sampleCount
            )
            let maximumPlausibleCount = max(80, expectedCount * 8)

            if htmlResult.kind.isSuccessLike,
               htmlResult.hitCount >= variant.sampleCount,
               htmlResult.hitCount <= maximumPlausibleCount {
                var savedCandidate = original
                savedCandidate.applyVisualTrainingRule(variant)
                savedCandidate.markVisualTrainingValidated(
                    "HTML-Live-Test bestätigt: \(htmlResult.hitCount) Treffer · \(variant.strategy)"
                )

                sources[index] = savedCandidate
                testResults[sourceID] = htmlResult
                isDirty = true
                testingSourceID = nil
                errorMessage = nil
                statusMessage = "\(original.name): Einlernregel per HTML-Live-Test validiert – bitte speichern"
                return
            }
        }

        testingSourceID = nil

        if let bestResult {
            testResults[sourceID] = bestResult
        }

        errorMessage =
            "Die neue Einlernregel wurde nicht gespeichert. " +
            "Weder Browser-Reload noch HTML-Live-Test konnten die markierten Beispiele reproduzieren. " +
            "Die vorherige Regel bleibt unverändert."

        statusMessage = "\(original.name): Einlernregel nicht reproduzierbar – unverändert"
'''

OLD_CARD_FOR = r'''          const cardFor = el => el?.closest?.(cardSelector) || el?.parentElement || el;
'''

NEW_CARD_FOR = r'''          const cardFor = el => {
            const semantic = el?.closest?.(cardSelector);
            if (semantic) return semantic;

            let node = el?.parentElement;
            const fallback = node || el;
            const titleProbeSelector = 'h1,h2,h3,h4,h5,h6,[class*="headline" i],[class*="heading" i],[class*="title" i],[data-testid*="title" i],strong';
            const clickableProbeSelector = 'a[href],[data-href],[data-url],[data-link],[role="link"],button[onclick],[onclick]';

            for (let depth = 0; node && depth < 9 && node !== document.body && node !== document.documentElement; depth += 1, node = node.parentElement) {
              const text = clean(node.textContent || '');
              if (text.length < 8 || text.length > 3000) continue;

              const linkCount = node.querySelectorAll?.(clickableProbeSelector)?.length || 0;
              if (linkCount < 1 || linkCount > 16) continue;

              const hasPlausibleTitle = Array.from(node.querySelectorAll?.(titleProbeSelector) || []).some(candidate => {
                const value = clean(candidate.textContent || candidate.getAttribute?.('aria-label') || candidate.title || '');
                return value.length >= 5 && value.length <= 320 && !generic(value);
              });

              if (hasPlausibleTitle) return node;
            }

            return fallback;
          };
'''

OLD_HTTP_EXTRACT = r'''            let title = stripHTML(inner)

            guard !title.isEmpty else { return nil }

            return Candidate(
                title: title,
                href: href,
                date: ""
            )
'''

NEW_HTTP_EXTRACT = r'''            var title = stripHTML(inner)
            var date = ""

            // Manche Newsrooms trennen Überschrift und eigentlichen Link
            // (z. B. ein Pfeil-Button). Dann ist der <a>-Text leer, obwohl
            // der umgebende Kartenblock eine saubere Überschrift enthält.
            if title.isEmpty || title.count < 5 || isGenericNavigationTitle(title) {
                let contextStart = max(0, match.range.location - 1800)
                let contextEnd = min(
                    ns.length,
                    NSMaxRange(match.range) + 700
                )
                let contextRange = NSRange(
                    location: contextStart,
                    length: max(0, contextEnd - contextStart)
                )
                let context = ns.substring(with: contextRange)

                if let nearbyTitle = nearestHTMLCardTitle(in: context) {
                    title = nearbyTitle
                }

                date = extractPublicationDate(
                    from: stripHTML(context)
                ) ?? ""
            }

            guard !title.isEmpty else { return nil }

            return Candidate(
                title: title,
                href: href,
                date: date
            )
'''

INSERT_BEFORE_STRIP = r'''    private func stripHTML(_ value: String) -> String {
'''

HELPER = r'''    private func nearestHTMLCardTitle(in html: String) -> String? {
        let patterns = [
            #"(?is)<h[1-6]\\b[^>]*>(.*?)</h[1-6]>"#,
            #"(?is)<[^>]+\\bclass\\s*=\\s*[\"'][^\"']*(?:headline|heading|title)[^\"']*[\"'][^>]*>(.*?)</[^>]+>"#
        ]

        var candidates: [String] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }

            let ns = html as NSString
            let matches = regex.matches(
                in: html,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            )

            for match in matches where match.numberOfRanges >= 2 {
                let raw = ns.substring(with: match.range(at: 1))
                let value = stripHTML(raw)
                if value.count >= 5,
                   value.count <= 320,
                   !isGenericNavigationTitle(value) {
                    candidates.append(value)
                }
            }
        }

        return candidates.last
    }

'''

OLD_PERFORM_GUARD = r'''        guard browserResult.kind == .technicalError || browserResult.kind == .timeout else {
            return browserResult
        }
'''

NEW_PERFORM_GUARD = r'''        let shouldTryHTTPFallback =
            browserResult.kind == .technicalError ||
            browserResult.kind == .timeout ||
            (
                browserResult.kind == .zeroHits &&
                (source.visualLearned || !(source.includeRegex ?? "").isEmpty)
            )

        guard shouldTryHTTPFallback else {
            return browserResult
        }
'''

OLD_HTTP_RETURN = r'''        guard httpResult.kind != .technicalError else {
            return browserResult
        }

        let baseRepair = httpResult.repairProposal
'''

NEW_HTTP_RETURN = r'''        guard httpResult.kind != .technicalError else {
            return browserResult
        }

        if httpResult.kind.isSuccessLike,
           httpResult.hitCount > 0,
           browserResult.kind == .zeroHits {
            return SourceTestResult(
                sourceID: source.id,
                kind: httpResult.kind,
                hitCount: httpResult.hitCount,
                examples: httpResult.examples,
                eligibleCount: httpResult.eligibleCount,
                eligibleExamples: httpResult.eligibleExamples,
                rejectedExamples: httpResult.rejectedExamples,
                message:
                    httpResult.message +
                    " Browser-Reload war leer; direkter HTML-Fallback wurde verwendet.",
                testedAt: Date(),
                repairProposal: httpResult.repairProposal
            )
        }

        let baseRepair = httpResult.repairProposal
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new.strip() in text:
        print(f"{label}: already applied")
        return text
    if old not in text:
        raise SystemExit(f"{label}: expected source block not found")
    print(f"{label}: applied")
    return text.replace(old, new, 1)


def patch_app_view_model() -> None:
    text = APP_VIEW_MODEL.read_text(encoding="utf-8")
    if "Einlernregel per HTML-Live-Test validiert – bitte speichern" not in text:
        text = replace_once(
            text,
            OLD_VALIDATION,
            NEW_VALIDATION,
            "AppViewModel validation",
        )
    APP_VIEW_MODEL.write_text(text, encoding="utf-8")


def patch_source_tester() -> None:
    text = SOURCE_TESTER.read_text(encoding="utf-8")
    text = replace_once(text, OLD_CARD_FOR, NEW_CARD_FOR, "SourceTester smart card")
    text = replace_once(text, OLD_HTTP_EXTRACT, NEW_HTTP_EXTRACT, "SourceTester HTML card title")
    if "private func nearestHTMLCardTitle(in html: String)" not in text:
        if INSERT_BEFORE_STRIP not in text:
            raise SystemExit("SourceTester helper insertion point not found")
        text = text.replace(
            INSERT_BEFORE_STRIP,
            HELPER + INSERT_BEFORE_STRIP,
            1,
        )
        print("SourceTester HTML helper: applied")
    text = replace_once(text, OLD_PERFORM_GUARD, NEW_PERFORM_GUARD, "SourceTester zero-hit fallback")
    text = replace_once(text, OLD_HTTP_RETURN, NEW_HTTP_RETURN, "SourceTester HTML result fallback")
    SOURCE_TESTER.write_text(text, encoding="utf-8")


def patch_version() -> None:
    text = PROJECT.read_text(encoding="utf-8")
    if "MARKETING_VERSION = 5.3.8;" in text:
        print("Project: version already 5.3.8")
        return
    old = "MARKETING_VERSION = 5.3.5;"
    count = text.count(old)
    if count == 0:
        raise SystemExit("Project: MARKETING_VERSION 5.3.5 not found")
    PROJECT.write_text(
        text.replace(old, "MARKETING_VERSION = 5.3.8;"),
        encoding="utf-8",
    )
    print(f"Project: bumped {count} version entries to 5.3.8")


if __name__ == "__main__":
    patch_app_view_model()
    patch_source_tester()
    patch_version()
