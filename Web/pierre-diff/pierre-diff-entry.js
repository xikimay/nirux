import { FileDiff, VirtualizedFileDiff, Virtualizer, getFiletypeFromFileName, processFile } from "@pierre/diffs";

const activeByRoot = new WeakMap();

function basename(path) {
  return (path || "").split("/").filter(Boolean).pop() || "Untitled";
}

function displayName(payload) {
  return payload.name || basename(payload.path);
}

function cacheKey(prefix, payload, contents) {
  return `${prefix}:${payload.path || ""}:${contents.length}:${hashString(contents)}`;
}

function hashString(value) {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(36);
}

function makeOptions(onRendered) {
  return {
    theme: "github-dark-default",
    themeType: "dark",
    diffStyle: "split",
    diffIndicators: "bars",
    hunkSeparators: "line-info-basic",
    lineDiffType: "word-alt",
    maxLineDiffLength: 1600,
    collapsedContextThreshold: 18,
    expansionLineCount: 80,
    overflow: "scroll",
    tokenizeMaxLineLength: 1200,
    unsafeCSS: `
      :host {
        --diffs-dark-bg: #1a1b26;
        --diffs-dark: #c0caf5;
        --diffs-font-family: ui-monospace, "SF Mono", Menlo, monospace;
        --diffs-header-font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        --diffs-font-size: 13px;
        --diffs-line-height: 20px;
        --diffs-gap-block: 6px;
        --diffs-gap-inline: 8px;
        --diffs-addition-color: #45d987;
        --diffs-deletion-color: #ff6b7d;
        --diffs-bg-addition-override: rgba(34, 197, 94, 0.18);
        --diffs-bg-deletion-override: rgba(239, 68, 68, 0.20);
        --diffs-bg-addition-emphasis-override: rgba(69, 217, 135, 0.34);
        --diffs-bg-deletion-emphasis-override: rgba(255, 107, 125, 0.34);
        background: #1a1b26;
      }
      [data-diffs-header=default] {
        border-bottom: 1px solid rgba(255, 255, 255, 0.07);
        min-height: 32px;
        padding-inline: 12px;
      }
      [data-separator=line-info-basic],
      [data-separator=line-info] {
        --diffs-bg-separator-override: #1f2335;
      }
      [data-column-number] {
        min-width: 4ch;
      }
    `,
    onPostRender() {
      onRendered?.();
    }
  };
}

function createState(root, callbacks) {
  destroy(root);

  const state = { views: [], onRendered: callbacks.onRendered };
  activeByRoot.set(root, state);
  return state;
}

function renderFile(state, container, payload) {
  const original = payload.original || "";
  const modified = payload.modified || "";
  const name = displayName(payload);
  const host = document.createElement("diffs-container");
  host.className = "nirux-pierre-host";
  container.appendChild(host);

  const view = new FileDiff(makeOptions(() => state.onRendered?.()));
  state.views.push(view);
  view.render({
    oldFile: {
      name,
      contents: original,
      lang: payload.language || undefined,
      cacheKey: cacheKey("old", payload, original)
    },
    newFile: {
      name,
      contents: modified,
      lang: payload.language || undefined,
      cacheKey: cacheKey("new", payload, modified)
    },
    fileContainer: host,
    forceRender: true
  });
}

function render(root, payload, callbacks = {}) {
  renderMany(root, { files: [payload] }, callbacks);
}

function renderMany(root, payload, callbacks = {}) {
  if (!(root instanceof HTMLElement)) {
    throw new Error("Pierre diff root is missing");
  }

  const files = (payload.files || []).filter(Boolean);
  const state = createState(root, callbacks);
  const stack = document.createElement("div");
  stack.className = "nirux-pierre-stack";

  if (payload.title || files.length > 1) {
    const summary = document.createElement("div");
    summary.className = "nirux-pierre-summary";
    const title = document.createElement("div");
    title.className = "nirux-pierre-summary-title";
    title.textContent = payload.title || "Changes";
    const count = document.createElement("div");
    count.className = "nirux-pierre-summary-count";
    count.textContent = `${files.length} file${files.length === 1 ? "" : "s"}`;
    summary.append(title, count);
    stack.appendChild(summary);
  }

  root.replaceChildren(stack);
  for (const file of files) {
    renderFile(state, stack, file);
  }
}

function destroy(root) {
  const state = activeByRoot.get(root);
  if (!state) return;
  for (const view of state.views) {
    view.cleanUp();
  }
  root.replaceChildren();
  activeByRoot.delete(root);
}

// MARK: - Branch Review

