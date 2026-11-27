// Draws Markdown, as ReviewPage.parseMarkdown reads it, for the Branch
// Review page and the editor's reading view: every string goes in with
// textContent. A link is live only when ReviewPage.safeURL keeps it; a
// click on it goes to the page's `open(url)`.
(function (root) {
  "use strict";

  const P = root.ReviewPage;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function link(text, url, open, className) {
    const live = P.safeURL(url);
    if (!live) return element("span", "dead-link", text);
    const anchor = element("a", className, text);
    anchor.href = "#";
    anchor.title = live;
    anchor.addEventListener("click", (event) => {
      event.preventDefault();
      open(live);
    });
    return anchor;
  }

  function spans(list, open) {
    const fragment = document.createDocumentFragment();
    for (const span of list) {
      switch (span.type) {
        case "code": fragment.append(element("code", null, span.text)); break;
        case "strong": fragment.append(element("strong", null, span.text)); break;
        case "em": fragment.append(element("em", null, span.text)); break;
        case "link": fragment.append(link(span.text, span.url, open)); break;
        default: fragment.append(document.createTextNode(span.text));
      }
    }
    return fragment;
  }

  function tableRow(cells, tag, align, open) {
    const row = element("tr");
    cells.forEach((cell, column) => {
      const node = element(tag);
      if (align[column]) node.style.textAlign = align[column];
      node.append(spans(cell, open));
      row.append(node);
    });
    return row;
  }

  function blocks(list, container, open) {
    for (const block of list) {
      switch (block.type) {
        case "heading": {
          const heading = element(`h${Math.min(6, Math.max(1, block.level))}`);
          heading.append(spans(block.spans, open));
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
              entry.append(element("span", "check", item.checked ? "☑ " : "☐ "));
            }
            entry.append(spans(item.spans, open));
            blocks(item.lists, entry, open);
            listElement.append(entry);
          }
          container.append(listElement);
          break;
        }
        case "code": container.append(element("pre", null, block.text)); break;
        case "quote": {
          const quote = element("blockquote");
          blocks(block.blocks, quote, open);
          container.append(quote);
          break;
        }
        case "rule": container.append(element("hr")); break;
        case "table": {
          const table = element("table");
          const head = element("thead");
          head.append(tableRow(block.head, "th", block.align, open));
          const body = element("tbody");
          for (const row of block.rows) body.append(tableRow(row, "td", block.align, open));
          table.append(head, body);
          container.append(table);
          break;
        }
        default: {
          const paragraph = element("p");
          paragraph.append(spans(block.spans, open));
          container.append(paragraph);
        }
      }
    }
  }

  // `withDecisions`: a pull request body's Decisions section comes first,
  // apart (ReviewPage.splitDecisions).
  function markdown(text, open, withDecisions) {
    const container = element("div", "markdown");
    const parsed = P.parseMarkdown(text);
    const { blocks: rest, decisions } = withDecisions ? P.splitDecisions(parsed) : { blocks: parsed, decisions: null };
    if (decisions) {
      const box = element("div", "decisions");
      box.append(element("div", "decisions-title", decisions.title));
      blocks(decisions.blocks, box, open);
      container.append(box);
    }
    blocks(rest, container, open);
    return container;
  }

  root.MarkdownView = Object.freeze({ element, link, markdown });
})(window);
