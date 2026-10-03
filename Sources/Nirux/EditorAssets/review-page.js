// The Branch Review page's pure functions (docs/branch-review.md, section 2):
// no DOM, so that tests run them under JavaScriptCore. review.js draws what
// they return, with textContent only.
//
// Markdown from a pull request or a handover is a branch's text, a fork's
// included: it is parsed into blocks and spans, never into HTML. Raw HTML
// in it reads as text.
(function (root) {
  "use strict";

  // Blocks: { type: "heading", level, spans } | { type: "paragraph", spans }
  // | { type: "list", ordered, start, items: [{ spans, checked, lists }] }
  // | { type: "code", text }
  // | { type: "quote", blocks } | { type: "rule" }.
  //
  // A branch can write anything here: the parser keeps every regular
  // expression linear and every loop moving, and nests quotes and lists
  // only so deep. Deeper ones read as the level above.
  const maxDepth = 8;

  function parseMarkdown(text) {
    // Every line break, Unicode's included, ends a line: one left inside a
    // line would read as its end to some expressions and not to others.
    return parseLines(String(text ?? "").replace(/\r\n?|[\u2028\u2029]/g, "\n").split("\n"), 0);
  }

  function parseLines(lines, depth) {
    const blocks = [];
    let index = 0;
    while (index < lines.length) {
      const line = lines[index];
      if (/^\s*$/.test(line)) {
        index++;
        continue;
      }
      const fence = line.match(/^\s{0,3}(```+|~~~+)/);
      if (fence) {
        // Closed by a line of the same character, at least as many, and
        // nothing else: "```js" opens a block, it doesn't close one.
        const closing = new RegExp(`^\\s{0,3}${fence[1][0] === "`" ? "`" : "~"}{${fence[1].length},}\\s*$`);
        const body = [];
        index++;
        while (index < lines.length && !closing.test(lines[index])) body.push(lines[index++]);
        index++;
        blocks.push({ type: "code", text: body.join("\n") });
        continue;
      }
      const heading = parseHeading(line);
      if (heading) {
        blocks.push(heading);
        index++;
        continue;
      }
      if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) {
        blocks.push({ type: "rule" });
        index++;
        continue;
      }
      if (isQuote(line) && depth < maxDepth) {
        const quoted = [];
        while (index < lines.length && isQuote(lines[index])) quoted.push(lines[index++].replace(/^\s{0,3}>\s?/, ""));
        blocks.push({ type: "quote", blocks: parseLines(quoted, depth + 1) });
        continue;
      }
      if (listItem(line)) {
        const parsed = parseList(lines, index, depth);
        blocks.push(parsed.list);
        index = parsed.next;
        continue;
      }
      // A paragraph, up to a blank line or another block. Its first line is
      // always in it: no line can stop the parse.
      const paragraph = [line.trim()];
      index++;
      while (
        index < lines.length && !/^\s*$/.test(lines[index]) && !parseHeading(lines[index])
        && !/^\s{0,3}(```|~~~)/.test(lines[index]) && !isQuote(lines[index]) && !listItem(lines[index])
      ) {
        paragraph.push(lines[index++].trim());
      }
      blocks.push({ type: "paragraph", spans: parseInline(paragraph.join(" ")) });
    }
    return blocks;
  }

  function isQuote(line) {
    return /^\s{0,3}>/.test(line);
  }

  // "## Title ##": the closing run of "#" goes only after a space, as in
  // CommonMark ("Port to C#" keeps its "#").
  function parseHeading(line) {
    const match = line.match(/^\s{0,3}(#{1,6})(?:[ \t]+(.*))?$/);
    if (!match) return null;
    let text = (match[2] ?? "").trim();
    const closing = text.match(/(^|[ \t])#+$/);
    if (closing) text = text.slice(0, closing.index).trim();
    return { type: "heading", level: match[1].length, spans: parseInline(text) };
  }

  // A list from `start`, nested by indentation: items are
  // { spans, lists }, `lists` the lists indented under the item.
  function parseList(lines, start, depth) {
    const first = listItem(lines[start]);
    const items = [];
    let index = start;
    while (index < lines.length) {
      const line = lines[index];
      if (/^\s*$/.test(line)) {
        // A blank line ends the list unless an item of it, or under it,
        // follows.
        let next = index + 1;
        while (next < lines.length && /^\s*$/.test(lines[next])) next++;
        const item = next < lines.length ? listItem(lines[next]) : null;
        if (!item || item.indent < first.indent || (item.indent === first.indent && item.ordered !== first.ordered)) break;
        index = next;
        continue;
      }
      const item = listItem(line);
      if (item && (item.indent === first.indent || (item.indent > first.indent && depth + 1 >= maxDepth))) {
        if (item.indent === first.indent && item.ordered !== first.ordered) break;
        items.push({ text: item.text, checked: item.checked, lists: [] });
        index++;
      } else if (item && item.indent > first.indent && items.length > 0) {
        const nested = parseList(lines, index, depth + 1);
        items[items.length - 1].lists.push(nested.list);
        index = nested.next;
      } else if (!item && indentation(line) > first.indent && items.length > 0) {
        // The item above goes on.
        items[items.length - 1].text += " " + line.trim();
        index++;
      } else {
        break;
      }
    }
    if (index === start) index++;
    return {
      list: {
        type: "list", ordered: first.ordered, start: first.start,
        items: items.map((item) => ({ spans: parseInline(item.text), checked: item.checked, lists: item.lists }))
      },
      next: index
    };
  }

  function indentation(line) {
    return line.match(/^[ \t]*/)[0].replace(/\t/g, "    ").length;
  }

  // `checked`: true or false for a task ("- [x] ..."), null otherwise.
  function listItem(line) {
    const bullet = line.match(/^([ \t]*)[-*+]\s+(?:\[([ xX])\]\s+)?(.*)$/);
    if (bullet) {
      const checked = bullet[2] === undefined ? null : bullet[2] !== " ";
      return { ordered: false, start: 1, indent: indentation(bullet[1]), checked, text: bullet[3] };
    }
    const number = line.match(/^([ \t]*)(\d{1,9})[.)]\s+(.*)$/);
    if (number) return { ordered: true, start: Number(number[2]), indent: indentation(number[1]), checked: null, text: number[3] };
    return null;
  }

  // Spans: { type: "text" | "code" | "strong" | "em", text }
  // | { type: "link", text, url } (url null when it isn't http or https).
  function parseInline(text) {
    const spans = [];
    const source = String(text ?? "");
    // Each alternative stops at the next of its own delimiters: the scan
    // stays linear whatever the text.
    const pattern = /`([^`]+)`|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*\s][^*]*)\*|(?<![\w])_([^_\s][^_]*)_(?![\w])|\[([^[\]]*)\]\(([^()\s]*)\)|<(https?:\/\/[^<>\s]+)>/g;
    let last = 0;
    for (const match of source.matchAll(pattern)) {
      if (match.index > last) spans.push({ type: "text", text: source.slice(last, match.index) });
      if (match[1] !== undefined) spans.push({ type: "code", text: match[1] });
      else if (match[2] !== undefined || match[3] !== undefined) spans.push({ type: "strong", text: match[2] ?? match[3] });
      else if (match[4] !== undefined || match[5] !== undefined) spans.push({ type: "em", text: match[4] ?? match[5] });
      else if (match[6] !== undefined) spans.push({ type: "link", text: match[6] || match[7], url: safeURL(match[7]) });
      else spans.push({ type: "link", text: match[8], url: safeURL(match[8]) });
      last = match.index + match[0].length;
    }
    if (last < source.length) spans.push({ type: "text", text: source.slice(last) });
    return spans;
  }

  // Only web links open, in the browser; Swift checks them again.
  function safeURL(url) {
    const value = String(url ?? "");
    return /^https?:\/\/[^\s\/?#<>"]+([\/?#][^\s<>"]*)?$/i.test(value) ? value : null;
  }

  // The sections of a pull request body: a heading that starts with
  // "Decisions" begins one shown apart, since decisions are what a reviewer
  // must not undo by accident. Returns { blocks, decisions } (decisions
  // null when there is no such heading).
  function splitDecisions(blocks) {
    const start = blocks.findIndex((block) => block.type === "heading" && /^decisions\b/i.test(plainText(block.spans)));
    if (start < 0) return { blocks, decisions: null };
    const level = blocks[start].level;
    let end = blocks.findIndex((block, index) => index > start && block.type === "heading" && block.level <= level);
    if (end < 0) end = blocks.length;
    return {
      blocks: blocks.slice(0, start).concat(blocks.slice(end)),
      decisions: { title: plainText(blocks[start].spans), blocks: blocks.slice(start + 1, end) }
    };
  }

  function plainText(spans) {
    return spans.map((span) => span.text).join("");
  }

  function count(number, noun) {
    return `${number} ${noun}${number === 1 ? "" : "s"}`;
  }

  // "3 commits (1 merge from main)".
  function commitsLabel(header) {
    const merges = header.mergesFromBase > 0
      ? ` (${count(header.mergesFromBase, "merge")} from ${header.base})`
      : "";
    return count(header.commits, "commit") + merges;
  }

  // "Sources/Nirux/" and "App.swift", with hidden characters shown.
  function splitPath(path) {
    const value = visible(path);
    const slash = value.lastIndexOf("/");
    return slash < 0 ? { folder: "", name: value } : { folder: value.slice(0, slash + 1), name: value.slice(slash + 1) };
  }

  // A path as the page shows it: line breaks, bidi controls and invisible
  // characters as their code point, as the diffs show them (a bidi
  // control can hide a file's real extension).
  const hiddenCharacters = /(?<!\p{Emoji})[\uFE0E\uFE0F]|(?![\uFE0E\uFE0F])[\p{Default_Ignorable_Code_Point}\n\r\u2028\u2029\uFFF9-\uFFFB]/gu;

  function visible(text) {
    return String(text ?? "").replace(
      hiddenCharacters,
      (character) => `\u27E8U+${character.codePointAt(0).toString(16).toUpperCase().padStart(4, "0")}\u27E9`
    );
  }

  const statusLetters = { added: "A", modified: "M", deleted: "D", renamed: "R", typeChanged: "T" };

  function statusLetter(status) {
    return statusLetters[status] ?? "M";
  }

  // The tests line of section 5: "Tests +578 for code +458", then what no
  // test mentions. "mentions", never "tested".
  function testsSummary(tests) {
    const parts = [];
    if (tests.testFilesUnlisted) {
      parts.push("Nirux couldn’t list the test files: every name reads as unmentioned.");
    }
    if (tests.declared > 0) {
      const names = tests.unmentioned.map((entry) => entry.name);
      const shown = names.slice(0, 3);
      const more = names.length > shown.length ? `, +${names.length - shown.length}` : "";
      parts.push(names.length === 0
        ? `Every one of the ${count(tests.declared, "new name")} is mentioned by a test.`
        : `${names.length} of ${count(tests.declared, "new name")} in no test: ${shown.join(", ")}${more}.`);
    }
    if (tests.unscannedFiles.length > 0) {
      parts.push(`Names unknown in ${tests.unscannedFiles.map(visible).join(", ")}.`);
    }
    if (tests.unreadTestFiles > 0) {
      parts.push(`${count(tests.unreadTestFiles, "test file")} not read.`);
    }
    return { lines: `Tests +${tests.testLines} for code +${tests.codeLines}`, notes: parts };
  }

  // Groups and files the risk filter leaves visible: a file raising the
  // risk, or every file without a filter.
  function matchesRisk(file, risk) {
    return !risk || file.risks.includes(risk);
  }

  // Why a row's diff or counts are what they are, when the row doesn't say.
  function fileTag(file) {
    if (file.isBinary) return "binary";
    if (file.omission === "tooLarge") return "too large";
    if (file.omission === "notRead") return "not read";
    if (file.isUntracked) return "new";
    return null;
  }

  // "14:05" from an ISO date, in the Mac's time zone.
  function clockTime(iso) {
    const date = new Date(String(iso ?? ""));
    if (Number.isNaN(date.getTime())) return "";
    return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  }

  const api = {
    parseMarkdown, parseInline, safeURL, splitDecisions, plainText, count, commitsLabel, splitPath,
    statusLetter, testsSummary, matchesRisk, visible, fileTag, clockTime
  };
  root.ReviewPage = Object.freeze(api);
})(typeof window !== "undefined" ? window : globalThis);
