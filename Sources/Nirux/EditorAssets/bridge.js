(function () {
  "use strict";

  var editor = null;
  var diffEditor = null;
  var diffMode = null;
  // path -> { model, cleanValue, contentListener }
  var models = {};
  var currentPath = null;
  var diffOriginalModel = null;
  var diffDecorationIds = { original: [], modified: [] };
  var diffDecorationTimer = null;
  var pierreDiffRoot = document.getElementById("pierre-diff");
  var pierreOriginalContent = "";
  var pierreGroupPayload = null;
  var pierreRenderTimer = null;
  var pendingMessages = [];
  var statusEl = document.getElementById("status");

  function postToSwift(message) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nirux) {
      window.webkit.messageHandlers.nirux.postMessage(message);
    }
  }

  function setStatus(text) {
    if (!statusEl) return;
    statusEl.textContent = text;
    statusEl.classList.remove("hidden");
  }

  function hideStatus() {
    if (!statusEl) return;
    statusEl.classList.add("hidden");
  }

  function showEditorSurface() {
    document.getElementById("editor").style.display = "block";
    document.getElementById("diff-editor").style.display = "none";
    if (pierreDiffRoot) pierreDiffRoot.style.display = "none";
  }

  function showMonacoDiffSurface() {
    document.getElementById("editor").style.display = "none";
    document.getElementById("diff-editor").style.display = "block";
    if (pierreDiffRoot) pierreDiffRoot.style.display = "none";
  }

  function showPierreDiffSurface() {
    document.getElementById("editor").style.display = "none";
    document.getElementById("diff-editor").style.display = "none";
    if (pierreDiffRoot) pierreDiffRoot.style.display = "block";
  }

  function reportDirtyFor(path) {
    var entry = models[path];
    if (!entry) return;
    var dirty = entry.model.getValue() !== entry.cleanValue;
    postToSwift({ type: "dirty", path: path, isDirty: dirty });
  }

  function languageFromPath(path) {
    var ext = (path.split(".").pop() || "").toLowerCase();
    switch (ext) {
      case "swift": return "swift";
      case "js": case "mjs": case "cjs": return "javascript";
      case "ts": case "tsx": return "typescript";
      case "jsx": return "javascript";
      case "json": return "json";
      case "md": case "markdown": return "markdown";
      case "html": case "htm": return "html";
      case "css": return "css";
      case "scss": return "scss";
      case "py": return "python";
      case "rb": return "ruby";
      case "go": return "go";
      case "rs": return "rust";
      case "c": case "h": return "c";
      case "cpp": case "cc": case "hpp": return "cpp";
      case "sh": case "bash": case "zsh": return "shell";
      case "yml": case "yaml": return "yaml";
      case "toml": return "ini";
      case "xml": case "plist": return "xml";
      case "sql": return "sql";
      default: return "plaintext";
    }
  }

  function ensureModel(path, content, lang) {
    if (models[path]) return models[path];
    var model = monaco.editor.createModel(content, lang);
    var entry = { model: model, cleanValue: content };
    // Listen on the model so dirty state updates whether the regular editor
    // or the diff editor's modified side is showing it.
    entry.contentListener = model.onDidChangeContent(function () {
      reportDirtyFor(path);
      if (diffMode === "monaco" && diffEditor && diffOriginalModel && currentPath === path) {
        scheduleDiffDecorations();
      } else if (diffMode === "pierre" && currentPath === path) {
        schedulePierreRender();
      }
    });
    models[path] = entry;
    return entry;
  }

  function applyOpen(payload) {
    var path = payload.path;
    var content = payload.content || "";
    var lang = payload.language || languageFromPath(path);

    if (models[path]) {
      // Reload existing model — Swift detected an external change while the
      // buffer was clean. Adopt the new content as the new clean baseline.
      models[path].model.setValue(content);
      monaco.editor.setModelLanguage(models[path].model, lang);
      models[path].cleanValue = content;
    } else {
      ensureModel(path, content, lang);
    }
    if (payload.activate === false) return;
    switchToPath(path);
    if (typeof payload.line === "number" && payload.line > 0) {
      revealLine(payload.line, payload.column || 1);
    }
  }

  function revealLine(line, column) {
    var target = activeEditor();
    if (!target) return;
    target.revealLineInCenter(line);
    target.setPosition({ lineNumber: line, column: column || 1 });
    target.focus();
  }

  function activeEditor() {
    if (diffMode === "monaco" && diffEditor) return diffEditor.getModifiedEditor();
    return editor;
  }

  function switchToPath(path) {
    if (!editor) return;
    var entry = models[path];
    if (!entry) return;
    // Switching to a different file always exits diff mode — the diff is
    // pinned to a single path and showing two files side-by-side from one
    // tab bar is more confusing than helpful.
    if (diffMode) exitDiff();
    currentPath = path;
    editor.setModel(entry.model);
    editor.focus();
    postToSwift({ type: "ready", path: path });
    reportDirtyFor(path);
  }

  function closeTab(path) {
    var entry = models[path];
    if (!entry) return;
    if (entry.contentListener) entry.contentListener.dispose();
    entry.model.dispose();
    delete models[path];
    if (currentPath === path) currentPath = null;
  }

  function markSaved(path) {
    var entry = models[path];
    if (!entry) return;
    entry.cleanValue = entry.model.getValue();
    postToSwift({ type: "dirty", path: path, isDirty: false });
  }

  function splitLines(text) {
    return (text || "").split(/\r\n|\r|\n/);
  }

  function lineDiffOps(originalText, modifiedText) {
    var original = splitLines(originalText);
    var modified = splitLines(modifiedText);
    var prefix = 0;
    while (
      prefix < original.length &&
      prefix < modified.length &&
      original[prefix] === modified[prefix]
    ) {
      prefix++;
    }

    var originalEnd = original.length - 1;
    var modifiedEnd = modified.length - 1;
    while (
      originalEnd >= prefix &&
      modifiedEnd >= prefix &&
      original[originalEnd] === modified[modifiedEnd]
    ) {
      originalEnd--;
      modifiedEnd--;
    }

    var originalMid = original.slice(prefix, originalEnd + 1);
    var modifiedMid = modified.slice(prefix, modifiedEnd + 1);
    if (originalMid.length === 0 && modifiedMid.length === 0) return [];

    // Keep the local diff cheap. Large unmatched regions are still marked
    // clearly as changed instead of freezing the editor with an O(n*m) table.
    if (originalMid.length * modifiedMid.length > 2000000) {
      var fallback = [];
      if (originalMid.length > 0) {
        fallback.push({ type: "delete", line: prefix + 1, count: originalMid.length });
      }
      if (modifiedMid.length > 0) {
        fallback.push({ type: "insert", line: prefix + 1, count: modifiedMid.length });
      }
      return fallback;
    }

    var rows = originalMid.length + 1;
    var cols = modifiedMid.length + 1;
    var dp = new Uint32Array(rows * cols);
    for (var i = 1; i < rows; i++) {
      for (var j = 1; j < cols; j++) {
        if (originalMid[i - 1] === modifiedMid[j - 1]) {
          dp[i * cols + j] = dp[(i - 1) * cols + j - 1] + 1;
        } else {
          dp[i * cols + j] = Math.max(dp[(i - 1) * cols + j], dp[i * cols + j - 1]);
        }
      }
    }

    var raw = [];
    var oi = originalMid.length;
    var mj = modifiedMid.length;
    while (oi > 0 && mj > 0) {
      if (originalMid[oi - 1] === modifiedMid[mj - 1]) {
        raw.push({ type: "equal" });
        oi--;
        mj--;
      } else if (dp[(oi - 1) * cols + mj] >= dp[oi * cols + mj - 1]) {
        raw.push({ type: "delete" });
        oi--;
      } else {
        raw.push({ type: "insert" });
        mj--;
      }
    }
    while (oi-- > 0) raw.push({ type: "delete" });
    while (mj-- > 0) raw.push({ type: "insert" });
    raw.reverse();

    var ops = [];
    var originalLine = prefix + 1;
    var modifiedLine = prefix + 1;
    for (var r = 0; r < raw.length; r++) {
      var op = raw[r];
      if (op.type === "equal") {
        originalLine++;
        modifiedLine++;
      } else if (op.type === "delete") {
        ops.push({ type: "delete", line: originalLine, count: 1 });
        originalLine++;
      } else {
        ops.push({ type: "insert", line: modifiedLine, count: 1 });
        modifiedLine++;
      }
    }
    return mergeLineOps(ops);
  }

  function mergeLineOps(ops) {
    var merged = [];
    for (var i = 0; i < ops.length; i++) {
      var op = ops[i];
      var last = merged[merged.length - 1];
      if (last && last.type === op.type && last.line + last.count === op.line) {
        last.count += op.count;
      } else {
        merged.push({ type: op.type, line: op.line, count: op.count });
      }
    }
    return merged;
  }

  function decorationFor(op) {
    var kind = op.type === "insert" ? "insert" : "delete";
    return {
      range: new monaco.Range(op.line, 1, op.line + op.count - 1, 1),
      options: {
        isWholeLine: true,
        className: "nirux-diff-line-" + kind,
        linesDecorationsClassName: "nirux-diff-gutter-" + kind,
        marginClassName: "nirux-diff-margin-" + kind,
        lineNumberClassName: "nirux-diff-line-number-" + kind,
        zIndex: 20
      }
    };
  }

  function clearDiffDecorations() {
    if (!diffEditor) {
      diffDecorationIds = { original: [], modified: [] };
      return;
    }
    diffDecorationIds.original = diffEditor.getOriginalEditor()
      .deltaDecorations(diffDecorationIds.original, []);
    diffDecorationIds.modified = diffEditor.getModifiedEditor()
      .deltaDecorations(diffDecorationIds.modified, []);
  }

  function scheduleDiffDecorations() {
    if (diffDecorationTimer) window.clearTimeout(diffDecorationTimer);
    diffDecorationTimer = window.setTimeout(function () {
      diffDecorationTimer = null;
      applyDiffDecorations();
    }, 0);
  }

  function applyDiffDecorations() {
    if (!diffEditor || !diffOriginalModel || !currentPath || !models[currentPath]) return;
    var originalDecorations = [];
    var modifiedDecorations = [];
    var ops = lineDiffOps(diffOriginalModel.getValue(), models[currentPath].model.getValue());
    for (var i = 0; i < ops.length; i++) {
      if (ops[i].type === "insert") {
        modifiedDecorations.push(decorationFor(ops[i]));
      } else {
        originalDecorations.push(decorationFor(ops[i]));
      }
    }
    diffDecorationIds.original = diffEditor.getOriginalEditor()
      .deltaDecorations(diffDecorationIds.original, originalDecorations);
    diffDecorationIds.modified = diffEditor.getModifiedEditor()
      .deltaDecorations(diffDecorationIds.modified, modifiedDecorations);
  }

  function enterMonacoDiff(path, originalContent) {
    var entry = models[path];
    if (!entry) return;
    if (diffMode === "pierre") exitPierreDiff();
    diffMode = "monaco";
    clearDiffDecorations();
    if (diffOriginalModel) { diffOriginalModel.dispose(); diffOriginalModel = null; }
    diffOriginalModel = monaco.editor.createModel(
      originalContent || "",
      entry.model.getLanguageId()
    );
    if (!diffEditor) {
      diffEditor = monaco.editor.createDiffEditor(document.getElementById("diff-editor"), {
        theme: "nirux-dark",
        automaticLayout: true,
        fontFamily: "ui-monospace, SF Mono, Menlo, monospace",
        fontSize: 13,
        minimap: { enabled: false },
        renderLineHighlight: "none",
        renderSideBySide: true,
        useInlineViewWhenSpaceIsLimited: false,
        enableSplitViewResizing: true,
        renderIndicators: true,
        hideUnchangedRegions: {
          enabled: true,
          contextLineCount: 4,
          minimumLineCount: 24,
          revealLineCount: 12
        },
        originalEditable: false,
        readOnly: false,
        ignoreTrimWhitespace: false
      });
      // Cmd+S on the modified side saves the buffer just like the regular
      // editor — without re-binding here it would no-op while in diff mode.
      diffEditor.getModifiedEditor().addCommand(
        monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS,
        function () { requestSave(); }
      );
    }
    diffEditor.setModel({ original: diffOriginalModel, modified: entry.model });
    showMonacoDiffSurface();
    hideStatus();
    diffEditor.layout();
    scheduleDiffDecorations();
    window.setTimeout(function () {
      diffEditor.layout();
      applyDiffDecorations();
    }, 0);
    diffEditor.getModifiedEditor().focus();
  }

  function exitMonacoDiff() {
    if (!diffEditor) return;
    clearDiffDecorations();
    if (diffDecorationTimer) {
      window.clearTimeout(diffDecorationTimer);
      diffDecorationTimer = null;
    }
    document.getElementById("diff-editor").style.display = "none";
    diffEditor.setModel(null);
    if (diffOriginalModel) { diffOriginalModel.dispose(); diffOriginalModel = null; }
  }

  function enterPierreDiff(path, originalContent) {
    var entry = models[path];
    if (!entry) return;
    if (!window.NiruxPierreDiff || !pierreDiffRoot) {
      enterMonacoDiff(path, originalContent);
      return;
    }

    if (diffMode === "monaco") exitMonacoDiff();
    diffMode = "pierre";
    pierreOriginalContent = originalContent || "";
    pierreGroupPayload = null;
    renderPierreDiff();
  }

  function enterPierreDiffGroup(payload) {
    if (!window.NiruxPierreDiff || !pierreDiffRoot) return;
    if (diffMode === "monaco") exitMonacoDiff();
    diffMode = "pierre-group";
    pierreOriginalContent = "";
    pierreGroupPayload = payload || { files: [] };
    renderPierreDiffGroup();
  }

  function schedulePierreRender() {
    if (pierreRenderTimer) window.clearTimeout(pierreRenderTimer);
    pierreRenderTimer = window.setTimeout(function () {
      pierreRenderTimer = null;
      renderPierreDiff();
    }, 80);
  }

  function renderPierreDiff() {
    if (diffMode !== "pierre" || !currentPath || !models[currentPath]) return;
    var entry = models[currentPath];
    setStatus("Rendering diff…");
    showPierreDiffSurface();
    try {
      window.NiruxPierreDiff.render(pierreDiffRoot, {
        path: currentPath,
        original: pierreOriginalContent,
        modified: entry.model.getValue(),
        language: entry.model.getLanguageId()
      }, {
        onRendered: function () {
          if (diffMode === "pierre") hideStatus();
        }
      });
    } catch (e) {
      postToSwift({ type: "error", message: "Pierre diff failed: " + String(e) });
      enterMonacoDiff(currentPath, pierreOriginalContent);
    }
  }

  function renderPierreDiffGroup() {
    if (diffMode !== "pierre-group" || !pierreGroupPayload) return;
    showPierreDiffSurface();
    if (pierreGroupPayload.loading) {
      if (window.NiruxPierreDiff && pierreDiffRoot) {
        window.NiruxPierreDiff.destroy(pierreDiffRoot);
      }
      setStatus("Preparing diffs…");
      return;
    }
    setStatus("Rendering diffs…");
    try {
      window.NiruxPierreDiff.renderMany(pierreDiffRoot, pierreGroupPayload, {
        onRendered: function () {
          if (diffMode === "pierre-group") {
            installPierreGroupToggles();
            hideStatus();
          }
        }
      });
      installPierreGroupToggles();
    } catch (e) {
      postToSwift({ type: "error", message: "Pierre multi-diff failed: " + String(e) });
      exitDiff();
    }
  }

  function installPierreGroupToggles() {
    if (!pierreDiffRoot || !pierreGroupPayload || !Array.isArray(pierreGroupPayload.files)) return;
    var hosts = pierreDiffRoot.querySelectorAll(".nirux-pierre-host");
    hosts.forEach(function (host, index) {
      if (host.previousElementSibling && host.previousElementSibling.classList.contains("nirux-pierre-file-header")) {
        return;
      }
      var file = pierreGroupPayload.files[index] || {};
      var header = document.createElement("button");
      header.type = "button";
      header.className = "nirux-pierre-file-header";
      header.setAttribute("aria-expanded", "true");

      var chevron = document.createElement("span");
      chevron.className = "nirux-pierre-file-chevron";
      chevron.textContent = "▾";

      var title = document.createElement("span");
      title.className = "nirux-pierre-file-title";
      title.textContent = file.name || file.path || ("File " + (index + 1));

      header.append(chevron, title);
      header.addEventListener("click", function () {
        var collapsed = host.classList.toggle("nirux-pierre-collapsed");
        header.classList.toggle("collapsed", collapsed);
        header.setAttribute("aria-expanded", collapsed ? "false" : "true");
        chevron.textContent = collapsed ? "▸" : "▾";
      });
      host.parentNode.insertBefore(header, host);
    });
  }

  function exitPierreDiff() {
    if (pierreRenderTimer) {
      window.clearTimeout(pierreRenderTimer);
      pierreRenderTimer = null;
    }
    pierreOriginalContent = "";
    pierreGroupPayload = null;
    if (window.NiruxPierreDiff && pierreDiffRoot) {
      window.NiruxPierreDiff.destroy(pierreDiffRoot);
    }
    if (pierreDiffRoot) pierreDiffRoot.style.display = "none";
  }

  function exitDiff() {
    if (diffMode === "monaco") {
      exitMonacoDiff();
    } else if (diffMode === "pierre" || diffMode === "pierre-group") {
      exitPierreDiff();
    }
    diffMode = null;
    showEditorSurface();
    hideStatus();
    if (editor) {
      editor.layout();
      editor.focus();
    }
  }

  function requestSave() {
    if (!currentPath) return;
    var entry = models[currentPath];
    if (!entry) return;
    postToSwift({
      type: "save",
      path: currentPath,
      content: entry.model.getValue()
    });
  }

  function handleMessage(msg) {
    switch (msg.type) {
      case "openFile": applyOpen(msg); break;
      case "switchTab": switchToPath(msg.path); break;
      case "closeTab": closeTab(msg.path); break;
      case "markSaved": markSaved(msg.path); break;
      case "goToLine":
        if (msg.path && currentPath !== msg.path) switchToPath(msg.path);
        if (typeof msg.line === "number") revealLine(msg.line, msg.column);
        break;
      case "enterDiff":
        if (msg.viewer === "monaco") {
          enterMonacoDiff(msg.path, msg.original);
        } else {
          enterPierreDiff(msg.path, msg.original);
        }
        break;
      case "enterPierreDiff": enterPierreDiff(msg.path, msg.original); break;
      case "enterMonacoDiff": enterMonacoDiff(msg.path, msg.original); break;
      case "enterDiffGroup": enterPierreDiffGroup(msg); break;
      case "exitDiff": exitDiff(); break;
    }
  }

  // Public API for Swift -> JS calls. Single entry point so we don't pile
  // up window.niruxBridge methods that mirror Swift state.
  window.niruxBridge = {
    handle: function (json) {
      try {
        var msg = typeof json === "string" ? JSON.parse(json) : json;
        if (!editor) {
          pendingMessages.push(msg);
        } else {
          handleMessage(msg);
        }
      } catch (e) {
        postToSwift({ type: "error", message: String(e) });
      }
    },
    setTheme: function (name) {
      if (window.monaco) monaco.editor.setTheme(name);
    }
  };

  require(["vs/editor/editor.main"], function () {
    monaco.editor.defineTheme("nirux-dark", {
      base: "vs-dark",
      inherit: true,
      rules: [],
      colors: {
        "editor.background": "#1a1b26",
        "editor.foreground": "#c0caf5",
        "editorLineNumber.foreground": "#3b4261",
        "editorLineNumber.activeForeground": "#7aa2f7",
        "editor.selectionBackground": "#28344a",
        "editor.lineHighlightBackground": "#1f2335",
        "diffEditor.insertedLineBackground": "#17462f80",
        "diffEditor.insertedTextBackground": "#2f8f5f80",
        "diffEditor.removedLineBackground": "#5a1f2c80",
        "diffEditor.removedTextBackground": "#b94b5e80",
        "diffEditorGutter.insertedLineBackground": "#2f8f5fcc",
        "diffEditorGutter.removedLineBackground": "#b94b5ecc",
        "diffEditorOverview.insertedForeground": "#41d487",
        "diffEditorOverview.removedForeground": "#ff6b7d",
        "diffEditor.border": "#3b4261"
      }
    });

    editor = monaco.editor.create(document.getElementById("editor"), {
      value: "",
      language: "plaintext",
      theme: "nirux-dark",
      automaticLayout: true,
      fontFamily: "ui-monospace, SF Mono, Menlo, monospace",
      fontSize: 13,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      renderLineHighlight: "all",
      smoothScrolling: true
    });

    // Cmd+S → ask Swift to write the active file. Swift writes, then sends
    // markSaved back so JS can adopt the new clean baseline.
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () {
      requestSave();
    });

    // Cmd+P → ask Swift to show its native file picker, scoped to the workspace.
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyP, function () {
      postToSwift({ type: "filePickerRequest" });
    });

    hideStatus();
    postToSwift({ type: "monacoReady" });

    // Drain anything Swift sent before Monaco was ready.
    var queued = pendingMessages;
    pendingMessages = [];
    for (var i = 0; i < queued.length; i++) {
      handleMessage(queued[i]);
    }
  });
})();
