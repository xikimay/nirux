import { FileDiff } from "@pierre/diffs";

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

window.NiruxPierreDiff = { render, renderMany, destroy };
