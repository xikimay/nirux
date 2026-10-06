import {
  FileDiff, VirtualizedFileDiff, Virtualizer, createAnnotationWrapperNode, getFiletypeFromFileName, getLineAnnotationName,
  processFile
} from "@pierre/diffs";

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
//   whole hidden payload. U+FE0E and U+FE0F stay right after an emoji,
//   whose look they pick; anywhere else, two of them are enough to encode
//   a payload.
// A carriage return that ends the line is a CRLF file's, and stays hidden,
// unless the hunk's lines don't all end with one: a change of line ending
// would read as no change. A last line without a newline has none.
const hiddenCharacters =
  /(?<!\p{Emoji})[\uFE0E\uFE0F]|(?![\uFE0E\uFE0F])[\p{Default_Ignorable_Code_Point}\n\r\u2028\u2029\uFFF9-\uFFFB]/gu;

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
    const endsWithCR = (line) => String(line.text ?? "").endsWith("\r");
    const ended = lines.filter((line, index) => line.kind !== "noNewlineMarker" && lines[index + 1]?.kind !== "noNewlineMarker");
    const showsLineEnding = ended.some(endsWithCR) && !ended.every(endsWithCR);
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

// `interactions`: the file's annotation and pointer callbacks.
function reviewOptions(fontSize, lineHeight, onRendered, interactions) {
  const options = makeOptions(onRendered);
  return {
    ...options,
    ...interactions,
    diffStyle: "unified",
    disableFileHeader: true,
    // The gutter button and the selected lines take the page's accent,
    // which the host inherits.
    unsafeCSS: `${options.unsafeCSS}
      :host {
        --diffs-font-size: ${fontSize}px;
        --diffs-line-height: ${lineHeight}px;
        --diffs-gap-block: ${reviewGap}px;
        --diffs-modified-color-override: var(--accent, #78a3f7);
      }
    `
  };
}

const annotationSides = new Set(["additions", "deletions"]);

// pierre's annotations, from the page's { side, lineNumber, key }: a
// removed line's on the "deletions" side, numbered in the base, an added
// or unchanged line's on the "additions" side, numbered in the working
// tree. An unchanged line's given by its number in the base goes on the
// working tree's side: pierre would put it in a slot of its own, first.
// The key is pierre's metadata. Left out: malformed ones, and ones on
// lines the diff doesn't show.
function lineAnnotations(annotations, lines) {
  const out = [];
  for (const annotation of Array.isArray(annotations) ? annotations : []) {
    if (!annotation || typeof annotation.key !== "string") continue;
    const line = shownLine(lines, annotation.side, annotation.lineNumber);
    if (line) out.push({ ...line, metadata: annotation.key });
  }
  return out;
}

// A line of the diff, { side, lineNumber }: an unchanged one given by its
// number in the base goes on the working tree's side. Null when it isn't a
// line the diff shows.
function shownLine(lines, side, lineNumber) {
  if (!annotationSides.has(side) || !Number.isSafeInteger(lineNumber)) return null;
  const unchanged = side === "deletions" ? lines.unchanged.get(lineNumber) : undefined;
  const line = unchanged === undefined ? { side, lineNumber } : { side: "additions", lineNumber: unchanged };
  return lines.shown.has(`${line.side}:${line.lineNumber}`) ? line : null;
}

// The lines the diff shows, as "side:number" (a removed line on the base's
// side, an added one on the working tree's, an unchanged one on both), and
// each unchanged line's number in the working tree by its number in the
// base.
function diffLines(fileDiff) {
  const shown = new Set();
  const unchanged = new Map();
  for (const hunk of fileDiff.hunks) {
    let deletion = hunk.deletionStart;
    let addition = hunk.additionStart;
    for (const content of hunk.hunkContent) {
      const context = content.type === "context";
      const deletions = context ? content.lines : content.deletions;
      const additions = context ? content.lines : content.additions;
      for (let offset = 0; offset < deletions; offset++) shown.add(`deletions:${deletion + offset}`);
      for (let offset = 0; offset < additions; offset++) shown.add(`additions:${addition + offset}`);
      if (context) for (let offset = 0; offset < content.lines; offset++) unchanged.set(deletion + offset, addition + offset);
      deletion += deletions;
      addition += additions;
    }
  }
  return { shown, unchanged };
}

// A range of lines, as the page gets and gives it: { start, side, end,
// endSide }, line numbers on their sides. A copy: the page never holds
// pierre's own object.
function lineRange(range) {
  const side = range.side ?? "additions";
  return { start: range.start, side, end: range.end, endSide: range.endSide ?? side };
}

// Calls a callback of the page. One that throws doesn't reach pierre: in
// the middle of a click, pierre would stop taking clicks; in a render, it
// would show the error in place of the diff.
function callPage(callback, ...values) {
  try {
    return callback(...values);
  } catch (error) {
    console.error(error);
    return undefined;
  }
}

