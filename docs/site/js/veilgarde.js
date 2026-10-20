/*
 * VeilGarde's site: the runtime every page loads first.
 *
 * window.VeilGarde holds the page code: small DOM helpers, wrapped storage, a highlighter for every language in the
 * change set, the data model the explorer, the overview and the chapters' excerpts share (built once from
 * window.VeilGardeData), the navigation, and the self-check registry. Classic script, no modules and no fetch:
 * the site is read from file://.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */
(function () {
  "use strict";
  var V = (window.VeilGarde = window.VeilGarde || {});
  var SVGNS = "http://www.w3.org/2000/svg";

  V.pages = [
    { file: "index.html", short: "The change at a glance", start: true },
    { file: "01-warp.html", n: 1, short: "How does the warp lens see a camera?" },
    { file: "02-bundle.html", n: 2, short: "What does the detector ship?" },
    { file: "03-fusion.html", n: 3, short: "How does the fusion base weigh the evidence?" },
    { file: "04-specialists.html", n: 4, short: "What do the specialist heads add?" },
    { file: "05-router.html", n: 5, short: "How does the router pick a path?" },
    { file: "06-training.html", n: 6, short: "How is each shipped model trained?" },
    { file: "07-flywheel.html", n: 7, short: "How does the flywheel grow the heads?" },
    { file: "08-watermark.html", n: 8, short: "How does a warp signature survive a crop?" },
    { file: "09-playground.html", n: 9, short: "How do I run each stage myself?" },
    { file: "10-pruning.html", n: 10, short: "What could VeilGarde do without?" }
  ];
  V.appendices = [
    { file: "code.html", short: "The change explorer" },
    { file: "selfcheck.html", short: "The self-check" }
  ];

  // MARK: Small helpers

  function setAttrs(node, attrs) {
    if (!attrs) return;
    Object.keys(attrs).forEach(function (k) {
      var v = attrs[k];
      if (v === null || v === undefined || v === false) return;
      if (k === "text") node.textContent = v;
      else if (k.slice(0, 2) === "on" && typeof v === "function") node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v === true ? "" : String(v));
    });
  }
  function append(node, children) {
    if (children === null || children === undefined) return;
    if (!Array.isArray(children)) children = [children];
    children.forEach(function (c) {
      if (c === null || c === undefined || c === false) return;
      if (Array.isArray(c)) { append(node, c); return; }
      node.appendChild(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
    });
  }
  /** An element, its attributes and its children. Text always goes in as text nodes, never as HTML. */
  V.h = function (tag, attrs, children) { var node = document.createElement(tag); setAttrs(node, attrs); append(node, children); return node; };
  V.s = function (tag, attrs, children) { var node = document.createElementNS(SVGNS, tag); setAttrs(node, attrs); append(node, children); return node; };
  var h = V.h;

  /** localStorage can throw (a private window, blocked site data): every read and write is wrapped. */
  V.storage = {
    get: function (key, fallback) { try { var v = window.localStorage.getItem("veilgarde:" + key); return v === null ? fallback : JSON.parse(v); } catch (e) { return fallback; } },
    set: function (key, value) { try { window.localStorage.setItem("veilgarde:" + key, JSON.stringify(value)); } catch (e) { /* storage unavailable: the page works without it */ } },
    remove: function (key) { try { window.localStorage.removeItem("veilgarde:" + key); } catch (e) { /* as above */ } }
  };
  V.fmt = {
    int: function (x) { return Number(x).toLocaleString("en-US"); },
    bytes: function (n) { return n >= 1048576 ? (n / 1048576).toFixed(2) + " MB" : n >= 1024 ? Math.round(n / 1024) + " KB" : n + " B"; },
    minus: function (s) { return String(s).replace(/^-/, "−"); }
  };
  V.root = function () { return (document.body && document.body.getAttribute("data-root")) || ""; };
  V.data = function () { return window.VeilGardeData || {}; };
  V.toast = function (text) {
    var t = h("div", { class: "toast", role: "status" }, text);
    document.body.appendChild(t);
    setTimeout(function () { t.remove(); }, 1400);
  };
  /** Copies text, or shows it selected in a field beside `near` when the clipboard is refused. */
  V.copy = function (text, done, near) {
    function fallback() {
      var field = h("input", { class: "copy-field", value: text, readonly: true, "aria-label": "Copy this" });
      var host = near || document.body, old = host.querySelector(".copy-field");
      if (old) old.remove();
      host.appendChild(field);
      field.select();
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { V.toast(done); }, fallback);
      else fallback();
    } catch (e) { fallback(); }
  };

  // MARK: Highlighting, one line at a time, with the state a line hands the next

  function words(s) { var o = {}; s.split(/\s+/).forEach(function (w) { if (w) o[w] = true; }); return o; }
  var KW = {
    swift: words("func let var if else guard return for in while struct enum class public private fileprivate internal open package static mutating nonmutating case switch default nil true false self Self super init deinit extension protocol import throws throw try rethrows where some any inout defer break continue repeat do catch lazy weak unowned final override async await typealias associatedtype subscript convenience required indirect is as get set willSet didSet fallthrough actor nonisolated consuming borrowing"),
    python: words("def class return if elif else for while in not and or is None True False import from as with try except finally raise pass break continue lambda yield global nonlocal assert del async await"),
    shell: words("if then else elif fi for in do done while until case esac function return local export set unset source exit readonly shift trap"),
    javascript: words("var let const function return if else for while do switch case default break continue new this typeof instanceof in of try catch finally throw null undefined true false delete void class extends super yield async await"),
    json: words("true false null"),
    toml: words("true false"),
    yaml: words("true false null yes no")
  };
  var CFG = {
    swift: { line: "//", block: ["/*", "*/"], strings: ['"""', '"'], raw: true, types: true, at: true, hash: true },
    python: { line: "#", strings: ['"""', "'''", '"', "'"], types: true, at: true },
    shell: { line: "#", strings: ['"', "'"], vars: true },
    javascript: { line: "//", block: ["/*", "*/"], strings: ['"', "'", "`"], types: true },
    css: { block: ["/*", "*/"], strings: ['"', "'"] },
    html: { block: ["<!--", "-->"], strings: ['"', "'"], tags: true },
    json: { strings: ['"'], keys: true },
    toml: { line: "#", strings: ['"', "'"], keys: true },
    yaml: { line: "#", strings: ['"', "'"], keys: true },
    text: { line: "#" }
  };
  /** The tokens of one line as nodes: comments, strings, numbers, keywords, types. `st` carries an open block
   *  comment, multi-line string or code fence to the next line. */
  V.highlight = function (line, lang, st) {
    st = st || {};
    lang = lang || "swift";
    var out = [], buf = "", i = 0, n = line.length, m;
    function flush() { if (buf) { out.push(document.createTextNode(buf)); buf = ""; } }
    function push(cls, s) { if (!s) return; flush(); out.push(h("span", { class: cls }, s)); }
    if (lang === "markdown") {
      if (/^\s*(```|~~~)/.test(line)) { st.fence = !st.fence; push("tk-c", line); return out; }
      if (st.fence) { push("tk-s", line); return out; }
      if (/^#{1,6}\s/.test(line)) { push("tk-k", line); return out; }
      line.split(/(`[^`]+`)/).forEach(function (part) { if (/^`[^`]+`$/.test(part)) push("tk-s", part); else if (part) { flush(); out.push(document.createTextNode(part)); } });
      return out;
    }
    var cfg = CFG[lang] || CFG.text, kw = KW[lang] || {};
    if (st.block) {
      var e = line.indexOf(st.block);
      if (e < 0) { push("tk-c", line); return out; }
      push("tk-c", line.slice(0, e + st.block.length));
      i = e + st.block.length;
      st.block = null;
    }
    if (st.str) {
      var close = findClose(line, 0, st.str, st.rawStr);
      if (close < 0) { push("tk-s", line); return out; }
      push("tk-s", line.slice(0, close + st.str.length));
      i = close + st.str.length;
      st.str = null;
    }
    while (i < n) {
      var c = line[i], rest = line.slice(i);
      if (cfg.line && rest.indexOf(cfg.line) === 0 && (lang !== "shell" && lang !== "text" || i === 0 || /\s/.test(line[i - 1]))) { push("tk-c", rest); i = n; break; }
      if (cfg.block && rest.indexOf(cfg.block[0]) === 0) {
        var end = line.indexOf(cfg.block[1], i + cfg.block[0].length);
        if (end < 0) { push("tk-c", rest); st.block = cfg.block[1]; i = n; break; }
        push("tk-c", line.slice(i, end + cfg.block[1].length));
        i = end + cfg.block[1].length;
        continue;
      }
      if (cfg.raw && (m = /^(#+)("""|")/.exec(rest))) {
        var closer = m[2] + m[1], at = line.indexOf(closer, i + m[0].length);
        if (at < 0) { push("tk-s", rest); if (m[2] === '"""') { st.str = closer; st.rawStr = true; } i = n; break; }
        push("tk-s", line.slice(i, at + closer.length));
        i = at + closer.length;
        continue;
      }
      var q = null;
      if (cfg.strings) for (var k = 0; k < cfg.strings.length; k++) if (rest.indexOf(cfg.strings[k]) === 0) { q = cfg.strings[k]; break; }
      if (q && !(lang === "shell" && q === "'" && i > 0 && /\w/.test(line[i - 1]))) {
        var cl = findClose(line, i + q.length, q, lang === "shell" && q === "'");
        if (cl < 0) { push("tk-s", rest); if (q.length === 3 || q === "`") { st.str = q; st.rawStr = false; } i = n; break; }
        var str = line.slice(i, cl + q.length);
        if (cfg.keys && /^\s*:/.test(line.slice(cl + q.length))) push("tk-t", str); else push("tk-s", str);
        i = cl + q.length;
        continue;
      }
      if (cfg.tags && c === "<" && (m = /^<\/?[A-Za-z][\w-]*/.exec(rest))) { push("tk-k", m[0]); i += m[0].length; continue; }
      if (cfg.vars && c === "$" && (m = /^\$(?:\{[^}]*\}|[A-Za-z_]\w*|[0-9@#?*$!-])/.exec(rest))) { push("tk-t", m[0]); i += m[0].length; continue; }
      if (cfg.at && c === "@" && (m = /^@[A-Za-z_][\w.]*/.exec(rest))) { push("tk-a", m[0]); i += m[0].length; continue; }
      if (cfg.hash && c === "#" && (m = /^#[A-Za-z_]\w*/.exec(rest))) { push("tk-a", m[0]); i += m[0].length; continue; }
      if (/[0-9]/.test(c) && (i === 0 || !/[\w$.]/.test(line[i - 1])) && (m = /^(?:0x[0-9A-Fa-f_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?)/.exec(rest))) {
        push("tk-n", m[0]); i += m[0].length; continue;
      }
      if ((m = /^[A-Za-z_$][\w$]*/.exec(rest)) && (i === 0 || !/[\w$]/.test(line[i - 1]))) {
        var w = m[0];
        if (kw[w]) push("tk-k", w);
        else if (cfg.keys && lang !== "json" && /^\s*[=:]/.test(line.slice(i + w.length)) && !line.slice(0, i).trim()) push("tk-t", w);
        else if (cfg.types && /^[A-Z]/.test(w)) push("tk-t", w);
        else buf += w;
        i += w.length;
        continue;
      }
      buf += c;
      i++;
    }
    flush();
    return out;
  };
  function findClose(line, from, q, raw) {
    for (var j = from; j < line.length; j++) {
      if (!raw && line[j] === "\\") { j++; continue; }
      if (line.indexOf(q, j) === j) return j;
    }
    return -1;
  }

  // MARK: The data model: every file, its declarations with their ids, the calls and the trails

  var KIND = { f: "func", i: "init", d: "deinit", s: "subscript", v: "var", S: "struct", C: "class", E: "enum", A: "actor", X: "extension", P: "protocol" };
  var STATUS = { a: "added", c: "changed", u: "unchanged" };
  V.KIND = KIND;
  V.CALLABLE = "fis";
  V.flags = { REQUIREMENT: 1, OPERATOR: 2, LOCAL: 4, ONE_LINE: 8 };
  function push(map, key, value) { (map[key] = map[key] || []).push(value); }
  function splitLines(text) {
    if (text === null || text === undefined) return null;
    var lines = text.split("\n");
    if (lines.length && lines[lines.length - 1] === "") lines.pop();
    return lines;
  }
  V.splitLines = splitLines;

  function scopesOf(file, rows, old) {
    var list = [];
    rows.forEach(function (row, k) {
      list.push({ local: k, file: file, old: !!old, kind: row[0], name: row[1], labels: row[2], mods: row[3], decl: row[4], sig: row[5], brace: row[6], end: row[7],
                  doc: row[8], parent: row[9], flags: row[10], status: old ? "removed" : STATUS[row[11]] || row[11], cases: row[12] || null });
    });
    var seen = {};
    list.forEach(function (sc) {
      var names = [], k = sc.local;
      while (k >= 0) { names.unshift(list[k].name); k = list[k].parent; }
      sc.qualified = names.join(".");
      sc.callable = V.CALLABLE.indexOf(sc.kind) >= 0;
      sc.labelText = sc.callable ? "(" + (sc.labels || []).map(function (l) { return l + ":"; }).join("") + ")" : "";
      var tail = sc.kind === "X" ? "extension:" + sc.qualified : sc.qualified + sc.labelText;
      var base = file.path + ":" + tail;
      seen[base] = (seen[base] || 0) + 1;
      sc.id = seen[base] === 1 ? base : base + "~" + seen[base];
      sc.tail = sc.id.slice(file.path.length + 1);
      sc.label = (sc.kind === "X" ? "extension " : "") + sc.qualified + sc.labelText;
      sc.depth = 0;
      for (var p = sc.parent; p >= 0; p = list[p].parent) sc.depth++;
      sc.from = sc.doc ? Math.min(sc.doc[0], sc.decl) : sc.decl;
      sc.to = sc.end || sc.sig;
    });
    return list;
  }

  var model = null;
  /** The model, built once from whatever data files the page loaded; null without data/index.js. */
  V.model = function () {
    if (model) return model;
    var D = V.data(), index = D.index;
    if (!index) return null;
    var groups = D.files || {}, recs = {}, missing = [], files = [], byPath = {}, scopes = [];
    index.groups.forEach(function (g) {
      if (!groups[g]) { missing.push(g); return; }
      groups[g].files.forEach(function (r) { recs[r.path] = r; });
    });
    index.files.forEach(function (meta, fi) {
      var rec = recs[meta.path] || null;
      var file = { i: fi, path: meta.path, name: meta.path.split("/").pop(), group: meta.group, status: meta.status, lang: meta.lang, lineCount: meta.lines,
                   bytes: meta.bytes, added: meta.added, removed: meta.removed, first: meta.first, scopeCount: meta.scopes, what: meta.what, loaded: !!rec,
                   text: rec ? rec.new : null, old: rec ? rec.old : null, hunks: rec ? rec.hunks : [], header: rec ? rec.header : null, marks: rec ? rec.marks : [],
                   from: rec ? rec.from || null : null, scopes: [], oldScopes: [], lines: null, oldLines: null };
      if (rec) {
        file.scopes = scopesOf(file, rec.scopes, false);
        file.scopes.forEach(function (sc) { sc.g = file.first + sc.local; scopes[sc.g] = sc; });
        file.oldScopes = scopesOf(file, rec.oldScopes || [], true);
      }
      files.push(file);
      byPath[file.path] = file;
    });
    var byQualified = {}, byName = {}, byLabelled = {};
    scopes.forEach(function (sc) {
      if (!sc) return;
      push(byQualified, sc.qualified, sc);
      push(byName, sc.name, sc);
      if (sc.callable) { push(byLabelled, sc.qualified + sc.labelText, sc); push(byLabelled, sc.name + sc.labelText, sc); }
    });
    var out = {}, into = {};
    index.edges.forEach(function (e) { if (scopes[e[0]] && scopes[e[1]]) { push(out, e[0], e); push(into, e[1], e); } });
    // The trails, and every place a declaration takes on them: once a trail at most.
    var trails = index.trails || [], trailById = {}, onTrail = {}, entries = [];
    trails.forEach(function (t) {
      trailById[t.id] = t;
      t.steps.forEach(function (st) {
        st.entries.forEach(function (en, k) { push(onTrail, en.scope, { trail: t, step: st.n, pos: k }); entries.push({ trail: t, step: st.n, pos: k, entry: en }); });
      });
    });
    model = { index: index, files: files, byPath: byPath, scopes: scopes, byQualified: byQualified, byName: byName, byLabelled: byLabelled,
              out: function (g) { return out[g] || []; }, into: function (g) { return into[g] || []; },
              trails: trails, trailById: trailById, placesOf: function (g) { return onTrail[g] || []; }, entries: entries, missing: missing, stripped: {} };
    return model;
  };
  V.linesOf = function (file) { if (!file.lines) file.lines = splitLines(file.text) || []; return file.lines; };
  V.oldLinesOf = function (file) { if (!file.oldLines) file.oldLines = splitLines(file.old) || []; return file.oldLines; };
  /** A header's tagged lines as plain text, its comment marks stripped. */
  V.headerText = function (file, range, lines) {
    if (!range) return null;
    var style = (file.header && file.header.style) || "swift";
    return (lines || V.linesOf(file)).slice(range[0] - 1, range[1]).map(function (l) {
      if (style === "hash") return l.replace(/^#(?:\s+(?:WHAT|PIN|IN|OUT):)?/, "").replace(/^ {0,8}/, "");
      if (style === "doc") return l.replace(/^\s*(?:[rubRUB]?""")?\s*(?:(?:WHAT|PIN|IN|OUT):)?/, "").replace(/^ {0,8}/, "").replace(/"""/g, "");
      return l.replace(/^\/\/(?:  (?:WHAT|PIN|IN|OUT):)?/, "").replace(/^ {0,8}/, "");
    }).join("\n");
  };
  V.kindWords = function (sc) {
    var words = [];
    if (sc.mods) words.push(sc.mods);
    words.push(sc.flags & V.flags.LOCAL && sc.kind === "f" ? "local func" : KIND[sc.kind]);
    if (sc.flags & V.flags.REQUIREMENT) words.push("protocol requirement");
    if (sc.flags & V.flags.OPERATOR) words.push("operator");
    return words.join(" · ");
  };

  // MARK: The trail picker

  /** Trail ids that were renamed, step by step to where each lives now, so a link written before still lands. */
  V.trailRenamed = { "watermark-1": "watermark-signing-1", "watermark-2": "watermark-signing-3", "watermark-3": "watermark-matching-3" };

  /** The trails as one grid, laid out by src/trails.json's picker: a row for each flow, a column for each kind, so a
   *  flow's training and its inference sit side by side and every cell lines up with the cells above it. A section
   *  with fewer kinds than the widest spans its last column. onPick(id) runs on a click; the arrow keys move between
   *  cells. V.pressTrail marks the chosen cell, and lights its row and its column. */
  V.trailPicker = function (picker, trailById, onPick, label) {
    var cols = Math.max.apply(null, picker.map(function (sec) { return sec.columns.length; }));
    var grid = h("div", { class: "trail-grid", role: "group", "aria-label": label, style: "--cols: " + cols });
    function span(n, i) { return i === n - 1 && n < cols ? "grid-column: span " + (cols - n + 1) : null; }
    picker.forEach(function (sec, si) {
      grid.appendChild(h("span", { class: "tg-sec" }, sec.title));
      sec.columns.forEach(function (c, ci) {
        grid.appendChild(h("span", { class: "tg-col", "data-sec": si, "data-col": ci, style: span(sec.columns.length, ci) }, c.label));
      });
      sec.rows.forEach(function (row, ri) {
        grid.appendChild(h("span", { class: "tg-row", "data-sec": si, "data-row": ri }, row.label));
        row.trails.forEach(function (id, ci) {
          var t = trailById[id];
          var b = h("button", { type: "button", class: "tg-cell", "data-trail": id, "data-kind": t.kind, "data-sec": si, "data-row": ri, "data-col": ci,
                                "aria-pressed": "false", "aria-label": t.title + ": " + t.subtitle, title: t.say, style: span(row.trails.length, ci) },
                    [h("span", { class: "tg-mark" }, t.mark), h("span", { class: "tg-sub" }, t.subtitle)]);
          b.addEventListener("click", function () { onPick(id); });
          grid.appendChild(b);
        });
      });
    });
    grid.addEventListener("keydown", function (e) {
      var b = e.target.closest ? e.target.closest(".tg-cell") : null, step = { ArrowLeft: [0, -1], ArrowRight: [0, 1], ArrowUp: [-1, 0], ArrowDown: [1, 0] }[e.key];
      if (!b || !step || e.metaKey || e.ctrlKey || e.altKey) return;
      var rows = [], at = null;
      grid.querySelectorAll(".tg-cell").forEach(function (c) {
        var key = c.getAttribute("data-sec") + ":" + c.getAttribute("data-row");
        if (!rows.length || rows[rows.length - 1].key !== key) rows.push({ key: key, cells: [] });
        rows[rows.length - 1].cells.push(c);
        if (c === b) at = [rows.length - 1, rows[rows.length - 1].cells.length - 1];
      });
      var r = at[0] + step[0], row = rows[r];
      if (!row) return;
      var next = row.cells[Math.max(0, Math.min(row.cells.length - 1, step[0] ? at[1] : at[1] + step[1]))];
      if (next && next !== b) { next.focus(); e.preventDefault(); }
    });
    return grid;
  };
  V.pressTrail = function (grid, id) {
    var on = grid.querySelector('.tg-cell[data-trail="' + id + '"]');
    grid.querySelectorAll(".tg-cell").forEach(function (c) { c.setAttribute("aria-pressed", c === on ? "true" : "false"); });
    grid.querySelectorAll(".tg-row, .tg-col").forEach(function (x) {
      var axis = x.classList.contains("tg-row") ? "data-row" : "data-col";
      x.classList.toggle("on", !!on && x.getAttribute("data-sec") === on.getAttribute("data-sec") && x.getAttribute(axis) === on.getAttribute(axis));
    });
  };

  // MARK: Code excerpts: <div class="code" data-excerpt="<id>"> quotes a declaration by its id, from the same verbatim data the explorer holds

  function renderExcerpt(node) {
    var id = node.getAttribute("data-excerpt"), m = V.model();
    var sc = m && m.scopes.filter(function (x) { return x && x.id === id; })[0];
    if (!sc) { node.appendChild(h("p", { class: "fig-error" }, "Missing excerpt " + id + ": rebuild with docs/site/src/build.py, or load its data file.")); node.setAttribute("data-rendered", "missing"); return; }
    var lines = V.linesOf(sc.file), from = sc.from, to = sc.to, st = {};
    for (var k = 0; k < from - 1; k++) V.highlight(lines[k], sc.file.lang, st);
    node.appendChild(h("div", { class: "code-head" }, [h("span", null, sc.file.path + ":" + from + "–" + to),
      h("span", null, h("a", { href: V.root() + "code.html#" + sc.id, title: "Open it in the change explorer" }, "explore"))]));
    var pre = h("pre", { tabindex: "0", "aria-label": "Source of " + sc.label });
    for (var n = from; n <= to; n++) pre.appendChild(h("div", { class: "ln" + (n === sc.sig ? " hl" : "") }, [h("span", null, String(n)), h("span", null, V.highlight(lines[n - 1], sc.file.lang, st))]));
    node.appendChild(pre);
    node.setAttribute("data-rendered", "ok");
  }

  /** A number written in a chapter, checked against the data it was read from: data-fact names the path into
   *  VeilGardeData.index.facts, data-round the decimals. */
  function factValue(path) {
    var v = (V.data().index || {}).facts;
    path.split(".").forEach(function (k) { v = v === undefined || v === null ? undefined : /^\d+$/.test(k) ? v[+k] : v[k]; });
    return v;
  }
  V.factValue = factValue;
  function factChecks() {
    return Array.prototype.map.call(document.querySelectorAll("[data-fact]"), function (el) {
      var path = el.getAttribute("data-fact"), want = factValue(path), round = el.getAttribute("data-round"), prefix = el.getAttribute("data-prefix");
      var shown = el.textContent.trim().replace(/−/g, "-").replace(/,/g, "").replace(/…$/, "");
      var expect = want === undefined ? undefined : round !== null ? Number(want).toFixed(+round) : prefix !== null ? String(want).slice(0, +prefix) : String(want);
      return { name: "the page's " + path + " reads " + el.textContent.trim(), ok: expect !== undefined && shown === expect, detail: "the data says " + (expect === undefined ? "nothing" : expect) };
    });
  }

  // MARK: Navigation

  function currentFile() { return location.pathname.split("/").pop() || "index.html"; }
  function buildNav() {
    var side = document.querySelector("nav.side");
    if (!side || side.childElementCount) return;
    var here = currentFile(), root = V.root();
    side.appendChild(h("a", { class: "brand", href: root + "index.html" }, "VeilGarde"));
    side.appendChild(h("p", { class: "brand-sub" }, "An AI-image detector as one Swift and MLX package: the change, the code and the chapters"));
    var list = h("ol", { class: "questions" });
    V.pages.forEach(function (c) {
      var a = h("a", { class: "q" + (c.later ? " later" : ""), href: root + c.file }, [h("span", { class: "n" }, c.start ? "▸" : String(c.n)), h("span", null, c.short + (c.later ? " · later" : ""))]);
      if (c.file === here) a.setAttribute("aria-current", "page");
      list.appendChild(h("li", null, a));
    });
    side.appendChild(list);
    side.appendChild(h("h3", null, "Appendices"));
    var more = h("ol", { class: "more" });
    V.appendices.forEach(function (c) {
      var a = h("a", { class: "q", href: root + c.file }, [h("span", { class: "n" }, "·"), h("span", null, c.short)]);
      if (c.file === here) a.setAttribute("aria-current", "page");
      more.appendChild(h("li", null, a));
    });
    side.appendChild(more);
    var menu = document.querySelector("button.menu");
    if (menu) {
      menu.setAttribute("aria-controls", "side-nav");
      side.id = side.id || "side-nav";
      menu.addEventListener("click", function () { var open = side.classList.toggle("open"); menu.setAttribute("aria-expanded", open ? "true" : "false"); if (open) { var first = side.querySelector("a"); if (first) first.focus(); } });
      side.addEventListener("keydown", function (e) { if (e.key === "Escape" && side.classList.contains("open")) { side.classList.remove("open"); menu.setAttribute("aria-expanded", "false"); menu.focus(); } });
    }
    var main = document.querySelector("main.page"), index = V.pages.findIndex(function (c) { return c.file === here; });
    if (main && index >= 0 && !main.querySelector("nav.prevnext")) {
      var prev = V.pages[index - 1], next = V.pages[index + 1];
      main.appendChild(h("nav", { class: "prevnext", "aria-label": "Previous and next chapter" }, [
        prev ? h("a", { class: "prev", href: root + prev.file, rel: "prev" }, [h("small", null, "← Previous"), prev.short]) : h("span"),
        next ? h("a", { class: "next", href: root + next.file, rel: "next" }, [h("small", null, "Next →"), next.short]) : null
      ]));
    }
    document.querySelectorAll("main h2[id]").forEach(function (hd) {
      if (!hd.querySelector(".anchor")) hd.appendChild(h("a", { class: "anchor", href: "#" + hd.id, "aria-label": "Link to this section" }, "#"));
    });
  }
  function openTarget() {
    var id = decodeURIComponent((location.hash || "").slice(1)), node = id && document.getElementById(id);
    if (!node) return;
    for (var d = node.closest("details"); d; d = d.parentElement && d.parentElement.closest("details")) d.open = true;
    if (node.tagName === "DETAILS") node.open = true;
  }

  // MARK: Loading the change's files

  /** Loads data/files/<group>.js for each group, or every group the index lists when `groups` is null, then calls
   *  done. They are classic scripts, injected: file:// allows those where it blocks fetch. A group that fails to
   *  load is reported by the self-check. */
  V.loadGroups = function (groups, done) {
    var idx = V.data().index;
    if (!idx) { done(); return; }
    var have = V.data().files || {};
    var want = (groups || idx.groups).filter(function (g, i, all) { return idx.groups.indexOf(g) >= 0 && !have[g] && all.indexOf(g) === i; });
    var left = want.length;
    if (!left) { model = null; done(); return; }
    want.forEach(function (g) {
      var s = document.createElement("script");
      s.src = V.root() + "data/files/" + g + ".js";
      s.onload = s.onerror = function () { if (--left === 0) { model = null; done(); } };
      document.head.appendChild(s);
    });
  };
  /** The groups this page needs: body[data-groups] ("all", or a comma list) and those its data-excerpt blocks quote from. */
  function groupsWanted() {
    var idx = V.data().index, attr = (document.body.getAttribute("data-groups") || "").trim();
    if (!idx) return [];
    if (attr === "all") return null;
    var out = attr ? attr.split(",").map(function (g) { return g.trim(); }) : [];
    document.querySelectorAll("[data-excerpt]").forEach(function (node) {
      var id = node.getAttribute("data-excerpt"), path = id.slice(0, id.indexOf(":")), f = idx.files.filter(function (x) { return x.path === path; })[0];
      if (f) out.push(f.group);
    });
    return out;
  }

  // MARK: Mount and self-check

  V.extraChecks = [];
  /** Loads the data the page needs, runs `before` (an app's own mount), then the navigation, the excerpts and the
   *  orb, marks the page mounted, and runs `after`. */
  V.mount = function (before, after) {
    V.loadGroups(groupsWanted(), function () {
      if (before) before();
      buildNav();
      document.querySelectorAll("[data-excerpt]").forEach(renderExcerpt);
      openTarget();
      window.addEventListener("hashchange", openTarget);
      if (V.ask && V.ask.mount) V.ask.mount();
      document.documentElement.setAttribute("data-mounted", "1");
      if (after) after();
    });
  };
  /** Every check the page can make, from every part that registered one, plus the page's own numbers and excerpts. */
  V.selfCheck = function () {
    var results = [];
    V.extraChecks.forEach(function (x) {
      var rows;
      try { rows = x.run() || []; } catch (e) { rows = [{ name: "its checks ran", ok: false, detail: e && e.message }]; }
      rows.forEach(function (r) { results.push(Object.assign({ part: x.name }, r)); });
    });
    factChecks().forEach(function (r) { results.push(Object.assign({ part: "numbers" }, r)); });
    document.querySelectorAll("[data-excerpt]").forEach(function (node) {
      results.push({ part: "excerpts", name: "the excerpt " + node.getAttribute("data-excerpt") + " drew from the data", ok: node.getAttribute("data-rendered") === "ok" });
    });
    return results;
  };
})();
