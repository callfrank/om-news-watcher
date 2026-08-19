from pathlib import Path

SOURCE_TESTER = Path("mac-app/OMNewsWatcher/Services/SourceTester.swift")

OLD = '''        let ns = html as NSString
        let matches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )

        var targets: [String] = []
        var seenTargets = Set<String>()

        for match in matches where match.numberOfRanges >= 2 {
'''

NEW = '''        let ns = html as NSString
        let anchorMatches = regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        )

        var targets: [String] = []
        var seenTargets = Set<String>()

        for match in anchorMatches where match.numberOfRanges >= 2 {
'''

text = SOURCE_TESTER.read_text(encoding="utf-8")

if NEW in text:
    print("5.3.9 hotfix already applied")
elif OLD in text:
    SOURCE_TESTER.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
    print("5.3.9 hotfix applied")
else:
    raise SystemExit("5.3.9 hotfix target block not found")
