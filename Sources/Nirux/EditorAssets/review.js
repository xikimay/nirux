// The Branch Review page (docs/branch-review.md, section 2). Swift sends the
// page's data (`BranchReview.Page`) and, when a row opens, its file's diff
// (`BranchReview.FileDiff`); the page sends back ids and links, never text
// to type. Every string from the branch is set with textContent.
(function () {
  "use strict";

  const P = window.ReviewPage;
  const pageElement = document.getElementById("page");
  const statusElement = document.getElementById("status");
  const bannerElement = document.getElementById("banner");
  const svgNS = "http://www.w3.org/2000/svg";

  // What the user opened and filtered, kept across a new page for the same
  // branch.
  // `diffs`: the diffs drawn, by path, with what they were drawn from (the
  // file's `diffKey` and the merge base, which fix lines, context and
  // numbers): a new page of the same branch keeps those that didn't change.
  // `holders`: every diff drawn, to let go of those a new page drops.
  // `openCommits` and `rowsShown`, by commit and group: what the user
  // opened stays open across pages.
  // `stored`: the stored review (`BranchReview.Page.Review`), its files'
  // Reviewed states by id; null until the column opened it. `clicks`: the
  // Reviewed clicks Swift hasn't answered yet, by path, with their number
  // (`clickCount`): they show over what it sent before.
  const state = {
    page: null, risk: null, openGroups: new Map(), openFiles: new Set(), openAccounts: new Set(), diffs: new Map(),
    holders: new Set(), openCommits: new Set(), rowsShown: new Map(), stored: null, clicks: new Map(),
    // From the clock: a page loaded again after its process died counts
    // on from past what Swift answered before.
    clickCount: Date.now()
  };
  // Ticks the elapsed time of the Explain under way.
  let explainTimer = null;

  function diffKey(file) {
    return file.diffKey ? `${file.diffKey}@${state.page.header.mergeBase}` : null;
  }
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
    const progress = element("span", "review-progress");
    progress.hidden = true;
    meta.append(progress);
    const section = element("div", "section");
    section.append(meta);
    const problem = element("div", "review-problem");
    problem.setAttribute("role", "status");
    problem.hidden = true;
    section.append(problem);
    if (info.notes.length > 0) {
      const notes = element("ul", "notes");
      for (const note of info.notes) {
        const item = element("li");
        item.append(icon("info"), element("span", null, note));
        notes.append(item);
      }
      section.append(notes);
    }
    const bar = element("div", "explain-bar");
    bar.id = "explain-bar";
    fillExplainBar(bar, page);
    section.append(bar);
    return section;
  }

  function button(label, primary, onClick) {
    const node = element("button", primary ? "action" : "action secondary", label);
    node.type = "button";
    node.addEventListener("click", onClick);
    return node;
  }

  // Explain's button, what it says, how the last one ended and today's
  // usage (`BranchReview.Page.ExplainBar`). Swift sends a new bar as the
  // run goes; the page stays as it is around it.
  function fillExplainBar(container, page) {
    const bar = page.explain;
    const actions = P.explainActions(bar);
    const row = element("div", "explain-row");
    const status = element("span", "explain-status");
    status.append(icon("spark"));
    const text = element("span");
    status.append(text);
    const explained = page.explanation;
    if (bar.state === "running" && bar.progress) {
      text.classList.add("explain-progress");
      text.textContent = P.explainProgress(bar.progress, Date.now());
    } else if (explained && bar.state === "ready") {
      // What the page shows, and what changed since.
      text.textContent = [`Explained by Claude at ${explained.head.slice(0, 7)}`, explained.model, actions.text]
        .filter(Boolean).join(" \u00B7 ");
    } else if (actions.text) {
      text.textContent = actions.text;
    }
    // Nothing to say beside the button: no lone icon either.
    status.firstChild.style.visibility = text.textContent ? "" : "hidden";
    row.append(status);
    if (bar.untracked > 0 && (bar.state === "ready" || bar.state === "checking" || bar.state === "unavailable")) {
      const label = element("label", "explain-untracked");
      const box = element("input");
      box.type = "checkbox";
      box.checked = bar.includeUntracked;
      box.addEventListener("change", () => post({ type: "includeUntracked", include: box.checked }));
      label.append(box, ` Include ${P.count(bar.untracked, "untracked file")}`);
      label.title = "Untracked files go by name only, unless included.";
      row.append(label);
    }
    for (const entry of actions.buttons) {
      const node = button(entry.label, entry.primary, () => {
        if (entry.action === "cancel") post({ type: "cancelExplain" });
        else post({ type: "explain", fresh: entry.fresh });
      });
      node.disabled = Boolean(entry.disabled);
      if (entry.disabled && bar.state === "unavailable") node.title = bar.message ?? "";
      row.append(node);
    }
    container.replaceChildren(row);
    if (bar.message) container.append(element("div", "explain-message", bar.message));
    const usage = P.usageLine(bar.usage);
    if (usage) {
      const line = element("div", "explain-usage", usage);
      line.title = "What these runs would cost at API prices. On a Claude subscription, they count toward the plan’s usage limits instead.";
      container.append(line);
    }
    clearInterval(explainTimer);
    explainTimer = null;
    if (bar.state === "running" && bar.progress) {
      explainTimer = setInterval(() => {
        if (!text.isConnected) return clearInterval(explainTimer);
        text.textContent = P.explainProgress(bar.progress, Date.now());
      }, 1000);
    }
  }

  // Claude's overview, above the author's account: labeled with the model
  // and the head it read. Shown as text, line breaks kept.
  function overview(explanation, page) {
    const block = element("div", "block");
    const source = element("div", "source claude");
    source.append(icon("spark"), element("span", null,
      `Claude \u00B7 read ${explanation.head.slice(0, 7)} and the repository \u00B7 ${explanation.model}`));
    if (!explanation.isCurrent) source.append(element("span", "outdated-tag", `the branch is at ${page.header.head.slice(0, 7)} now`));
    block.append(source, element("div", "overview", explanation.overview));
    return block;
  }

  // The author's claims the code doesn't match, with Claude's evidence;
  // matching ones only counted. Then Claude's questions for the author.
  function checked(page) {
    const explanation = page.explanation;
    if (!explanation || (explanation.claims.length === 0 && explanation.matching === 0 && explanation.questions.length === 0)) {
      return null;
    }
    const section = element("div", "section");
    section.append(element("div", "label", "Checked by Claude"));
    if (explanation.claims.length > 0 || explanation.matching > 0) {
      const block = element("div", "block");
      const source = element("div", "source claude");
      const counts = [];
      if (explanation.matching > 0) counts.push(`${explanation.matching} match`);
      if (explanation.claims.length > 0) counts.push(`${explanation.claims.length} don’t fully`);
      source.append(icon("spark"), element("span", null, `The author’s claims, checked against the code \u00B7 ${counts.join(" \u00B7 ")}`));
      block.append(source);
      const list = element("div", "claims");
      for (const claim of explanation.claims) {
        const item = element("div", "claim");
        const body = element("div");
        body.append(element("div", "claim-text", claim.claim), element("div", "claim-evidence", claim.evidence));
        item.append(element("span", "verdict", P.verdictLabel(claim.verdict)), body);
        list.append(item);
      }
      if (explanation.claims.length > 0) block.append(list);
      section.append(block);
    }
    if (explanation.questions.length > 0) {
      const block = element("div", "block");
      const source = element("div", "source claude");
      source.append(icon("help"), element("span", null, "Claude’s questions for the author"));
      const list = element("ul", "questions");
      for (const question of explanation.questions) list.append(element("li", null, question));
      block.append(source, list);
      section.append(block);
    }
    return section;
  }

  function accounts(page) {
    const section = element("div", "section");
    section.append(element("div", "label", "What and why"));
    if (page.explanation) section.append(overview(page.explanation, page));
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
        details.open = state.openCommits.has(commit.oid);
        details.addEventListener("toggle", () => {
          if (details.open) state.openCommits.add(commit.oid);
          else state.openCommits.delete(commit.oid);
        });
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
    const byIntent = page.groups.some((group) => group.intent);
    section.append(element("div", "label", byIntent ? "Changes \u00B7 by intent (Claude)" : "Changes \u00B7 by path"));
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
      button.append(chevron);
      if (group.intent) {
        const intent = element("span", "intent", P.intentLabel(group.intent));
        intent.dataset.intent = group.intent;
        button.append(intent);
      }
      button.append(element("span", "group-title", group.title), count, element("span", "group-progress"));
      const check = checkbox("group-check");
      check.addEventListener("click", () => toggleGroupReviewed(group, check));
      const head = element("div", "group-head");
      head.append(button, check);
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
      more.addEventListener("click", () => {
        showMore();
        state.rowsShown.set(group.key, shown);
      });
      body.append(more);
      const setOpen = (open) => {
        if (open && shown === 0) {
          // As many rows as the user had shown on the page before.
          do showMore(); while (shown < members.length && shown < (state.rowsShown.get(group.key) ?? 0));
        }
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
      box.append(head, body);
      list.append(box);
    }
    section.append(list);
    return section;
  }

  function fileRow(file) {
    const box = element("div", "file");
    box.dataset.id = String(file.id);
    box.dataset.path = file.path;
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
    const tags = element("span", "tag", tag ?? "");
    tags.append(element("span", "review-note"));
    row.append(
      chevron, element("span", `status-letter ${letter}`, letter), path, fileRisks, tags,
      lineCounts(file.additions, file.deletions)
    );
    if (file.summary) {
      const summary = element("span", `file-summary${file.summaryIsOutdated ? " outdated" : ""}`, file.summary);
      if (file.summaryIsOutdated) summary.append(element("span", "outdated-tag", "changed since explained"));
      row.append(summary);
    }
    row.setAttribute("aria-label", [
      `${file.status} ${path.title}`, tag, `${file.additions} added, ${file.deletions} removed`,
      riskLabels.length > 0 ? `risks: ${riskLabels.join(", ")}` : null,
      file.summary ? `Claude: ${file.summary}${file.summaryIsOutdated ? " (changed since explained)" : ""}` : null
    ].filter(Boolean).join(", "));
    const diff = element("div", "diff");
    diff.hidden = true;
    row.addEventListener("click", () => toggleFile(file, row, diff));
    const check = checkbox("file-check");
    check.addEventListener("click", () => toggleReviewed(file, check));
    const head = element("div", "file-head");
    head.append(row, check);
    box.classList.toggle("dim", !P.matchesRisk(file, state.risk));
    box.append(head, diff);
    applyFileReview(box, file);
    if (state.openFiles.has(file.path)) toggleFile(file, row, diff);
    return box;
  }

  // MARK: Reviewed (section 6.3)

  // A checkbox beside a row's button (a button can't hold one): a box
  // drawn in a larger target.
  function checkbox(className) {
    const button = element("button", `review-check ${className}`);
    button.type = "button";
    button.setAttribute("role", "checkbox");
    const box = element("span", "box");
    const tick = icon("check");
    tick.classList.add("tick");
    const dash = icon("minus");
    dash.classList.add("dash");
    box.append(tick, dash);
    button.append(box);
    return button;
  }

  // Disabled, but still focusable and with its tooltip.
  function setEnabled(check, enabled) {
    if (enabled) check.removeAttribute("aria-disabled");
    else check.setAttribute("aria-disabled", "true");
  }

  function isEnabled(check) {
    return check.getAttribute("aria-disabled") !== "true";
  }

  // Each file's state, by id: Swift's, under the clicks it hasn't
  // answered yet. Empty while the review isn't known. Made once per
  // change: rows are built hundreds at a time.
  let statesMade = null;

  function reviewStates() {
    if (statesMade) return statesMade;
    const stored = state.stored;
    if (!stored || stored.files.length !== state.page.files.length) return (statesMade = []);
    statesMade = state.page.files.map((file) => {
      const click = state.clicks.get(file.path);
      if (!click || !P.isMarkable(stored.files[file.id])) return stored.files[file.id];
      return click.reviewed ? "reviewed" : "none";
    });
    return statesMade;
  }

  function canWrite() {
    return Boolean(state.stored && state.stored.canWrite && reviewStates().length > 0);
  }

  function applyFileReview(box, file, states) {
    const stored = state.stored;
    const reviewState = (states ?? reviewStates())[file.id];
    const check = box.querySelector(".file-check");
    check.setAttribute("aria-checked", String(P.isReviewed(reviewState)));
    check.setAttribute("aria-label", `Reviewed: ${P.visible(file.path)}`);
    check.title = !stored ? "Opening the review\u2026" : reviewState === undefined ? stored.problem ?? "" : P.reviewTitle(reviewState);
    setEnabled(check, canWrite() && P.isMarkable(reviewState));
    box.querySelector(".review-note").textContent = reviewState === "changed" ? "changed since reviewed" : "";
    box.classList.toggle("reviewed", P.isReviewed(reviewState));
  }

  // Every row built, every group, the progress and why the review can't
  // be changed, from Swift's review and the clicks it hasn't answered.
  function applyReview() {
    if (!state.page) return;
    const stored = state.stored;
    const states = reviewStates();
    const known = states.length > 0;
    for (const box of pageElement.querySelectorAll(".file")) {
      const file = state.page.files[Number(box.dataset.id)];
      if (file) applyFileReview(box, file, states);
    }
    for (const group of state.page.groups) {
      const box = pageElement.querySelector(`.group[data-key="${CSS.escape(group.key)}"]`);
      if (!box) continue;
      const groupState = known ? P.groupReviewState(group.files, states) : "disabled";
      const check = box.querySelector(".group-check");
      check.setAttribute("aria-checked", groupState === "all" ? "true" : groupState === "some" ? "mixed" : "false");
      check.setAttribute("aria-label", `Reviewed: every file of ${group.title}`);
      check.title = !stored ? "Opening the review\u2026"
        : groupState === "all" ? "Clear Reviewed for these files" : "Mark these files reviewed";
      setEnabled(check, canWrite() && groupState !== "disabled");
      const reviewed = group.files.filter((id) => P.isReviewed(states[id])).length;
      box.querySelector(".group-progress").textContent = known ? ` \u00B7 ${reviewed}/${group.files.length} reviewed` : "";
    }
    const progress = pageElement.querySelector(".review-progress");
    if (progress) {
      progress.replaceChildren();
      if (known) progress.append(element("span", "separator", "\u00B7"), element("span", null, P.reviewProgress(states)));
      progress.hidden = !known;
    }
    // Changed only when its text does: it is a live region.
    const problem = pageElement.querySelector(".review-problem");
    const text = stored && stored.problem ? stored.problem : "";
    if (problem && problem.textContent !== text) {
      problem.replaceChildren();
      if (text) problem.append(icon("info"), element("span", null, text));
      problem.hidden = !text;
    }
  }

  function toggleReviewed(file, check) {
    if (!isEnabled(check)) return;
    setReviewed([file.id], !P.isReviewed(reviewStates()[file.id]));
  }

  function toggleGroupReviewed(group, check) {
    if (!isEnabled(check)) return;
    const action = P.groupReviewAction(group.files, reviewStates());
    if (action.ids.length > 0) setReviewed(action.ids, action.reviewed);
  }

  // Shown at once, until Swift answers this click (`showReview`). A file
  // marked reviewed folds its diff, as on GitHub.
  function setReviewed(ids, reviewed) {
    state.clickCount += 1;
    const sequence = state.clickCount;
    const boxes = new Map([...pageElement.querySelectorAll(".file")].map((box) => [Number(box.dataset.id), box]));
    for (const id of ids) {
      const file = state.page.files[id];
      if (!file) continue;
      state.clicks.set(file.path, { reviewed, sequence });
      statesMade = null;
      if (!reviewed) continue;
      state.openFiles.delete(file.path);
      const box = boxes.get(id);
      const diff = box?.querySelector(".diff");
      if (diff && !diff.hidden) toggleFile(file, box.querySelector(".file-row"), diff);
    }
    applyReview();
    post({ type: "reviewed", ids, reviewed, generation: state.page.generation, sequence });
  }

  // Swift's review: the clicks it answered go.
  function takeReview(stored) {
    statesMade = null;
    state.stored = stored;
    for (const [path, click] of state.clicks) {
      if (stored && click.sequence <= stored.acknowledged) state.clicks.delete(path);
    }
  }

  function toggleFile(file, row, diff) {
    const open = diff.hidden;
    diff.hidden = !open;
    row.setAttribute("aria-expanded", String(open));
    if (open) {
      state.openFiles.add(file.path);
      if (!diff.hasChildNodes()) {
        const shown = state.diffs.get(file.path);
        if (shown && diffKey(file) && shown.key === diffKey(file)) {
          shown.node.classList.remove("stale");
          diff.append(shown.node);
          return;
        }
        if (shown) {
          // The file changed: its diff stays, dimmed, until the new one
          // replaces it, rather than blink to "Loading".
          shown.node.classList.add("stale");
          diff.append(shown.node);
        } else {
          diff.append(element("div", "diff-message", "Loading\u2026"));
        }
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

  // Where the reader is: the first group header or row still in view, by
  // what it shows (ids change from page to page), and how far down the
  // viewport it starts. Rows added above it don't move it.
  function anchorKey(node) {
    return node.classList.contains("file") ? `file:${node.dataset.path}` : `group:${node.closest(".group").dataset.key}`;
  }

  function readingAnchor() {
    if (pageElement.hidden || window.scrollY === 0) return null;
    for (const node of pageElement.querySelectorAll(".group-header, .file")) {
      const box = node.getBoundingClientRect();
      if (box.height > 0 && box.bottom > 0) return { key: anchorKey(node), top: box.top };
    }
    return null;
  }

  function restoreAnchor(anchor) {
    if (!anchor) return false;
    for (const node of pageElement.querySelectorAll(".group-header, .file")) {
      if (anchorKey(node) !== anchor.key) continue;
      window.scrollBy(0, node.getBoundingClientRect().top - anchor.top);
      return true;
    }
    return false;
  }

  // A text selection in the page: Swift holds back a new page of the same
  // head, which would drop it, until it goes. Diffs draw in shadow roots.
  function inPage(node) {
    while (node) {
      if (pageElement.contains(node)) return true;
      node = node.getRootNode().host ?? null;
    }
    return false;
  }

  let selecting = false;
  document.addEventListener("selectionchange", () => {
    const selection = document.getSelection();
    // In a shadow root, WebKit reports the selection collapsed, anchored
    // at the host's parent: its text says it's there.
    const active = Boolean(selection && selection.rangeCount > 0 && selection.toString() !== "" && inPage(selection.anchorNode));
    if (active === selecting) return;
    selecting = active;
    post({ type: "selection", active });
  });

  function render(page) {
    const samebranch = state.page && state.page.header.branch === page.header.branch;
    if (!samebranch) {
      state.risk = null;
      state.openGroups.clear();
      state.openFiles.clear();
      state.openAccounts.clear();
      state.openCommits.clear();
      state.rowsShown.clear();
    }
    state.page = page;
    if (!samebranch) state.clicks.clear();
    takeReview(page.review ?? null);
    if (state.risk && !page.risks.some((risk) => risk.kind === state.risk && risk.files > 0)) state.risk = null;
    // A refresh keeps the reader where they were, read before the diffs
    // kept move to the new page and shorten the old one.
    const scrolled = pageElement.hidden ? 0 : window.scrollY;
    const anchor = samebranch ? readingAnchor() : null;
    if (!samebranch || !review) {
      review = window.NiruxPierreDiff.createReview(document);
      state.diffs.clear();
      state.holders.clear();
    }
    const sections = [header(page), accounts(page), checked(page), risks(page), groups(page)].filter(Boolean);
    statusElement.classList.remove("shown");
    bannerElement.hidden = true;
    pageElement.replaceChildren(...sections);
    pageElement.hidden = false;
    for (const holder of state.holders) {
      if (holder.isConnected) continue;
      review.removeFile(holder);
      state.holders.delete(holder);
    }
    for (const [path, shown] of state.diffs) {
      if (!shown.node.isConnected) state.diffs.delete(path);
    }
    applyRiskFilter(false);
    applyReview();
    window.scrollTo(0, scrolled);
    restoreAnchor(anchor);
  }

  function showDiff(json) {
    const diff = JSON.parse(json);
    const box = pageElement.querySelector(`.file[data-id="${Number(diff.id)}"] .diff`);
    if (!state.page) return;
    const file = state.page.files.find((entry) => entry.id === diff.id);
    // A diff read for another page of the review, whose row this isn't.
    if (!box || !review || diff.generation !== state.page.generation || (diff.path && file && diff.path !== file.path)) return;
    const previous = box.querySelector(".diff-box");
    if (previous) {
      review.removeFile(previous);
      state.holders.delete(previous);
    }
    // The diff drawn before is gone: a later page mustn't reuse it.
    if (file) state.diffs.delete(file.path);
    box.replaceChildren();
    if (diff.message || diff.hunks.length === 0) {
      // Not kept: a failed read must be read again by the next page.
      box.append(element("div", "diff-message", diff.message || "No line changed."));
      return;
    }
    const holder = element("div", "diff-box");
    box.append(holder);
    try {
      review.renderFile(holder, { path: file ? file.path : "", hunks: diff.hunks });
    } catch (error) {
      review.removeFile(holder);
      box.replaceChildren(element("div", "diff-message", `Couldn’t show this diff: ${error.message}`));
      return;
    }
    state.holders.add(holder);
    if (file && diffKey(file)) state.diffs.set(file.path, { key: diffKey(file), node: holder });
  }

  // Explain's bar as the run goes: only the bar changes.
  function showExplain(json) {
    const bar = JSON.parse(json);
    if (!state.page) return;
    state.page.explain = bar;
    const container = document.getElementById("explain-bar");
    if (container) fillExplainBar(container, state.page);
  }

  // The branch moved since the page was read: it stays as it is, and a
  // banner offers the new one.
  function showReload(message, action) {
    const button = element("button", "action", action ? String(action) : "Reload");
    button.type = "button";
    button.addEventListener("click", () => post({ type: "reload" }));
    bannerElement.replaceChildren(element("span", null, String(message ?? "")), button);
    bannerElement.hidden = false;
  }

  function hideReload() {
    bannerElement.hidden = true;
  }

  // The stored review again, after a write: for this page's generation
  // only.
  function showReview(json) {
    const stored = JSON.parse(json);
    if (!state.page || stored.generation !== state.page.generation) return;
    takeReview(stored);
    applyReview();
  }

  // A message in place of the page: loading, or why there is no review,
  // with a button when Swift offers something to do. What the user opened
  // stays, for the page that comes back.
  function showStatus(message, action) {
    statusElement.replaceChildren(element("div", null, String(message ?? "")));
    if (action) {
      const button = element("button", "action", String(action));
      button.type = "button";
      button.addEventListener("click", () => post({ type: "statusAction" }));
      statusElement.append(button);
    }
    statusElement.classList.add("shown");
    bannerElement.hidden = true;
    pageElement.hidden = true;
  }

  window.NiruxReview = Object.freeze({ show, showDiff, showExplain, showStatus, showReload, hideReload, showReview });
  post({ type: "ready" });
})();
