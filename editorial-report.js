import fs from "node:fs/promises";
import path from "node:path";

const repoRoot = process.cwd();
const statePath = path.join(repoRoot, "data", "editorial-state.json");
const itemsPath = path.join(repoRoot, "data", "items.json");
const latestMdPath = path.join(repoRoot, "docs", "editorial", "latest.md");
const latestHtmlPath = path.join(repoRoot, "docs", "editorial", "latest.html");

function berlinParts(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Berlin",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", weekday: "short",
    hourCycle: "h23"
  }).formatToParts(date);
  return Object.fromEntries(parts.map(({ type, value }) => [type, value]));
}

function asArray(value) {
  if (Array.isArray(value)) return value;
  if (value && typeof value === "object") return Object.values(value);
  return [];
}

async function readJson(file, fallback) {
  try { return JSON.parse(await fs.readFile(file, "utf8")); }
  catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw error;
  }
}

function compactItem(item) {
  const pick = (keys) => keys.map((key) => item?.[key]).find((v) => v !== undefined && v !== null && v !== "");
  return {
    title: pick(["title", "name", "headline"]),
    url: pick(["url", "link", "href"]),
    source: pick(["sourceName", "source", "feedName", "publisher"]),
    publishedAt: pick(["publishedAt", "published", "date", "publishedDate"]),
    detectedAt: pick(["detectedAt", "createdAt", "timestamp", "foundAt"]),
    category: pick(["folder", "category", "topic"]),
    relevance: pick(["relevance", "score", "stars"])
  };
}

function escapeHtml(text) {
  return text.replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[char]);
}

async function main() {
  const now = new Date();
  const berlin = berlinParts(now);
  const hour = Number(berlin.hour);
  const minute = Number(berlin.minute);
  const isMorningWindow = hour === 7 && minute >= 30;
  const isNoonWindow = hour === 12;
  if (!isMorningWindow && !isNoonWindow) {
    console.log(`Nicht im Berliner Zielzeitfenster (${berlin.hour}:${berlin.minute}); Lauf wird beendet.`);
    return;
  }

  if (!process.env.OPENAI_API_KEY) {
    throw new Error("GitHub-Secret OPENAI_API_KEY fehlt. Der Sol-Bericht wurde nicht erzeugt.");
  }

  const state = await readJson(statePath, {
    lastSuccessfulRun: null,
    lastReport: "",
    recentTopics: []
  });
  const rawItems = await readJson(itemsPath, []);
  const candidates = asArray(rawItems)
    .map(compactItem)
    .filter((item) => item.title && item.url)
    .slice(0, 120);

  const runStamp = `${berlin.day}.${berlin.month}.${berlin.year}, ${hhmm} Uhr`;
  const prompt = `Du bist der E-Commerce-News-Watcher für onlinemarktplatz.de.
Erstelle genau einen kompakten, redaktionell verwertbaren Bericht in deutscher Sprache.
Stand des Laufs: ${runStamp} (Europe/Berlin).
Vorheriger erfolgreicher Lauf: ${state.lastSuccessfulRun || "keiner"}.

Arbeite zuerst systematisch in vier getrennten Feldern:
1. offizielle Newsrooms/Pressebereiche relevanter Marktplätze, Händler, Shopsoftware-, Payment- und Logistikanbieter;
2. Investor-Relations-Seiten und regulatorische Finanzberichte;
3. Behörden, Gerichte, Gesetzgeber und EU-Institutionen;
4. Verbände, Forschungsinstitute sowie offizielle Produkt- und Entwicklerankündigungen.
Nutze Websuche zur Entdeckung und öffne konkrete Primärquellen. Medien sind nur Hinweise, keine alleinige Basis.
Prüfe danach die aktuelle Berichterstattung auf onlinemarktplatz.de auf inhaltliche Dubletten.

Berücksichtige vorrangig Veröffentlichungen seit dem vorherigen erfolgreichen Lauf. Wiederhole kein Thema aus dem vorherigen Bericht, außer eine substanzielle neue Entwicklung ist ausdrücklich benannt.
Wähle höchstens fünf, aber niemals schwache Füllthemen. Internationale Meldungen nur mit konkreter Relevanz für Deutschland, Europa, Händler, Marken oder Marktplatz-Verkäufer.
Trenne strikt bestätigte Fakten, Schätzungen/Prognosen und offene Fragen. Verwechsle bei Finanzdaten nie Umsatz mit GMV/GTV oder Ergebnis.

Wenn nach vollständiger Recherche und Dublettenprüfung kein ausreichend relevanter neuer Treffer vorliegt, gib ausschließlich diesen Satz aus:
Heute keine neuen relevanten Quellen-Treffer für onlinemarktplatz.de.

Andernfalls beginne exakt mit:
E-Commerce-News-Watcher für onlinemarktplatz.de
Stand: ${runStamp}, Europe/Berlin

Danach pro Thema exakt diese Felder:
Priorität [1-5]: [präzise mögliche Überschrift]
Veröffentlichungsdatum:
Ereignisdatum:
Kernaussage:
Relevanz für Händler und E-Commerce:
Bestätigte Fakten:
Schätzungen oder Prognosen:
Offene Fragen:
Dublettenprüfung:
Empfohlene nächste Schritte/Artikelpotenzial:
Wichtigste Primärquelle: [Bezeichnung mit direktem Link]

Schreibe neutral, präzise, kritisch und ohne PR-Sprache oder Clickbait. Erstelle, veröffentliche oder terminiere keinen WordPress-Beitrag und ändere keinerlei Website-Inhalte.

Kandidaten aus dem bestehenden Quellen-Watcher (nur als Ausgangspunkt, nicht ungeprüft übernehmen):
${JSON.stringify(candidates)}

Vorheriger Bericht zur Dublettenprüfung:
${state.lastReport || "(noch keiner)"}`;

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${process.env.OPENAI_API_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      model: "gpt-5.6-sol",
      reasoning: { effort: "high" },
      tools: [{ type: "web_search" }],
      store: false,
      input: prompt
    })
  });
  if (!response.ok) throw new Error(`OpenAI API Fehler ${response.status}: ${await response.text()}`);
  const payload = await response.json();
  const report = String(payload.output_text || "").trim();
  if (!report) throw new Error("Die OpenAI API lieferte keinen Bericht.");

  await fs.mkdir(path.dirname(statePath), { recursive: true });
  await fs.mkdir(path.dirname(latestMdPath), { recursive: true });
  await fs.writeFile(latestMdPath, report + "\n", "utf8");
  await fs.writeFile(latestHtmlPath, `<!doctype html><html lang="de"><meta charset="utf-8"><title>E-Commerce-News-Watcher</title><style>body{max-width:900px;margin:40px auto;padding:0 20px;font:16px/1.55 system-ui,sans-serif;color:#1d1d1f}pre{white-space:pre-wrap;font:inherit}a{color:#005ea8}</style><pre>${escapeHtml(report)}</pre></html>\n`, "utf8");

  const headings = [...report.matchAll(/^Priorität \[[^\]]+\]:\s*(.+)$/gm)].map((m) => m[1]).slice(0, 5);
  await fs.writeFile(statePath, JSON.stringify({
    lastSuccessfulRun: now.toISOString(),
    recentTopics: headings,
    lastReport: report
  }, null, 2) + "\n", "utf8");
  console.log(`Redaktioneller Bericht erzeugt: ${headings.length} Themen.`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
