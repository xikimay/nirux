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

// Shown as their code point, ⟨U+202E⟩:
// - line breaks inside a line: in the patch text pierre parses, they would
//   end the line there, and the rest would read as another line or a hunk
//   header;
// - characters that change how a line reads without showing: bidi controls,
//   which reorder what follows ("Trojan Source"), zero-width and other
//   invisible characters, Hangul fillers, and tag characters.
// A carriage return that ends the line is a CRLF file's, and stays.
const hiddenCharacters =
  /[\n\r\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180E\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u206F\u3164\uFEFF\uFFA0\u{E0000}-\u{E007F}]/gu;

function codePoint(character) {
  return `\u27E8U+${character.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")}\u27E9`;
}

function patchLine(text) {
  const value = String(text ?? "");
  const crlf = value.endsWith("\r");
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
    const lines = (hunk.lines || []).filter((line) => line && (line.kind in linePrefixes || line.kind === "noNewlineMarker"));
    // From each index on: whether only added lines (markers aside) follow.
    const onlyAddedFrom = new Array(lines.length + 1).fill(true);
    for (let index = lines.length - 1; index >= 0; index--) {
      onlyAddedFrom[index] = onlyAddedFrom[index + 1] && (lines[index].kind === "added" || lines[index].kind === "noNewlineMarker");
    }
    const lastLine = lines.findLastIndex((line) => line.kind !== "noNewlineMarker");
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
      body.push(linePrefixes[line.kind] + patchLine(line.text));
      previous = line.kind;
    });
    const section = String(hunk.section ?? "").replace(/[\r\n\u2028\u2029]/g, " ").trim();
    const header = `@@ -${lineNumber(hunk.oldStart)},${oldCount} +${lineNumber(hunk.newStart)},${newCount} @@`;
    out.push(section ? `${header} ${section}` : header, ...body);
  }
  return `${out.join("\n")}\n`;
}

// pierre's metadata for one file's hunks. Throws when they can't be read.
function reviewFileDiff(file) {
  const fileDiff = processFile(patchText(file.hunks), { isGitDiff: false, throwOnError: true });
  if (!fileDiff) throw new Error("Pierre diff couldn't read the hunks");
  fileDiff.name = String(file.path ?? "");
  // Set here rather than left to pierre: its lookup of an extension such as
  // `.constructor` or `.toString` returns a function, and the file would
  // never render.
  const lang = getFiletypeFromFileName(fileDiff.name);
  fileDiff.lang = typeof lang === "string" ? lang : "text";
  // With the last line unchanged, both sides lack the newline, and unified
  // view would draw the marker twice in one row: lines would overlap.
  for (const hunk of fileDiff.hunks) {
    if (hunk.noEOFCRAdditions && hunk.noEOFCRDeletions && hunk.hunkContent.at(-1)?.type === "context") {
      hunk.noEOFCRDeletions = false;
    }
  }
  return fileDiff;
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

// They go into CSS: a number, or the default.
function points(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

// `scrollRoot` is what scrolls: the document, or an element whose first
// child, already in place, holds the files. `fontSize` and `lineHeight`
// are in points.
function createReview(scrollRoot, { fontSize, lineHeight, onRendered } = {}) {
  fontSize = points(fontSize, 12);
  lineHeight = points(lineHeight, 18);
  const virtualizer = new Virtualizer();
  virtualizer.setup(scrollRoot instanceof HTMLElement ? scrollRoot : document);
  const views = new Map();
  let destroyed = false;

  // Renders `file` ({ path, hunks }) into `container`, replacing what it
  // showed. The path only picks the syntax. Throws, and leaves what the
  // container showed, when the hunks can't be read.
  function renderFile(container, file) {
    if (destroyed) throw new Error("Pierre diff review was destroyed");
    if (!(container instanceof HTMLElement)) {
      throw new Error("Pierre diff container is missing");
    }
    const fileDiff = reviewFileDiff(file);
    removeFile(container);
    const host = document.createElement("diffs-container");
    host.className = "nirux-review-diff";
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
    for (const container of [...views.keys()]) removeFile(container);
    virtualizer.cleanUp();
  }

  return { renderFile, removeFile, destroy: destroyReview };
}

window.NiruxPierreDiff = { render, renderMany, destroy, createReview };