// A file of the review.
class ReviewFileDiff extends VirtualizedFileDiff {
  constructor(...values) {
    super(...values);
    // pierre takes the line under the pointer anywhere in the page: a drag
    // from one file onto another reported the other's line numbers to the
    // first. Only the file's own lines count.
    const manager = this.interactionManager;
    for (const name of ["getSelectionPointFromPath", "getSelectionPointerInfo"]) {
      const resolve = manager[name].bind(manager);
      manager[name] = (path, ...rest) => (manager.pre != null && path.includes(manager.pre) ? resolve(path, ...rest) : undefined);
    }
  }

  // pierre keeps an annotation's element by its index in the list: one
  // added or removed before it made it again, and it lost what it held and
  // its focus. Here, by its side, line and key. A new one goes among those
  // of its line in the list's order; one already there moves (and loses its
  // focus) only when the order of its line changed.
  renderAnnotations() {
    const container = this.fileContainer;
    const { renderAnnotation } = this.options;
    if (this.isContainerManaged || container == null || renderAnnotation == null) {
      super.renderAnnotations();
      return;
    }
    const stale = new Map(this.annotationCache);
    const lastOnLine = new Map();
    for (const annotation of this.lineAnnotations) {
      const id = `${annotation.side}:${annotation.lineNumber}:${annotation.metadata}`;
      const slot = getLineAnnotationName(annotation);
      const last = lastOnLine.get(slot);
      let element = this.annotationCache.get(id)?.element;
      if (element == null) {
        const content = renderAnnotation(annotation);
        if (content == null) continue;
        element = createAnnotationWrapperNode(slot);
        element.appendChild(content);
        this.annotationCache.set(id, { element, annotation });
        if (last != null) last.after(element);
        else container.insertBefore(element, [...container.children].find((child) => child.slot === slot) ?? null);
      } else if (last != null && last.compareDocumentPosition(element) & Node.DOCUMENT_POSITION_PRECEDING) {
        last.after(element);
      }
      stale.delete(id);
      lastOnLine.set(slot, element);
    }
    for (const [id, { element }] of stale) {
      this.annotationCache.delete(id);
      element.remove();
    }
  }
}

