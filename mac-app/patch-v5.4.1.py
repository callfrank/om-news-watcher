from pathlib import Path

APP_VIEW_MODEL = Path("mac-app/OMNewsWatcher/ViewModels/AppViewModel.swift")
PROJECT = Path("mac-app/OMNewsWatcher.xcodeproj/project.pbxproj")

OLD_FAILURE = r'''        testingSourceID = nil

        if let bestResult {
            testResults[sourceID] = bestResult
        }

        errorMessage =
            "Die neue Einlernregel wurde nicht gespeichert. " +
            "Weder Browser-Reload noch HTML-Live-Test konnten die markierten Beispiele reproduzieren. " +
            "Die vorherige Regel bleibt unverändert."

        statusMessage = "\(original.name): Einlernregel nicht reproduzierbar – unverändert"
'''

NEW_FAILURE = r'''        testingSourceID = nil

        // v5.4.1: Wenn Browser- und HTML-Reproduktion technisch scheitern,
        // darf ein enges URL-Muster trotzdem anhand der vom Benutzer
        // tatsächlich markierten Beispiel-URLs validiert werden. Das ist
        // deutlich belastbarer als weitere seitenabhängige DOM-Fallbacks:
        // Alle Beispiele müssen vollständig vom Regex erfasst werden,
        // denselben internen Host besitzen und unterschiedliche Detailziele
        // darstellen. Der GitHub-Watcher bleibt anschließend der produktive
        // End-to-End-Nachweis.
        for variant in variants {
            guard variant.strategy.contains("URL-Muster"),
                  let pattern = variant.urlRegex,
                  !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  variant.sampleCount >= 2,
                  variant.sampleURLs.count >= variant.sampleCount,
                  let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                  )
            else {
                continue
            }

            let sampleURLs = Array(
                variant.sampleURLs.prefix(variant.sampleCount)
            )

            let allMatchExactly = sampleURLs.allSatisfy { value in
                let range = NSRange(
                    value.startIndex..<value.endIndex,
                    in: value
                )
                guard let match = regex.firstMatch(
                    in: value,
                    options: [],
                    range: range
                ) else {
                    return false
                }
                return match.range == range
            }

            guard allMatchExactly else { continue }

            let parsed = sampleURLs.compactMap(URL.init(string:))
            guard parsed.count == sampleURLs.count else { continue }

            let hosts = Set(
                parsed.compactMap { $0.host?.lowercased() }
            )
            guard hosts.count == 1,
                  let sampleHost = hosts.first,
                  let sourceHost = URL(string: original.url)?.host?.lowercased(),
                  sampleHost == sourceHost ||
                    sampleHost.hasSuffix(".\(sourceHost)") ||
                    sourceHost.hasSuffix(".\(sampleHost)")
            else {
                continue
            }

            let pathParts = parsed.map {
                $0.path.split(separator: "/").map(String.init)
            }
            guard pathParts.allSatisfy({ $0.count >= 3 }) else {
                continue
            }

            let leaves = Set(
                pathParts.compactMap { $0.last?.lowercased() }
            )
            guard leaves.count >= 2 else { continue }

            var savedCandidate = original
            savedCandidate.applyVisualTrainingRule(variant)
            savedCandidate.markVisualTrainingValidated(
                "Markierte Beispiel-URLs bestätigen das enge URL-Muster · \(variant.strategy) · GitHub-Endtest ausstehend"
            )

            sources[index] = savedCandidate
            if let bestResult {
                testResults[sourceID] = bestResult
            } else {
                testResults.removeValue(forKey: sourceID)
            }
            isDirty = true
            errorMessage = nil
            statusMessage = "\(original.name): URL-Muster anhand der markierten Beispiele validiert – bitte speichern und GitHub-Watcher starten"
            return
        }

        if let bestResult {
            testResults[sourceID] = bestResult
        }

        errorMessage =
            "Die neue Einlernregel wurde nicht gespeichert. " +
            "Weder Browser-Reload, HTML-Live-Test noch die markierten Beispiel-URLs konnten ein ausreichend enges Muster bestätigen. " +
            "Die vorherige Regel bleibt unverändert."

        statusMessage = "\(original.name): Einlernregel nicht reproduzierbar – unverändert"
'''


def patch_view_model() -> None:
    text = APP_VIEW_MODEL.read_text(encoding="utf-8")
    if NEW_FAILURE.strip() in text:
        print("AppViewModel sample URL fallback already applied")
        return
    if OLD_FAILURE not in text:
        raise SystemExit("AppViewModel v5.3.8 failure block not found")
    APP_VIEW_MODEL.write_text(
        text.replace(OLD_FAILURE, NEW_FAILURE, 1),
        encoding="utf-8",
    )
    print("AppViewModel sample URL fallback applied")


def patch_version() -> None:
    text = PROJECT.read_text(encoding="utf-8")
    if "MARKETING_VERSION = 5.4.1;" in text:
        print("Project: version already 5.4.1")
        return

    old = "MARKETING_VERSION = 5.4.0;"
    count = text.count(old)
    if count == 0:
        raise SystemExit("Project: MARKETING_VERSION 5.4.0 not found")

    PROJECT.write_text(
        text.replace(old, "MARKETING_VERSION = 5.4.1;"),
        encoding="utf-8",
    )
    print(f"Project: bumped {count} version entries to 5.4.1")


if __name__ == "__main__":
    patch_view_model()
    patch_version()
