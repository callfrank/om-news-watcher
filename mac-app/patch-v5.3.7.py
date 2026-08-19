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

        // v5.3.7: Wenn der Browser-Reload keine Treffer reproduziert,
        // wird die gelernte URL-Regel zusätzlich gegen das echte Server-HTML
        // geprüft. Das ist für Newsrooms wichtig, deren interaktive Oberfläche
        // im eingebetteten Browser anders rendert als beim vollständigen Reload.
        // Eine Regel wird nur übernommen, wenn dieser Live-Test Treffer liefert.
        testingSourceID = sourceID

        for variant in variants {
            guard let regex = variant.urlRegex,
                  !regex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }

            var htmlCandidate = original
            htmlCandidate.applyVisualTrainingRule(variant)
            htmlCandidate.fetchMode = "html"

            statusMessage = "\(original.name): Browser-Reload leer – direkter HTML-Test läuft …"

            let htmlTester = SourceTester()
            activeTester = htmlTester
            let htmlResult = await htmlTester.test(htmlCandidate)
            activeTester = nil

            if bestResult == nil ||
               htmlResult.hitCount > (bestResult?.hitCount ?? -1) {
                bestResult = htmlResult
            }

            let expectedCount = max(
                variant.previewCount,
                variant.sampleCount
            )

            let maximumPlausibleCount = max(
                80,
                expectedCount * 8
            )

            if htmlResult.kind.isSuccessLike,
               htmlResult.hitCount >= variant.sampleCount,
               htmlResult.hitCount <= maximumPlausibleCount {
                htmlCandidate.markVisualTrainingValidated(
                    "Direkter HTML-Abruf bestätigt: \(htmlResult.hitCount) Treffer · \(variant.strategy)"
                )

                sources[index] = htmlCandidate
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
            "Weder der Browser-Reload noch der direkte HTML-Live-Test konnten die markierten Beispiele zuverlässig reproduzieren. " +
            "Die vorherige Regel bleibt unverändert."

        statusMessage = "\(original.name): Einlernregel nicht reproduzierbar – unverändert"
'''


def patch_app_view_model() -> None:
    text = APP_VIEW_MODEL.read_text(encoding="utf-8")

    if "Einlernregel per HTML-Live-Test validiert – bitte speichern" in text:
        print("AppViewModel: v5.3.7 live HTML fallback already present")
        return

    if OLD_BLOCK not in text:
        raise SystemExit(
            "AppViewModel: expected visual-training validation block not found; refusing unsafe patch"
        )

    APP_VIEW_MODEL.write_text(
        text.replace(OLD_BLOCK, NEW_BLOCK, 1),
        encoding="utf-8",
    )
    print("AppViewModel: v5.3.7 live HTML validation fallback applied")


def patch_version() -> None:
    text = PROJECT.read_text(encoding="utf-8")

    if "MARKETING_VERSION = 5.3.7;" in text:
        print("Project: version already 5.3.7")
        return

    old = "MARKETING_VERSION = 5.3.5;"
    count = text.count(old)
    if count == 0:
        raise SystemExit(
            "Project: MARKETING_VERSION 5.3.5 not found; refusing unsafe version rewrite"
        )

    PROJECT.write_text(
        text.replace(old, "MARKETING_VERSION = 5.3.7;"),
        encoding="utf-8",
    )
    print(f"Project: bumped {count} MARKETING_VERSION entries to 5.3.7")


if __name__ == "__main__":
    patch_app_view_model()
    patch_version()
