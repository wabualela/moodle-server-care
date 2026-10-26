# The Arabic team report (`assets/report-template.html`)

## Contents
1. Audience and purpose
2. Structure of the page (sections in order)
3. Filling the template (placeholders, chart data)
4. Visual identity: read the platform's theme colours
5. Writing rules (Arabic)
6. Publishing and updating
7. Before publishing

## 1. Audience and purpose
The team and management of the platform, in Arabic: why students feel the platform is slow (or what risks the server
carries), what is not the cause, what will be fixed in which order, what was already done, and what management must
decide or provide. It is read on phones. It replaces long chat messages and becomes the reference for the fix plan;
it is updated in place as fixes land (same URL), not rewritten.

## 2. Structure of the page (sections in order)
| Section id | Content | Source |
|---|---|---|
| header | eyebrow (team report · platform name), title, one-sentence lede, data period, site, status pills | synthesis §1 |
| `#progress` (optional, after fixes start) | what was done, when, downtime in total, stat tiles of measured effects, table by area with status pills, "next" list with dates | operations log |
| `#summary` | verdict box (2 paragraphs: the server is / is not the problem; the main causes in one sentence each), 4-6 stat tiles | synthesis §1-2 |
| `#traffic` | what changed (dates, growth, mobile share, real students or not), chart 1: requests per day by device class plus the server p95 line | `per_day.tsv`, `ua_classes_daily.tsv` |
| `#causes` | chart 2: median server time per page; one card per cause ranked by what students feel: what happens / evidence / fix, with an impact pill | `endpoint_summary_P1.tsv`, synthesis §2 |
| `#ruled-out` | what is NOT the cause, each with its evidence (capacity, database, other projects, traffic volume) | synthesis §3 |
| `#monitor` | what the 48-hour monitor showed: stat tiles and chart 3 (front page vs login TTFB per hour against PHP requests per hour), bullet findings, limits of the measurement | `ttfb.csv`, `metrics.csv`, `per_hour.tsv` |
| `#plan` | phases table: #, action, expected effect, risk pill, status pill; phase rows (quick wins, browser side, maintenance night, after the fixes) | synthesis §5 |
| `#backup` (optional) | current backup layers and the decision, plus an "ask" box for what management must provide | backup module |
| `#ops` | operational notes table: note, importance pill, details, status | synthesis §4 |
| `#projects` (optional) | other projects on the same server and their state | phase 0 |
| `#method` | numbered steps of what was done read-only; a note that nothing was changed during the audit except the self-expiring monitor; that numbers are aggregated with no personal data | this module |
| footer | prepared for, diagnosis date, last update and what changed in it | |

Remove optional sections that do not apply (and their TOC links). Do not invent sections for a small audit: a
summary, causes, ruled out, plan, ops notes and method is a complete report.

## 3. Filling the template
- Text placeholders are written `{{LIKE_THIS}}` (Arabic guidance next to each in an HTML comment). Search for `{{`
  until none is left: `grep -c '{{' report.html` must be 0 before publishing.
- Example rows and cards are marked `<!-- repeat -->`: copy them as many times as needed, delete the rest.
- Numbers go in `<span class="num">…</span>` (monospace, left-to-right isolated inside Arabic text). Use Western
  digits, thousands separators as in `12,500`, and units the reader knows (ث for seconds, ميجابايت).
- Charts are drawn by the script at the end from three data blocks at its top (`DATA.days`, `DATA.pages`,
  `DATA.monitor`). Fill them from the files above; leave a block empty (`[]`) to hide its chart (the figure then shows
  "لا توجد بيانات" instead of a broken chart). Set `DATA.eventIndex` / `DATA.eventLabel` to mark a launch or change on
  chart 1, and the axis maxima `maxY`, `maxP`, `maxX`, `maxS`, `maxR` to round values just above the data.
- Chart labels and the axis captions are Arabic; series colours come from CSS variables, so they follow the theme and
  dark mode automatically.

## 4. Visual identity: read the platform's theme colours
The page should look like the platform the team knows. All colours are CSS variables in one `:root` block at the top
of the template (`--brand`, `--brand-strong`, `--brand-deep`, `--brand-soft`, `--page`, `--highlight`,
`--highlight-text`, fonts), with a dark-mode block below it.

