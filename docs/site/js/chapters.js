/*
 * The chapters' live parts: the shipped bundle's tables, read from the manifest the build re-hashed, and the check
 * that holds a chapter's hand-written list to the code it describes: the result JSON's keys against ResultJSON.swift.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */
(function () {
  "use strict";
  var V = window.VeilGarde, h = V.h;

  function facts() { return (V.data().index || {}).facts || {}; }
  function frozen() { var f = facts().frozenRoles; return f ? f.roles : null; }
  function short(sha) { return sha ? sha.slice(0, 12) + "…" : ""; }
  function table(head, rows) {
    return h("div", { class: "scroll" }, h("table", { class: "data" }, [h("thead", null, h("tr", null, head.map(function (t) { return h("th", { class: /^(Bytes|Size)$/.test(t) ? "n" : null }, t); }))), h("tbody", null, rows)]));
  }

  function artifacts(node) {
    var m = facts().manifest, roles = frozen();
    if (!m) { node.appendChild(h("p", { class: "fig-error" }, "The build found no manifest.json under Sources/VeilGardeInference/Resources.")); return; }
    node.appendChild(table(["Role", "File", "Bytes", "SHA-256", "Frozen", "Re-hashed by the build"], m.artifacts.map(function (a) {
      return h("tr", null, [h("td", { class: "mono" }, a.head ? "head · " + a.head : a.role), h("td", { class: "mono" }, a.file), h("td", { class: "n" }, V.fmt.int(a.bytes)),
        h("td", { class: "mono", title: a.sha256 }, short(a.sha256)), h("td", null, roles ? (roles.indexOf(a.role) >= 0 ? "frozen" : "") : "not read"),
        h("td", null, h("span", { class: "status " + (a.matches ? "ok" : "bad") }, a.matches ? "matches" : a.onDisk ? "differs" : "missing"))]);
    })));
  }
  function weights(node) {
    var m = facts().manifest;
    if (!m) return;
    node.appendChild(table(["Role", "File", "Bytes", "SHA-256", "Recorded from"], (m.weights || []).map(function (w) {
      return h("tr", null, [h("td", { class: "mono" }, w.role), h("td", { class: "mono" }, w.file), h("td", { class: "n" }, V.fmt.int(w.bytes)), h("td", { class: "mono", title: w.sha256 }, short(w.sha256)), h("td", null, w.source || "")]);
    })));
  }
  function history(node) {
    var m = facts().manifest;
    if (!m) return;
    node.appendChild(h("ul", { class: "decisions" }, (m.history || []).map(function (e) {
      return h("li", null, [h("span", { class: "id" }, (e.date || "").slice(0, 10) + " · " + e.kind + " · " + e.slot), e.note || ""]);
    })));
  }

  function fileText(path) { var m = V.model(), f = m && m.byPath[path]; return f && f.loaded ? f.text : null; }
  function checks() {
    var out = [];
    var keys = document.querySelectorAll("[data-json-key]");
    if (keys.length) {
      var src = fileText("Sources/VeilGardeCore/Result/ResultJSON.swift"), missing = [];
      Array.prototype.forEach.call(keys, function (el) { var k = el.getAttribute("data-json-key"); if (!src || src.indexOf('"' + k + '"') < 0) missing.push(k); });
      out.push({ name: "every result JSON key this page lists is written by ResultJSON.swift", ok: !!src && !missing.length, detail: missing.join(", ") || keys.length + " keys" });
    }
    var m2 = facts().manifest;
    if (document.getElementById("artifacts")) {
      out.push({ name: "the build re-hashed every shipped artifact and each matches its manifest", ok: !!m2 && m2.artifacts.every(function (a) { return a.matches; }), detail: m2 ? m2.artifacts.length + " artifacts" : "no manifest" });
      out.push({ name: "the build read the frozen roles from Artifact.swift", ok: !!frozen(), detail: (frozen() || []).join(", ") });
    }
    return out;
  }

  function mount() {
    [["artifacts", artifacts], ["weights", weights], ["history", history]].forEach(function (x) { var node = document.getElementById(x[0]); if (node && !node.childElementCount) x[1](node); });
  }
  V.chapters = { mount: mount, checks: checks };
  V.extraChecks.push({ name: "chapter", run: checks });
})();