// The Branch Review page (docs/branch-review.md) has each file's hunks, not
// its contents: it renders a file's diff from them, unified, without
// pierre's file header (the page draws its own row), and only near the
// viewport, so that a long branch stays fast. The lines are a branch's,
// a fork's included: what they hold must read as it is.

// Shown as their code point, \u27E8U+202E\u27E9 in the page:
// - line breaks inside a line: in the patch text pierre parses, they would
//   end the line there, and the rest would read as another line or a hunk
//   header;
// - characters that change how a line reads without showing (Unicode's
//   default ignorable ones): bidi controls, which reorder what follows
//   ("Trojan Source"), zero-width and other invisible characters, Hangul
//   fillers, tag characters, and variation selectors, which can carry a
//   whole hidden payload. U+FE0E and U+FE0F, which pick an emoji's look,
//   stay.
// A carriage return that ends the line is a CRLF file's, and stays hidden,
// unless the hunk's changed lines don't all end with one: a change of line
// ending would read as no change.
const hiddenCharacters = /(?![\uFE0E\uFE0F])[\p{Default_Ignorable_Code_Point}\n\r\u2028\u2029\uFFF9-\uFFFB]/gu;

function codePoint(character) {
  return `\u27E8U+${character.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")}\u27E9`;
}

function patchLine(text, showsLineEnding) {
  const value = String(text ?? "");
  const crlf = !showsLineEnding && value.endsWith("\r");
  const body = (crlf ? value.slice(0, -1) : value).replace(hiddenCharacters, codePoint);
  return crlf ? `${body}\r` : body;
}

const linePrefixes = { context: " ", added: "+", removed: "-" };
const noNewline = "\\ No newline at end of file";

// A hunk line number, as the header can spell it.
function lineNumber(value) {
  return Math.min(Number.MAX_SAFE_INTEGER, Math.max(0, Math.trunc(Number(value) || 0)));
}

// One file's unified patch, from hunks shaped like `BranchReview.Hunk`:
// { oldStart, newStart, section, lines: [{ kind, text }] }, kind one of
// "context", "added", "removed", "noNewlineMarker". The counts come from
// the lines, so the header always matches them. A "no newline" marker
// counts only where git writes one: at the end of the hunk, or after the
// last removed line when only added lines follow.
function patchText(hunks) {
  // The same name on both sides: pierre reads different ones as a rename.
  const out = ["--- file", "+++ file"];
  for (const hunk of hunks || []) {
    const lines = (hunk.lines || []).filter((line) => line && (Object.hasOwn(linePrefixes, line.kind) || line.kind === "noNewlineMarker"));
    // From each index on: whether only added lines (markers aside) follow.
    const onlyAddedFrom = new Array(lines.length + 1).fill(true);
    for (let index = lines.length - 1; index >= 0; index--) {
      onlyAddedFrom[index] = onlyAddedFrom[index + 1] && (lines[index].kind === "added" || lines[index].kind === "noNewlineMarker");
    }
    const lastLine = lines.findLastIndex((line) => line.kind !== "noNewlineMarker");
    const changed = lines.filter((line) => line.kind === "added" || line.kind === "removed");
    const endsWithCR = (line) => String(line.text ?? "").endsWith("\r");
    const showsLineEnding = changed.some(endsWithCR) && !changed.every(endsWithCR);
    const body = [];
    let previous;
    let oldCount = 0;
    let newCount = 0;
    lines.forEach((line, index) => {
      if (line.kind === "noNewlineMarker") {
        const endsSide = index > lastLine || (previous === "removed" && onlyAddedFrom[index + 1]);
        if (previous !== undefined && previous !== "noNewlineMarker" && endsSide) {
          body.push(noNewline);
          previous = "noNewlineMarker";
        }
        return;
      }
      if (line.kind !== "added") oldCount++;
      if (line.kind !== "removed") newCount++;
      body.push(linePrefixes[line.kind] + patchLine(line.text, showsLineEnding));
      previous = line.kind;
    });
    const section = String(hunk.section ?? "").replace(/[\r\n\u2028\u2029]/g, " ").trim();
    const header = `@@ -${lineNumber(hunk.oldStart)},${oldCount} +${lineNumber(hunk.newStart)},${newCount} @@`;
    out.push(section ? `${header} ${section}` : header, ...body);
  }
  return `${out.join("\n")}\n`;
}

// Past these, a file's diff isn't colored.
const maxHighlightedLines = 1500;
const maxHighlightedCharacters = 100000;

function isLarge(fileDiff) {
  let lines = 0;
  let characters = 0;
  for (const side of [fileDiff.deletionLines, fileDiff.additionLines]) {
    lines += side.length;
    for (const line of side) characters += line.length;
  }
  return lines > maxHighlightedLines || characters > maxHighlightedCharacters;
}