// They go into CSS: a number, or the default.
function points(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

const reviewsByRoot = new WeakMap();

// `scrollRoot` is what scrolls: the document, or an element whose first
// child, already in place, holds the files. `fontSize` and `lineHeight`
// are in points. The page's callbacks, each optional, get the container of
// the file they are about:
// - `renderAnnotation({ side, lineNumber, key }, container)` returns the
//   element shown under that line, or nothing (it is asked again at the
//   next render). The side and line are where it shows: an unchanged
//   line's given by its number in the base comes with its number in the
//   working tree. pierre puts the element in the page's DOM, in a slot of
//   the diff: the page's CSS styles it, and nothing of the annotation is
//   written as markup. Asked once for each side, line and key while the
//   annotation stays.
// - `onGutterClick(range, container)`: the button the gutter shows by the
//   line under the pointer was clicked, or dragged over lines. With
//   onSelect, the lines show selected, without a call to it. Without it,
//   there is no button. The button takes the pointer only, not keys: the
//   page offers another way to comment.
// - `onSelect(range, container)`: lines were selected by clicking or
//   dragging over their numbers (null: unselected). Without it, numbers
//   don't select.
// A range is { start, side, end, endSide }: line numbers on their sides,
// "deletions" for the base's, "additions" for the working tree's (an
// unchanged line's). `start` is where the drag began: it can be below
// `end`, on the other side, or in another hunk; both are lines of the
// file's diff.
function createReview(scrollRoot, {
  fontSize, lineHeight, onRendered, renderAnnotation, onGutterClick, onSelect
} = {}) {
  fontSize = points(fontSize, 12);
  // Whole points: placeholders count lines at this height, and a fraction
  // isn't laid out the same way by every WebKit (macOS 15's rounds it,
  // later ones keep 1/64 pt).
  lineHeight = Math.max(1, Math.round(points(lineHeight, 18)));
  const root = scrollRoot instanceof HTMLElement ? scrollRoot : document;
  // One review per scroll root: a page that reloads its data creates a new
  // one, and the old one's diffs go.
  reviewsByRoot.get(root)?.destroy();
  const virtualizer = new Virtualizer();
  virtualizer.setup(root);
  // pierre adds the scroll position it read last to a file's top on
  // screen: in a frame that runs between a scroll and the event that says
  // so (one `setAnnotations` asks for, say), the file's offset comes out
  // off by the distance scrolled, and the file draws none of its lines
  // until the next scroll. Both read now agree.
  virtualizer.getOffsetInScrollContainer = (element) => {
    const container = virtualizer.getScrollContainerElement();
    const top = element.getBoundingClientRect().top - (container?.getBoundingClientRect().top ?? 0);
    return (container ? container.scrollTop : window.scrollY) + top;
  };
  const views = new Map();
  let destroyed = false;
  // Set while the page sets a selection: onSelect is the user's.
  let selecting = false;

  // pierre's callbacks for the file in `container`.
  function interactions(container) {
    const options = {};
    // pierre reports a gutter click's lines again as a selection.
    let clickedGutter = false;
    if (typeof renderAnnotation === "function") {
      options.renderAnnotation = (annotation) => {
        const { side, lineNumber, metadata: key } = annotation;
        const element = callPage(renderAnnotation, { side, lineNumber, key }, container);
        return element instanceof HTMLElement ? element : undefined;
      };
    }
    if (typeof onGutterClick === "function") {
      options.enableGutterUtility = true;
      options.onGutterUtilityClick = (range) => {
        clickedGutter = true;
        callPage(onGutterClick, lineRange(range), container);
      };
    }
    if (typeof onSelect === "function") {
      options.enableLineSelection = true;
      options.onLineSelected = (range) => {
        if (selecting) return;
        if (clickedGutter) {
          clickedGutter = false;
          return;
        }
        callPage(onSelect, range ? lineRange(range) : null, container);
      };
    }
    return options;
  }

  // Renders `file` ({ path, hunks, annotations }) into `container`,
  // replacing what it showed, in a `diffs-container` element (with
  // `data-uncolored="large"` when the file is too large to color). The
  // path only picks the syntax; the annotations are as `setAnnotations`
  // takes them. Throws, and leaves what the container showed, when the
  // hunks can't be read.
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
    const view = new ReviewFileDiff(
      reviewOptions(fontSize, lineHeight, onRendered && (() => callPage(onRendered)), interactions(container)),
      virtualizer, { lineHeight, fileGap: reviewGap }
    );
    const lines = diffLines(fileDiff);
    views.set(container, { view, host, lines });
    // Set before rendering: off screen, pierre renders a placeholder, and
    // drops what `render` is given.
    view.setLineAnnotations(lineAnnotations(file.annotations, lines));
    view.render({ fileDiff, fileContainer: host });
  }

  // Replaces the annotations of the file in `container`: [{ side,
  // lineNumber, key }], each shown under its line, in this order on the
  // same line. On screen, the file renders again now, so the page's
  // elements are in place on return, and what the viewport shows stays in
  // place. The same annotations again render nothing: a render would drop
  // a text selection in the file.
  function setAnnotations(container, annotations) {
    const entry = views.get(container);
    if (!entry) return;
    const { view } = entry;
    const next = lineAnnotations(annotations, entry.lines);
    // The rows whose annotations change lose the height pierre measured
    // with them: pierre measures again only rows it renders, and none once
    // a file has no annotation.
    const keysByLine = (list) => {
      const byLine = new Map();
      for (const { side, lineNumber, metadata } of list) {
        const line = `${side}:${lineNumber}`;
        byLine.set(line, [...(byLine.get(line) ?? []), metadata]);
      }
      return byLine;
    };
    const before = keysByLine(view.lineAnnotations);
    const after = keysByLine(next);
    let changed = false;
    for (const line of new Set([...before.keys(), ...after.keys()])) {
      if (JSON.stringify(before.get(line)) === JSON.stringify(after.get(line))) continue;
      changed = true;
      const [side, lineNumber] = line.split(":");
      // The row's index in the unified view, which the review shows, and
      // by which pierre keeps its heights then.
      const index = view.getLineIndex(Number(lineNumber), side)?.[0];
      if (index !== undefined) view.heightCache.delete(index);
    }
    if (!changed) return;
    // Read after the return: it takes in a resize of the window pierre
    // hasn't drawn for yet.
    const anchor = virtualizer.getScrollAnchor(virtualizer.getHeight());
    view.computeApproximateSize();
    view.setLineAnnotations(next);
    // Not `rerender`, which would render the range of the last render,
    // and the whole file when there was none.
    view.render({ forceRender: true });
    view.reconcileHeights();
    // pierre does so after the renders it starts.
    virtualizer.scrollFix(anchor);
  }

  // Shows `range` as the selected lines of the file in `container`, or
  // none when it is null, or when its ends aren't lines of the diff.
  // onSelect isn't called.
  function setSelection(container, range) {
    const entry = views.get(container);
    if (!entry) return;
    let selection = null;
    if (range) {
      const { start, side, end, endSide } = lineRange(range);
      const first = shownLine(entry.lines, side, start);
      const last = shownLine(entry.lines, endSide, end);
      if (first && last) {
        selection = { start: first.lineNumber, side: first.side, end: last.lineNumber, endSide: last.side };
      }
    }
    selecting = true;
    try {
      entry.view.setSelectedLines(selection);
    } finally {
      selecting = false;
    }
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

  const review = { renderFile, setAnnotations, setSelection, removeFile, destroy: destroyReview };
  reviewsByRoot.set(root, review);
  return review;
}

window.NiruxPierreDiff = { render, renderMany, destroy, createReview };
