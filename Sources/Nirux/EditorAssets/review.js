// The Branch Review page (docs/branch-review.md, section 2). Swift sends the
// page's data (`BranchReview.Page`) and, when a row opens, its file's diff
// (`BranchReview.FileDiff`); the page sends back ids and links, never text
// to type. Every string from the branch is set with textContent.
(function () {
  "use strict";

  const P = window.ReviewPage;
  const pageElement = document.getElementById("page");
  const statusElement = document.getElementById("status");
  const svgNS = "http://www.w3.org/2000/svg";

  // What the user opened and filtered, kept across a new page for the same
  // branch.
  const state = { page: null, risk: null, openGroups: new Map(), openFiles: new Set(), openAccounts: new Set() };
  let review = null;

  function post(message) {
    window.webkit?.messageHandlers?.review?.postMessage(message);
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function icon(name) {
    const svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("class", "icon");
    svg.setAttribute("aria-hidden", "true");
    const use = document.createElementNS(svgNS, "use");
    use.setAttribute("href", `#i-${name}`);
    svg.append(use);
    return svg;
  }

  function lineCounts(additions, deletions) {
    const span = element("span", "lines");
    span.append(element("span", "added", `+${additions}`));
    if (deletions > 0) span.append(" ", element("span", "removed", `−${deletions}`));
    return span;
  }

  function link(text, url, className) {
    if (!url) return element("span", "dead-link", text);
    const anchor = element("a", className, text);
    anchor.href = "#";
    anchor.title = url;
    anchor.addEventListener("click", (event) => {
      event.preventDefault();
      post({ type: "openLink", url });
    });
    return anchor;
  }

  // MARK: Markdown

  function spans(list) {
    const fragment = document.createDocumentFragment();
    for (const span of list) {
      switch (span.type) {
        case "code": fragment.append(element("code", null, span.text)); break;
        case "strong": fragment.append(element("strong", null, span.text)); break;
        case "em": fragment.append(element("em", null, span.text)); break;
        case "link": fragment.append(link(span.text, span.url)); break;
        default: fragment.append(document.createTextNode(span.text));
      }
    }
    return fragment;
  }

  function blocks(list, container) {
    for (const block of list) {
      switch (block.type) {
        case "heading": {
          const heading = element(`h${Math.min(6, Math.max(1, block.level))}`);
          heading.append(spans(block.spans));
          container.append(heading);
          break;
        }
        case "list": {
          const listElement = element(block.ordered ? "ol" : "ul");
          if (block.ordered && block.start > 1) listElement.start = block.start;
          for (const item of block.items) {
            const entry = element("li");
            // A task list says which steps the author did.
            if (item.checked !== null && item.checked !== undefined) {
              entry.classList.add("task");
              entry.append(element("span", "check", item.checked ? "\u2611 " : "\u2610 "));
            }
            entry.append(spans(item.spans));
            blocks(item.lists, entry);
            listElement.append(entry);
          }
          container.append(listElement);
          break;
        }
        case "code": container.append(element("pre", null, block.text)); break;
        case "quote": {
          const quote = element("blockquote");
          blocks(block.blocks, quote);
          container.append(quote);
          break;
        }
        case "rule": container.append(element("hr")); break;
        default: {
          const paragraph = element("p");
          paragraph.append(spans(block.spans));
          container.append(paragraph);
        }
      }
    }
  }

  function markdown(text, withDecisions) {
    const container = element("div", "markdown");
    const parsed = P.parseMarkdown(text);
    const { blocks: rest, decisions } = withDecisions ? P.splitDecisions(parsed) : { blocks: parsed, decisions: null };
    if (decisions) {
      const box = element("div", "decisions");
      box.append(element("div", "decisions-title", decisions.title));
      blocks(decisions.blocks, box);
      container.append(box);
    }
    blocks(rest, container);
    return container;
  }

  // MARK: Sections

  function header(page) {
    const { header: info } = page;
    const meta = element("div", "meta");
    if (info.pullRequest) {
      const chip = link("", info.pullRequest.url, "chip");
      chip.append(icon("pr"), `#${info.pullRequest.number}${info.pullRequest.isDraft ? " draft" : ""}`);
      meta.append(chip);
    }
    const parts = [
      element("span", "mono", info.head.slice(0, 7)),
      element("span", null, P.commitsLabel(info)),
      element("span", null, P.count(info.files, "file")),
      lineCounts(info.additions, info.deletions),
      element("span", null, `Read ${P.clockTime(info.readAt)}`)
    ];
    parts.forEach((part, index) => {
      if (index > 0) meta.append(element("span", "separator", "·"));
      meta.append(part);
    });
    const section = element("div", "section");
    section.append(meta);
    if (info.notes.length > 0) {
      const notes = element("ul", "notes");
      for (const note of info.notes) {
        const item = element("li");
        item.append(icon("info"), element("span", null, note));
        notes.append(item);
      }
      section.append(notes);
    }
    return section;
  }

  function accounts(page) {
    const section = element("div", "section");
    section.append(element("div", "label", "What and why"));
    const authored = page.accounts.filter((account) => account.source !== "commits");
    if (authored.length === 0) {
      const block = element("div", "block");
      block.append(element("div", "empty", page.accounts.length > 0
        ? "No pull request and no handover: the commits are the author’s only account."
        : "No pull request, no handover and no commit yet."));
      section.append(block);
    }
    for (const account of page.accounts) {
      const block = element("div", "block");
      const source = element("div", "source");
      source.append(icon(account.source === "pullRequest" ? "pr" : account.source === "commits" ? "commit" : "file"));
      source.append(element("span", null, account.label));
      block.append(source);
      if (account.title) block.append(element("h3", "block-title", account.title));
      if (account.source === "commits") {
        block.append(commitList(account.commits));
      } else if (account.text.trim().length > 0) {
        const text = markdown(account.text, account.source === "pullRequest");
        block.append(text);
        if (account.text.length > longAccount) clamp(block, text, `${account.source}:${account.label}`);
      } else {
        block.append(element("div", "empty", "No description."));
      }
      section.append(block);
    }
    return section;
  }

  // Past this many characters, an account shows its beginning and a
  // button for the rest: a handover can fill several screens.
  const longAccount = 1500;

  function clamp(block, text, key) {
    const button = element("button", "more");
    button.type = "button";
    const apply = () => {
      const open = state.openAccounts.has(key);
      text.classList.toggle("clamped", !open);
      button.textContent = open ? "Show less" : "Show all";
    };
    button.addEventListener("click", () => {
      if (state.openAccounts.has(key)) state.openAccounts.delete(key);
      else state.openAccounts.add(key);
      apply();
    });
    apply();
    block.append(button);
  }

  function commitList(commits) {
    const list = element("ul", "commits");
    for (const commit of commits) {
      const item = element("li");
      item.append(element("span", "oid mono", commit.oid.slice(0, 7)));
      if (commit.body.trim().length > 0) {
        const details = element("details");
        details.append(element("summary", null, commit.subject));
        details.append(element("pre", null, commit.body.trim()));
        item.append(details);
      } else {
        item.append(element("span", null, commit.subject));
      }
      list.append(item);
    }
    return list;
  }

  function risks(page) {
    const section = element("div", "section");
    section.append(element("div", "label", "Risk signals · Nirux rules"));
    const chips = element("div", "risks");
    for (const risk of page.risks) {
      const chip = element("button", "chip");
      chip.type = "button";
      chip.dataset.risk = risk.kind;
      chip.append(icon(risk.kind), `${risk.label} `, element("b", null, String(risk.files)));
      if (risk.files === 0) {
        chip.disabled = true;
      } else {
        chip.title = risk.reasons.map(P.visible).join(", ");
        chip.setAttribute("aria-pressed", String(state.risk === risk.kind));
        chip.addEventListener("click", () => {
          state.risk = state.risk === risk.kind ? null : risk.kind;
          applyRiskFilter(true);
        });
      }
      chips.append(chip);
    }
    section.append(chips);
    const summary = P.testsSummary(page.tests);
    const tests = element("div", "tests");
    tests.append(icon("flask"), element("span", null, summary.lines));
    for (const note of summary.notes) tests.append(element("span", null, note));
    section.append(tests);
    return section;
  }

  // Dims the files that don't raise the risk, and opens the groups that
  // hold those that do: a lockfile's sits in a folded group.
  function applyRiskFilter(opensGroups) {
    for (const chip of pageElement.querySelectorAll("button.chip[data-risk]")) {
      if (!chip.disabled) chip.setAttribute("aria-pressed", String(chip.dataset.risk === state.risk));
    }
    const files = new Map(state.page.files.map((file) => [file.id, file]));
    if (opensGroups && state.risk) {
      for (const group of state.page.groups) {
        if (!group.files.some((id) => P.matchesRisk(files.get(id), state.risk))) continue;
        const box = pageElement.querySelector(`.group[data-key="${CSS.escape(group.key)}"]`);
        box?.setOpen(true);
        box?.showMatching((file) => P.matchesRisk(file, state.risk));
      }
    }
    for (const row of pageElement.querySelectorAll(".file")) {
      row.classList.toggle("dim", !P.matchesRisk(files.get(Number(row.dataset.id)), state.risk));
    }
  }

  // Past this many rows, a group shows the first ones and a button for
  // the next: a branch can list thousands of untracked files.
  const rowsPerStep = 300;

  function groups(page) {
    const section = element("div", "section");
    section.append(element("div", "label", "Changes \u00B7 by path"));
    const list = element("div", "groups");
    const files = new Map(page.files.map((file) => [file.id, file]));
    for (const group of page.groups) {
      const members = group.files.map((id) => files.get(id)).filter(Boolean);
      const box = element("div", `group${group.isFolded ? " folded" : ""}`);
      box.dataset.key = group.key;
      const button = element("button", "group-header");
      button.type = "button";
      const chevron = icon("chevron");
      chevron.classList.add("chevron");
      const additions = members.reduce((sum, file) => sum + file.additions, 0);
      const deletions = members.reduce((sum, file) => sum + file.deletions, 0);
      const count = element("span", "group-count", `${P.count(members.length, "file")} \u00B7 `);
      count.append(lineCounts(additions, deletions));
      button.append(chevron, element("span", "group-title", group.title), count);
      const body = element("div", "group-body");
      // Rows are built when the group first opens.
      let shown = 0;
      const more = element("button", "more rows-more");
      more.type = "button";
      const showMore = () => {
        const next = members.slice(shown, shown + rowsPerStep);
        shown += next.length;
        for (const file of next) body.insertBefore(fileRow(file), more);
        more.hidden = shown >= members.length;
        more.textContent = `Show ${P.count(Math.min(rowsPerStep, members.length - shown), "more file")}`;
      };
      more.addEventListener("click", showMore);
      body.append(more);
      const setOpen = (open) => {
        if (open && shown === 0) showMore();
        body.hidden = !open;
        button.setAttribute("aria-expanded", String(open));
      };
      box.setOpen = (open) => {
        setOpen(open);
        state.openGroups.set(group.key, open);
      };
      // Builds rows up to the last file `matches` keeps: the risk filter's
      // may be past the first step.
      box.showMatching = (matches) => {
        const last = members.findLastIndex(matches);
        while (shown <= last) showMore();
      };
      button.addEventListener("click", () => box.setOpen(body.hidden));
      setOpen(state.openGroups.get(group.key) ?? !group.isFolded);
      box.append(button, body);
      list.append(box);
    }
    section.append(list);
    return section;
  }

  function fileRow(file) {
    const box = element("div", "file");
    box.dataset.id = String(file.id);
    const row = element("button", "file-row");
    row.type = "button";
    const chevron = icon("chevron");
    chevron.classList.add("chevron");
    const letter = P.statusLetter(file.status);
    const path = element("span", "path");
    path.title = file.oldPath ? `${P.visible(file.oldPath)} \u2192 ${P.visible(file.path)}` : P.visible(file.path);
    if (file.oldPath) path.append(element("span", "from", `${P.visible(file.oldPath)} \u2192 `));
    const { folder, name } = P.splitPath(file.path);
    path.append(element("span", "folder", folder), name);
    const fileRisks = element("span", "file-risks");
    const riskLabels = file.risks.map((kind) => state.page.risks.find((entry) => entry.kind === kind)?.label ?? kind);
    file.risks.forEach((kind, index) => {
      const mark = icon(kind);
      const title = document.createElementNS(svgNS, "title");
      title.textContent = riskLabels[index];
      mark.append(title);
      fileRisks.append(mark);
    });
    const tag = P.fileTag(file);
    row.append(
      chevron, element("span", `status-letter ${letter}`, letter), path, fileRisks, element("span", "tag", tag ?? ""),
      lineCounts(file.additions, file.deletions)
    );
    row.setAttribute("aria-label", [
      `${file.status} ${path.title}`, tag, `${file.additions} added, ${file.deletions} removed`,
      riskLabels.length > 0 ? `risks: ${riskLabels.join(", ")}` : null
    ].filter(Boolean).join(", "));
    const diff = element("div", "diff");
    diff.hidden = true;
    row.addEventListener("click", () => toggleFile(file, row, diff));
    box.classList.toggle("dim", !P.matchesRisk(file, state.risk));
    box.append(row, diff);
    if (state.openFiles.has(file.path)) toggleFile(file, row, diff);
    return box;
  }

  function toggleFile(file, row, diff) {
    const open = diff.hidden;
    diff.hidden = !open;
    row.setAttribute("aria-expanded", String(open));
    if (open) {
      state.openFiles.add(file.path);
      if (!diff.hasChildNodes()) {
        diff.append(element("div", "diff-message", "Loading\u2026"));
        post({ type: "loadFile", id: file.id, generation: state.page.generation });
      }
    } else {
      state.openFiles.delete(file.path);
    }
  }

  // MARK: Entry points for Swift

  function show(json) {
    try {
      render(JSON.parse(json));
    } catch (error) {
      // Never leave the previous page up as if it were this one: its rows'
      // ids are another snapshot's.
      state.page = null;
      showStatus(`The page couldn’t show this review: ${error.message}`);
      throw error;
    }
  }

  function render(page) {
    const samebranch = state.page && state.page.header.branch === page.header.branch;
    if (!samebranch) {
      state.risk = null;
      state.openGroups.clear();
      state.openFiles.clear();
      state.openAccounts.clear();
    }
    state.page = page;
    if (state.risk && !page.risks.some((risk) => risk.kind === state.risk && risk.files > 0)) state.risk = null;
    const sections = [header(page), accounts(page), risks(page), groups(page)];
    review = window.NiruxPierreDiff.createReview(document);
    // A refresh keeps the reader where they were, as far as the new page
    // goes.
    const scrolled = pageElement.hidden ? 0 : window.scrollY;
    statusElement.classList.remove("shown");
    pageElement.replaceChildren(...sections);
    pageElement.hidden = false;
    applyRiskFilter(false);
    window.scrollTo(0, scrolled);
  }

  function showDiff(json) {
    const diff = JSON.parse(json);
    const box = pageElement.querySelector(`.file[data-id="${Number(diff.id)}"] .diff`);
    if (!state.page) return;
    const file = state.page.files.find((entry) => entry.id === diff.id);
    // A diff read for another page of the review, whose row this isn't.
    if (!box || !review || diff.generation !== state.page.generation || (diff.path && file && diff.path !== file.path)) return;
    const previous = box.querySelector(".diff-box");
    if (previous) review.removeFile(previous);
    box.replaceChildren();
    if (diff.message || diff.hunks.length === 0) {
      box.append(element("div", "diff-message", diff.message || "No line changed."));
      return;
    }
    const holder = element("div", "diff-box");
    box.append(holder);
    try {
      review.renderFile(holder, { path: file ? file.path : "", hunks: diff.hunks });
    } catch (error) {
      box.replaceChildren(element("div", "diff-message", `Couldn’t show this diff: ${error.message}`));
    }
  }

  // A message in place of the page: loading, or why there is no review.
  // What the user opened stays, for the page that comes back.
  function showStatus(message) {
    statusElement.textContent = String(message ?? "");
    statusElement.classList.add("shown");
    pageElement.hidden = true;
  }

  window.NiruxReview = Object.freeze({ show, showDiff, showStatus });
  post({ type: "ready" });
})();
