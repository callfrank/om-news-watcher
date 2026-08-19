from pathlib import Path

SOURCE_TESTER = Path("mac-app/OMNewsWatcher/Services/SourceTester.swift")
PROJECT = Path("mac-app/OMNewsWatcher.xcodeproj/project.pbxproj")

OLD_TARGET_DISCOVERY = r'''        let ns = html as NSString
        let anchorMatches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )

        var targets: [String] = []
        var seenTargets = Set<String>()

        for match in anchorMatches where match.numberOfRanges >= 2 {
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
'''

NEW_TARGET_DISCOVERY = r'''        let ns = html as NSString
        let anchorMatches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )

        var rawCandidates: [String] = []

        for match in anchorMatches where match.numberOfRanges >= 2 {
            rawCandidates.append(
                ns.substring(with: match.range(at: 1))
            )
        }

        // v5.4.0: Headless-/React-Seiten legen News-URLs häufig nur in
        // eingebettetem JSON oder JavaScript ab. Diese Strings sind im
        // Server-HTML vorhanden, aber nicht als <a href>. Deshalb scannen
        // wir zusätzlich die eingebetteten URL-/Pfad-Strings. Akzeptiert
        // werden anschließend weiterhin ausschließlich Ziele, die zur
        // eingelernten URL-Regel bzw. zur Form der Trainingsbeispiele passen.
        rawCandidates.append(
            contentsOf: embeddedURLCandidates(from: html)
        )

        var targets: [String] = []
        var seenTargets = Set<String>()

        for rawHref in rawCandidates {
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
'''

INSERT_BEFORE_METADATA = r'''    private func fetchHTTPArticleMetadata(
'''

EMBEDDED_HELPER = r'''    private func embeddedURLCandidates(
        from html: String
    ) -> [String] {
        var decoded = html

        // JSON-/JavaScript-Escapes schrittweise auflösen. Zweimalige
        // Anwendung deckt auch doppelt escaped serialisierte Daten ab.
        for _ in 0..<2 {
            decoded = decoded
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(
                    of: "\\u002F",
                    with: "/",
                    options: [.caseInsensitive]
                )
        }

        decoded = decoded
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(
                of: "&#x2F;",
                with: "/",
                options: [.caseInsensitive]
            )
            .replacingOccurrences(of: "&#47;", with: "/")

        let patterns = [
            #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#,
            #"/(?:[A-Za-z0-9._~!$&'()*+,;=:@%\-]+/){2,}[A-Za-z0-9._~!$&'()*+,;=:@%\-]+"#
        ]

        let ns = decoded as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var result: [String] = []
        var seen = Set<String>()

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            for match in regex.matches(
                in: decoded,
                options: [],
                range: fullRange
            ) {
                var value = ns.substring(with: match.range)
                    .trimmingCharacters(
                        in: CharacterSet(charactersIn: ".,;:)]}>")
                    )

                // Häufige JSON-/HTML-Reste am Ende eines URL-Strings entfernen.
                while value.hasSuffix("\\") {
                    value.removeLast()
                }

                guard value.count >= 4 else { continue }
                guard seen.insert(value.lowercased()).inserted else { continue }
                result.append(value)

                if result.count >= 500 {
                    return result
                }
            }
        }

        return result
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
        OLD_TARGET_DISCOVERY,
        NEW_TARGET_DISCOVERY,
        "SourceTester embedded URL discovery",
    )

    if "private func embeddedURLCandidates(" not in text:
        if INSERT_BEFORE_METADATA not in text:
            raise SystemExit("SourceTester metadata insertion point not found")
        text = text.replace(
            INSERT_BEFORE_METADATA,
            EMBEDDED_HELPER + INSERT_BEFORE_METADATA,
            1,
        )
        print("SourceTester embedded URL helper: applied")

    SOURCE_TESTER.write_text(text, encoding="utf-8")


def patch_version() -> None:
    text = PROJECT.read_text(encoding="utf-8")
    if "MARKETING_VERSION = 5.4.0;" in text:
        print("Project: version already 5.4.0")
        return

    old = "MARKETING_VERSION = 5.3.9;"
    count = text.count(old)
    if count == 0:
        raise SystemExit("Project: MARKETING_VERSION 5.3.9 not found")

    PROJECT.write_text(
        text.replace(old, "MARKETING_VERSION = 5.4.0;"),
        encoding="utf-8",
    )
    print(f"Project: bumped {count} version entries to 5.4.0")


if __name__ == "__main__":
    patch_source_tester()
    patch_version()
