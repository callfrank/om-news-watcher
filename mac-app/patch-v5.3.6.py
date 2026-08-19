from pathlib import Path

APP_VIEW_MODEL = Path("mac-app/OMNewsWatcher/ViewModels/AppViewModel.swift")
PROJECT = Path("mac-app/OMNewsWatcher.xcodeproj/project.pbxproj")

OLD_BLOCK = r'''        guard let candidate = acceptedSource,
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

NEW_BLOCK = r'''        if let candidate = acceptedSource,
           let result = bestResult {
            sources[index] = candidate
            testResults[sourceID] = result
            isDirty = true
            statusMessage = "\(original.name): Einlernregel validiert – bitte speichern"
            return
        }

        // v5.3.6: Eine dynamische Seite darf eine sauber markierte Regel nicht mehr
        // nur deshalb verlieren, weil genau der nachgelagerte Reload gerade 0 Treffer
        // liefert. Die markierten Beispiel-URLs werden als zweite Validierungsebene
        // verwendet. Nur stabile, interne URL-Muster dürfen diesen Fallback nutzen.
        let sampleURLs = rule.sampleURLs.compactMap { URL(string: $0) }
        let sourceHost = URL(string: original.url)?.host?.lowercased()
        let sampleHosts = Set(
            sampleURLs.compactMap { $0.host?.lowercased() }
        )
        let sampleDepths = sampleURLs.map {
            $0.path.split(separator: "/").count
        }

        let sameInternalHost: Bool = {
            guard let sourceHost,
                  sampleHosts.count == 1,
                  let sampleHost = sampleHosts.first
            else {
                return false
            }

            return sampleHost == sourceHost ||
                sampleHost.hasSuffix(".\(sourceHost)") ||
                sourceHost.hasSuffix(".\(sampleHost)")
        }()

        let stablePathShape: Bool = {
            guard sampleURLs.count >= 2,
                  let minimumDepth = sampleDepths.min(),
                  let maximumDepth = sampleDepths.max()
            else {
                return false
            }

            return maximumDepth - minimumDepth <= 2
        }()

        let hasStableURLRule =
            !(rule.urlRegex ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty

        if rule.isUsable,
           sameInternalHost,
           stablePathShape,
           hasStableURLRule {
            var fallbackCandidate = original
            fallbackCandidate.applyVisualTrainingRule(rule)
            fallbackCandidate.markVisualTrainingValidated(
                "Mit Fallback übernommen: \(rule.sampleCount) markierte Beispiele · Reload lieferte vorübergehend keine reproduzierbaren Treffer"
            )

            sources[index] = fallbackCandidate
            if let bestResult {
                testResults[sourceID] = bestResult
            }
            isDirty = true
            errorMessage = nil
            statusMessage = "\(original.name): Einlernregel mit Fallback validiert – bitte speichern"
            return
        }

        if let bestResult {
            testResults[sourceID] = bestResult
        }

        errorMessage =
            "Die neue Einlernregel wurde nicht gespeichert. " +
            "Weder der Reload-Test noch die markierten Beispiel-URLs ergaben ein ausreichend stabiles internes URL-Muster. " +
            "Die vorherige Regel bleibt unverändert."

        statusMessage = "\(original.name): Einlernregel nach Reload verworfen"
'''


def patch_app_view_model() -> None:
    text = APP_VIEW_MODEL.read_text(encoding="utf-8")

    if "Einlernregel mit Fallback validiert – bitte speichern" in text:
        print("AppViewModel: v5.3.6 fallback already present")
        return

    if OLD_BLOCK not in text:
        raise SystemExit(
            "AppViewModel: expected validation block not found; aborting instead of patching an unknown source state"
        )

    APP_VIEW_MODEL.write_text(
        text.replace(OLD_BLOCK, NEW_BLOCK, 1),
        encoding="utf-8",
    )
    print("AppViewModel: v5.3.6 fallback applied")


def patch_version() -> None:
    text = PROJECT.read_text(encoding="utf-8")

    if "MARKETING_VERSION = 5.3.6;" in text:
        print("Project: version already 5.3.6")
        return

    old = "MARKETING_VERSION = 5.3.5;"
    count = text.count(old)
    if count == 0:
        raise SystemExit(
            "Project: MARKETING_VERSION 5.3.5 not found; refusing an unsafe version rewrite"
        )

    PROJECT.write_text(
        text.replace(old, "MARKETING_VERSION = 5.3.6;"),
        encoding="utf-8",
    )
    print(f"Project: bumped {count} MARKETING_VERSION entries to 5.3.6")


if __name__ == "__main__":
    patch_app_view_model()
    patch_version()
