// The Branch Review page (docs/branch-review.md, section 2). Swift sends the
// page's data (`BranchReview.Page`) and, when a row opens, its file's diff
// (`BranchReview.FileDiff`); the page sends back ids, links and the user's
// comments, never text to type into an agent. Every string from the branch
// is set with textContent.
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
    clickCount: Date.now(),
    // Comments (section 6.1). `editors`: what is being written, by key (a
    // new comment's draft id, or the id of the comment an edit is of).
    // `dismissed`: drafts closed, by id, with the click Swift must answer
    // before its data stops showing them. `deleting`: comments asked to
    // go, likewise. `commentNodes`: what shows under lines and with files,
    // by key, kept so that a refresh doesn't take a focus. `hunks`: each
    // file's hunks drawn, by path, for the rows a comment is on.
    // `holderPaths`: which file each diff drawn shows. `selection`: lines
    // selected by their numbers ({ path, range }). `notices`: why lines
    // took no comment, by path. `cardProblems`: why a Delete wasn't done,
    // by comment. `focusAfter`: the comment just written, which takes the
    // focus its editor had. `wasWritable`: whether the review could be
    // written at Swift's last answer.
    editors: new Map(), dismissed: new Map(), deleting: new Map(), commentNodes: new Map(), hunks: new Map(),
    holderPaths: new Map(), selection: null, notices: new Map(), cardProblems: new Map(), focusAfter: null, typing: null,
    wasWritable: false, blockExtras: new Map(), refocus: null
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
    // The unsent comments go to the agent at once (section 6.2): the
    // column's sheet says where, and what goes.
    const send = button("", true, () => post({ type: "sendComments" }));
    send.classList.add("send-comments");
    send.hidden = true;
    section.append(send);
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
    const wrongNotes = P.notesLine(bar);
    if (wrongNotes) container.append(element("div", "explain-usage", wrongNotes));
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
        // Rows built after the page shows their comments at once. A
        // failure is logged: the page stays.
        const counts = state.page ? fileCounts() : null;
        for (const file of next) {
          const row = fileRow(file);
          body.insertBefore(row, more);
          try {
            if (counts) fillFileComments(row, file, counts);
          } catch (error) {
            console.error(error);
          }
        }
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
    tags.append(element("span", "review-note"), element("span", "comment-count"));
    row.append(
      chevron, element("span", `status-letter ${letter}`, letter), path, fileRisks, tags,
      lineCounts(file.additions, file.deletions)
    );
    if (file.summary) {
      const summary = element("span", `file-summary${file.summaryIsOutdated ? " outdated" : ""}`, file.summary);
      if (file.summaryIsOutdated) summary.append(element("span", "outdated-tag", "changed since explained"));
      row.append(summary);
    }
    row.dataset.label = [
      `${file.status} ${path.title}`, tag, `${file.additions} added, ${file.deletions} removed`,
      riskLabels.length > 0 ? `risks: ${riskLabels.join(", ")}` : null,
      file.summary ? `Claude: ${file.summary}${file.summaryIsOutdated ? " (changed since explained)" : ""}` : null
    ].filter(Boolean).join(", ");
    row.setAttribute("aria-label", row.dataset.label);
    const diff = element("div", "diff");
    diff.hidden = true;
    row.addEventListener("click", () => toggleFile(file, row, diff));
    const check = checkbox("file-check");
    check.addEventListener("click", () => toggleReviewed(file, check));
    const comment = element("button", "file-comment");
    comment.type = "button";
    comment.title = "Comment on this file";
    comment.setAttribute("aria-label", `Comment on ${P.visible(file.path)}`);
    comment.append(icon("comment"));
    comment.addEventListener("click", () => openEditor(file, null));
    const head = element("div", "file-head");
    head.append(row, comment, check);
    const comments = element("div", "file-comments");
    comments.hidden = true;
    box.classList.toggle("dim", !P.matchesRisk(file, state.risk));
    box.append(head, comments, diff);
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
    const sequence = nextSequence();
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
    if (stored) takeComments(stored);
    else commentsByID = new Map();
    // After the comments: the editor of a note's check that became one is
    // gone, and its button says so.
    showNoteMarks();
  }

  function toggleFile(file, row, diff) {
    const open = diff.hidden;
    diff.hidden = !open;
    row.setAttribute("aria-expanded", String(open));
    if (open) {
      state.openFiles.add(file.path);
      if (!diff.hasChildNodes()) {
        const shown = state.diffs.get(file.path);
        // Drawn from this patch, with this explanation's notes.
        if (shown && diffKey(file) && shown.key === diffKey(file) && shown.notesVersion === state.page.notesVersion) {
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

  // MARK: Comments (section 6.1)

  // Swift's comments, and the drafts of new ones, placed, by id.
  let commentsByID = new Map();

  function storedComments() {
    return state.stored?.comments ?? [];
  }

  function storedComment(id) {
    return commentsByID.get(id) ?? null;
  }

  function nextSequence() {
    state.clickCount += 1;
    return state.clickCount;
  }

  // The page's files by path, made once per page.
  let filesByPath = new Map();

  function fileOf(path) {
    return filesByPath.get(path) ?? null;
  }

  function canComment() {
    return Boolean(state.stored?.canWrite);
  }

  function cantComment() {
    return state.stored?.problem ?? "Comments can’t be saved now.";
  }

  // Where a comment's rows were: placed, its own; else its excerpt's ends.
  function commentEnds(comment) {
    if (comment.start) return [comment.start, comment.end];
    const rows = comment.excerpt ?? [];
    if (rows.length === 0) return [null, null];
    const end = (row) => ({ side: row.kind === "removed" ? "deletions" : "additions", line: row.line });
    return [end(rows[0]), end(rows[rows.length - 1])];
  }

  function dropEditor(editor) {
    clearTimeout(editor.timer);
    state.editors.delete(editor.key);
  }

  // A draft Swift holds that no editor shows: typed before a Reload, the
  // column closing or a crash. Not one the user just closed or sent, until
  // Swift has seen it.
  function restoreEditors() {
    for (const comment of storedComments()) {
      const [start, end] = commentEnds(comment);
      if (comment.state === "draft" && !state.editors.has(comment.id) && !state.dismissed.has(comment.id)) {
        state.editors.set(comment.id, {
          key: comment.id, id: comment.id, path: comment.path, start, end, editing: null, text: comment.text, saved: true
        });
      }
      if (comment.edit && !state.editors.has(comment.id) && !state.dismissed.has(comment.edit.id)) {
        state.editors.set(comment.id, {
          key: comment.id, id: comment.edit.id, path: comment.path, start, end, editing: comment.id, text: comment.edit.text,
          saved: true
        });
      }
    }
  }

  // An edit whose comment went: what was typed becomes a new comment's
  // editor where the comment was, under its own id, which keeps the
  // element (and the focus it may have). A save of the edit still on its
  // way is answered for nothing.
  function convertEditor(
    editor, why = "Its comment was deleted: Comment saves this as a new one.",
    whyGone = "Its comment was deleted, and its file is no longer in the diff: this can’t be saved."
  ) {
    const node = state.commentNodes.get(editor.key);
    const focused = editor.parts?.text && document.activeElement === editor.parts.text;
    state.editors.delete(editor.key);
    state.commentNodes.delete(editor.key);
    editor.editing = null;
    editor.id = crypto.randomUUID();
    editor.key = editor.id;
    editor.saved = false;
    editor.request = undefined;
    // Where the comment was last seen under its lines, in that page; rows
    // that weren't (outdated, say) aren't a page's: it goes on the file.
    if (!editor.underLines) editor.start = editor.end = null;
    const file = fileOf(editor.path);
    editor.problem = file ? why : whyGone;
    state.editors.set(editor.key, editor);
    if (node) {
      node.dataset.key = editor.key;
      state.commentNodes.set(editor.key, node);
    }
    if (focused) state.refocus = editor;
  }

  // An edit whose comment went to the agent: Swift made its draft a new
  // comment's, where the comment is (section 6.2). The editor goes on as
  // that draft, its element (and focus) kept.
  function adoptDraft(editor) {
    const node = state.commentNodes.get(editor.key);
    const focused = editor.parts?.text && document.activeElement === editor.parts.text;
    state.editors.delete(editor.key);
    state.commentNodes.delete(editor.key);
    Object.assign(editor, { editing: null, key: editor.id, saved: true, chosen: null, request: undefined, submitted: false });
    editor.problem = "Its comment went to the agent: this is a new comment now.";
    state.editors.set(editor.key, editor);
    if (node) {
      node.dataset.key = editor.key;
      state.commentNodes.set(editor.key, node);
    }
    if (focused) state.refocus = editor;
    // What was typed since its draft's last save (a Save refused) is saved.
    if (storedComment(editor.id)?.text !== editor.text) scheduleSave(editor);
  }

  // Swift answered up to `stored.acknowledged`, with why the clicks it
  // refused were refused: an editor whose Comment or Save went closes, one
  // refused says why, and so does a card whose Delete was.
  function takeComments(stored) {
    commentsByID = new Map(storedComments().map((comment) => [comment.id, comment]));
    const problems = new Map((stored.commentProblems ?? []).map((problem) => [problem.sequence, problem.message]));
    // Writable again, or its problem gone: what couldn't be done then is
    // said no more, the drafts closed meanwhile go now, and the text whose
    // save was refused is saved.
    const recovered = stored.canWrite && (!state.wasWritable || (state.hadProblem && !stored.problem));
    if (recovered) {
      state.cardProblems.clear();
      for (const [id, sequence] of state.dismissed) {
        if (sequence !== Infinity) continue;
        const now = nextSequence();
        state.dismissed.set(id, now);
        post({ type: "removeDraft", id, sequence: now });
      }
    }
    state.wasWritable = Boolean(stored.canWrite);
    state.hadProblem = Boolean(stored.problem);
    // A review not read (a lock, git) lists no comment: that isn't one
    // deleted.
    const known = state.page && stored.files.length === state.page.files.length;
    // A draft closed whose removal was refused stays closed, and goes once
    // something can be written again.
    for (const [id, sequence] of state.dismissed) {
      if (sequence <= stored.acknowledged) {
        if (problems.has(sequence)) state.dismissed.set(id, Infinity);
        else state.dismissed.delete(id);
      }
    }
    for (const [id, sequence] of state.deleting) {
      if (sequence > stored.acknowledged) continue;
      state.deleting.delete(id);
      if (problems.has(sequence)) state.cardProblems.set(id, problems.get(sequence));
    }
    for (const editor of [...state.editors.values()]) {
      // Its comment went (deleted elsewhere): what was typed stays, as a
      // new comment where it was.
      if (known && editor.editing && !storedComment(editor.editing) && !editor.submitted) {
        convertEditor(editor);
        continue;
      }
      // Its comment went to the agent: the edit is a new comment's draft
      // (Swift's), or what was typed since its last save is, or nothing
      // changed and it goes.
      // A Save on its way when it went is refused: its answer goes.
      if (editor.editing && storedComment(editor.editing)?.state === "sent") {
        const sent = storedComment(editor.editing);
        if (storedComment(editor.id)?.state === "draft") {
          adoptDraft(editor);
        } else if (editor.text.trim() !== sent.text.trim()) {
          editor.submitted = false;
          convertEditor(
            editor, "Its comment went to the agent: Comment saves this as a new one.",
            "Its comment went to the agent, and its file is no longer in the diff: this can’t be saved."
          );
        } else {
          dropEditor(editor);
        }
        continue;
      }
      // An edit's place as the comment shows now, in this page: where it
      // goes should its comment be deleted elsewhere.
      const edited = editor.editing ? storedComment(editor.editing) : null;
      if (edited) {
        const [start, end] = commentEnds(edited);
        const underLines = shownAt(edited.id) === "lines";
        const file = fileOf(edited.path);
        Object.assign(editor, {
          path: edited.path, start, end, underLines,
          chosen: underLines && file ? { file: file.id, generation: state.page.generation } : null
        });
      }
      // Made a comment, or its edit saved or cancelled, in another column:
      // an editor with nothing on its way, nothing refused, and not in use
      // here goes.
      const idle = editor.request === undefined && !editor.timer && !editor.unsaved && document.activeElement !== editor.parts?.text;
      const made = !editor.editing && editor.saved && storedComment(editor.id)?.state !== "draft" && storedComment(editor.id);
      const editDone = known && edited && editor.saved && edited.edit?.id !== editor.id;
      if (idle && (made || editDone)) {
        dropEditor(editor);
        continue;
      }
      // Its draft as Swift placed it: its label names where it is, in
      // this page.
      const draft = !editor.editing ? storedComment(editor.id) : null;
      if (draft?.state === "draft") {
        const [start, end] = draft.onFile ? [null, null] : commentEnds(draft);
        Object.assign(editor, { path: draft.path, start, end, chosen: null });
      }
      if (recovered && editor.unsaved && editor.request === undefined) {
        editor.unsaved = false;
        editor.problem = null;
        scheduleSave(editor);
      }
      if (editor.request === undefined || editor.request > stored.acknowledged) continue;
      const refused = problems.get(editor.request) ?? null;
      const submitted = editor.submitted;
      editor.request = undefined;
      editor.submitted = false;
      editor.problem = refused;
      // A save refused: saved again once something can be written.
      editor.unsaved = Boolean(refused) && !submitted;
      if (!submitted || refused) continue;
      // Saved: its comment shows, made or changed.
      const comment = storedComment(editor.editing ?? editor.id);
      if (comment && comment.state !== "draft" && !(editor.editing && comment.edit)) {
        dropEditor(editor);
        clearSelection(editor.path);
        state.focusAfter = editor.key;
      } else {
        editor.problem = "Nirux couldn’t confirm this was saved: try again.";
      }
    }
    restoreEditors();
  }

  // Where a comment, or an editor, shows: under its file's lines, with its
  // file, or among those whose file is gone.
  function shownAt(key) {
    const editor = state.editors.get(key);
    const comment = storedComment(editor?.editing ?? key);
    if (!comment || (editor && !editor.editing && comment.id !== editor.id)) {
      if (!editor) return null;
      if (!fileOf(editor.path)) return "gone";
      return editor.start && !chosenBefore(editor) ? "lines" : "file";
    }
    if (comment.placement === "fileGone") return "gone";
    return comment.placement === "placed" && comment.start ? "lines" : "file";
  }

  // The order things first showed in, kept: two on one line don't swap
  // places (and lose a focus) when one is typed in.
  let firstSeen = new Map();

  // `items` in the order their keys first showed in, those new in their
  // order here.
  function inFirstSeenOrder(items, keyOf = (item) => item) {
    for (const item of items) if (!firstSeen.has(keyOf(item))) firstSeen.set(keyOf(item), firstSeen.size);
    return items.sort((one, other) => firstSeen.get(keyOf(one)) - firstSeen.get(keyOf(other)));
  }

  // Lines chosen in a page a new one replaced, not saved yet: numbered as
  // that page did, they show with their file until Swift places them.
  function chosenBefore(editor) {
    return Boolean(editor.start && editor.chosen && editor.chosen.generation !== state.page?.generation);
  }

  // What shows under the lines of file `id`: comments, the drafts an editor
  // shows (a draft closed waits for Swift's answer, unseen), and the
  // editors Swift doesn't list yet.
  function annotationsOf(id) {
    const comments = storedComments().filter((comment) => comment.state !== "draft" || state.editors.has(comment.id));
    const editors = [...state.editors.values()]
      .filter((editor) => !storedComment(editor.editing ?? editor.id) && editor.start && !chosenBefore(editor))
      .map((editor) => ({ key: editor.key, file: fileOf(editor.path)?.id, end: editor.end }));
    return inFirstSeenOrder(P.commentAnnotations(comments, id, editors), (annotation) => annotation.key);
  }

  // The element a key shows, made once and filled again as it changes;
  // each card with what it was made from.
  const cardSignatures = new WeakMap();

  function commentNode(key) {
    let node = state.commentNodes.get(key);
    if (!node) {
      node = element("div", "comment");
      node.dataset.key = key;
      state.commentNodes.set(key, node);
    }
    fillComment(key, node);
    return node;
  }

  function fillComment(key, node) {
    const editor = state.editors.get(key);
    if (editor) {
      const view = editorView(editor);
      if (node.firstChild !== view) node.replaceChildren(view);
      updateEditor(editor);
      cardSignatures.delete(node);
      return;
    }
    const comment = storedComment(key);
    if (!comment || comment.state === "draft") {
      if (node.firstChild) node.replaceChildren();
      cardSignatures.delete(node);
      return;
    }
    // Made again only when it changed: a button kept keeps its focus.
    const signature = JSON.stringify([
      comment, state.deleting.has(key), state.cardProblems.get(key) ?? "", canComment(), node.dataset.confirming ?? ""
    ]);
    if (cardSignatures.get(node) === signature) return;
    cardSignatures.set(node, signature);
    node.replaceChildren(commentCard(comment, node));
  }

  function commentCard(comment, node) {
    const card = element("div", `comment-card${comment.state === "sent" ? " sent" : ""}`);
    const meta = element("div", "comment-meta");
    meta.append(element("span", "comment-label", comment.state === "sent" ? `Sent at ${comment.sentAt}` : "Comment"));
    const ends = commentEnds(comment);
    const lines = P.linesLabel(...ends);
    if (shownAt(comment.id) !== "lines") {
      const where = shownAt(comment.id) === "gone" ? `${P.visible(comment.path)}, ${lines}` : lines;
      meta.append(element("span", "comment-where", `on ${where}`));
    }
    card.append(meta);
    const note = P.placementNote(comment);
    if (note) card.append(element("div", "comment-note", note));
    if (comment.excerpt?.length > 0 && comment.placement !== "placed") {
      const excerpt = element("div", "comment-excerpt");
      for (const row of comment.excerpt) {
        const line = element("div", `excerpt-row ${row.kind}`);
        // A CRLF file's line ending, which the diff hides too.
        const text = String(row.text ?? "").replace(/\r$/, "");
        line.append(element("span", "excerpt-line", String(row.line)), element("span", "excerpt-text", P.visible(text)));
        excerpt.append(line);
      }
      card.append(excerpt);
    }
    card.append(element("div", "comment-body", comment.text));
    const problem = state.cardProblems.get(comment.id);
    if (problem) {
      const why = element("div", "comment-problem", problem);
      why.setAttribute("role", "alert");
      card.append(why);
    }
    const actions = element("div", "comment-actions");
    const named = (control, verb) => {
      control.setAttribute("aria-label", `${verb} your comment on ${lines}`);
      return control;
    };
    if (state.deleting.has(comment.id)) {
      actions.append(element("span", "comment-pending", "Deleting…"));
    } else if (node.dataset.confirming === "delete") {
      actions.append(
        element("span", "comment-confirm", "Delete this comment?"),
        button("Keep", false, () => {
          delete node.dataset.confirming;
          fillComment(comment.id, node);
          node.querySelector(".comment-actions button")?.focus();
        }),
        named(button("Delete", true, () => deleteComment(comment.id, node)), "Delete")
      );
    } else {
      if (comment.state !== "sent") actions.append(named(button("Edit", false, () => editComment(comment)), "Edit"));
      actions.append(named(button("Delete", false, () => {
        node.dataset.confirming = "delete";
        fillComment(comment.id, node);
        node.querySelector(".comment-actions button:last-child")?.focus();
      }), "Delete"));
    }
    for (const control of actions.querySelectorAll("button")) control.disabled = !canComment();
    card.append(actions);
    return card;
  }

  function editorView(editor) {
    if (editor.view) return editor.view;
    const view = element("div", "comment-editor");
    view.setAttribute("role", "group");
    view.setAttribute("aria-label", "Comment");
    const label = element("div", "comment-label");
    const text = element("textarea", "comment-text");
    text.maxLength = 20000;
    text.rows = 3;
    text.value = editor.text;
    text.placeholder = "Comment for the agent";
    text.addEventListener("input", () => {
      editor.text = text.value;
      scheduleSave(editor);
      updateEditor(editor);
    });
    text.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        submit(editor);
      }
    });
    const problem = element("div", "comment-problem");
    problem.setAttribute("role", "alert");
    const actions = element("div", "comment-actions");
    const cancel = button("Cancel", false, () => closeEditor(editor));
    const send = button(editor.editing ? "Save" : "Comment", true, () => submit(editor));
    actions.append(cancel, send);
    view.append(label, text, problem, actions);
    editor.view = view;
    editor.parts = { label, text, problem, send };
    return view;
  }

  function updateEditor(editor) {
    if (!editor.parts) return;
    const { label, text, problem, send } = editor.parts;
    const lines = P.linesLabel(editor.start, editor.end) + (chosenBefore(editor) ? ", as the diff was" : "");
    label.textContent = editor.editing ? `Editing your comment on ${lines}` : `New comment on ${lines}`;
    text.setAttribute("aria-label", label.textContent);
    // Nothing typed meanwhile is lost: the text is Swift's to answer for.
    text.readOnly = Boolean(editor.submitted);
    const why = editor.problem ?? (canComment() ? null : cantComment());
    if (problem.textContent !== (why ?? "")) problem.textContent = why ?? "";
    problem.hidden = !why;
    send.disabled = Boolean(editor.submitted) || editor.text.trim() === "" || !canComment();
    send.textContent = editor.submitted ? "Saving…" : editor.editing ? "Save" : "Comment";
  }

  // What a request names a comment's place by: the comment an edit is of,
  // or the file and its rows (or that it is on the whole file), in the
  // page they were chosen in. Swift fixes a draft's place at its first
  // save, reading the rows in that page (or one of its last few). An
  // editor of a draft Swift holds sends the page's file now, or none for a
  // file no longer in it: its place is fixed.
  function place(editor) {
    if (editor.editing) return { editing: editor.editing };
    const file = fileOf(editor.path);
    const at = editor.chosen ?? (file ? { file: file.id, generation: state.page.generation } : null);
    if (!at) return {};
    return editor.start ? { ...at, start: editor.start, end: editor.end } : { ...at, onFile: true };
  }

  // A draft is saved a moment after the last key. Comment, Save and Cancel
  // drop the save still waiting (the text goes with Comment and Save): it
  // would bring the draft back after them.
  function scheduleSave(editor) {
    clearTimeout(editor.timer);
    editor.timer = setTimeout(() => saveDraft(editor), 600);
  }

  function saveDraft(editor) {
    clearTimeout(editor.timer);
    editor.timer = null;
    // An editor closed, or of another branch's page, saves nothing.
    if (state.editors.get(editor.key) !== editor || !state.page || !canComment() || editor.submitted) return;
    editor.request = nextSequence();
    editor.saved = true;
    post({ type: "saveDraft", id: editor.id, text: editor.text, sequence: editor.request, ...place(editor) });
  }

  function submit(editor) {
    if (!state.page || !canComment() || editor.submitted || editor.text.trim() === "") return;
    clearTimeout(editor.timer);
    editor.request = nextSequence();
    editor.submitted = true;
    editor.problem = null;
    if (editor.editing) {
      post({ type: "editComment", id: editor.editing, text: editor.text, sequence: editor.request });
    } else {
      post({ type: "addComment", id: editor.id, text: editor.text, sequence: editor.request, ...place(editor) });
    }
    updateEditor(editor);
  }

  function closeEditor(editor) {
    dropEditor(editor);
    // Its draft waits for Swift's answer, unseen; for good while nothing
    // can be written.
    if (editor.saved) {
      if (canComment()) {
        const sequence = nextSequence();
        state.dismissed.set(editor.id, sequence);
        post({ type: "removeDraft", id: editor.id, sequence });
      } else {
        state.dismissed.set(editor.id, Infinity);
      }
    }
    clearSelection(editor.path);
    refreshComments();
    // The focus goes back to what opened it when it can (a note's
    // button), else to where comments start: the file's button (not
    // scrolled to: the page stays where the user reads).
    const back = editor.returnFocus?.isConnected ? editor.returnFocus : fileBox(editor.path)?.querySelector(".file-comment");
    back?.focus({ preventScroll: true });
  }

  function editComment(comment) {
    const [start, end] = commentEnds(comment);
    const editor = {
      key: comment.id, id: comment.edit?.id ?? crypto.randomUUID(), path: comment.path, start, end, editing: comment.id,
      text: comment.edit?.text ?? comment.text, saved: Boolean(comment.edit), underLines: shownAt(comment.id) === "lines"
    };
    state.editors.set(comment.id, editor);
    refreshComments();
    focusEditor(editor);
  }

  function deleteComment(id, node) {
    delete node.dataset.confirming;
    state.cardProblems.delete(id);
    const sequence = nextSequence();
    state.deleting.set(id, sequence);
    post({ type: "deleteComment", id, sequence });
    refreshComments();
    // The card goes: the focus goes back to where comments start.
    fileBox(storedComment(id)?.path)?.querySelector(".file-comment")?.focus({ preventScroll: true });
  }

  function focusEditor(editor) {
    const text = editor.parts?.text;
    if (!text || !text.isConnected) return;
    text.focus();
    text.setSelectionRange(text.value.length, text.value.length);
  }

  function fileBox(path) {
    const file = fileOf(path);
    return file ? pageElement.querySelector(`.file[data-id="${file.id}"]`) : null;
  }

  // A new comment on `lines` of `file` ({ start, end }), or on the whole
  // file (null).
  // `text`: what the editor starts with (a note's "check this"). Returns
  // the editor; none while nothing can be written.
  function openEditor(file, lines, text = "") {
    if (!canComment()) {
      return notice(file.path, cantComment(), { untilWritable: true });
    }
    state.notices.delete(file.path);
    const id = crypto.randomUUID();
    const editor = { key: id, id, path: file.path, start: lines?.start ?? null, end: lines?.end ?? null, editing: null, text, saved: false };
    // The page the lines were chosen in: a new one may replace it before
    // the first save, and number them otherwise. A comment on the file
    // takes the file as the page shows it then.
    if (editor.start) editor.chosen = { file: file.id, generation: state.page.generation };
    state.editors.set(id, editor);
    if (state.selection?.path === file.path) state.selection = null;
    if (!state.openFiles.has(file.path)) {
      const box = fileBox(file.path);
      if (box) toggleFile(file, box.querySelector(".file-row"), box.querySelector(".diff"));
    }
    refreshComments();
    focusEditor(editor);
    return editor;
  }

  function commentOnLines(container, range) {
    const file = fileOf(state.holderPaths.get(container));
    if (!file) return;
    // A diff dimmed while the file's new one is read numbers lines of
    // before.
    if (container.classList.contains("stale")) return notice(file.path, "This diff is being read again: choose the lines once it shows.");
    const lines = P.commentRange(state.hunks.get(file.path), range);
    if (lines.problem) return notice(file.path, lines.problem);
    openEditor(file, lines);
  }

  // Why the lines the user chose take no comment, by the file, until the
  // next choice; or why nothing can be written, until it can.
  function notice(path, text, { untilWritable = false } = {}) {
    state.notices.set(path, { text, untilWritable });
    refreshComments();
  }

  // Lines selected for the file at `path` are let go: their comment is
  // written, or dropped.
  function clearSelection(path) {
    if (state.selection?.path === path) state.selection = null;
    for (const [holder, shown] of state.holderPaths) if (shown === path) review?.setSelection(holder, null);
  }

  // Each file's block: its comments on the whole file, those not under
  // their lines, the editors there, why lines took no comment, and a
  // button for lines selected by their numbers; and its row's count.
  // `keys` are the comments and editors of the file, in order.
  function fillFileComments(box, file, counts, keys) {
    const block = box.querySelector(".file-comments");
    if (!block || !state.page) return;
    const nodes = inFirstSeenOrder((keys ?? fileKeys().get(file.path) ?? []).filter((key) => shownAt(key) === "file"))
      .map(commentNode);
    const notice = state.notices.get(file.path);
    if (notice?.untilWritable && canComment()) state.notices.delete(file.path);
    const shown = state.notices.get(file.path);
    // Kept while they say the same, so that the block isn't made again
    // under an editor being typed in.
    let extras = state.blockExtras.get(file.path);
    const selected = state.selection?.path === file.path && !isStale(file.path)
      ? P.commentRange(state.hunks.get(file.path), state.selection.range) : null;
    const offer = selected && !selected.problem && canComment() ? P.linesLabel(selected.start, selected.end) : null;
    if (!extras || extras.notice !== shown?.text || extras.offer !== offer) {
      const made = [];
      if (shown) {
        const note = element("div", "comment-notice", shown.text);
        note.setAttribute("role", "status");
        made.push(note);
      }
      if (offer) made.push(button(`Comment on ${offer}`, false, () => openEditor(file, selected)));
      extras = { notice: shown?.text, offer, nodes: made };
      state.blockExtras.set(file.path, extras);
    }
    const wanted = [...nodes, ...extras.nodes];
    if (wanted.length !== block.children.length || wanted.some((node, index) => block.children[index] !== node)) {
      block.replaceChildren(...wanted);
    }
    block.hidden = wanted.length === 0;
    const count = counts.comments.get(file.id) ?? 0;
    const drafts = counts.drafts.get(file.id) ?? 0;
    const label = [count > 0 ? P.count(count, "comment") : null, drafts > 0 ? P.count(drafts, "draft") : null].filter(Boolean).join(", ");
    const badge = box.querySelector(".comment-count");
    if (badge.textContent !== label) badge.textContent = label;
    const row = box.querySelector(".file-row");
    const name = [row.dataset.label, label].filter(Boolean).join(", ");
    if (row.getAttribute("aria-label") !== name) row.setAttribute("aria-label", name);
  }

  // Each file's comments (drafts aside) and editors, by path, once per
  // refresh.
  function fileKeys() {
    const byPath = new Map();
    const add = (path, key) => byPath.set(path, [...(byPath.get(path) ?? []), key]);
    for (const comment of storedComments()) if (comment.state !== "draft") add(comment.path, comment.id);
    for (const editor of state.editors.values()) if (!editor.editing) add(editor.path, editor.key);
    return byPath;
  }

  // The diff drawn for `path` is dimmed while its new one is read: its
  // lines are of before.
  function isStale(path) {
    for (const [holder, shown] of state.holderPaths) if (shown === path && holder.classList.contains("stale")) return true;
    return false;
  }

  // Each file's comments and drafts (a new comment's, or an edit's), by
  // its id: a row counts both, whether its diff is open or not. Not a
  // draft closed while nothing could be written.
  function fileCounts() {
    const drafts = new Map();
    for (const comment of storedComments()) {
      if (comment.file === null || comment.file === undefined) continue;
      const draft = comment.state === "draft" ? comment.id : comment.edit?.id;
      if (draft && state.dismissed.get(draft) !== Infinity) drafts.set(comment.file, (drafts.get(comment.file) ?? 0) + 1);
    }
    return { comments: P.commentCounts(storedComments()), drafts };
  }

  // "Send N Comments to Agent", for the unsent comments not already in an
  // agent's prompt; off while nothing can be written: sent, they are
  // marked so.
  function fillSendButton() {
    const send = pageElement.querySelector(".send-comments");
    if (!send) return;
    const inPrompt = new Set(state.stored?.inPrompt ?? []);
    const count = storedComments().filter((comment) => comment.state === "unsent" && !inPrompt.has(comment.id)).length;
    send.hidden = count === 0;
    send.textContent = P.sendLabel(count);
    send.disabled = !canComment();
    send.title = canComment() ? "" : cantComment();
  }

  // Comments whose file no longer differs from the base, at the top; a
  // draft only through its editor.
  function fillGoneComments() {
    const section = pageElement.querySelector(".gone-comments");
    if (!section) return;
    const keys = [...new Set([...storedComments().map((comment) => comment.id), ...state.editors.keys()])]
      .filter((key) => shownAt(key) === "gone" && (storedComment(key)?.state !== "draft" || state.editors.has(key)));
    const list = section.querySelector(".gone-list");
    const nodes = keys.map(commentNode);
    if (nodes.length !== list.children.length || nodes.some((node, index) => list.children[index] !== node)) list.replaceChildren(...nodes);
    section.hidden = nodes.length === 0;
  }

  // What each diff drawn was last given, so that a refresh that changes
  // nothing under its lines renders nothing.
  const annotated = new WeakMap();

  // Swift's data or the editors changed: what shows under lines, with
  // files and at the top follows. A failure here is logged: the page and
  // its diffs stay.
  function refreshComments() {
    if (!state.page || !review) return;
    try {
      for (const [holder, path] of state.holderPaths) {
        const file = fileOf(path);
        if (!holder.isConnected || !file) continue;
        const annotations = diffAnnotations(holder, file);
        const key = JSON.stringify(annotations);
        if (annotated.get(holder) === key) continue;
        annotated.set(holder, key);
        review.setAnnotations(holder, annotations);
      }
      const counts = fileCounts();
      const keys = fileKeys();
      for (const box of pageElement.querySelectorAll(".file")) {
        const file = state.page.files[Number(box.dataset.id)];
        if (file) fillFileComments(box, file, counts, keys.get(file.path) ?? []);
      }
      fillGoneComments();
      fillSendButton();
      const shown = new Set([...storedComments().map((comment) => comment.id), ...state.editors.keys()]);
      for (const [key, node] of state.commentNodes) {
        if (!shown.has(key)) state.commentNodes.delete(key);
        else if (node.isConnected) fillComment(key, node);
      }
      // A comment just written takes the focus its editor had, unless the
      // user went elsewhere meanwhile.
      if (state.focusAfter) {
        const node = state.commentNodes.get(state.focusAfter);
        state.focusAfter = null;
        const dropped = !document.activeElement || document.activeElement === document.body;
        if (node?.isConnected && dropped) {
          node.tabIndex = -1;
          node.focus({ preventScroll: true });
        }
      }
      if (state.refocus) {
        const editor = state.refocus;
        state.refocus = null;
        focusEditor(editor);
      }
    } catch (error) {
      console.error(error);
    }
    reportHolding();
  }

  // An editor moved (from its file to under its lines, as its file's diff
  // is drawn) loses the focus without a focusout (WebKit says nothing when
  // a focused element leaves the page), and may wait out of the page for
  // that diff: once pierre draws it back, its text takes the focus again,
  // unless the user went elsewhere.
  function restoreFocus() {
    const typing = state.typing;
    if (!typing?.isConnected || document.activeElement === typing) return;
    if (document.activeElement && document.activeElement !== document.body) return;
    typing.focus({ preventScroll: true });
    reportHolding();
  }
  document.addEventListener("focusin", (event) => {
    state.typing = event.target?.classList?.contains("comment-text") ? event.target : null;
  });
  document.addEventListener("focusout", (event) => {
    if (event.target === state.typing) state.typing = null;
  });

  // A text selection in the page: Swift holds back a new page of the same
  // head, which would drop it, until it goes. Diffs draw in shadow roots.
  function inPage(node) {
    while (node) {
      if (pageElement.contains(node)) return true;
      node = node.getRootNode().host ?? null;
    }
    return false;
  }

  // A comment being typed holds it back too: a new page would move its
  // editor, and take the focus. So does a press on an editor's button,
  // which takes the focus from its text before its click.
  let selecting = false;
  let holding = false;
  let pressing = false;
  function reportHolding() {
    const writing = pressing || Boolean(document.activeElement?.closest?.(".comment-editor"));
    const active = selecting || writing;
    if (active === holding) return;
    holding = active;
    post({ type: "selection", active });
  }
  document.addEventListener("selectionchange", () => {
    const selection = document.getSelection();
    // In a shadow root, WebKit reports the selection collapsed, anchored
    // at the host's parent: its text says it's there.
    selecting = Boolean(selection && selection.rangeCount > 0 && selection.toString() !== "" && inPage(selection.anchorNode));
    reportHolding();
  });
  document.addEventListener("focusin", reportHolding);
  document.addEventListener("focusout", () => setTimeout(reportHolding, 0));
  document.addEventListener("pointerdown", (event) => {
    pressing = Boolean(event.target?.closest?.(".comment-editor"));
    // A press elsewhere: the field that had the focus no longer takes it
    // back.
    if (!pressing) state.typing = null;
    if (pressing) reportHolding();
  }, true);
  for (const type of ["pointerup", "pointercancel"]) {
    document.addEventListener(type, () => setTimeout(() => {
      pressing = false;
      reportHolding();
    }, 0), true);
  }

  function render(page) {
    const samebranch = state.page && state.page.header.branch === page.header.branch;
    if (!samebranch) {
      state.risk = null;
      // What was being written is another branch's: its saves waiting go.
      for (const editor of [...state.editors.values()]) dropEditor(editor);
      state.cardProblems.clear();
      state.blockExtras.clear();
      firstSeen = new Map();
      state.dismissed.clear();
      state.deleting.clear();
      state.notices.clear();
      state.selection = null;
      state.openGroups.clear();
      state.openFiles.clear();
      state.openAccounts.clear();
      state.openCommits.clear();
      state.rowsShown.clear();
    }
    state.page = page;
    filesByPath = new Map(page.files.map((file) => [file.path, file]));
    if (!samebranch) state.clicks.clear();
    takeReview(page.review ?? null);
    if (state.risk && !page.risks.some((risk) => risk.kind === state.risk && risk.files > 0)) state.risk = null;
    // A refresh keeps the reader where they were, read before the diffs
    // kept move to the new page and shorten the old one.
    const scrolled = pageElement.hidden ? 0 : window.scrollY;
    const anchor = samebranch ? readingAnchor() : null;
    if (!samebranch || !review) {
      review = window.NiruxPierreDiff.createReview(document, {
        // Claude's notes and the comments, under the same lines.
        renderAnnotation: (annotation) => annotation.key.startsWith(notePrefix)
          ? noteCard(annotation) : commentNode(annotation.key),
        // A diff drawn later (as it scrolls into view) may bring back an
        // editor that had the focus.
        onRendered: () => restoreFocus(),
        onGutterClick: (range, container) => commentOnLines(container, range),
        onSelect: (range, container) => {
          const path = state.holderPaths.get(container);
          state.selection = range && path ? { path, range } : null;
          refreshComments();
        }
      });
      notes.clear();
      noteCards.clear();
      state.diffs.clear();
      state.holders.clear();
      state.holderPaths.clear();
      state.hunks.clear();
      state.commentNodes.clear();
    }
    const gone = element("div", "section gone-comments");
    gone.hidden = true;
    gone.append(element("div", "label", "Comments on files no longer in the diff"), element("div", "gone-list"));
    const sections = [header(page), gone, accounts(page), checked(page), risks(page), groups(page)].filter(Boolean);
    statusElement.classList.remove("shown");
    bannerElement.hidden = true;
    pageElement.replaceChildren(...sections);
    pageElement.hidden = false;
    for (const holder of state.holders) {
      if (holder.isConnected) continue;
      review.removeFile(holder);
      state.holders.delete(holder);
      state.holderPaths.delete(holder);
    }
    for (const [path, shown] of state.diffs) {
      if (!shown.node.isConnected) state.diffs.delete(path);
    }
    // The notes of the diffs let go.
    for (const [id, card] of noteCards) {
      if (card.isConnected) continue;
      noteCards.delete(id);
      notes.delete(id);
    }
    applyRiskFilter(false);
    applyReview();
    refreshComments();
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
      state.holderPaths.delete(previous);
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
    const fileNotes = Array.isArray(diff.notes) ? diff.notes : [];
    for (const note of fileNotes) {
      // The last mark Swift confirmed.
      note.settled = note.isWrong;
      // Its file: its "check this" may become one of its comments.
      note.path = file?.path ?? null;
      notes.set(note.id, note);
    }
    holderNotes.set(holder, fileNotes.map((note) => ({ side: note.side, lineNumber: note.lineNumber, key: notePrefix + note.id })));
    if (file) {
      state.hunks.set(file.path, diff.hunks);
      state.holderPaths.set(holder, file.path);
      // Lines selected in the diff of before are let go.
      if (state.selection?.path === file.path) state.selection = null;
    }
    try {
      const annotations = diffAnnotations(holder, file);
      review.renderFile(holder, { path: file ? file.path : "", hunks: diff.hunks, annotations });
      annotated.set(holder, JSON.stringify(annotations));
    } catch (error) {
      state.holderPaths.delete(holder);
      review.removeFile(holder);
      box.replaceChildren(element("div", "diff-message", `Couldn’t show this diff: ${error.message}`));
      return;
    }
    state.holders.add(holder);
    if (file && diffKey(file)) state.diffs.set(file.path, { key: diffKey(file), node: holder, notesVersion: diff.notesVersion });
  }

  // MARK: Claude's notes (section 4.3)

  // By id: the diffs' annotations name them by it, and a card, once drawn,
  // is updated in place.
  const notes = new Map();
  const noteCards = new Map();
  // A note's annotation key: never a comment's.
  const notePrefix = "note:";
  // The notes each diff drawn came with, as annotations.
  const holderNotes = new WeakMap();

  // What shows under the lines of the diff in `holder`: Claude's notes,
  // then the comments, the drafts and the editors of `file`.
  function diffAnnotations(holder, file) {
    return [...(holderNotes.get(holder) ?? []), ...(file ? annotationsOf(file.id) : [])];
  }

  // A note under the last changed line of its hunk, labeled as Claude's,
  // with the head it read, its "check this" apart; it can be marked wrong,
  // and the mark undone.
  let noteCount = 0;

  function noteCard(annotation) {
    const note = notes.get(annotation.key.slice(notePrefix.length));
    if (!note) return null;
    const card = element("div", "note");
    const source = element("div", "source claude");
    const head = note.head ? ` \u00B7 read ${String(note.head).slice(0, 7)}` : "";
    source.append(icon("spark"), element("span", null, `Claude \u00B7 ${note.model}${head}`));
    const text = element("div", "note-text", note.text);
    text.id = `note-text-${++noteCount}`;
    card.append(source, text);
    let checkText = null;
    if (note.check) {
      const check = element("div", "note-check");
      const label = element("div", "note-check-label");
      label.append(icon("help"), element("span", null, "Check this"));
      checkText = element("div", "note-text", note.check);
      checkText.id = `note-check-${noteCount}`;
      check.append(label, checkText);
      card.append(check);
    }
    const actions = element("div", "note-actions");
    const marked = element("span", "note-marked", "Marked wrong");
    // Made once: a keyboard user keeps the focus on it.
    const toggle = element("button", "more");
    toggle.type = "button";
    toggle.setAttribute("aria-describedby", text.id);
    toggle.addEventListener("click", () => {
      if (toggle.getAttribute("aria-disabled") === "true") return;
      note.isWrong = !note.isWrong;
      // Swift answers each click: until the last answer, the page's mark.
      note.inFlight = (note.inFlight ?? 0) + 1;
      showNoteMark(card, note);
      post({ type: "markWrong", id: note.id, wrong: note.isWrong });
    });
    actions.append(marked, toggle);
    // A "check this" made one of the review's comments: an editor under the
    // note's line, holding it, to edit, then Comment.
    if (checkText) {
      const comment = element("button", "more note-comment", "Comment on this");
      comment.type = "button";
      comment.setAttribute("aria-describedby", checkText.id);
      comment.addEventListener("click", () => {
        if (isEnabled(comment)) commentOnNote(note, comment);
      });
      // After Mark wrong, which stays the actions' first button.
      actions.append(comment);
    }
    card.append(actions);
    noteCards.set(note.id, card);
    showNoteMark(card, note);
    return card;
  }

  // What a note's "check this" makes as a comment: said to be Claude's,
  // so that the agent doesn't read it as the reviewer's own words.
  function checkComment(note) {
    return `Claude’s check: ${note.check}`;
  }

  // The editor of a new comment under `note`'s line, holding its "check
  // this" (on its file when the line takes no comment); the one already
  // open for it, if any. Not in a diff dimmed while its new one is read:
  // its lines are of before.
  function commentOnNote(note, button) {
    const file = note.path ? fileOf(note.path) : null;
    if (!file) return;
    if (isStale(file.path)) return notice(file.path, "This diff is being read again: comment on the note once it shows.");
    const open = [...state.editors.values()].find((editor) => editor.fromNote === note.id);
    if (open) return focusEditor(open);
    const lines = P.commentRange(state.hunks.get(file.path), { side: note.side, start: note.lineNumber, end: note.lineNumber });
    const editor = openEditor(file, lines.problem ? null : lines, checkComment(note));
    if (editor) Object.assign(editor, { fromNote: note.id, returnFocus: button });
  }

  function showNoteMark(card, note) {
    card.classList.toggle("wrong", note.isWrong);
    card.querySelector(".note-marked").hidden = !note.isWrong;
    const toggle = card.querySelector(".note-actions button");
    toggle.textContent = note.isWrong ? "Undo" : "Mark wrong";
    // A review this Nirux can't write: the mark couldn't be kept. Not
    // `disabled`, which would take the focus away.
    const stored = state.stored;
    const writable = stored ? stored.canWrite : true;
    setEnabled(toggle, writable);
    toggle.title = !writable && stored?.problem ? stored.problem : "";
    // Comment on this: not while nothing can be written, on a note marked
    // wrong, nor once a comment or a draft holds its check, unless that is
    // its editor's, open: it is shown again.
    const comment = card.querySelector(".note-comment");
    if (!comment) return;
    const open = [...state.editors.values()].some((editor) => editor.fromNote === note.id);
    const why = !canComment() ? cantComment()
      : note.isWrong ? "This note is marked wrong."
      : !open && storedComments().some((made) => made.text === checkComment(note)) ? "This check is in a comment or a draft already." : "";
    setEnabled(comment, why === "");
    comment.title = why;
  }

  // A note's mark as the review file holds it (null: the click wasn't
  // taken), shown once every click on it is answered. With `from` and
  // `to`, only marks changed: the diffs drawn at `from` stay current.
  function markNote(id, wrong, from, to) {
    const note = notes.get(String(id));
    if (note) {
      note.inFlight = Math.max(0, (note.inFlight ?? 0) - 1);
      if (wrong !== null && wrong !== undefined) note.settled = Boolean(wrong);
      if (note.inFlight === 0) {
        note.isWrong = Boolean(note.settled);
        const card = noteCards.get(note.id);
        if (card) showNoteMark(card, note);
      }
    }
    if (!state.page || from === null || from === undefined || state.page.notesVersion !== from) return;
    state.page.notesVersion = to;
    for (const shown of state.diffs.values()) {
      if (shown.notesVersion === from) shown.notesVersion = to;
    }
  }

  // The stored review changed: whether marks can be kept.
  function showNoteMarks() {
    for (const [id, card] of noteCards) {
      const note = notes.get(id);
      if (note) showNoteMark(card, note);
    }
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
    refreshComments();
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

  window.NiruxReview = Object.freeze({ show, showDiff, showExplain, showStatus, showReload, hideReload, showReview, markNote });
  post({ type: "ready" });
})();
