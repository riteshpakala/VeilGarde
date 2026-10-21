/*
 * The change at a glance (index.html): the request quoted from the ledger, the package's layers lit by each step of
 * the chosen trail, the trail grid (a row a flow, a column a kind) and a stepper over its steps, the counts, the commands and tests the
 * ledger recorded, the decisions, and the open questions. Everything shown here is read from data/run.js and data/index.js, so it is what the build saw.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */
(function () {
  "use strict";
  var V = window.VeilGarde, h = V.h;
  var state = { trail: null, step: 1 }, picker = null;

  function run() { return V.data().run || {}; }
  function index() { return V.data().index || null; }
  function layerOfFile(path) {
    var idx = index(), f = idx.files.filter(function (x) { return x.path === path; })[0];
    return f ? idx.layers[f.group] : null;
  }
  function firstFileOf(prefix) {
    var idx = index(), f = idx.files.filter(function (x) { return x.path === prefix || x.path.indexOf(prefix.replace(/\/?$/, "/")) === 0; })[0];
    return f ? f.path : null;
  }
  function excluded(path) { return index().excluded.filter(function (x) { return x.path === path || x.path.indexOf(path.replace(/\/?$/, "/")) === 0; })[0] || null; }
  function fileLink(path) {
    var hit = firstFileOf(path);
    if (hit) return h("a", { href: "code.html#" + hit, title: "Open it in the change explorer" }, path);
    var out = excluded(path);
    if (out) return h("span", null, [h("code", null, path), " · left out of the explorer: ", h("a", { href: "#excluded" }, out.reason)]);
    return h("code", null, path);
  }

  // MARK: The request

  function renderRequest(node) {
    var r = run();
    if (!r.request) { node.appendChild(h("p", { class: "fig-error" }, "data/run.js holds no request.")); return; }
    var paras = r.request.split(/\n\s*\n/).map(function (p) { return p.trim(); }).filter(Boolean), shown = 3;
    var q = h("blockquote", { class: "request" }, paras.slice(0, shown).map(function (p) { return h("p", null, p); }));
    if (paras.length > shown) {
      q.appendChild(h("details", { class: "request-rest" }, [h("summary", null, "The rest of the request · " + (paras.length - shown) + " more paragraphs"),
        paras.slice(shown).map(function (p) { return h("p", null, p); })]));
    }
    q.appendChild(h("cite", null, "The request, " + (r.request_note ? "from" : "verbatim from") + " docs/site/src/ledger.json, made " +
      ((r.base || {}).label ? "against " + r.base.label : "at base " + ((r.base || {}).commit || "").slice(0, 7)) + " on " +
      ((r.base || {}).date || "an unrecorded date") + "." + (r.request_note ? " " + r.request_note : "")));
    node.appendChild(q);
    var more = [];
    (r.amendments || []).forEach(function (a) {
      more.push(h("li", { id: a.id }, [h("span", { class: "id" }, a.id + " · " + (a.date || "")), " ", h("span", { class: "pre" }, a.text), a.edited ? h("span", { class: "dim" }, " (" + a.edited + ")") : null]));
    });
    (r.answers || []).forEach(function (a) { more.push(h("li", { id: a.id }, [h("span", { class: "id" }, a.id), " ", h("b", null, a.question), " ", a.answer])); });
    if (more.length) {
      node.appendChild(h("details", { class: "engineers" }, [h("summary", null, "The amendments and the answers that shaped the request · " + more.length),
        h("div", { class: "inner" }, h("ul", { class: "decisions" }, more))]));
    }
  }

  // MARK: The picture and the stepper

  function layersOf(step) {
    var m = V.model(), out = {};
    step.entries.forEach(function (en) { var sc = m.scopes[en.scope], path = sc ? sc.file.path : en.id.split(":")[0], l = layerOfFile(path); if (l) out[l] = true; });
    return out;
  }
  function trailOf(id) { var idx = index(); return idx.trails.filter(function (t) { return t.id === id; })[0] || idx.trails[0]; }
  /** Lights step n of trail id: the layers its declarations live in, its entries, and links into the explorer. */
  function light(id, n) {
    var t = trailOf(id), st = t.steps[n - 1];
    if (!st) return;
    if (state.trail !== t.id) { state.trail = t.id; renderSteps(); }
    state.step = n;
    var lit = layersOf(st);
    document.querySelectorAll("#system .layer").forEach(function (g) { g.classList.toggle("lit", !!lit[g.getAttribute("data-layer")]); });
    if (picker) V.pressTrail(picker, t.id);
    document.querySelectorAll("#stepper button.step").forEach(function (b) { b.setAttribute("aria-pressed", +b.getAttribute("data-step") === n ? "true" : "false"); });
    var detail = document.getElementById("step-detail");
    detail.textContent = "";
    var chapters = (st.chapters || []).map(function (f, i) {
      var page = V.pages.filter(function (p) { return p.file === f; })[0];
      return [i ? (i === st.chapters.length - 1 ? " and " : ", ") : "", h("a", { href: f }, page && page.n ? "chapter " + page.n : f)];
    });
    detail.appendChild(h("p", null, [h("b", null, t.title + " · step " + n + " of " + t.steps.length + ": " + st.title), " · lights " + Object.keys(lit).join(", ") + " · ",
      h("a", { href: "code.html#trail-" + t.id + "-" + n }, "walk it in the explorer"), chapters.length ? [" · follow it in ", chapters] : null]));
    detail.appendChild(h("ol", null, st.entries.map(function (en, k) {
      var tail = en.id.slice(en.id.indexOf(":") + 1);
      return h("li", null, [h("a", { href: "code.html#trail-" + t.id + "-" + n + ";n=" + (k + 1) }, h("code", null, tail)), " · " + en.note.split(/(?<=[.!?])\s/)[0]]);
    })));
  }
  function remember(id, n) { try { history.replaceState(null, "", "#step-" + id + "-" + n); } catch (e) { /* file:// may refuse */ } }
  /** The chosen trail's step buttons, rebuilt when the trail changes. */
  function renderSteps() {
    var t = trailOf(state.trail), list = document.getElementById("step-list");
    if (!list) return;
    list.textContent = "";
    list.setAttribute("aria-label", "The " + t.title.toLowerCase() + " trail's steps");
    t.steps.forEach(function (st) {
      var b = h("button", { type: "button", class: "step", id: "step-" + t.id + "-" + st.n, "data-step": st.n, "aria-pressed": "false" }, [h("span", { class: "n" }, String(st.n)), h("span", null, st.title)]);
      b.addEventListener("click", function () { light(t.id, st.n); remember(t.id, st.n); });
      list.appendChild(h("li", null, b));
    });
    var say = document.getElementById("trail-say");
    if (say) say.textContent = t.say;
  }
  function renderStepper(node) {
    var idx = index();
    state.trail = idx.trails[0].id;
    var byId = {};
    idx.trails.forEach(function (t) { byId[t.id] = t; });
    picker = V.trailPicker(idx.picker, byId, function (id) { light(id, 1); remember(id, 1); }, "The trails");
    node.appendChild(h("div", { class: "trail-pick" }, picker));
    node.appendChild(h("p", { class: "trail-say", id: "trail-say" }));
    node.appendChild(h("ol", { id: "step-list" }));
    node.appendChild(h("div", { class: "detail", id: "step-detail", "aria-live": "polite" }));
    renderSteps();
    var counts = {};
    idx.files.forEach(function (f) { var l = idx.layers[f.group]; if (l && f.group.indexOf("Sources-") === 0) counts[l] = (counts[l] || 0) + f.scopes; });
    document.querySelectorAll("#system .layer").forEach(function (g) {
      var l = g.getAttribute("data-layer"), c = g.querySelector(".count"), a = g.querySelector("a"), first = firstFileOf("Sources/" + l);
      if (c) c.textContent = (counts[l] || 0) + " declarations";
      if (a && first) a.setAttribute("href", "code.html#" + first);
    });
    function fromHash() {
      var r = /^#step-([a-z]+(?:-[a-z]+)*)-(\d+)$/.exec(location.hash || "");
      if (r && idx.trails.some(function (t) { return t.id === r[1]; })) { var t = trailOf(r[1]); return [t.id, Math.max(1, Math.min(t.steps.length, +r[2]))]; }
      return null;
    }
    var at = fromHash() || [idx.trails[0].id, 1];
    light(at[0], at[1]);
    window.addEventListener("hashchange", function () { var a = fromHash(); if (a) light(a[0], a[1]); });
  }

  // MARK: The counts

  function latestTests() {
    var by = {};
    (run().tests || []).forEach(function (t) { by[t.suite] = t; });
    return Object.keys(by).map(function (k) { return by[k]; });
  }
  function card(title, big, line, source) { return h("div", { class: "count-card" }, [h("h3", null, title), h("div", { class: "big" }, big), line ? h("p", null, line) : null, h("small", null, source)]); }
  function renderCounts(node) {
    var idx = index(), c = idx.counts, f = c.files, tests = latestTests();
    var passed = 0, failed = 0, skipped = 0;
    tests.forEach(function (t) { passed += t.passed || 0; failed += t.failed || 0; skipped += t.skipped || 0; });
    node.appendChild(card("Files", V.fmt.int(f.added) + " added", V.fmt.int(f.modified) + " modified · " + V.fmt.int(f.renamed) + " renamed · " + V.fmt.int(f.deleted) + " deleted · " + V.fmt.int(c.excluded) + " left out",
                          "git diff --name-status -M " + idx.base.commit + " (" + (idx.base.label || "the base") + ") and the untracked files, when the page was built"));
    node.appendChild(card("Lines", "+" + V.fmt.int(c.lines.added) + " −" + V.fmt.int(c.lines.removed), V.fmt.int(c.embedded) + " files embedded verbatim", "the hunks of every embedded file"));
    node.appendChild(card("Declarations", V.fmt.int(c.scopes.added) + " added", V.fmt.int(c.scopes.changed) + " changed · " + V.fmt.int(c.scopes.unchanged) + " unchanged · " + V.fmt.int(c.scopes.removed) + " removed, in " + V.fmt.int(c.swift) + " Swift files",
                          "build.py's parse; its two counts agree on every file"));
    node.appendChild(card("Calls", V.fmt.int(c.edges.exact + c.edges.likely + c.edges.ambiguous) + " edges", "exact " + V.fmt.int(c.edges.exact) + " · likely " + V.fmt.int(c.edges.likely) + " · ambiguous " + V.fmt.int(c.edges.ambiguous),
                          "matched by name and argument labels when this page was built, not by a compiler"));
    node.appendChild(card("Tests", V.fmt.int(passed + failed + skipped) + " run", V.fmt.int(passed) + " passed · " + V.fmt.int(failed) + " failed · " + V.fmt.int(skipped) + " skipped, in " + tests.length + " suites",
                          "the latest run of each suite in the ledger; this page runs none"));
    node.appendChild(card("Trails", V.fmt.int(c.trails) + " trails", V.fmt.int(c.trail) + " entries over " + idx.trails.reduce(function (a, t) { return a + t.steps.length; }, 0) + " steps, " +
                          V.fmt.int(c.onTrail) + " declarations, every anchor found", "docs/site/src/trails.json, resolved by build.py"));
  }

  // MARK: Checks, decisions, questions

  function renderChecks(node) {
    var r = run();
    var rows = (r.commands || []).map(function (c) {
      var ok = c.exit === 0;
      return h("tr", { id: c.id }, [h("td", { class: "mono nowrap" }, c.id), h("td", { class: "nowrap" }, [c.date || "", c.phase ? [h("br"), "phase " + c.phase] : null]), h("td", { class: "mono" }, c.cmd),
        h("td", null, h("span", { class: "status " + (ok ? "ok" : "bad") }, ok ? "exit 0" : "exit " + c.exit + ", failed")),
        h("td", null, h("ul", { class: "lines-out" }, (c.lines || []).map(function (l) { return h("li", null, l); })))]);
    });
    node.appendChild(h("div", { class: "scroll" }, h("table", { class: "data" }, [h("thead", null, h("tr", null, ["Command", "When", "What ran", "Result", "The lines that matter"].map(function (t) { return h("th", null, t); }))), h("tbody", null, rows)])));
  }
  function renderTests(node) {
    var rows = (run().tests || []).map(function (t) {
      var state = t.failed ? ["bad", t.failed + " failed"] : t.skipped ? ["skip", t.skipped + " skipped"] : ["ok", "passed"];
      return h("tr", { id: t.id }, [h("td", { class: "mono nowrap" }, t.id), h("td", { class: "nowrap" }, [t.date || "", t.phase ? [h("br"), "phase " + t.phase] : null]), h("td", { class: "mono" }, t.suite),
        h("td", { class: "n" }, String(t.passed)), h("td", { class: "n" }, String(t.failed)), h("td", { class: "n" }, String(t.skipped)), h("td", null, [h("span", { class: "status " + state[0] }, state[1]), t.note ? " · " + t.note : ""])]);
    });
    node.appendChild(h("div", { class: "scroll" }, h("table", { class: "data" }, [h("thead", null, h("tr", null, ["Run", "When", "Suite", "Passed", "Failed", "Skipped", "Result"].map(function (t, k) { return h("th", { class: k >= 3 && k <= 5 ? "n" : null }, t); }))), h("tbody", null, rows)])));
  }
  function renderDecisions(node) {
    node.appendChild(h("ul", { class: "decisions" }, (run().decisions || []).map(function (d) {
      var shapes = d.retired ? [" · shaped ", h("code", null, d.file || ""), h("span", { class: "dim" }, ", retired on " + d.retired + " and kept on the 2026-rnd branch")]
                             : [" · shapes ", fileLink(d.file || "")];
      return h("li", { id: d.id, class: d.retired ? "retired" : null }, [h("span", { class: "id" }, d.id), h("b", null, d.chose)].concat(shapes,
        [h("span", { class: "why" }, "Rather than " + d.rejected + ". Why: " + d.reason)]));
    })));
  }
  function renderQuestions(node) {
    var r = run(), q = r.questions || [], a = r.assumptions || [], answered = {};
    (r.answers || []).forEach(function (x) { if (x.question_id) answered[x.question_id] = x; });
    var open = q.filter(function (x) { return !answered[x.id]; }), closed = q.filter(function (x) { return answered[x.id]; });
    node.appendChild(h("h3", null, "Open questions"));
    node.appendChild(open.length ? h("ul", { class: "decisions" }, open.map(function (x) { return h("li", { id: x.id }, [h("span", { class: "id" }, x.id), x.text || x.question || ""]); }))
                                 : h("p", null, q.length ? "None open: the owner answered every one." : "None recorded in the ledger."));
    if (closed.length) {
      node.appendChild(h("h3", null, "Answered"));
      node.appendChild(h("ul", { class: "decisions" }, closed.map(function (x) {
        var an = answered[x.id];
        return h("li", { id: x.id }, [h("span", { class: "id" }, x.id), x.text || x.question || "", h("span", { class: "dim" }, " Answered in " + an.id + (an.date ? ", " + an.date : "") + ".")]);
      })));
    }
    node.appendChild(h("h3", null, "Assumptions"));
    node.appendChild(a.length ? h("ul", { class: "decisions" }, a.map(function (x) { return h("li", { id: x.id }, [h("span", { class: "id" }, x.id), x.text]); }))
                              : h("p", null, "None recorded in the ledger."));
    var w = (index() || {}).warnings || [];
    node.appendChild(h("h3", null, "Follow-ups the build flagged"));
    node.appendChild(w.length ? h("ul", { class: "decisions" }, w.map(function (x) { return h("li", null, x); }))
                              : h("p", null, "None: every Swift file has its header and every trail entry is linked to the ones before."));
  }
  function renderAlso(node) {
    var idx = index(), m = V.model(), on = {}, by = {}, order = [];
    m.entries.forEach(function (e) { on[e.entry.scope] = true; });
    m.files.forEach(function (f) {
      var key = f.path.indexOf("/") < 0 ? "(the repo root)" : f.path.split("/").slice(0, f.path.indexOf("Sources/") === 0 || f.path.indexOf("Tests/") === 0 ? 2 : 1).join("/");
      if (!by[key]) { by[key] = { files: 0, scopes: 0, onTrail: 0, first: f.path }; order.push(key); }
      by[key].files++;
      for (var g = f.first; g < f.first + f.scopeCount; g++) { by[key].scopes++; if (on[g]) by[key].onTrail++; }
    });
    node.appendChild(h("div", { class: "scroll" }, h("table", { class: "data" }, [h("thead", null, h("tr", null, [h("th", null, "Folder"), h("th", { class: "n" }, "Files"), h("th", { class: "n" }, "Declarations"), h("th", { class: "n" }, "On a trail")])),
      h("tbody", null, order.map(function (k) { var b = by[k]; return h("tr", null, [h("td", { class: "mono" }, h("a", { href: "code.html#" + b.first }, k)), h("td", { class: "n" }, String(b.files)), h("td", { class: "n" }, String(b.scopes)), h("td", { class: "n" }, String(b.onTrail))]); }))])));
  }
  function renderExcluded(node) {
    var idx = index();
    node.appendChild(h("div", { class: "scroll" }, h("table", { class: "data" }, [h("thead", null, h("tr", null, [h("th", null, "File"), h("th", { class: "n" }, "Size"), h("th", null, "Why it is left out")])),
      h("tbody", null, idx.excluded.map(function (x) { return h("tr", null, [h("td", { class: "mono" }, x.path), h("td", { class: "n" }, V.fmt.bytes(x.bytes)), h("td", null, x.reason)]); }))])));
  }
  function renderCommits(node) {
    var idx = index(), commits = (idx.head && idx.head.commits) || [];
    node.appendChild(h("ul", { class: "decisions" }, [h("li", null, [h("span", { class: "id" }, "base"), "the base: " + (idx.base.label || idx.base.short)])].concat(commits.map(function (c) {
      return h("li", null, [h("span", { class: "id" }, c.short + " · " + c.date), c.subject]);
    })).concat(idx.head.first ? [h("li", null, [h("span", { class: "id" }, "this tree"), "the repository's first commit: every file in it, the history one commit, its phases recorded in the ledger"])]
               : idx.head.dirty ? [h("li", null, [h("span", { class: "id" }, "working tree"), "uncommitted edits on top of " + idx.head.short + ", included here"])] : [])));
  }

  function mount() {
    if (!index()) { var main = document.querySelector("main.page"); if (main) main.insertBefore(h("p", { class: "fig-error" }, "The data was not built. Run docs/site/src/build.py, then reload."), main.firstChild); return; }
    [["request", renderRequest], ["stepper", renderStepper], ["counts", renderCounts], ["checks", renderChecks], ["tests", renderTests], ["decisions", renderDecisions],
     ["questions", renderQuestions], ["also", renderAlso], ["excluded-list", renderExcluded], ["commits", renderCommits]].forEach(function (x) {
      var node = document.getElementById(x[0]);
      if (node) x[1](node);
    });
  }
  function selfCheck() {
    var idx = index(), out = [];
    if (!idx) return [{ name: "the overview's data is loaded", ok: false }];
    var layers = Array.prototype.map.call(document.querySelectorAll("#system .layer"), function (g) { return g.getAttribute("data-layer"); });
    var missing = [];
    idx.trails.forEach(function (t) { t.steps.forEach(function (st) { Object.keys(layersOf(st)).forEach(function (l) { if (layers.indexOf(l) < 0) missing.push(l); }); }); });
    out.push({ name: "the picture has a box for every layer any trail lights", ok: !missing.length && layers.length === 8, detail: missing.join(", ") || layers.join(", ") });
    out.push({ name: "the picker has a button per trail, and the stepper one per step of the chosen trail",
               ok: document.querySelectorAll("#stepper .trail-pick button").length === idx.trails.length && document.querySelectorAll("#stepper button.step").length === trailOf(state.trail).steps.length });
    // The grid lines up: a column's cells share a left edge, and a row's cells a top and a height.
    var cells = Array.prototype.map.call(document.querySelectorAll("#stepper .tg-cell"), function (b) { var r = b.getBoundingClientRect(); return { b: b, r: r }; });
    var misaligned = cells.filter(function (c) {
      return cells.some(function (d) {
        var sameCol = d.b.getAttribute("data-col") === c.b.getAttribute("data-col"), sameRow = d.b.getAttribute("data-sec") === c.b.getAttribute("data-sec") && d.b.getAttribute("data-row") === c.b.getAttribute("data-row");
        return (sameCol && Math.abs(d.r.left - c.r.left) > 0.5) || (sameRow && (Math.abs(d.r.top - c.r.top) > 0.5 || Math.abs(d.r.height - c.r.height) > 0.5));
      });
    });
    out.push({ name: "the picker's cells line up: a column's cells start at one left edge, a row's share one top and one height",
               ok: cells.length === idx.trails.length && !misaligned.length, detail: misaligned.map(function (c) { return c.b.getAttribute("data-trail"); }).join(", ") });
    var bad = (run().decisions || []).filter(function (d) { return d.file && !d.retired && !firstFileOf(d.file) && !excluded(d.file); });
    var retired = (run().decisions || []).filter(function (d) { return d.retired; });
    out.push({ name: "every decision in force names a file in the change; a retired one names its date", ok: !bad.length && retired.every(function (d) { return /^\d{4}-\d\d-\d\d$/.test(d.retired); }),
               detail: bad.map(function (d) { return d.id + " → " + d.file; }).join(", ") || retired.length + " retired" });
    out.push({ name: "the ledger's commands all carry an exit code", ok: (run().commands || []).every(function (c) { return typeof c.exit === "number"; }) });
    return out;
  }
  V.overview = { mount: mount, selfCheck: selfCheck, light: light };
  if (document.getElementById("system")) V.extraChecks.push({ name: "overview", run: selfCheck });
})();
