# Differ

A tool for finding changes between versions of PDFs, webpages, etc.

A native macOS app (SwiftUI + PDFKit) that compares two versions of a document and shows the changes as tracked changes.

## Install

Requires macOS 14 or later (Apple silicon or Intel).

A signed and notarised download is in preparation. Until it is published under [Releases](https://github.com/johnnyryan/Differ/releases), build the app from source (see [Build](#build)) and drag `build/Differ.app` to Applications.

## Sources

Each side can be:

- a **PDF file** (drop it, click the card, or use ⌘O / ⇧⌘O)
- a **live web page** (drag the link from the browser's address bar, or paste the URL)
- a **Wayback Machine capture**, e.g. `https://web.archive.org/web/20260626145103/https://www.microsoft.com/en-gb/privacy/privacystatement`

When two links are dropped at once, they are ordered oldest → newest automatically.

**Web archive versions…** under each address field lists every Wayback Machine capture of that page (one entry per distinct version, or one per day), grouped by year with *Jump to* buttons and a filter. Pick one as the original or revised version.

### Collapsed / hidden text

Web pages are read straight from their HTML, ignoring CSS, so text inside collapsed accordions, tabs and "read more" panels is included. The page's `<main>` region is used when it holds most of the text, so site navigation and footers are left out. If the HTML is thin (content loaded by JavaScript), the page is rendered in a hidden WebKit view: every `<details>` element, `aria-expanded="false"` toggle, Bootstrap collapse and "Expand all / Show more" button is clicked, then the DOM is read. Settings → *Render web pages with JavaScript → Always* forces this.

### Dates of change (optional, off by default)

Turn on **Date changes** (start screen, Options menu or Settings). When at least one side is a Wayback capture and both sides are the same page, the app lists the captures between the two versions (Wayback CDX API, distinct content only, up to 48 sampled) and bisects them for every change. Each change is labelled with the window in which it first appeared, e.g. `[7 Oct 2025 – 14 Oct 2025]`. Right-click a change in the sidebar to open the first capture that contains it.

## Formatting

The tracked-changes view and the exports keep the look of the source: PDF font families, sizes, bold/italic, centred lines and indents; web headings, bulleted/numbered lists, emphasis and links. Paragraphs in PDFs are rebuilt from line geometry; words hyphenated at line ends are rejoined unless both versions show a real compound (“long-term”).

## Views

- **Tracked Changes**: one merged text with deletions struck through in red, insertions underlined in green, and date tags.
- **Side by Side**: both versions. PDFs show highlight annotations; web pages show their text with changes highlighted.
- **On Page** (⌘3): the newer version's own rendering. For a PDF, its real pages with added text highlighted and removed text in red notes in a markup margin, linked by leader lines; for a web page, the page itself with its own styling and the changes written in, collapsed sections opened. Clicking never follows links.
- Sidebar: every change, filterable (Added / Removed / Replaced) and searchable; ⌘[ and ⌘] step through them.

## Export

- **Word document with tracked changes** (⌘E): real `w:ins`/`w:del` revisions that can be accepted or rejected in Word or Pages. Each revision is dated with the Wayback date when the change first appeared.
- **PDF of the tracked-changes view** (⇧⌘E)
- **Original / revised PDF with highlights**
- **Revised PDF with changes marked** (the On Page view, with margin notes)

## Credit

Differ. Johnny Ryan 2026 — shown in About, on the start screen and in exported documents.

## Build

Requires the Xcode Command Line Tools (no Xcode project needed):

```
./build.sh          # → build/Differ.app (universal, ad-hoc signed)
```

To make a drag-to-install disk image:

```
./release.sh              # → build/Differ.dmg, signed and notarised
./release.sh --unsigned   # → build/Differ.dmg, ad-hoc signed (macOS blocks it when downloaded)
```

The signed image needs a *Developer ID Application* certificate in the keychain and notary credentials stored once with `xcrun notarytool store-credentials differ-notary`.

Headless use:

```
"build/Differ.app/Contents/MacOS/Differ" --compare OLD NEW [--dates] [--render] [--docx out.docx] [--text out.txt] [--annotated prefix] [--onpage out.pdf]
"build/Differ.app/Contents/MacOS/Differ" --captures URL [--daily]
```

## Licence

[Mozilla Public License 2.0](LICENSE)
