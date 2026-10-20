/*
 * The change explorer (code.html): every file the run changed, verbatim, before and after, with each Swift file's
 * declarations, the trails that tell each flow in the order the code runs (training and inference for the warp model,
 * the fusion head, the specialists and the noiseprint, signing and matching for the watermark, and the pruning study),
 * picked from one grid with a row a flow and a column a kind, and calls matched by name and
 * argument labels when the page was built (src/build.py). A page-level app: the find box, the source pane's scroll and the tree's open
 * folders must outlive each other's updates. VeilGarde.explorer.mount(root) draws it; VeilGarde.explorer.selfCheck()
 * needs no root, so the self-check page can load the data and check it.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */
(function () {
  "use strict";
  var V = window.VeilGarde, h = V.h, KIND = V.KIND;
  var TAG = { f: "func", i: "init", d: "deinit", s: "subs", v: "var", S: "struct", C: "class", E: "enum", A: "actor", X: "ext", P: "proto" };
  var TIERS = ["exact", "likely", "ambiguous"];
  var NARROW = 900;
  var HONEST = "Matched by name and argument labels when this page was built, not by a compiler.";
  var FILTERS = [["all", "All files"], ["changed", "Changed since the base"], ["edited", "Edited, not added"], ["trail", "On a trail"]];
  /** The one trail's steps before there were several, to where each lives now, so old links still land. */
  var LEGACY = { 1: "warp-inference-1", 2: "warp-inference-2", 3: "warp-inference-3", 4: "warp-inference-4", 5: "warp-inference-5",
                 6: "warp-inference-6", 7: "specialist-inference-1", 8: "warp-training-1", 9: "watermark-signing-1" };

  function model() { return V.model(); }
  /** A trail's name inside a sentence: "the warp training trail". */
  function trailName(t) { return t.title.charAt(0).toLowerCase() + t.title.slice(1); }
  /** The trail being walked; a declaration's places on the trails; its place on the walked one, or null. */
  function current() { var m = model(); return m.trailById[state.trail] || m.trails[0]; }
  function placesOf(sc) { return sc ? model().placesOf(sc.g) : []; }
  function onCurrent(sc) { return placesOf(sc).filter(function (o) { return o.trail === current(); })[0] || null; }
  function lastLine(sc) { return sc.end || sc.sig; }
  function scopeAt(file, n) {
    var best = null;
    file.scopes.forEach(function (sc) { if (sc.from <= n && n <= lastLine(sc) && (!best || sc.decl > best.decl || (sc.decl === best.decl && sc.local > best.local))) best = sc; });
    return best;
  }
  function dedent(lines) {
    var pad = Infinity;
    lines.forEach(function (l) { if (l.trim()) pad = Math.min(pad, l.match(/^\s*/)[0].length); });
    return lines.map(function (l) { return l.slice(pad === Infinity ? 0 : pad); });
  }
  function signature(sc) {
    var lines = V.linesOf(sc.file), to = sc.brace ? sc.brace[0] : lastLine(sc), parts = [];
    for (var n = sc.decl; n <= to; n++) {
      var line = lines[n - 1] || "";
      if (sc.brace && n === sc.brace[0]) line = line.slice(0, sc.brace[1]);
      parts.push(line.replace(/\s+$/, ""));
    }
    return dedent(parts).join("\n");
  }
  function docLines(sc) { return sc.doc ? dedent(V.linesOf(sc.file).slice(sc.doc[0] - 1, sc.doc[1])) : null; }
  function docText(sc) { return sc.doc ? V.linesOf(sc.file).slice(sc.doc[0] - 1, sc.doc[1]).map(function (l) { return l.replace(/^\s*\/\/\/ ?/, ""); }).join("\n") : null; }
  function headerPart(file, tag) { return file.header && file.header[tag] ? V.headerText(file, file.header[tag]).replace(/\s+/g, " ").trim() : null; }
  function hunksTouching(file, sc) {
    return (file.hunks || []).filter(function (hk) { var n = hk[2], nc = hk[3]; return nc ? n <= lastLine(sc) && sc.from <= n + nc - 1 : sc.from < n && n <= lastLine(sc); });
  }
  function hunkText(hk) { return "−" + hk[0] + "," + hk[1] + " +" + hk[2] + "," + hk[3]; }
  function changeLine(file, sc) {
    if (sc.status === "added") return file.status === "added" ? "Added with its file, in the new text's lines " + sc.from + "–" + lastLine(sc) + "." : "Added: the base had no declaration with this id.";
    if (sc.status === "changed") return "Changed: " + hunksTouching(file, sc).map(hunkText).join(", ") + " touches its lines.";
    if (sc.status === "removed") return "Removed: in the base, absent now.";
    return "Unchanged since the base.";
  }
  function fileChangeLine(file) {
    var n = (file.hunks || []).length;
    if (file.status === "added") return "Added: " + V.fmt.int(file.lineCount) + " lines.";
    if (file.status === "deleted") return "Deleted: its " + V.fmt.int(file.removed) + " lines are gone.";
    return (file.status === "renamed" ? "Renamed from " + file.from + ". " : "Modified: ") + "+" + file.added + " −" + file.removed + " in " + n + (n === 1 ? " hunk" : " hunks") + ".";
  }

  // MARK: Search

  function stripped(file) {
    var m = model(), s = m.stripped[file.path];
    if (s) return s;
    var chars = [], lines = [], line = 1, text = file.text || "";
    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (c === "\n") { line++; continue; }
      if (c === " " || c === "\t" || c === "\r") continue;
      chars.push(c);
      lines.push(line);
    }
    s = m.stripped[file.path] = { text: chars.join(""), lines: lines };
    return s;
  }
  function labelsFrom(params) {
    var out = [], depth = 0, cur = "";
    for (var i = 0; i <= params.length; i++) {
      var c = params[i];
      if (c === "(" || c === "[" || c === "<") depth++;
      else if (c === ")" || c === "]" || c === ">") depth--;
      if ((c === "," && depth === 0) || i === params.length) {
        var before = cur.split(":")[0].trim().split(/\s+/);
        if (cur.indexOf(":") >= 0 && before[0]) out.push(before[0].replace(/`/g, ""));
        cur = "";
      } else cur += c;
    }
    return out;
  }
  function uniq(list) { var seen = {}; return list.filter(function (sc) { if (seen[sc.g]) return false; seen[sc.g] = true; return true; }); }
  function findSymbol(q) {
    var m = model(), hits = [];
    if (/\(/.test(q)) {
      hits = (m.byLabelled[q] || []).slice();
      if (!hits.length) m.scopes.forEach(function (sc) { if (sc && sc.callable && (sc.qualified + sc.labelText).slice(-q.length) === q) hits.push(sc); });
    } else {
      hits = (m.byQualified[q] || []).concat(q.indexOf(".") < 0 ? m.byName[q] || [] : []);
      if (!hits.length && q.indexOf(".") > 0) m.scopes.forEach(function (sc) { if (sc && sc.qualified.slice(-q.length - 1) === "." + q) hits.push(sc); });
      hits = hits.concat(m.scopes.filter(function (sc) {
        return sc && sc.cases && q.indexOf(".") > 0 && sc.qualified === q.slice(0, q.lastIndexOf(".")) && sc.cases.indexOf(q.slice(q.lastIndexOf(".") + 1)) >= 0;
      }));
    }
    return uniq(hits);
  }
  function findSignature(line) {
    var m = model(), name = null, labels = null, kinds = null, r;
    if ((r = /\bfunc\s+([^\s(<]+)\s*(?:<[^(]*>)?\s*\(([\s\S]*?)\)\s*(?:async|throws|rethrows|->|where|\{|$)/.exec(line))) { name = r[1].replace(/`/g, ""); labels = labelsFrom(r[2]); kinds = "f"; }
    else if ((r = /\binit[?!]?\s*(?:<[^(]*>)?\s*\(([\s\S]*?)\)/.exec(line))) { name = "init"; labels = labelsFrom(r[1]); kinds = "i"; }
    else if ((r = /\bsubscript\s*\(([\s\S]*?)\)/.exec(line))) { name = "subscript"; labels = labelsFrom(r[1]); kinds = "s"; }
    else if ((r = /\bvar\s+`?(\w+)`?\s*:/.exec(line))) { name = r[1]; kinds = "v"; }
    else if ((r = /\b(struct|class|enum|protocol|actor)\s+`?(\w+)/.exec(line))) { name = r[2]; kinds = "SCEPA"; }
    else if ((r = /\bextension\s+([\w.]+)/.exec(line))) { name = r[1].split(".").pop(); kinds = "X"; }
    if (!name) return [];
    var hits = (m.byName[name] || []).filter(function (sc) { return kinds.indexOf(sc.kind) >= 0; });
    if (labels) {
      var exact = hits.filter(function (sc) { return sc.labels && sc.labels.join(":") === labels.join(":"); });
      if (exact.length) hits = exact;
    }
    return hits;
  }
  function findBody(q) {
    var needle = q.replace(/\s+/g, "");
    if (needle.length < 24) return [];
    var hits = [];
    model().files.forEach(function (file) {
      if (!file.loaded) return;
      var s = stripped(file), at = s.text.indexOf(needle);
      if (at < 0) return;
      var first = s.lines[at], last = s.lines[at + needle.length - 1], sc = null;
      file.scopes.forEach(function (c) { if (c.from <= first && last <= lastLine(c) && (!sc || c.decl > sc.decl)) sc = c; });
      hits.push(sc ? { sc: sc, line: first } : { file: file, line: first });
    });
    return hits;
  }
  function findLoose(q) {
    var low = q.toLowerCase(), ranked = [], m = model();
    m.scopes.forEach(function (sc) {
      if (!sc) return;
      var name = sc.name.toLowerCase(), qual = sc.qualified.toLowerCase(), file = sc.file.name.toLowerCase();
      var rank = name === low || qual === low ? 0 : name.indexOf(low) === 0 ? 1 : qual.indexOf(low) >= 0 ? 2 : file.indexOf(low) >= 0 && sc.parent < 0 ? 3 : -1;
      if (rank >= 0) ranked.push({ sc: sc, rank: rank });
    });
    ranked.sort(function (a, b) { return a.rank - b.rank || a.sc.qualified.length - b.sc.qualified.length || a.sc.g - b.sc.g; });
    var out = ranked.map(function (r) { return r.sc; });
    m.files.forEach(function (f) { if (!f.scopes.length && f.path.toLowerCase().indexOf(low) >= 0) out.push({ file: f, line: 1 }); });
    return out;
  }
  /** Matches for a query, best first: [{ sc, line?, file?, how }]. Whitespace is ignored in a pasted body. */
  function search(raw) {
    var q = (raw || "").trim();
    if (!q || !model()) return [];
    var multi = /\n/.test(q), out = [];
    function add(list, how) { list.forEach(function (x) { out.push(x.g !== undefined ? { sc: x, how: how } : Object.assign({ how: how }, x)); }); }
    if (!multi && /^[\w.<>=!+\-*\/%&|^~?`]+(\([\w:]*\))?$/.test(q)) add(findSymbol(q.replace(/`/g, "")), "by name");
    var decl = /\b(func|init|subscript|var|struct|class|enum|protocol|actor|extension)\b/;
    if (!out.length && decl.test(q)) {
      if (multi) add(findBody(q), "by its text");
      if (!out.length) add(findSignature(q.split("\n").filter(function (l) { return decl.test(l); })[0] || q), "by its signature");
    }
    if (!out.length) add(findBody(q), "by its text");
    if (!out.length && !multi) add(findLoose(q), "by part of its name");
    var seen = {};
    return out.filter(function (r) { var key = r.sc ? "s" + r.sc.g : "f" + r.file.path + r.line; if (seen[key]) return false; seen[key] = true; return true; });
  }

  // MARK: Deep links

  /** "#<path>[:<line>|:<id tail>]", "#trail-<trail>-<n>[;n=<k>]", the older "#trail-<n>[;n=<k>]", or "#q=<text>" → what it names.
   *  A step of a renamed trail lands where it lives now (V.trailRenamed). */
  function parseTarget(raw) {
    var m = model(), r;
    if (!m || !raw) return null;
    if ((r = /^trail-([a-z]+(?:-[a-z]+)*)-(\d+)(?:;n=(\d+))?$/.exec(raw))) {
      var t = m.trailById[r[1]], n = +r[2];
      if (!t && V.trailRenamed[r[1] + "-" + n]) return parseTarget("trail-" + V.trailRenamed[r[1] + "-" + n] + (r[3] ? ";n=" + r[3] : ""));
      if (!t || n < 1 || n > t.steps.length) return null;
      return { trail: t.id, step: n, pos: r[3] ? Math.max(0, Math.min(+r[3] - 1, t.steps[n - 1].entries.length - 1)) : 0 };
    }
    if ((r = /^trail-(\d+)(?:;n=(\d+))?$/.exec(raw))) return LEGACY[+r[1]] ? parseTarget("trail-" + LEGACY[+r[1]] + (r[2] ? ";n=" + r[2] : "")) : null;
    if ((r = /^q=([\s\S]*)$/.exec(raw))) return { query: r[1] };
    var file = m.byPath[raw], rest = null, cut = raw.indexOf(":");
    if (!file && cut > 0 && m.byPath[raw.slice(0, cut)]) { file = m.byPath[raw.slice(0, cut)]; rest = raw.slice(cut + 1); }
    if (!file) return null;
    if (!rest) return { file: file };
    if (/^\d+$/.test(rest)) return { file: file, line: +rest, sc: scopeAt(file, +rest) };
    var hit = file.scopes.filter(function (sc) { return sc.tail === rest; });
    if (!hit.length) hit = file.scopes.filter(function (sc) { return sc.qualified === rest; });
    return hit.length === 1 ? { file: file, sc: hit[0], line: hit[0].sig } : { file: file };
  }

  // MARK: The app

  var ui = null, state = { file: null, sc: null, line: 0, mode: "new", only: false, filter: "all", trail: null, step: 0, pos: -1, lastPos: 0, at: {}, results: [], active: 0 };

  function mount(root) {
    if (!root) return;
    var m = model();
    if (!m) { root.appendChild(h("p", { class: "fig-error" }, "The data was not built. Run docs/site/src/build.py, then reload.")); return; }
    ui = { root: root };
    state.only = !!V.storage.get("explorer:only", false);
    state.filter = V.storage.get("explorer:filter", "all");
    if (!FILTERS.some(function (f) { return f[0] === state.filter; })) state.filter = "all";
    var kept = V.storage.get("explorer:trail", "");
    state.trail = m.trailById[kept] ? kept : m.trails[0].id;
    root.appendChild(statusLine());
    root.appendChild(findBox());
    root.appendChild(trailStrip());
    root.appendChild(treePanel());
    root.appendChild(sourcePanel());
    ui.card = h("aside", { class: "xp-card", "aria-live": "polite", "aria-label": "The selected declaration" });
    root.appendChild(ui.card);
    root.appendChild(h("p", { class: "keys xp-keys" }, ["Keys: ", h("kbd", null, "/"), " finds · ", h("kbd", null, "["), " ", h("kbd", null, "]"), " walk the chosen trail · ",
      h("kbd", null, "↑"), " ", h("kbd", null, "↓"), " in the source move between declarations · ", h("kbd", null, "Esc"), " clears the box."]));
    root.addEventListener("keydown", onKey);
    document.addEventListener("keydown", function (e) {
      var el = document.activeElement;
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
      if (el && (/INPUT|TEXTAREA|SELECT/.test(el.tagName) || el.closest(".ask"))) return;
      if (e.key === "/") { ui.find.focus(); e.preventDefault(); }
      else if ((e.key === "]" || e.key === "[") && !root.contains(el)) { stepBy(e.key === "]" ? 1 : -1); e.preventDefault(); }
    });
    window.addEventListener("hashchange", function () { readHash(false); });
    window.addEventListener("resize", fitTree);
    fitTree();
    applyFilter();
    if (!readHash(true)) {
      var last = parseTarget(V.storage.get("explorer:last", ""));
      if (last && last.sc) select(last.sc, { hash: false, quiet: true });
      else walk(1, 0, { hash: false, quiet: true });
    }
    renderCard();
  }

  function statusLine() {
    var m = model(), idx = m.index, c = idx.counts, head = idx.head || {};
    var parts = [h("span", null, V.fmt.int(c.embedded) + " files embedded, " + V.fmt.int(c.excluded) + " left out · " + V.fmt.int(c.scopes.total) + " Swift declarations · from " +
      (idx.base.label || idx.base.short) + " to " + (head.first ? "this tree" : (head.short || "?") + (head.dirty ? " and the working tree" : "")))];
    var notes = [];
    if (m.missing.length) notes.push("Missing: data/files/" + m.missing.join(".js, data/files/") + ".js. Run docs/site/src/build.py.");
    return h("div", { class: "xp-status" }, parts.concat(notes.map(function (n) { return h("p", { class: "xp-stale" }, n); })));
  }

  function findBox() {
    ui.find = h("textarea", { rows: 2, spellcheck: "false", autocomplete: "off", "aria-label": "Find a declaration or a piece of code", "aria-controls": "xp-results",
                              placeholder: "A name, a signature or a body" });
    ui.results = h("ol", { class: "xp-results", id: "xp-results", role: "listbox", hidden: true, "aria-label": "Matches" });
    var timer = null, pasted = false;
    ui.find.addEventListener("paste", function () { pasted = true; });
    ui.find.addEventListener("input", function () {
      clearTimeout(timer);
      fitFind();
      timer = setTimeout(function () { runSearch(pasted); pasted = false; }, 120);
    });
    ui.find.addEventListener("keydown", function (e) {
      var single = ui.find.value.indexOf("\n") < 0, open = !ui.results.hidden && state.results.length;
      if (e.key === "Escape") { ui.find.value = ""; fitFind(); runSearch(false); if (ui.pre) ui.pre.focus(); e.preventDefault(); }
      else if (open && single && (e.key === "ArrowDown" || e.key === "ArrowUp")) { activate(state.active + (e.key === "ArrowDown" ? 1 : -1)); e.preventDefault(); }
      else if (open && e.key === "Enter" && (single || e.metaKey || e.ctrlKey) && !e.shiftKey) { choose(state.active); e.preventDefault(); }
      e.stopPropagation();
    });
    return h("div", { class: "xp-find" }, [
      h("label", { class: "xp-find-label" }, ["Find", ui.find]),
      h("p", { class: "note" }, "Paste a name, Type.method, a signature line or a whole function body straight from the editor."),
      ui.results
    ]);
  }
  function fitFind() { ui.find.rows = Math.min(6, Math.max(2, ui.find.value.split("\n").length)); }
  function runSearch(jump) {
    var q = ui.find.value;
    state.results = search(q);
    state.active = 0;
    ui.results.textContent = "";
    if (!q.trim()) { ui.results.hidden = true; ui.find.removeAttribute("aria-activedescendant"); return; }
    ui.results.hidden = false;
    if (!state.results.length) {
      ui.results.appendChild(h("li", { class: "xp-none" }, "Nothing in the change matches. Try the bare function name, or paste the whole signature line."));
      return;
    }
    state.results.slice(0, 30).forEach(function (r, k) {
      var sc = r.sc, where = sc ? sc.file : r.file;
      var li = h("li", { role: "option", id: "xp-opt-" + k, "aria-selected": k === 0 ? "true" : "false" }, [
        h("b", null, sc ? sc.label : where.name),
        h("small", null, (sc ? KIND[sc.kind] + " · " : "") + where.path + ":" + (r.line || (sc ? sc.sig : 1)) + " · found " + r.how)
      ]);
      li.addEventListener("mousedown", function (e) { e.preventDefault(); });
      li.addEventListener("click", function () { choose(k); });
      ui.results.appendChild(li);
    });
    if (state.results.length > 30) ui.results.appendChild(h("li", { class: "xp-none" }, "and " + (state.results.length - 30) + " more"));
    ui.find.setAttribute("aria-activedescendant", "xp-opt-0");
    if (jump && state.results.length >= 1) choose(0, { keepFocus: true });
  }
  function activate(k) {
    var n = Math.min(state.results.length, 30);
    if (!n) return;
    state.active = (k + n) % n;
    Array.prototype.forEach.call(ui.results.querySelectorAll("[role=option]"), function (li, i) { li.setAttribute("aria-selected", i === state.active ? "true" : "false"); });
    ui.find.setAttribute("aria-activedescendant", "xp-opt-" + state.active);
    var li = ui.results.querySelector("#xp-opt-" + state.active);
    if (li && li.scrollIntoView) li.scrollIntoView({ block: "nearest" });
  }
  function choose(k, opts) {
    var r = state.results[k];
    if (!r) return;
    if (r.sc) select(r.sc, { line: r.line, from: "find" });
    else { openFile(r.file, { from: "find" }); pickLine(r.line); }
    if (!(opts && opts.keepFocus) && ui.pre) ui.pre.focus({ preventScroll: true });
  }

  // MARK: The trails

  function trailStrip() {
    var m = model();
    ui.trailGrid = V.trailPicker(m.index.picker, m.trailById, function (id) { chooseTrail(id); }, "The trails through the code");
    ui.stepList = h("ol", { class: "xp-steps" });
    ui.say = h("p", { class: "xp-say" });
    ui.prev = h("button", { type: "button", class: "xp-walk" }, "← previous");
    ui.next = h("button", { type: "button", class: "xp-walk" }, "next →");
    ui.prev.addEventListener("click", function () { stepBy(-1); });
    ui.next.addEventListener("click", function () { stepBy(1); });
    return h("div", { class: "xp-trail" }, [h("div", { class: "xp-trails" }, ui.trailGrid),
                                           h("div", { class: "scroll" }, ui.stepList),
                                           h("div", { class: "xp-say-row" }, [ui.say, h("span", { class: "xp-walks" }, [ui.prev, ui.next])])]);
  }
  /** The walked trail's step buttons, rebuilt when the trail changes. */
  function stepButtons() {
    var t = current();
    if (ui.stepsOf === t.id) return;
    ui.stepsOf = t.id;
    ui.stepList.textContent = "";
    ui.stepList.setAttribute("aria-label", "The " + trailName(t) + " trail's " + t.steps.length + " steps");
    var n = t.steps.length;
    ui.stepList.style.setProperty("--cols", String(n <= 3 ? n : n === 4 ? 2 : 3));
    ui.stepList.style.setProperty("--n", String(n));
    ui.steps = t.steps.map(function (st) {
      var b = h("button", { type: "button", "data-step": st.n, "aria-pressed": "false", title: st.title }, [h("span", { class: "xp-n" }, String(st.n)), h("span", { class: "xp-t" }, st.title)]);
      b.addEventListener("click", function () { walk(st.n, 0, { from: "trail" }); });
      var li = h("li", null, b);
      ui.stepList.appendChild(li);
      return li;
    });
  }
  function renderTrail() {
    var t = current();
    stepButtons();
    V.pressTrail(ui.trailGrid, t.id);
    ui.steps.forEach(function (li, k) { li.firstChild.setAttribute("aria-pressed", state.step === k + 1 ? "true" : "false"); });
    ui.say.textContent = "";
    if (!state.step) {
      ui.say.appendChild(document.createTextNode(t.say + " Pick a step."));
    } else {
      var st = t.steps[state.step - 1];
      if (state.pos >= 0) {
        ui.say.appendChild(h("b", null, t.mark + " · step " + st.n + " of " + t.steps.length));
        ui.say.appendChild(document.createTextNode(" · " + st.title + " · function " + (state.pos + 1) + " of " + st.entries.length));
        if (st.chapters && st.chapters.length) { ui.say.appendChild(document.createTextNode(" · ")); ui.say.appendChild(chapterLinks(st.chapters)); }
      } else {
        var back = h("button", { type: "button", class: "xp-link" }, "back to function " + (state.lastPos + 1));
        back.addEventListener("click", function () { walk(state.step, state.lastPos, { from: "trail" }); });
        ui.say.appendChild(document.createTextNode("Step " + st.n + " · off the " + trailName(t) + " trail · "));
        ui.say.appendChild(back);
        var other = placesOf(state.sc)[0];
        if (other) {
          var go = h("button", { type: "button", class: "xp-link" }, "this one is on the " + trailName(other.trail) + " trail, step " + other.step);
          go.addEventListener("click", function () { walkTo(other.trail.id, other.step, other.pos, { from: "trail" }); });
          ui.say.appendChild(document.createTextNode(" · "));
          ui.say.appendChild(go);
        }
      }
    }
    var end = t.steps[t.steps.length - 1];
    ui.prev.disabled = !state.step || (state.step === 1 && state.pos === 0);
    ui.next.disabled = state.step === end.n && state.pos === end.entries.length - 1;
    ui.root.setAttribute("data-trail", t.id);
    ui.root.setAttribute("data-step", String(state.step));
    ui.root.setAttribute("data-pos", String(state.pos));
  }
  /** "Chapter 1 and chapter 2": the chapters a step follows, each a link. */
  function chapterLinks(files) {
    var out = h("span", { class: "xp-chapters" }, "follow it in ");
    files.forEach(function (f, i) {
      var page = V.pages.filter(function (p) { return p.file === f; })[0];
      if (i) out.appendChild(document.createTextNode(i === files.length - 1 ? " and " : ", "));
      out.appendChild(h("a", { href: V.root() + f, title: page ? page.short : f }, page && page.n ? "chapter " + page.n : f));
    });
    return out;
  }
  /** Walks another trail. The selected declaration stays when it is on that trail too; otherwise the walk resumes
   *  where it last stood on that trail, or at its first function. */
  function chooseTrail(id, opts) {
    var m = model(), t = m.trailById[id];
    if (!t || (t === current() && state.step)) return;
    setTrail(id);
    var on = onCurrent(state.sc);
    if (on) {
      state.step = on.step; state.pos = on.pos; state.lastPos = on.pos; state.at[id] = { step: on.step, pos: on.pos };
      renderCard();
      renderTrail();
      if (!opts || opts.hash !== false) writeHash();
      return;
    }
    var at = state.at[id] || { step: 1, pos: 0 };
    walk(at.step, at.pos, Object.assign({ from: "trail" }, opts || {}));
  }
  function setTrail(id) {
    if (state.trail === id) return;
    state.trail = id;
    V.storage.set("explorer:trail", id);
  }
  function walk(n, k, opts) {
    var t = current(), st = t.steps[n - 1];
    if (!st) return;
    k = Math.max(0, Math.min(k, st.entries.length - 1));
    state.step = n;
    state.pos = k;
    state.lastPos = k;
    state.at[t.id] = { step: n, pos: k };
    var en = st.entries[k];
    select(model().scopes[en.scope], Object.assign({ trail: true, line: en.line }, opts || {}));
  }
  function walkTo(id, n, k, opts) { setTrail(id); walk(n, k, opts); }
  function stepBy(d) {
    var t = current();
    if (!state.step) return walk(1, 0, { from: "trail" });
    if (state.pos < 0) return walk(state.step, state.lastPos, { from: "trail" });
    var k = state.pos + d, n = state.step;
    if (k >= t.steps[n - 1].entries.length) { if (n < t.steps.length) { n++; k = 0; } else return; }
    if (k < 0) { if (n > 1) { n--; k = t.steps[n - 1].entries.length - 1; } else return; }
    walk(n, k, { from: "trail" });
  }
  /** The badges as one group beside a name in the tree, which wraps below the name when the row is too narrow for both. */
  function badgeGroup(places) {
    var list = badges(places);
    return list.length ? h("span", { class: "xp-badges" }, list) : null;
  }
  /** A trail's mark and the steps of it a file or a declaration takes: WI3,4 is steps 3 and 4 of warp inference. */
  function badges(places) {
    var m = model(), by = {};
    places.forEach(function (o) { var s = by[o.trail.id] = by[o.trail.id] || []; if (s.indexOf(o.step) < 0) s.push(o.step); });
    return m.trails.filter(function (t) { return by[t.id]; }).map(function (t) {
      var list = by[t.id].sort(function (a, b) { return a - b; });
      return h("span", { class: "xp-badge", "data-trail": t.id, "data-kind": t.kind, title: "On the " + trailName(t) + " trail at step" + (list.length > 1 ? "s " : " ") + list.join(", ") }, t.mark + list.join(","));
    });
  }

  // MARK: The tree

  function treePanel() {
    var m = model(), roots = { key: "", folders: {}, order: [], files: [] };
    m.files.forEach(function (file) {
      var parts = file.path.split("/"), node = roots;
      if (parts.length === 1) parts = ["(the repo root)", parts[0]];
      for (var i = 0; i < parts.length - 1; i++) {
        var key = (node.key ? node.key + "/" : "") + parts[i];
        if (!node.folders[parts[i]]) { node.folders[parts[i]] = { key: key, name: parts[i], folders: {}, order: [], files: [] }; node.order.push(parts[i]); }
        node = node.folders[parts[i]];
      }
      node.files.push(file);
    });
    var remembered = V.storage.get("explorer:open", {}) || {};
    ui.fileNodes = {};
    ui.folderNodes = [];
    function count(node) { var n = node.files.length; node.order.forEach(function (k) { n += count(node.folders[k]); }); return n; }
    function remember(d, key) {
      d.addEventListener("toggle", function () {
        var open = V.storage.get("explorer:open", {}) || {};
        if (d.open) open[key] = true; else delete open[key];
        V.storage.set("explorer:open", open);
      });
    }
    function folder(node) {
      var d = h("details", { class: "xp-node", "data-node": node.key, open: remembered[node.key] ? true : null },
                h("summary", null, [h("span", null, node.name), h("small", null, count(node) + " files")]));
      var list = h("div", { class: "xp-kids" });
      node.order.forEach(function (k) { list.appendChild(folder(node.folders[k])); });
      node.files.forEach(function (f) { list.appendChild(fileNode(f)); });
      d.appendChild(list);
      remember(d, node.key);
      ui.folderNodes.push(d);
      return d;
    }
    function fileNode(file) {
      var places = [];
      file.scopes.forEach(function (sc) { places = places.concat(m.placesOf(sc.g)); });
      var d = h("details", { class: "xp-file", "data-file": file.path, open: remembered[file.path] ? true : null },
                h("summary", null, [h("span", { class: "xp-st st-" + file.status, title: file.status }, file.status.charAt(0).toUpperCase()),
                                    h("span", { class: "xp-main" }, [h("span", { class: "xp-fname", title: file.path }, file.name), badgeGroup(places)]),
                                    h("small", null, file.scopes.length ? String(file.scopes.length) : "")]));
      d.querySelector("summary").addEventListener("click", function () { openFile(file, { from: "tree" }); });
      d.addEventListener("toggle", function () { if (d.open) scopeList(file); });
      if (d.open) scopeList(file);
      remember(d, file.path);
      ui.fileNodes[file.path] = d;
      return d;
    }
    var tops = roots.order.map(function (k) { return folder(roots.folders[k]); });
    ui.filter = h("select", { "aria-label": "Which files the tree lists" }, FILTERS.map(function (f) {
      var n = m.files.filter(function (file) { return passes(file, f[0]); }).length;
      return h("option", { value: f[0], selected: f[0] === state.filter ? true : null }, f[1] + " (" + n + ")");
    }));
    ui.filter.addEventListener("change", function () { state.filter = ui.filter.value; V.storage.set("explorer:filter", state.filter); applyFilter(); });
    ui.treeLabel = h("span", null, "Files");
    ui.files = h("details", { class: "xp-files", open: true }, [h("summary", null, ui.treeLabel),
      h("label", { class: "xp-filter" }, ["Show", ui.filter]), h("div", { class: "xp-tree-inner" }, tops)]);
    ui.tree = h("nav", { class: "xp-tree", "aria-label": "Every file in the change, by folder" }, ui.files);
    return ui.tree;
  }
  function passes(file, filter) {
    if (filter === "changed") return file.status !== "unchanged";
    if (filter === "edited") return file.status === "modified" || file.status === "renamed" || file.status === "deleted";
    if (filter === "trail") return file.scopes.some(function (sc) { return model().placesOf(sc.g).length > 0; });
    return true;
  }
  function applyFilter() {
    Object.keys(ui.fileNodes).forEach(function (p) { ui.fileNodes[p].hidden = !passes(model().byPath[p], state.filter); });
    ui.folderNodes.slice().reverse().forEach(function (d) { d.hidden = !d.querySelector(".xp-file:not([hidden])"); });
  }
  function fitTree() {
    var narrow = window.innerWidth <= NARROW;
    if (ui && ui.files && ui.narrow !== narrow) { ui.files.open = !narrow; ui.narrow = narrow; }
  }
  function scopeList(file) {
    var d = ui.fileNodes[file.path];
    if (!d || d.querySelector("ul") || !file.scopes.length) return;
    var ul = h("ul", { class: "xp-scopes" });
    file.scopes.forEach(function (sc) {
      var b = h("button", { type: "button", "data-fn": sc.id, style: "padding-left:" + (0.4 + sc.depth * 0.8) + "rem", title: sc.label },
                [h("span", { class: "xp-kind" }, TAG[sc.kind]), h("span", { class: "xp-main" }, [h("span", { class: "xp-sname" }, sc.name + sc.labelText), badgeGroup(placesOf(sc))])]);
      b.addEventListener("click", function () { select(sc, { from: "tree" }); });
      ul.appendChild(h("li", null, b));
    });
    d.appendChild(ul);
  }
  function revealInTree(file, sc) {
    var d = ui.fileNodes[file.path];
    if (!d) return;
    if (d.hidden) { state.filter = "all"; ui.filter.value = "all"; applyFilter(); }
    Array.prototype.forEach.call(ui.tree.querySelectorAll(".xp-file.current"), function (x) { x.classList.remove("current"); });
    d.classList.add("current");
    for (var p = d.parentElement; p && p !== ui.tree; p = p.parentElement) if (p.tagName === "DETAILS" && !p.open && p !== ui.files) p.open = true;
    Array.prototype.forEach.call(ui.tree.querySelectorAll("[aria-current]"), function (b) { b.removeAttribute("aria-current"); });
    var target = d.querySelector("summary");
    if (sc) {
      if (!d.open) d.open = true;
      scopeList(file);
      var b = d.querySelector('[data-fn="' + cssEscape(sc.id) + '"]');
      if (b) { b.setAttribute("aria-current", "true"); target = b; }
    }
    if (ui.narrow || !target) return;
    var t = ui.tree.getBoundingClientRect(), r = target.getBoundingClientRect();
    if (r.top < t.top || r.bottom > t.bottom) ui.tree.scrollTop += r.top - t.top - t.height / 3;
  }
  function cssEscape(s) { return window.CSS && CSS.escape ? CSS.escape(s) : s.replace(/["\\]/g, "\\$&"); }

  // MARK: The source

  function sourcePanel() {
    ui.path = h("span", { class: "xp-path" }, "");
    ui.modes = {};
    var seg = h("span", { class: "xp-seg", role: "group", "aria-label": "Which text to show" }, ["new", "old", "diff"].map(function (mode) {
      var b = h("button", { type: "button", "aria-pressed": mode === state.mode ? "true" : "false", title: { new: "The working tree's text", old: "The base commit's text", diff: "The hunks between them" }[mode] },
                { new: "New", old: "Old", diff: "Diff" }[mode]);
      b.addEventListener("click", function () { setMode(mode); });
      ui.modes[mode] = b;
      return b;
    }));
    ui.copyLine = h("button", { type: "button", title: "Copy File.swift:line for the editor's Open Quickly or Go to File" }, "Copy line");
    ui.copyLink = h("button", { type: "button", title: "Copy a link to this place" }, "Copy link");
    ui.onlyButton = h("button", { type: "button", "aria-pressed": "false", title: "Show only the selected declaration" }, "Only this declaration");
    ui.copyLine.addEventListener("click", function () { var t = copyLineText(); V.copy(t, "Copied " + t, ui.source); });
    ui.copyLink.addEventListener("click", function () { V.copy(location.href.split("#")[0] + "#" + hashFor(), "Link copied", ui.source); });
    ui.onlyButton.addEventListener("click", function () { state.only = !state.only; V.storage.set("explorer:only", state.only); applyOnly(); });
    ui.pre = h("pre", { tabindex: "0", "aria-label": "Source" });
    ui.pre.addEventListener("click", function (e) {
      var row = e.target.closest && e.target.closest(".ln");
      if (!row || !state.file || (window.getSelection && String(window.getSelection()))) return;
      var n = +row.getAttribute("data-n");
      if (!n) return;
      var sc = state.mode !== "old" ? scopeAt(state.file, n) : null;
      if (sc && sc !== state.sc) select(sc, { from: "source", scroll: false, line: n });
      else pickLine(n);
    });
    ui.source = h("section", { class: "xp-source code", "aria-label": "The open file" }, [
      h("div", { class: "code-head" }, [ui.path, h("span", { class: "xp-tools" }, [seg, ui.copyLine, ui.copyLink, ui.onlyButton])]), ui.pre]);
    return ui.source;
  }
  function copyLineText() {
    if (state.sc && state.mode !== "old") return state.sc.file.name + ":" + (state.line && state.line >= state.sc.from && state.line <= lastLine(state.sc) ? state.line : state.sc.sig);
    return state.file ? state.file.name + ":" + (state.line || 1) : "";
  }
  function setMode(mode) {
    if (!state.file) return;
    if (mode === "old" && state.file.status === "added") mode = "new";
    if (mode === "new" && state.file.status === "deleted") mode = "old";
    state.mode = mode;
    Object.keys(ui.modes).forEach(function (k) { ui.modes[k].setAttribute("aria-pressed", k === mode ? "true" : "false"); });
    renderSource(state.file);
    mark(state.sc);
    if (state.sc && mode !== "old") scrollRow(row(state.sc.from), "top");
    ui.root.setAttribute("data-mode", mode);
  }
  function openFile(file, opts) {
    if (!file) return;
    if (state.file !== file) {
      state.file = file;
      state.line = 0;
      if (file.status === "added" && state.mode === "old") state.mode = "new";
      if (file.status === "deleted") state.mode = "old";
      ui.modes.old.disabled = file.status === "added" || !file.loaded;
      ui.modes.new.disabled = file.status === "deleted" || !file.loaded;
      Object.keys(ui.modes).forEach(function (k) { ui.modes[k].setAttribute("aria-pressed", k === state.mode ? "true" : "false"); });
      renderSource(file);
      ui.path.textContent = file.path + " · " + file.status;
      ui.pre.setAttribute("aria-label", "Source of " + file.name);
      ui.treeLabel.textContent = "Files · " + file.name;
      ui.root.setAttribute("data-file", file.path);
      ui.root.setAttribute("data-mode", state.mode);
    }
    if (opts && opts.from) {
      // Opened directly, from the tree, find or a link: a selection in another file lets go.
      if (state.sc && state.sc.file !== file) { state.sc = null; mark(null); ui.root.removeAttribute("data-scope"); }
      revealInTree(file, state.sc);
      renderCard();
      try { window.dispatchEvent(new CustomEvent("veilgarde:context")); } catch (e) { /* the orb reads the selection when it opens */ }
      if (opts.hash !== false) writeHash();
    }
  }
  function renderSource(file) {
    var frag = document.createDocumentFragment(), starts = {};
    ui.rows = [];
    ui.byNew = {};
    if (!file.loaded) {
      frag.appendChild(h("div", { class: "xp-empty-file" }, "This file's data is not loaded on this page."));
      ui.pre.replaceChildren(frag);
      return;
    }
    if (state.mode === "diff") renderDiff(file, frag);
    else {
      var old = state.mode === "old", lines = old ? V.oldLinesOf(file) : V.linesOf(file), st = {};
      (old ? file.oldScopes : file.scopes).forEach(function (sc) { if (!starts[sc.decl]) starts[sc.decl] = sc; });
      if (!lines.length) frag.appendChild(h("div", { class: "xp-empty-file" }, old ? "The base had no such file: it was added." : "The file is empty now."));
      lines.forEach(function (line, i) {
        var n = i + 1;
        var r = h("div", { class: "ln" + (starts[n] ? " sc" : ""), "data-n": n }, [h("span", null, String(n)), h("span", null, V.highlight(line, file.lang, st))]);
        if (starts[n]) r.setAttribute("data-fn", starts[n].id);
        ui.rows.push(r);
        if (!old) ui.byNew[n] = r;
        frag.appendChild(r);
      });
    }
    ui.pre.replaceChildren(frag);
    ui.marked = [];
    ui.pre.scrollTop = 0;
    applyOnly();
  }
  function renderDiff(file, frag) {
    var oldL = V.oldLinesOf(file), newL = V.linesOf(file), so = {}, sn = {}, i = 1, j = 1;
    function row(kind, o, n, text, st) {
      var at = kind === "del" ? n : n;
      var r = h("div", { class: "ln d " + kind, "data-n": kind === "del" ? "" : n, "data-at": at, "data-o": o || "" },
                [h("span", null, o ? String(o) : ""), h("span", null, kind === "del" ? "" : String(n)), h("span", null, kind === "add" ? "+" : kind === "del" ? "−" : " "),
                 h("span", null, V.highlight(text, file.lang, st))]);
      if (kind !== "del") ui.byNew[n] = r;
      ui.rows.push(r);
      frag.appendChild(r);
    }
    function equal(toOld) {
      while (i < toOld) { V.highlight(oldL[i - 1], file.lang, so); row("ctx", i, j, newL[j - 1], sn); i++; j++; }
    }
    (file.hunks || []).forEach(function (hk) {
      equal(hk[0]);
      for (var a = 0; a < hk[1]; a++) row("del", hk[0] + a, hk[2], oldL[hk[0] + a - 1], so);
      for (var b = 0; b < hk[3]; b++) row("add", null, hk[2] + b, newL[hk[2] + b - 1], sn);
      i = hk[0] + hk[1];
      j = hk[2] + hk[3];
    });
    equal(oldL.length + 1);
    if (!ui.rows.length) frag.appendChild(h("div", { class: "xp-empty-file" }, "No text in either version."));
  }
  function row(n) { return ui.byNew[n] || null; }
  function mark(sc) {
    (ui.marked || []).forEach(function (r) { r.classList.remove("hl", "sig", "doc"); });
    ui.marked = [];
    if (!sc || state.mode === "old") { applyOnly(); return; }
    for (var n = sc.from; n <= lastLine(sc); n++) {
      var r = row(n);
      if (!r) continue;
      r.classList.add("hl");
      if (n === sc.sig) r.classList.add("sig");
      ui.marked.push(r);
    }
    applyOnly();
  }
  function applyOnly() {
    if (!ui.onlyButton) return;
    ui.onlyButton.setAttribute("aria-pressed", state.only ? "true" : "false");
    ui.onlyButton.disabled = !state.sc;
    Array.prototype.forEach.call(ui.pre.querySelectorAll(".xp-gap"), function (g) { g.remove(); });
    var sc = state.mode === "old" ? null : state.sc, run = 0;
    var hiding = state.only && sc;
    ui.rows.forEach(function (r, i) {
      var at = +(r.getAttribute("data-at") || r.getAttribute("data-n"));
      var hide = hiding && (at < sc.from || at > lastLine(sc));
      r.hidden = !!hide;
      if (hide) run++;
      if ((!hide || i === ui.rows.length - 1) && run) {
        var gap = h("div", { class: "xp-gap", "aria-hidden": "true" }, "… " + run + (run === 1 ? " line" : " lines"));
        if (hide) r.after(gap); else r.before(gap);
        run = 0;
      }
    });
  }
  function scrollRow(r, where) {
    if (!r || r.hidden) return;
    var p = ui.pre.getBoundingClientRect(), b = r.getBoundingClientRect();
    if (b.top < p.top || b.bottom > p.bottom - 8 || where === "top") ui.pre.scrollTop = ui.pre.scrollTop + b.top - p.top - Math.min(p.height / 4, 80);
  }
  function flash(n) {
    var r = row(n);
    if (!r) return;
    if (r.hidden) { state.only = false; applyOnly(); }
    scrollRow(r, "top");
    r.classList.add("flash");
    setTimeout(function () { r.classList.remove("flash"); }, 1600);
  }
  function pickLine(n) {
    Array.prototype.forEach.call(ui.pre.querySelectorAll(".ln.picked"), function (r) { r.classList.remove("picked"); });
    state.line = n;
    var r = state.mode === "old" ? ui.rows[n - 1] : row(n);
    if (r) { r.classList.add("picked"); flash(n); }
    ui.root.setAttribute("data-line", String(n));
    writeHash();
  }

  function select(sc, opts) {
    opts = opts || {};
    if (!sc) return;
    var wasOld = state.mode === "old", same = state.file === sc.file;
    if (wasOld) state.mode = "new";
    openFile(sc.file);
    if (wasOld && same) setMode("new");
    state.sc = sc;
    state.line = opts.line || 0;
    if (!opts.trail) {
      var on = onCurrent(sc);
      if (on) { state.step = on.step; state.pos = on.pos; state.lastPos = on.pos; state.at[state.trail] = { step: on.step, pos: on.pos }; }
      else if (state.step) state.pos = -1;
    }
    mark(sc);
    if (opts.scroll !== false) scrollRow(row(sc.from), "top");
    if (opts.line && opts.line !== sc.decl) flash(opts.line);
    revealInTree(sc.file, sc);
    renderCard();
    renderTrail();
    ui.root.setAttribute("data-scope", sc.id);
    ui.root.setAttribute("data-line", String(sc.sig));
    try { window.dispatchEvent(new CustomEvent("veilgarde:context")); } catch (e) { /* an old browser: the orb reads the selection when it opens */ }
    if (opts.hash !== false) writeHash();
    V.storage.set("explorer:last", sc.id);
    if (!opts.quiet && window.innerWidth <= NARROW && (opts.from === "find" || opts.from === "trail" || opts.from === "hash")) ui.source.scrollIntoView({ block: "start" });
  }

  // MARK: The card

  function renderCard() {
    var card = ui.card, sc = state.sc;
    card.textContent = "";
    if (!sc) {
      card.appendChild(h("p", { class: "xp-empty" }, state.file ? (state.file.scopes.length ? "Pick a declaration in " + state.file.name + ", in the tree or in the source." : "This file has no declarations to pick. Click a line to copy it as " + state.file.name + ":N.")
                                                               : "Pick a file in the tree, a step on a trail, or paste a function into the box."));
      if (state.file) card.appendChild(fileBlock(state.file));
      return;
    }
    var parent = sc.parent >= 0 ? sc.file.scopes[sc.parent] : null;
    card.appendChild(h("h3", null, sc.label));
    card.appendChild(h("p", { class: "xp-kindline" }, [V.kindWords(sc), " · ", sc.file.name + ":" + sc.sig, parent ? [" · in ", jump(parent, parent.qualified)] : null]));
    card.appendChild(h("pre", { class: "xp-sig" }, signature(sc).split("\n").map(function (l, i) { return [i ? "\n" : "", V.highlight(l, "swift", {})]; })));
    var doc = docLines(sc);
    if (doc) { card.appendChild(h("h4", null, "Doc comment")); card.appendChild(h("pre", { class: "xp-raw" }, doc.join("\n"))); }
    if (sc.cases && sc.cases.length) { card.appendChild(h("h4", null, "Cases")); card.appendChild(h("p", { class: "xp-cases" }, sc.cases.join(", "))); }
    card.appendChild(h("h4", null, "Change"));
    card.appendChild(h("p", { class: "xp-change" }, [h("span", { class: "xp-st st-" + sc.status }, sc.status), " ", changeLine(sc.file, sc)]));
    placesOf(sc).slice().sort(function (a, b) { return (b.trail === current()) - (a.trail === current()); })
      .forEach(function (on) { card.appendChild(trailBlock(on)); });
    card.appendChild(headerBlock(sc.file));
    card.appendChild(edgeBlock("Calls", model().out(sc.g), 1, "Calls nothing the matcher could name."));
    card.appendChild(edgeBlock("Called by", model().into(sc.g), 0, "Nothing calls it by name."));
    card.appendChild(h("p", { class: "note xp-honest" }, HONEST + " Exact: one declaration fits, and its type is named or implied. Likely: the name and labels are unique, and the receiver's type was not read. Ambiguous: two to eight fit, and every one is listed."));
  }
  function fileBlock(file) {
    var wrap = h("div", null, [h("h3", null, file.path), h("p", { class: "xp-kindline" }, [h("span", { class: "xp-st st-" + file.status }, file.status), " " + fileChangeLine(file)])]);
    if (file.what) wrap.appendChild(h("p", { class: "xp-doc" }, file.what));
    wrap.appendChild(headerBlock(file, true));
    return wrap;
  }
  function trailBlock(on) {
    var t = on.trail, st = t.steps[on.step - 1], entry = st.entries[on.pos];
    var wrap = h("div", { class: "xp-on-trail", "data-trail": t.id, "data-kind": t.kind }, [
      h("h4", null, [h("span", { class: "xp-badge", "data-trail": t.id, "data-kind": t.kind }, t.mark + st.n), " On the " + trailName(t) + " trail"]),
      h("p", { class: "xp-step-line" }, "Step " + st.n + " of " + t.steps.length + " · " + st.title + " · function " + (on.pos + 1) + " of " + st.entries.length),
      h("p", { class: "xp-note" }, entry.note)
    ]);
    var links = h("p", { class: "xp-links" });
    if (entry.cite) {
      links.appendChild(document.createTextNode("Source of the why: "));
      links.appendChild(entry.href ? h("a", { href: V.root() + entry.href }, citeLabel(entry)) : document.createTextNode(citeLabel(entry)));
    } else links.appendChild(document.createTextNode("No cite: the note says what the code does."));
    links.appendChild(document.createTextNode(" · "));
    links.appendChild(h("a", { href: V.root() + "index.html#step-" + t.id + "-" + st.n }, "the overview at this step"));
    if (st.chapters && st.chapters.length) { links.appendChild(document.createTextNode(" · ")); links.appendChild(chapterLinks(st.chapters)); }
    wrap.appendChild(links);
    var prev = h("button", { type: "button", class: "xp-walk" }, "← previous on this trail"), next = h("button", { type: "button", class: "xp-walk" }, "next on this trail →");
    var lastStep = t.steps[t.steps.length - 1];
    prev.disabled = st.n === 1 && on.pos === 0;
    next.disabled = st.n === lastStep.n && on.pos === st.entries.length - 1;
    function from(d) { setTrail(t.id); state.step = st.n; state.pos = on.pos; stepBy(d); }
    prev.addEventListener("click", function () { from(-1); });
    next.addEventListener("click", function () { from(1); });
    wrap.appendChild(h("p", { class: "xp-walks" }, [prev, next]));
    return wrap;
  }
  function citeLabel(entry) {
    var c = entry.cite;
    if (/^ledger#/.test(c)) return "the ledger, " + c.slice(7);
    if (/^(PIN|WHAT)$/.test(c)) return "this file's " + c;
    if (/^(PIN|WHAT):/.test(c)) return c.split(":")[0] + " of " + c.split(":")[1].split("/").pop();
    if (/^test:/.test(c)) return "the test “" + c.slice(5) + "”";
    if (/^doc:/.test(c)) return "the doc comment of " + c.slice(4);
    if (/^comment:/.test(c)) return "a comment in " + c.slice(8).split("#")[0].split("/").pop();
    return c;
  }
  function headerBlock(file, open) {
    var d = h("details", { class: "xp-header", open: open ? true : null }, h("summary", null, "The file's header: what it is, and what is pinned"));
    if (!file.header) { d.appendChild(h("p", { class: "xp-empty" }, "This file has no WHAT header.")); return d; }
    var lines = V.linesOf(file).length ? V.linesOf(file) : V.oldLinesOf(file);
    d.appendChild(h("pre", { class: "xp-raw" }, lines.slice(file.header.lines[0] - 1, file.header.lines[1]).join("\n")));
    return d;
  }
  function jump(sc, text, line) {
    var b = h("button", { type: "button", class: "xp-link", "data-fn": sc.id, title: sc.id }, text);
    b.addEventListener("click", function () { select(sc, { from: "card", line: line }); });
    return b;
  }
  function edgeBlock(title, edges, end, empty) {
    var m = model(), wrap = h("div", { class: "xp-edges" }, h("h4", null, [title, h("small", null, edges.length ? " " + edges.length : "")]));
    if (!edges.length) { wrap.appendChild(h("p", { class: "xp-empty" }, empty)); return wrap; }
    [0, 1, 2].forEach(function (tier) {
      var list = edges.filter(function (e) { return e[2] === tier; }).sort(function (a, b) { return a[end] - b[end]; });
      if (!list.length) return;
      var ul = h("ul", null);
      list.forEach(function (e, k) {
        var other = m.scopes[e[end]], caller = m.scopes[e[0]];
        var at = h("button", { type: "button", class: "xp-at", title: "The call, in " + caller.file.name }, caller.file.name + ":" + e[3]);
        at.addEventListener("click", function () { if (state.sc !== caller) select(caller, { from: "card", scroll: false }); flash(e[3]); });
        ul.appendChild(h("li", { hidden: k >= 40 ? true : null }, [jump(other, other.label), e[4] > 1 ? h("small", null, " ×" + e[4]) : null, " ", at]));
      });
      var group = h("div", { class: "xp-tier" }, [h("span", { class: "tier tier-" + TIERS[tier] }, TIERS[tier]), ul]);
      if (list.length > 40) {
        var more = h("button", { type: "button", class: "xp-link" }, "and " + (list.length - 40) + " more");
        more.addEventListener("click", function () { Array.prototype.forEach.call(ul.children, function (li) { li.hidden = false; }); more.remove(); });
        group.appendChild(more);
      }
      wrap.appendChild(group);
    });
    return wrap;
  }

  // MARK: The hash

  function hashFor() {
    if (state.sc && state.pos >= 0 && state.step) return "trail-" + state.trail + "-" + state.step + ";n=" + (state.pos + 1);
    if (state.sc) return state.sc.id;
    if (state.file) return state.file.path + (state.line ? ":" + state.line : "");
    return "";
  }
  function writeHash() {
    try { history.replaceState(null, "", "#" + hashFor()); } catch (e) { /* file:// may refuse; the page still works */ }
  }
  function readHash(first) {
    var raw = "";
    try { raw = decodeURIComponent((location.hash || "").slice(1)); } catch (e) { raw = (location.hash || "").slice(1); }
    var t = parseTarget(raw);
    if (!t) return false;
    if (t.query !== undefined) { ui.find.value = t.query; fitFind(); runSearch(true); return true; }
    if (t.step) { walkTo(t.trail, t.step, t.pos, { hash: false, from: "hash", quiet: first }); return true; }
    if (t.sc) { select(t.sc, { hash: false, from: "hash", line: t.line, quiet: first }); return true; }
    if (t.file) { openFile(t.file, { from: "hash", hash: false }); if (t.line) pickLine(t.line); ui.root.setAttribute("data-line", String(t.line || 1)); return true; }
    return false;
  }

  function onKey(e) {
    if (e.target === ui.find || e.target === ui.filter) return;
    var inSource = ui.pre.contains(e.target);
    if (e.key === "]" || e.key === "[") { stepBy(e.key === "]" ? 1 : -1); e.preventDefault(); }
    else if (inSource && (e.key === "ArrowDown" || e.key === "ArrowUp") && state.file && state.file.scopes.length && !e.metaKey && !e.altKey) {
      var list = state.file.scopes, at = state.sc ? list.indexOf(state.sc) : -1;
      var k = Math.max(0, Math.min(list.length - 1, at + (e.key === "ArrowDown" ? 1 : -1)));
      if (list[k] && list[k] !== state.sc) select(list[k], { from: "source" });
      e.preventDefault();
    }
  }

  // MARK: What the ask orb reads

  function edgeNames(edges, end) {
    var m = model();
    return edges.slice(0, 30).map(function (e) { return m.scopes[e[end]].label + " (" + TIERS[e[2]] + ", the call at " + m.scopes[e[0]].file.name + ":" + e[3] + ")"; }).join("; ") +
           (edges.length > 30 ? "; and " + (edges.length - 30) + " more" : "");
  }
  /** One declaration as the chat reads it: where it sits, its change, its trail notes, its file's header, its code
   *  with the editor's line numbers, its calls and callers. */
  function describe(sc, lead, cap) {
    var m = model(), file = sc.file, lines = V.linesOf(file);
    var from = sc.from, to = lastLine(sc), last = Math.min(to, from + cap - 1), parts = [];
    var parent = sc.parent >= 0 ? file.scopes[sc.parent] : null;
    parts.push(lead + sc.label + ": " + V.kindWords(sc) + " in " + file.path + ", line " + sc.sig + (parent ? ", inside " + parent.qualified : "") + ".");
    parts.push("Its change since the base: " + changeLine(file, sc));
    m.placesOf(sc.g).forEach(function (on) {
      var t = on.trail, st = t.steps[on.step - 1], en = st.entries[on.pos];
      parts.push("It is on the " + trailName(t) + " trail, " + t.subtitle + ", told in the order it runs: step " + st.n + " of " + t.steps.length + ", \"" + st.title + "\", function " + (on.pos + 1) +
                 " of " + st.entries.length + ". The trail's note on it: " + en.note + (en.cite ? " Source of the note: " + en.cite + "." : " The note has no cite: it says what the code does."));
    });
    var what = headerPart(file, "what"), pin = headerPart(file, "pin");
    if (what) parts.push("The file's header, WHAT: " + what);
    if (pin) parts.push("The file's header, PIN: " + pin);
    var doc = docText(sc);
    if (doc) parts.push("Its doc comment: " + doc.replace(/\s+/g, " ").trim());
    var code = [];
    for (var n = from; n <= last; n++) code.push(n + "  " + lines[n - 1]);
    parts.push("Its code, " + file.name + " lines " + from + " to " + last + (last < to ? " of " + to + ", cut there" : "") + ", each line numbered as in the editor:\n```swift\n" + code.join("\n") + "\n```");
    parts.push("What it calls, " + HONEST.charAt(0).toLowerCase() + HONEST.slice(1, -1) + ": " + (m.out(sc.g).length ? edgeNames(m.out(sc.g), 1) : "nothing the matcher could name") + ".");
    parts.push("What calls it, matched the same way: " + (m.into(sc.g).length ? edgeNames(m.into(sc.g), 0) : "nothing by name") + ".");
    return parts.join("\n\n");
  }
  function describeFile(file, lead, around, cap) {
    var lines = V.linesOf(file).length ? V.linesOf(file) : V.oldLinesOf(file), parts = [];
    parts.push(lead + file.path + ", a " + file.lang + " file. " + fileChangeLine(file));
    var what = headerPart(file, "what"), pin = headerPart(file, "pin");
    if (what) parts.push("Its header, WHAT: " + what);
    if (pin) parts.push("Its header, PIN: " + pin);
    if (!what && file.what) parts.push("What it says about itself: " + file.what);
    var from = Math.max(1, (around || 1) - Math.floor(cap / 4)), to = Math.min(lines.length, from + cap - 1), code = [];
    for (var n = from; n <= to; n++) code.push(n + "  " + lines[n - 1]);
    parts.push("Lines " + from + " to " + to + " of " + lines.length + ", numbered as in the editor:\n```\n" + code.join("\n") + "\n```");
    return parts.join("\n\n");
  }
  function context() {
    if (!ui) return null;
    if (state.sc) {
      var here = onCurrent(state.sc) || placesOf(state.sc)[0];
      return { kind: "code", label: state.sc.label + (here ? " · " + here.trail.mark + here.step : ""), text: describe(state.sc, "The reader is on the change explorer, looking at ", 220) };
    }
    if (state.file) return { kind: "code", label: state.file.path, text: describeFile(state.file, "The reader is on the change explorer, looking at ", state.line, 220) };
    return null;
  }

  var mapText = null;
  var MAP_BUDGET = 24000; // characters, about 6,000 tokens
  /** The codebase at a glance, for the chat: every file with the first sentence of its header, folder by folder,
   *  what was left out, then every trail. The sentences are cut shorter until the whole fits the budget. */
  function codeMap() {
    if (mapText) return mapText;
    var m = model(), idx = m.index;
    function render(cap) {
      var out = [], folder = null;
      out.push(idx.files.length + " files changed from " + (idx.base.label || idx.base.short) + " to " + (idx.head.first ? "this tree" : (idx.head.short || "the head") + (idx.head.dirty ? " and the working tree" : "")) +
               ", by folder, each with the first sentence of its header; a file not marked was added:");
      m.files.forEach(function (f) {
        var dir = f.path.indexOf("/") < 0 ? "(the repo root)" : f.path.split("/").slice(0, -1).join("/");
        if (dir !== folder) { out.push(dir + "/"); folder = dir; }
        var what = (f.what || "").replace(/\s+/g, " ").trim();
        out.push("  " + f.name + (f.status === "added" ? "" : " [" + f.status + "]") + ": " + (what ? (what.length > cap ? what.slice(0, cap - 1) + "…" : what) : "no header"));
      });
      out.push("", "Left out of this page, by name only: " + idx.excluded.length + " files, among them the shipped model JSONs under Sources/VeilGardeInference/Resources/, test fixtures, Package.resolved and LICENSE.");
      out.push("", "The trails through the code, each in the order it runs:");
      m.trails.forEach(function (t) {
        out.push(t.title + " (" + t.mark + ", " + t.kind + "), " + t.subtitle + ":");
        t.steps.forEach(function (st) { out.push("  " + st.n + ". " + st.title + ": " + st.entries.map(function (en) { return m.scopes[en.scope].qualified; }).join(", ")); });
      });
      return out.join("\n");
    }
    var caps = [140, 110, 90, 70, 50, 30, 20];
    for (var k = 0; k < caps.length; k++) { mapText = render(caps[k]); if (mapText.length <= MAP_BUDGET) break; }
    return mapText;
  }

  // MARK: The chat's tools: the whole change, read on demand, from the data this page already holds

  var TOOL_SPECS = [
    { type: "function", "function": { name: "find_declarations", description: "Find Swift declarations in the change by name, Type.method, or part of a name. Returns up to 20, each with its file, line and id.",
      parameters: { type: "object", properties: { query: { type: "string", description: "A name such as run, WarpInference.run or WarpInference.run(cgImage:config:progress:)" } }, required: ["query"] } } },
    { type: "function", "function": { name: "read_declaration", description: "Read one declaration whole: its code with line numbers, its doc comment, its file's header, its change, its trail note, and what it calls and what calls it.",
      parameters: { type: "object", properties: { name: { type: "string", description: "Its qualified name, with argument labels when several share it, or an id from find_declarations" } }, required: ["name"] } } },
    { type: "function", "function": { name: "search_text", description: "Search every file in the change for a piece of text, ignoring case. Returns up to 40 matching lines with their file and line.",
      parameters: { type: "object", properties: { text: { type: "string", description: "The text to look for, such as dual-warp or sensorRawProbability" } }, required: ["text"] } } },
    { type: "function", "function": { name: "read_file", description: "Read a file in the change. Without lines, returns its header and the outline of its declarations; with from and to, returns those lines, numbered, at most 300.",
      parameters: { type: "object", properties: { path: { type: "string", description: "Its path, such as Sources/VeilGardeLens/Warp/WarpLens.swift, or its file name when unique" },
                                                   from: { type: "integer" }, to: { type: "integer" } }, required: ["path"] } } }
  ];
  function resolveDeclaration(q) {
    var m = model();
    q = String(q || "").trim().replace(/^`+|`+$/g, "");
    if (!q) return [];
    var byId = m.scopes.filter(function (sc) { return sc && sc.id === q; });
    if (byId.length) return byId;
    var t = parseTarget(q);
    if (t && t.sc) return [t.sc];
    var hits = findSymbol(q);
    if (!hits.length && /\(/.test(q)) hits = findSymbol(q.replace(/\(.*$/, ""));
    return hits;
  }
  function fileNamed(p) {
    var m = model();
    p = String(p || "").trim().replace(/^\/+/, "").replace(/:\d+$/, "");
    if (m.byPath[p]) return [m.byPath[p]];
    return m.files.filter(function (f) { return f.name === p || f.path.slice(-p.length - 1) === "/" + p; });
  }
  var TOOLS = {
    find_declarations: function (a) {
      var q = String(a.query || "").trim(), m = model();
      if (!q) return { text: "Give a name to find." };
      var found = search(q).filter(function (r) { return r.sc; }).slice(0, 20);
      if (!found.length) return { text: "No declaration in the change is named like \"" + q + "\". Try search_text for words inside the code.", read: { label: "looked for " + q } };
      return { read: { label: "looked for " + q }, text: found.map(function (r) {
        var sc = r.sc;
        return sc.label + ": " + KIND[sc.kind] + ", " + sc.file.path + ":" + sc.sig + m.placesOf(sc.g).map(function (o) { return ", " + trailName(o.trail) + " trail step " + o.step; }).join("") + ". id " + sc.id;
      }).join("\n") };
    },
    read_declaration: function (a) {
      var hits = resolveDeclaration(a.name);
      if (!hits.length) return { text: "No declaration matches \"" + a.name + "\". Use find_declarations first." };
      if (hits.length > 1) return { text: "Several declarations match; read one by its id:\n" + hits.slice(0, 12).map(function (sc) { return sc.id + " (" + KIND[sc.kind] + ", " + sc.file.path + ":" + sc.sig + ")"; }).join("\n") };
      var sc = hits[0];
      return { read: { label: sc.qualified + sc.labelText, href: "#" + sc.id }, text: describe(sc, "", 260) };
    },
    search_text: function (a) {
      var needle = String(a.text || "").trim(), low = needle.toLowerCase(), out = [], total = 0;
      if (low.length < 2) return { text: "Give at least two characters to search for." };
      model().files.forEach(function (f) {
        if (!f.loaded) return;
        V.linesOf(f).forEach(function (l, i) {
          if (l.toLowerCase().indexOf(low) < 0) return;
          total++;
          if (out.length < 40) out.push(f.path + ":" + (i + 1) + ": " + l.trim().slice(0, 160));
        });
      });
      return { read: { label: "searched \"" + needle + "\"" }, text: total ? out.join("\n") + (total > 40 ? "\nand " + (total - 40) + " more lines" : "") : "No line in the change contains \"" + needle + "\"." };
    },
    read_file: function (a) {
      var files = fileNamed(a.path);
      if (files.length > 1) return { text: "Several files match: " + files.map(function (f) { return f.path; }).join(", ") };
      if (!files.length) return { text: "No file " + a.path + " in the change. It may be one the page leaves out: the shipped model JSONs, test fixtures, Package.resolved, LICENSE." };
      var file = files[0], lines = V.linesOf(file);
      if (!file.loaded) return { text: file.path + " is in the change, but its data file is not loaded on this page." };
      if (!a.from && !a.to) {
        var head = [headerPart(file, "what"), headerPart(file, "pin")].filter(Boolean);
        var outline = file.scopes.slice(0, 160).map(function (sc) { return "  line " + sc.sig + ": " + new Array(sc.depth + 1).join("  ") + KIND[sc.kind] + " " + sc.name + sc.labelText; });
        var body = outline.length ? "Declarations:\n" + outline.join("\n") : "Its first lines:\n" + lines.slice(0, 60).map(function (l, i) { return (i + 1) + "  " + l; }).join("\n");
        return { read: { label: file.name, href: "#" + file.path }, text: file.path + ", " + lines.length + " lines, " + file.status + ".\nHeader: " + (head.length ? head.join(" PIN: ") : file.what || "none") + "\n" + body };
      }
      var from = Math.max(1, Math.floor(+a.from || 1)), to = Math.min(lines.length, Math.floor(+a.to || from + 119));
      if (to < from) to = Math.min(lines.length, from + 119);
      if (to - from > 299) to = from + 299;
      var code = [];
      for (var n = from; n <= to; n++) code.push(n + "  " + lines[n - 1]);
      return { read: { label: file.name + " " + from + "–" + to, href: "#" + file.path + ":" + from }, text: file.path + " lines " + from + " to " + to + " of " + lines.length + ":\n```\n" + code.join("\n") + "\n```" };
    }
  };
  /** Runs one tool call from the chat: its name and its JSON arguments in, { text, read } out, the text capped. */
  function runTool(name, args) {
    if (!model()) return { text: "The change's data is not loaded on this page." };
    try { args = typeof args === "string" ? JSON.parse(args || "{}") : (args || {}); } catch (e) { return { text: "The arguments were not JSON: " + String(args).slice(0, 100) }; }
    var fn = TOOLS[name];
    if (!fn) return { text: "There is no tool named " + name + "." };
    var out = fn(args);
    if (out.text.length > 14000) out.text = out.text.slice(0, 14000) + "\n[cut here]";
    return out;
  }

  // MARK: Self-check

  function applies(oldL, newL, hunks) {
    var out = [], i = 1, j = 1;
    for (var k = 0; k < hunks.length; k++) {
      var hk = hunks[k];
      if (hk[0] - i !== hk[2] - j || hk[0] < i) return false;
      out = out.concat(oldL.slice(i - 1, hk[0] - 1), newL.slice(hk[2] - 1, hk[2] - 1 + hk[3]));
      i = hk[0] + hk[1];
      j = hk[2] + hk[3];
    }
    if (oldL.length - (i - 1) !== newL.length - (j - 1)) return false;
    out = out.concat(oldL.slice(i - 1));
    return out.length === newL.length && out.every(function (l, n) { return l === newL[n]; });
  }
  function selfCheck() {
    var m = model(), out = [], bad;
    function check(name, ok, detail) { out.push({ name: name, ok: !!ok, detail: detail || "" }); }
    if (!m) return [{ name: "the data is loaded", ok: false, detail: "data/index.js is missing" }];
    var idx = m.index;
    check("every group's data file is loaded", !m.missing.length, m.missing.join(", ") || idx.groups.length + " groups");
    var enc = window.TextEncoder ? new TextEncoder() : null;
    bad = m.files.filter(function (f) {
      if (!f.loaded) return true;
      var text = f.status === "deleted" ? f.old : f.text, lines = V.splitLines(text);
      return lines.length !== f.lineCount || (enc && enc.encode(text).length !== f.bytes) || f.scopes.length !== f.scopeCount;
    });
    check("each file's text has the lines, bytes and declarations the index records", !bad.length, bad.length ? bad[0].path : m.files.length + " files");
    var running = 0;
    bad = m.files.filter(function (f) { var wrong = f.first !== running; running += f.scopes.length; return wrong; });
    check("the files' declaration numbering runs on without a gap", !bad.length && running === idx.counts.scopes.total, running + " declarations");
    bad = m.files.filter(function (f) { return f.loaded && f.old !== null && !applies(V.oldLinesOf(f), V.linesOf(f), f.hunks); });
    check("every file's hunks turn its base text into its new text", !bad.length, bad.length ? bad[0].path : "");
    bad = m.files.filter(function (f) { var n = (V.linesOf(f).length || V.oldLinesOf(f).length); return f.header && (f.header.lines[0] < 1 || f.header.lines[1] > n); });
    check("every header lies inside its file", !bad.length, bad.length ? bad[0].path : "");
    var scopes = m.scopes.filter(Boolean);
    bad = scopes.filter(function (sc) { return sc.decl < 1 || sc.decl > sc.sig || lastLine(sc) < sc.sig || lastLine(sc) > V.linesOf(sc.file).length; });
    check("every declaration's lines lie inside its file", !bad.length, bad.length ? bad[0].id : scopes.length + " declarations");
    var word = { f: /\bfunc\b/, i: /\binit\b/, d: /\bdeinit\b/, s: /\bsubscript\b/, v: /\bvar\b/, S: /\bstruct\b/, C: /\bclass\b/, E: /\benum\b/, A: /\bactor\b/, X: /\bextension\b/, P: /\bprotocol\b/ };
    bad = scopes.filter(function (sc) { return !word[sc.kind].test(V.linesOf(sc.file)[sc.sig - 1] || ""); });
    check("every declaration's signature line holds its keyword", !bad.length, bad.length ? bad[0].id : "");
    bad = idx.sample.filter(function (s) { return !m.scopes[s[0]] || m.scopes[s[0]].id !== s[1]; });
    check("the ids this page derives equal the build's", !bad.length, bad.length ? bad[0][1] + " is " + (m.scopes[bad[0][0]] || {}).id : idx.sample.length + " sampled");
    bad = idx.edges.filter(function (e) { return !m.scopes[e[0]] || !m.scopes[e[1]] || !(e[2] >= 0 && e[2] <= 2) || !(e[3] >= 1); });
    check("every call edge joins two declarations, with a tier and a line", !bad.length, V.fmt.int(idx.edges.length) + " edges");
    var trails = m.trails, pages = V.pages.map(function (p) { return p.file; });
    check("eleven trails: the four verdict flows trained and run, the watermark signed and matched, and the pruning study, each with a mark of its own and its steps numbered from 1",
          trails.length === 11 && ["warp", "fusion", "specialist", "noiseprint"].every(function (k) { return m.trailById[k + "-training"] && m.trailById[k + "-inference"]; }) &&
          m.trailById["watermark-signing"] && m.trailById["watermark-matching"] && m.trailById.pruning &&
          trails.every(function (t, i) { return t.mark && trails.findIndex(function (u) { return u.mark === t.mark; }) === i; }) &&
          trails.every(function (t) { return t.steps.length >= 3 && t.steps.length <= 9 && t.steps.every(function (st, i) { return st.n === i + 1 && st.entries.length > 0; }); }),
          trails.map(function (t) { return t.mark + " " + t.steps.length; }).join(" · "));
    var cells = [];
    bad = [];
    (idx.picker || []).forEach(function (sec) {
      sec.rows.forEach(function (row) {
        row.trails.forEach(function (id, ci) { var t = m.trailById[id]; cells.push(id); if (!t || !sec.columns[ci] || sec.columns[ci].kind !== t.kind) bad.push(id); });
      });
    });
    check("the picker holds every trail once, each in its kind's column",
          !bad.length && cells.length === trails.length && trails.every(function (t) { return cells.indexOf(t.id) >= 0; }), bad.join(", ") || (idx.picker || []).map(function (sec) { return sec.title; }).join(" · "));
    bad = [];
    trails.forEach(function (t) {
      var seen = {};
      t.steps.forEach(function (st) {
        (st.chapters || []).forEach(function (f) { if (pages.indexOf(f) < 0) bad.push(t.id + " step " + st.n + " names " + f); });
        st.entries.forEach(function (en) {
          var sc = m.scopes[en.scope];
          if (!sc || sc.id !== en.id) { bad.push(en.id + " does not resolve"); return; }
          if (seen[en.scope]) bad.push(t.id + " holds " + en.id + " twice");
          seen[en.scope] = true;
          var body = V.linesOf(sc.file).slice(sc.from - 1, lastLine(sc)).join("\n");
          if (body.indexOf(en.anchor) < 0) bad.push(en.id + " lost its anchor");
          if ((V.linesOf(sc.file)[en.line - 1] || "").indexOf(en.anchor.split("\n")[0]) < 0) bad.push(en.id + "'s anchor moved from line " + en.line);
        });
      });
    });
    check("every trail entry resolves, once a trail, and still holds its anchor; every chapter a step names is a page", !bad.length, bad.join("; ") || m.entries.length + " entries");
    var first = m.scopes[trails[0].steps[0].entries[0].scope], top = function (q) { var r = search(q)[0]; return r && r.sc; };
    var body = V.linesOf(first.file).slice(first.decl - 1, lastLine(first)).join("\n");
    var bySig = search(signature(first).split("\n").join(" ")).filter(function (r) { return r.sc; }).map(function (r) { return r.sc; });
    check("find returns the first trail entry by name and by its body, and lists it among the declarations with its signature",
          top(first.qualified) === first && top(body) === first && bySig.indexOf(first) >= 0 && (bySig.length > 1 || bySig[0] === first),
          first.label + (bySig.length > 1 ? "; " + bySig.length + " declarations share its signature line" : ""));
    var reindented = body.split("\n").map(function (l) { return "\t  " + l.trim(); }).join("\n");
    check("a pasted body, reindented, still finds it", top(reindented) === first);
    var a = parseTarget(first.file.path + ":" + first.sig), b = parseTarget(first.id), c = parseTarget("trail-" + trails[0].id + "-1;n=1"), d = parseTarget("trail-3;n=2"),
        w = parseTarget("trail-watermark-3;n=2");
    check("every deep-link form names its place: a line, an id, a trail step, an older step link through the map of old steps, and a step of a renamed trail",
          a && b && a.sc === first && b.sc === first && c && c.trail === trails[0].id && c.step === 1 && c.pos === 0 && d && d.trail === "warp-inference" && d.step === 3 && d.pos === 1 &&
          w && w.trail === "watermark-matching" && w.step === 3 && w.pos === 1);
    var map = codeMap();
    check("the codebase map names every file and every trail, in about 6,000 tokens", m.files.every(function (f) { return map.indexOf("\n  " + f.name + (f.status === "added" ? ":" : " [")) >= 0; }) &&
          trails.every(function (t) { return map.indexOf(t.title + " (" + t.mark + ", ") >= 0; }) && map.length <= MAP_BUDGET + 2000, V.fmt.int(map.length) + " characters");
    var reads = [runTool("read_declaration", { name: "WarpInference.run" }), runTool("read_file", { path: "WarpLens.swift" }), runTool("search_text", { text: "dual-warp" }),
                 runTool("find_declarations", { query: "ResultJSON.encode" }), runTool("read_file", { path: "Sources/VeilGardeLens/Warp/WarpResidual.swift", from: 17, to: 20 })];
    check("the chat's tools read a declaration, a file, a search, a lookup and a range of lines",
          /static func run\(cgImage/.test(reads[0].text) && /Declarations:/.test(reads[1].text) && /dual-warp/i.test(reads[2].text) && /ResultJSON\.encode/.test(reads[3].text) && /^17  /m.test(reads[4].text),
          reads.map(function (r) { return r.text.length; }).join(", ") + " characters");
    return out;
  }

  V.explorer = {
    mount: mount, selfCheck: selfCheck, search: search, parseTarget: parseTarget, model: model, context: context,
    map: codeMap, tools: TOOL_SPECS, tool: runTool, describe: describe,
    trailFile: function (id, n) { var m = model(), t = m && m.trailById[id]; return t && t.steps[n - 1] ? m.scopes[t.steps[n - 1].entries[0].scope].file.path : null; }
  };
  if (V.data().index) V.extraChecks.push({ name: "explorer", run: selfCheck });
})();
