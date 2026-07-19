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
  // Per-tab view state (scroll + cursor) so switching tabs restores position.
  var viewStates = {};
  var wordWrap = false;
  var minimapEnabled = false;
  var editorFontSize = 13;
  // path -> { content, count } for saves posted to Swift but not yet
  // acknowledged via markSaved. markSaved must adopt the content that was
  // actually written, not whatever the buffer holds when the ack arrives —
  // keystrokes typed during the round-trip would otherwise be blessed as
  // clean without ever reaching disk.
  var pendingSaves = {};

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
      revealLine(payload.line, payload.column || 1, payload.endLine);
    }
  }

  function revealLine(line, column, endLine) {
    var target = activeEditor();
    if (!target) return;
    var model = target.getModel();
    if (model) {
      line = Math.min(line, model.getLineCount());
    }
    // A range (agent "show me this code" flow): select line..endLine so the
    // snippet is visibly highlighted, not just scrolled to.
    if (typeof endLine === "number" && endLine > line && model) {
      var end = Math.min(endLine, model.getLineCount());
      var range = {
        startLineNumber: line,
        startColumn: 1,
        endLineNumber: end,
        endColumn: model.getLineMaxColumn(end)
      };
      target.setSelection(range);
      target.revealRangeInCenter(range);
      target.focus();
      return;
    }
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
    // Save where we were in the file we're leaving.
    if (currentPath && models[currentPath]) {
      viewStates[currentPath] = editor.saveViewState();
    }
    currentPath = path;
    editor.setModel(entry.model);
    if (viewStates[path]) {
      editor.restoreViewState(viewStates[path]);
    }
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
    delete viewStates[path];
    delete pendingSaves[path];
    if (currentPath === path) currentPath = null;
  }

  function markSaved(path) {
    var entry = models[path];
    if (!entry) return;
    var pending = pendingSaves[path];
    if (pending) {
      entry.cleanValue = pending.content;
      pending.count--;
      if (pending.count === 0) delete pendingSaves[path];
    } else {
      entry.cleanValue = entry.model.getValue();
    }
    reportDirtyFor(path);
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
        // Inherit the live toggles — the diff editor is created lazily, so
        // hardcoding these would desync it from zoom/wrap/minimap state.
        fontSize: editorFontSize,
        wordWrap: wordWrap ? "on" : "off",
        minimap: { enabled: minimapEnabled },
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
      bindZoomCommands(diffEditor.getModifiedEditor());
      diffEditor.getModifiedEditor().addCommand(
        monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyF,
        function () { diffEditor.getModifiedEditor().getAction("actions.find").run(); }
      );
      diffEditor.getModifiedEditor().addCommand(
        monaco.KeyMod.CtrlCmd | monaco.KeyMod.Alt | monaco.KeyCode.Enter,
        function () { postToSwift({ type: "sendSelectionShortcut" }); },
        "!findWidgetVisible"
      );
      // F7 / Shift+F7 — jump between diff hunks (VS Code's diff navigation keys).
      diffEditor.getModifiedEditor().addCommand(
        monaco.KeyCode.F7,
        function () { goToDiffHunk("next"); }
      );
      diffEditor.getModifiedEditor().addCommand(
        monaco.KeyMod.Shift | monaco.KeyCode.F7,
        function () { goToDiffHunk("previous"); }
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

  function goToDiffHunk(direction) {
    if (!diffEditor) return;
    // IDiffEditor.goToDiff is the modern API; older Monaco builds only have
    // the accessible diff-review actions, which also move the cursor.
    if (typeof diffEditor.goToDiff === "function") {
      diffEditor.goToDiff(direction);
      return;
    }
    var actionId = direction === "next"
      ? "editor.action.diffReview.next"
      : "editor.action.diffReview.prev";
    var action = diffEditor.getModifiedEditor().getAction(actionId);
    if (action) action.run();
  }

  function postSave(path, entry) {
    var content = entry.model.getValue();
    var pending = pendingSaves[path];
    if (pending) {
      pending.content = content;
      pending.count++;
    } else {
      pendingSaves[path] = { content: content, count: 1 };
    }
    postToSwift({ type: "save", path: path, content: content });
  }

  function requestSave() {
    if (!currentPath) return;
    var entry = models[currentPath];
    if (!entry) return;
    postSave(currentPath, entry);
  }

  // Save every dirty buffer, not just the active tab. Each save goes through
  // the same Swift round-trip as Cmd+S (write + markSaved per path).
  // skipPaths carries buffers Swift knows changed on disk while dirty —
  // writing those would clobber the external change.
  function saveAllDirty(skipPaths) {
    var skip = {};
    (skipPaths || []).forEach(function (path) { skip[path] = true; });
    Object.keys(models).forEach(function (path) {
      if (skip[path]) return;
      var entry = models[path];
      if (entry.model.getValue() === entry.cleanValue) return;
      postSave(path, entry);
    });
  }

  function applyFontSize() {
    if (editor) editor.updateOptions({ fontSize: editorFontSize });
    if (diffEditor) diffEditor.updateOptions({ fontSize: editorFontSize });
  }

  function zoomFont(delta) {
    editorFontSize = Math.max(8, Math.min(32, editorFontSize + delta));
    applyFontSize();
  }

  function resetFontZoom() {
    editorFontSize = 13;
    applyFontSize();
  }

  function bindZoomCommands(target) {
    target.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Equal, function () { zoomFont(1); });
    target.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Minus, function () { zoomFont(-1); });
    target.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Digit0, function () { resetFontZoom(); });
  }

  function toggleWordWrap() {
    wordWrap = !wordWrap;
    var wrap = wordWrap ? "on" : "off";
    if (editor) editor.updateOptions({ wordWrap: wrap });
    if (diffEditor) diffEditor.updateOptions({ wordWrap: wrap });
  }

  function toggleMinimap() {
    minimapEnabled = !minimapEnabled;
    if (editor) editor.updateOptions({ minimap: { enabled: minimapEnabled } });
    if (diffEditor) diffEditor.updateOptions({ minimap: { enabled: minimapEnabled } });
  }

  // Swift asks for the current selection (send-to-agent flow). Always
  // reply — an empty payload tells the Swift side to no-op.
  function reportSelection(requestID) {
    var target = activeEditor();
    var model = target && target.getModel();
    var sel = target && target.getSelection();
    // Pierre diff modes render outside Monaco: the regular editor is
    // hidden but keeps its pre-diff selection — never paste that.
    var pierreActive = diffMode && diffMode !== "monaco";
    if (pierreActive || !currentPath || !model || !sel || sel.isEmpty()) {
      postToSwift({ type: "selection", requestID: requestID, path: "" });
      return;
    }
    // A full-line selection parks the cursor on column 1 of the next
    // line; that line contributes no content, so drop it from the range.
    var endLine = sel.endLineNumber;
    if (sel.endColumn === 1 && endLine > sel.startLineNumber) endLine -= 1;
    postToSwift({
      type: "selection",
      requestID: requestID,
      path: currentPath,
      text: model.getValueInRange(sel),
      startLine: sel.startLineNumber,
      endLine: endLine
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
        if (typeof msg.line === "number") revealLine(msg.line, msg.column, msg.endLine);
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
      case "toggleWordWrap": toggleWordWrap(); break;
      case "saveAll": saveAllDirty(msg.skipPaths); break;
      case "toggleMinimap": toggleMinimap(); break;
      case "getSelection": reportSelection(msg.requestID); break;
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
    // Base64 transport — avoids embedding raw JSON (backticks, ${...}) in a
    // JS template literal, which broke on files containing those sequences.
    handleB64: function (b64) {
      try {
        var binary = atob(b64);
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        var json = new TextDecoder("utf-8").decode(bytes);
        window.niruxBridge.handle(json);
      } catch (e) {
        postToSwift({ type: "error", message: "b64 decode failed: " + String(e) });
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
        "editorStickyScroll.background": "#1a1b26",
        "editorStickyScroll.shadow": "#00000066",
        "editorStickyScrollHover.background": "#1f2335",
        "editorBracketHighlight.foreground1": "#7aa2f7",
        "editorBracketHighlight.foreground2": "#e0af68",
        "editorBracketHighlight.foreground3": "#9ece6a",
        "editorBracketHighlight.foreground4": "#bb9af7",
        "editorBracketHighlight.foreground5": "#7dcfff",
        "editorBracketHighlight.foreground6": "#f7768e",
        "editorBracketHighlight.unexpectedBracket.foreground": "#ff6b7d",
        "editorBracketPairGuide.activeBackground1": "#7aa2f766",
        "editorBracketPairGuide.activeBackground2": "#e0af6866",
        "editorBracketPairGuide.activeBackground3": "#9ece6a66",
        "editorBracketPairGuide.activeBackground4": "#bb9af766",
        "editorBracketPairGuide.activeBackground5": "#7dcfff66",
        "editorBracketPairGuide.activeBackground6": "#f7768e66",
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
      smoothScrolling: true,
      stickyScroll: { enabled: true },
      bracketPairColorization: { enabled: true },
      guides: { bracketPairs: true },
      find: { seedSearchStringFromSelection: "selection" }
    });

    // Cmd+S → ask Swift to write the active file. Swift writes, then sends
    // markSaved back so JS can adopt the new clean baseline.
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () {
      requestSave();
    });

    // Explicit find binding — guarantees Cmd+F opens the find widget even if
    // key routing above the WebView ever intercepts it before Monaco sees it.
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyF, function () {
      editor.getAction("actions.find").run();
    });

    bindZoomCommands(editor);

    // Explicit go-to-line binding — same rationale as the Cmd+F binding
    // above. addCommand registers page-globally, so route through
    // activeEditor(): targeting `editor` while the diff surface is up would
    // open the goto-line input on the hidden editor.
    editor.addCommand(monaco.KeyMod.WinCtrl | monaco.KeyCode.KeyG, function () {
      var target = activeEditor();
      if (target) target.getAction("editor.action.gotoLine").run();
    });

    // Cmd+P → ask Swift to show its native file picker, scoped to the workspace.
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyP, function () {
      postToSwift({ type: "filePickerRequest" });
    });

    // Cmd+Opt+Enter → send selection to the agent terminal. The
    // precondition keeps Monaco's own Cmd+Opt+Enter (Replace All) working
    // while the find widget is open; Swift's key interceptor forwards the
    // chord here instead of the menu for editor columns.
    editor.addCommand(
      monaco.KeyMod.CtrlCmd | monaco.KeyMod.Alt | monaco.KeyCode.Enter,
      function () { postToSwift({ type: "sendSelectionShortcut" }); },
      "!findWidgetVisible"
    );

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