// pierre's metadata for one file's hunks, and whether it is too large to
// color. Throws when they can't be read.
function reviewFileDiff(file) {
  const fileDiff = processFile(patchText(file.hunks), { isGitDiff: false, throwOnError: true });
  if (!fileDiff) throw new Error("Pierre diff couldn't read the hunks");
  fileDiff.name = String(file.path ?? "");
  // Set here rather than left to pierre: its lookup of an extension such as
  // `.constructor` or `.toString` returns a function, and the file would
  // never render. By the file's name, as the editor does: `Dockerfile`.
  // A large file is plain text: pierre colors a whole file at once, on the
  // main thread, which takes seconds for a few hundred KB.
  const large = isLarge(fileDiff);
  const lang = getFiletypeFromFileName(basename(fileDiff.name));
  fileDiff.lang = typeof lang === "string" && !large ? lang : "text";
  // With the last line unchanged, both sides lack the newline, and unified
  // view would draw the marker twice in one row: lines would overlap.
  for (const hunk of fileDiff.hunks) {
    if (hunk.noEOFCRAdditions && hunk.noEOFCRDeletions && hunk.hunkContent.at(-1)?.type === "context") {
      hunk.noEOFCRDeletions = false;
    }
  }
  return { fileDiff, large };
}

// The blank above and below a file's lines. Placeholders off screen are
// sized from the same values the CSS gets, so a file doesn't change height
// when it renders.
const reviewGap = 6;

function reviewOptions(fontSize, lineHeight, onRendered) {
  const options = makeOptions(onRendered);
  return {
    ...options,
    diffStyle: "unified",
    disableFileHeader: true,
    unsafeCSS: `${options.unsafeCSS}
      :host {
        --diffs-font-size: ${fontSize}px;
        --diffs-line-height: ${lineHeight}px;
        --diffs-gap-block: ${reviewGap}px;
      }
    `
  };
}

// They go into CSS: a number, or the default. On WebKit's layout grid
// (1/64 pt): a line height off it would make placeholders and rendered
// files differ by a fraction of a point.
function points(value, fallback) {
  const number = Math.round(Number(value) * 64) / 64;
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

const reviewsByRoot = new WeakMap();

// `scrollRoot` is what scrolls: the document, or an element whose first
// child, already in place, holds the files. `fontSize` and `lineHeight`
// are in points.
function createReview(scrollRoot, { fontSize, lineHeight, onRendered } = {}) {
  fontSize = points(fontSize, 12);
  lineHeight = points(lineHeight, 18);
  const root = scrollRoot instanceof HTMLElement ? scrollRoot : document;
  // One review per scroll root: a page that reloads its data creates a new
  // one, and the old one's diffs go.
  reviewsByRoot.get(root)?.destroy();
  const virtualizer = new Virtualizer();
  virtualizer.setup(root);
  const views = new Map();
  let destroyed = false;

  // Renders `file` ({ path, hunks }) into `container`, replacing what it
  // showed, in a `diffs-container` element (with `data-uncolored="large"`
  // when the file is too large to color). The path only picks the syntax.
  // Throws, and leaves what the container showed, when the hunks can't be
  // read.
  function renderFile(container, file) {
    if (destroyed) throw new Error("Pierre diff review was destroyed");
    if (!(container instanceof HTMLElement)) {
      throw new Error("Pierre diff container is missing");
    }
    const { fileDiff, large } = reviewFileDiff(file);
    removeFile(container);
    const host = document.createElement("diffs-container");
    host.className = "nirux-review-diff";
    // The page can say why a file isn't colored.
    if (large) host.dataset.uncolored = "large";
    container.appendChild(host);
    const view = new VirtualizedFileDiff(
      reviewOptions(fontSize, lineHeight, onRendered), virtualizer, { lineHeight, fileGap: reviewGap }
    );
    views.set(container, { view, host });
    view.render({ fileDiff, fileContainer: host });
  }

  function removeFile(container) {
    const entry = views.get(container);
    if (!entry) return;
    entry.view.cleanUp();
    entry.host.remove();
    views.delete(container);
  }

  // The review renders nothing more.
  function destroyReview() {
    if (destroyed) return;
    destroyed = true;
    if (reviewsByRoot.get(root) === review) reviewsByRoot.delete(root);
    for (const container of [...views.keys()]) removeFile(container);
    virtualizer.cleanUp();
  }

  const review = { renderFile, removeFile, destroy: destroyReview };
  reviewsByRoot.set(root, review);
  return review;
}

window.NiruxPierreDiff = { render, renderMany, destroy, createReview };
