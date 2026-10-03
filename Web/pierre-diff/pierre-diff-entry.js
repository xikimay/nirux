import { FileDiff, VirtualizedFileDiff, Virtualizer, processFile } from "@pierre/diffs";

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
// viewport, so that a long branch stays fast.

// A line break inside a line would end it in the patch text the hunks are
// given to pierre as: the rest would read as another line, or as a hunk
// header. They are shown as symbols instead. A carriage return that ends
// the line is a CRLF file's, and stays.
const shownLineBreaks = { "\n": "\u2424", "\r": "\u240D", "\u2028": "\u2424", "\u2029": "\u2424" };

function patchLine(text) {
  const value = String(text ?? "");
  const crlf = value.endsWith("\r");
  const body = (crlf ? value.slice(0, -1) : value).replace(/[\n\r\u2028\u2029]/g, (c) => shownLineBreaks[c]);
  return crlf ? `${body}\r` : body;
}

const linePrefixes = { context: " ", added: "+", removed: "-" };

// One file's unified patch, from hunks shaped like `BranchReview.Hunk`:
// { oldStart, newStart, section, lines: [{ kind, text }] }, kind one of
// "context", "added", "removed", "noNewlineMarker". The counts come from
// the lines, so the header always matches them.
function patchText(hunks) {
  const out = ["--- a/file", "+++ b/file"];
  for (const hunk of hunks || []) {
    const body = [];
    let oldCount = 0;
    let newCount = 0;
    for (const line of hunk.lines || []) {
      if (line.kind === "noNewlineMarker") {
        if (body.length > 0) body.push("\\ No newline at end of file");
        continue;
      }
      const prefix = linePrefixes[line.kind];
      if (prefix === undefined) continue;
      if (line.kind !== "added") oldCount++;
      if (line.kind !== "removed") newCount++;
      body.push(prefix + patchLine(line.text));
    }
    const section = String(hunk.section ?? "").replace(/[\r\n\u2028\u2029]/g, " ").trim();
    const oldStart = Math.max(0, Math.trunc(Number(hunk.oldStart) || 0));
    const newStart = Math.max(0, Math.trunc(Number(hunk.newStart) || 0));
    out.push(`@@ -${oldStart},${oldCount} +${newStart},${newCount} @@${section ? ` ${section}` : ""}`, ...body);
  }
  return `${out.join("\n")}\n`;
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
// child holds the files. `fontSize` and `lineHeight` are in points.
function createReview(scrollRoot, { fontSize, lineHeight, onRendered } = {}) {
  fontSize = points(fontSize, 12);
  lineHeight = points(lineHeight, 18);
  const virtualizer = new Virtualizer();
  virtualizer.setup(scrollRoot instanceof HTMLElement ? scrollRoot : document);
  const views = new Map();

  // Renders `file` ({ path, oldPath, hunks }) into `container`, replacing
  // what it showed. Throws when the hunks can't be read as a patch.
  function renderFile(container, file) {
    if (!(container instanceof HTMLElement)) {
      throw new Error("Pierre diff container is missing");
    }
    removeFile(container);
    const fileDiff = processFile(patchText(file.hunks), { isGitDiff: false, throwOnError: true });
    if (!fileDiff) throw new Error("Pierre diff couldn't read the hunks");
    fileDiff.name = String(file.path ?? "");
    if (file.oldPath) fileDiff.prevName = String(file.oldPath);
    else delete fileDiff.prevName;

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

  function destroyReview() {
    for (const container of [...views.keys()]) removeFile(container);
    virtualizer.cleanUp();
  }

  return { renderFile, removeFile, destroy: destroyReview };
}

window.NiruxPierreDiff = { render, renderMany, destroy, createReview };