Where to read the colours (read-only):
1. `25_moodle/moodle_info.txt`, section `## theme_identity`: the current theme's colour and font settings (and
   Boost's). Boost and Classic use `brandcolor`; child themes and commercial themes use their own names (for example
   RemUI and other premium themes have primary/secondary/accent or "theme colour" settings); take the primary brand
   colour, a darker hover shade if present, and an accent/highlight colour.
2. If the theme stores no colours (preset only): the compiled CSS. A read-only GET of the stylesheet URL found in the
   front page HTML (`/theme/styles.php/<theme>/<rev>/all`) and look for `--primary`, `--bs-primary` or the most
   frequent brand hex in buttons and the navbar. Or ask the owner for the brand colours and logo.
3. Fonts: a theme font setting (`fontname`, Google font), else IBM Plex Sans Arabic (good Arabic coverage) with a
   system fallback.

Then:
- `--brand` = primary colour; `--brand-strong` = its hover/darker shade (about 15-20 % darker); `--brand-deep` =
  near-black of the same hue for body text; `--brand-soft` = a very light tint for boxes; `--page` = an off-white with
  a hint of the hue; `--highlight` = the accent (warm colours work well for "ask" boxes and the p95 line).
- Dark mode: lighten the brand (tints around 70-80 % lightness) so text and lines on the dark background keep a
  contrast of at least 4.5:1 for text and 3:1 for chart lines; keep the hue.
- Check contrast of white text on `--band` (the header) and of `--brand` text on `--page`; adjust the shade, not the
  hue, until it passes.
- Write in the CSS comment where the colours came from (theme setting names, not the site's name).

## 5. Writing rules (Arabic)
- Short sentences, plain words, one idea per sentence. Explain a technical term once, in parentheses, the first time
  ("nginx (برنامج استقبال الطلبات على الخادم)").
- Lead with the outcome: the verdict, then evidence, then what is needed from management, then next steps with dates.
- Say what each number measures and where: «زمن تجهيز الصفحة على الخادم» is not «زمن ظهور الصفحة للطالب». Give the
  sample (period, number of requests) in the caption or the tile text.
- Status pills, consistently: «نُفّذ» (done, verified), «نُفّذ جزئياً» (part done, say which part), «مجدول» (date),
  «بانتظار قرار» (who decides), «بانتظار التنفيذ», «اختبار تجريبي ناجح» for a dry run. Never «نُفّذ» for a dry run or
  a change whose real effect is measured later.
- Dates as «13 مارس» with the time zone stated once (for example «بتوقيت الرياض» or the students' zone); times in
  24-hour form inside `num` spans.
- No personal data, no IP addresses, no secrets, no internal paths that reveal credentials; other projects' names
  only if the owner wants them in a team document.
- Credit and blame: describe systems, not people. Changes made outside the audit (by the provider or the owner) are
  stated as such.

## 6. Publishing and updating
- Default: a private Artifact (it starts private; the owner shares it from the Share menu). Load the
  `artifact-design` skill first and follow its contract; the template is already a page fragment with a `<title>`,
  Google Fonts only, inline CSS and JS, light/dark tokens on `:root` and `[data-theme]`, and works at phone width.
  For a standalone file instead, wrap it in `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">…</head><body>…</body></html>`.
- Keep the source HTML in the audit folder on the server (not in the plugin) so later sessions can update it.
- Update in place (same URL) when a fix lands: change the status pill, add the measured effect, update "last
  updated" in the header meta and the footer, and say what changed in this version.
- Record the publication (URL, version) in the server handbook; never put the URL in the plugin.

## 7. Before publishing
1. Independent fact-check against the operations log (`references/fact-check.md`). Not optional.
2. `grep -c '{{' report.html` = 0; no `<!-- repeat -->` example rows left with placeholder content.
3. Open it in light and dark mode and at phone width (or check the Artifact preview); charts readable, no horizontal
   page scroll.
4. The owner approves the text before it goes to the team (core rules §4: anything user-visible).
