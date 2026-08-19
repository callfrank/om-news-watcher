import json
from pathlib import Path

SOURCES = Path("sources.json")


def main() -> None:
    data = json.loads(SOURCES.read_text(encoding="utf-8"))
    found = False

    for source in data:
        if source.get("name") != "Wero":
            continue

        found = True
        source["allowExternal"] = False
        source["allowTitleOnly"] = False
        source["candidateSelector"] = (
            'a[href^="/media-insights/"],'
            'a[href*="epicompany.eu/media-insights/"]'
        )
        source["includeRegex"] = (
            r'^https?://(?:www\.)?epicompany\.eu/media-insights/[^/?#]+/?'
            r'(?:\?[^#]*)?(?:#.*)?$'
        )
        source["minTitleLength"] = 8
        break

    if not found:
        raise SystemExit("Wero source not found")

    SOURCES.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("Wero source rule applied")


if __name__ == "__main__":
    main()
