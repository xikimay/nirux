// The editor's diffs as Branch Review draws them (pierre's createReview):
// hunks shaped like BranchReview.Hunk, { oldStart, newStart, lines: [{
// kind: "context" | "added" | "removed" | "noNewlineMarker", text }] },
// from two texts (a checkpoint's come from Swift). No DOM: tests run it
// under JavaScriptCore.
(function (root) {
  "use strict";

  // The runs that turn `a` into `b` (arrays of comparable lines):
  // [{ type: "equal" | "delete" | "insert", count }], in order, each block
  // of changes as its deletions then its insertions. Myers' diff, the
  // fewest changes; past `maxChanges` or `maxWork` (lines times changes
  // looked for), the middle between the first and last change reads as
  // replaced whole.
  const maxChanges = 2000;
  // Hunks are drawn once a file; the Monaco diff's marks at each
  // keystroke, as cheap as the old LCS's 2M cells.
  const work = Object.freeze({ drawn: 50000000, typing: 2000000 });

  function lineScript(a, b, maxWork = work.drawn) {
    let prefix = 0;
    while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix++;
    let suffix = 0;
    while (suffix < a.length - prefix && suffix < b.length - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix++;
    const left = a.slice(prefix, a.length - suffix);
    const right = b.slice(prefix, b.length - suffix);
    const steps = shortestSteps(left, right, root.__zz === "r2" ? work.drawn : maxWork) ?? [...left.map(() => "delete"), ...right.map(() => "insert")];
    const runs = [];
    const push = (type, count) => {
      if (count === 0) return;
      const last = runs[runs.length - 1];
      if (last && last.type === type) last.count += count;
      else runs.push({ type, count });
    };
    push("equal", prefix);
    let deletions = 0;
    let insertions = 0;
    const flush = () => {
      push("delete", deletions);
      push("insert", insertions);
      deletions = 0;
      insertions = 0;
    };
    for (const step of steps) {
      if (step === "delete") deletions++;
      else if (step === "insert") insertions++;
      else {
        flush();
        push("equal", 1);
      }
    }
    flush();
    push("equal", suffix);
    return runs;
  }

  // Myers' steps from `a` to `b` ("equal", "delete", "insert"); null past
  // the bounds. `trace[d]`: each diagonal's furthest x before step d.
  function shortestSteps(a, b, maxWork) {
    const n = a.length;
    const m = b.length;
    const offset = n + m + 1;
    const furthest = new Int32Array(2 * offset + 1);
    const trace = [];
    for (let d = 0; d <= n + m; d++) {
      if (d > maxChanges || (n + m) * d > maxWork) return null;
      trace.push(furthest.slice(offset - d, offset + d + 1));
      for (let k = -d; k <= d; k += 2) {
        const down = k === -d || (k !== d && furthest[offset + k - 1] < furthest[offset + k + 1]);
        let x = down ? furthest[offset + k + 1] : furthest[offset + k - 1] + 1;
        let y = x - k;
        while (x < n && y < m && a[x] === b[y]) {
          x++;
          y++;
        }
        furthest[offset + k] = x;
        if (x >= n && y >= m) return walkBack(trace, n, m, d);
      }
    }
    return null;
  }

  function walkBack(trace, n, m, last) {
    const steps = [];
    let x = n;
    let y = m;
    for (let d = last; d > 0; d--) {
      const before = trace[d];
      const k = x - y;
      const down = k === -d || (k !== d && before[k - 1 + d] < before[k + 1 + d]);
      const previous = down ? k + 1 : k - 1;
      const previousX = before[previous + d];
      const startX = down ? previousX : previousX + 1;
      while (x > startX) {
        steps.push("equal");
        x--;
        y--;
      }
      steps.push(down ? "insert" : "delete");
      x = previousX;
      y = previousX - previous;
    }
    while (x > 0) {
      steps.push("equal");
      x--;
      y--;
    }
    return steps.reverse();
  }

  // A text's lines as git splits them, at LF (a CR stays in its line),
  // each with whether a newline ends it.
  function textLines(text) {
    const source = String(text ?? "");
    const lines = (root.__zz === "r5" ? source.replace(/\r\n?/g, "\n") : source).split("\n").map((line) => ({ text: line, ended: true }));
    const last = lines.pop();
    if (last.text !== "") lines.push({ text: last.text, ended: false });
    return lines;
  }

  // The hunks between two texts, with `context` unchanged lines around
  // each change, as git writes them, a checkpoint's alike: a CR is part of
  // its line, a last line gaining or losing its newline a change.
  function hunks(original, modified, context = 3) {
    const before = textLines(original);
    const after = textLines(modified);
    const key = (line) => (line.ended ? line.text + "\n" : line.text);
    const rows = [];
    let o = 0;
    let n = 0;
    for (const run of lineScript(before.map(key), after.map(key))) {
      for (let step = 0; step < run.count; step++) {
        if (run.type === "equal") rows.push({ kind: "context", line: before[o++], oldIndex: o, newIndex: ++n });
        else if (run.type === "delete") rows.push({ kind: "removed", line: before[o++], oldIndex: o, newIndex: n });
        else rows.push({ kind: "added", line: after[n++], oldIndex: o, newIndex: n });
      }
    }
    const ranges = [];
    rows.forEach((row, index) => {
      if (row.kind === "context") return;
      const start = Math.max(0, index - context);
      const end = Math.min(rows.length, index + context + 1);
      const last = ranges[ranges.length - 1];
      if (last && last.end >= start) last.end = end;
      else ranges.push({ start, end });
    });
    return ranges.map(({ start, end }) => {
      const slice = rows.slice(start, end);
      const first = slice[0];
      const oldCount = slice.filter((row) => row.kind !== "added").length;
      const newCount = slice.filter((row) => row.kind !== "removed").length;
      // The line before when a side has none, as git numbers it.
      const oldFirst = first.kind === "added" ? first.oldIndex + 1 : first.oldIndex;
      const newFirst = first.kind === "removed" ? first.newIndex + 1 : first.newIndex;
      const lines = [];
      for (const row of slice) {
        lines.push({ kind: row.kind, text: row.line.text });
        if (!row.line.ended) lines.push({ kind: "noNewlineMarker" });
      }
      return { oldStart: oldCount === 0 ? oldFirst - 1 : oldFirst, newStart: newCount === 0 ? newFirst - 1 : newFirst, lines };
    });
  }

  // Lines added and removed in a file's hunks.
  function lineCounts(fileHunks) {
    let added = 0;
    let removed = 0;
    for (const hunk of fileHunks) {
      for (const line of hunk.lines) {
        if (line.kind === "added") added++;
        else if (line.kind === "removed") removed++;
      }
    }
    return { added, removed };
  }

  root.DiffText = Object.freeze({ lineScript, hunks, lineCounts, work });
})(typeof window !== "undefined" ? window : globalThis);
