/*
 * The ask orb: on every page, an orb at the bottom right that opens into a mini chat about what the reader is
 * looking at. On an explorer it reads what the page's provider gives it, VeilGarde.explorer.provider(): on the
 * change explorer the selected declaration, its code, its change and its places on the trails, with a map of the
 * whole change and four tools that read the rest from the data the page already holds; on the ML explorer the same
 * declaration with its ML step, a map that opens with the shipped models' facts, and a fifth tool that reads a whole
 * step. The provider's voice holds the words each explorer uses. On any other page, the page's visible text. It
 * calls Mistral's chat API from the browser, and only when
 * the reader sends a message, with the key src/askkey.py copied from this Mac into local/ask.js (gitignored), or,
 * on a copy of the site with no such file (another engineer's), the reader's own key, asked for in a dialog when the
 * chat opens and kept in this browser. `?ask-key=none` on any page shows the site as that engineer sees it.
 * Replies are built from text nodes, never as HTML. VeilGarde.ask.transport can be replaced, so the checks never
 * call the network.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */
(function () {
  "use strict";
  var V = window.VeilGarde, h = V.h;
  var ENDPOINT = "https://api.mistral.ai/v1/chat/completions";
  var DEFAULTS = { provider: "mistral", model: "mistral-large-4", reasoning: "none" };
  var HISTORY = 12;
  var ROUNDS = 5; // rounds of reading before the model must answer
  var PAGE_CAP = 9000;
  var SYSTEM = [
    "You are the guide on VeilGarde's site, a static explorer of one change to the VeilGarde repository and the chapters that explain it.",
    "VeilGarde is a detector for AI-generated images, with a crop-robust watermark, as one Swift package you can train and run on a Mac. " +
    "It has two lanes. The detector reads what an image depicts, from a frozen DINOv2 embedding, and whether a camera captured its pixels, from the capture signature, through one fusion head; specialist heads then add evidence under a stacked combiner, and one verdict comes out. " +
    "The watermark reads the warp residual: every 32×32 tile is warped through 16 fixed homographies and back, each tile's fragility becomes four ordinal bits, and a crop or a re-encode is matched against the signature.",
    "Answer the reader's question about what they are looking at, described below.",
    "- Give the answer first, in plain words and short sentences. Most answers fit in a few sentences.",
    "- Ground every claim about VeilGarde in what follows. When it does not say, say so instead of guessing.",
    "- Never invent numbers, results, names or line numbers.",
    "- Point at code as File.swift:line, with the line numbers given.",
    "- Use `backticks` for identifiers, and a fenced block only to show code."
  ].join("\n");
  /** The words the orb uses on a page that is not an explorer, or on an explorer with nothing selected. */
  var PAGE_VOICE = {
    reading: "", mapHeading: "", selectedHeading: "What the reader is looking at:",
    starters: ["Explain this page in two sentences.", "What should I understand first here?"],
    emptyNote: "Ask about this page. The answer reads what the page shows.",
    placeholder: "Ask about this page", readTitle: "Open it in the change explorer", aboutPrefix: "this page: "
  };

  var state = { messages: [], busy: null, tried: false, loading: false, pasted: "", config: null };
  var ui = {};
  var waiting = [];

  // MARK: What the reader is looking at

  /** The explorer mounted on this page, as the orb reads it: { kind, set, page, voice, context, map, tools, tool }, or null. */
  function explorerHere() { return V.explorer && V.explorer.provider ? V.explorer.provider() : null; }
  function pageProvider() { return { kind: "page", set: null, page: "code.html", voice: PAGE_VOICE, context: pageContext, map: null, tools: null, tool: null }; }
  /** What the chat reads now: the page's explorer and its selection, or, with no explorer or nothing selected, the page. */
  function reading() {
    var p = explorerHere(), ctx = p ? p.context() : null;
    if (!ctx) { p = pageProvider(); ctx = p.context(); }
    return { p: p, ctx: ctx };
  }
  function context() { return reading().ctx; }
  function pageContext() {
    var main = document.querySelector("main.page") || document.body;
    var title = ((main.querySelector("h1") || {}).textContent || document.title).trim();
    var text = (main.innerText || main.textContent || "").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    if (text.length > PAGE_CAP) text = text.slice(0, PAGE_CAP) + "\n[the page goes on]";
    return { kind: "page", label: title, text: "The reader is on the page \"" + title + "\" (" + (location.pathname.split("/").pop() || "index.html") + "). What it shows:\n\n" + text };
  }

  // MARK: The key

  var PASTED = "your key, kept in this browser";
  /** `?ask-key=none`: behave as a copy of the site without this Mac's key (no local/ask.js), as another engineer sees it. */
  var NO_LOCAL = /(?:^|&)ask-key=none(?:&|$)/.test(location.search.slice(1));

  /** Calls done with the key and model: this Mac's (local/ask.js, loaded once, on first use), else the reader's own, else null. */
  function withConfig(done) {
    var local = NO_LOCAL ? null : V.data().ask;
    if (local && local.key) return done(Object.assign({}, DEFAULTS, local));
    if (state.loading) { waiting.push(done); return; }
    if (!state.tried && !NO_LOCAL) {
      state.tried = true;
      state.loading = true;
      waiting.push(done);
      var s = document.createElement("script");
      var settle = function () { state.loading = false; var all = waiting; waiting = []; all.forEach(withConfig); };
      s.src = V.root() + "local/ask.js";
      s.onload = settle;
      s.onerror = function () { s.remove(); settle(); };
      document.head.appendChild(s);
      return;
    }
    state.tried = true;
    var key = state.pasted || V.storage.get("ask:key", "");
    done(key ? Object.assign({}, DEFAULTS, { key: key, source: PASTED }) : null);
  }
  function forgetKey() { state.pasted = ""; V.storage.remove("ask:key"); }

  /** The dialog that asks for the reader's own key: opened when the chat opens and finds none, or when Mistral refuses one. */
  function askForKey(message) {
    if (!ui.dialog) {
      ui.keyField = h("input", { type: "password", autocomplete: "off", spellcheck: "false", autofocus: "", placeholder: "Your Mistral API key",
                                 "aria-label": "Your Mistral API key", "aria-describedby": "ask-key-why" });
      ui.keyNote = h("p", { class: "ask-key-note", role: "alert", hidden: true });
      var later = h("button", { type: "button", class: "ask-key-later" }, "Not now");
      var form = h("form", { method: "dialog" }, [
        h("h2", { id: "ask-key-title" }, [h("span", { class: "ask-dot", "aria-hidden": "true" }), "Use your own Mistral key"]),
        h("p", { id: "ask-key-why" }, "The chat asks Mistral about what you are reading. This copy of the site has no key of its own, so it needs yours."),
        ui.keyField, ui.keyNote,
        h("p", { class: "ask-key-fine" }, ["The key stays in this browser and goes only to Mistral's API, with each question you send. You can make one under API keys at ",
          h("span", { class: "ask-key-url" }, "console.mistral.ai"), "."]),
        h("div", { class: "ask-key-actions" }, [later, h("button", { type: "submit", class: "ask-key-use" }, "Use this key")])
      ]);
      ui.dialog = h("dialog", { class: "ask-key", "aria-labelledby": "ask-key-title" }, [form]);
      form.addEventListener("submit", function (e) {
        e.preventDefault();
        var key = ui.keyField.value.trim();
        if (!key || /\s/.test(key)) { note(key ? "A key has no spaces in it." : "Paste a key first."); ui.keyField.focus(); return; }
        state.pasted = key;
        V.storage.set("ask:key", key);
        ui.keyField.value = "";
        ui.dialog.close();
      });
      later.addEventListener("click", function () { ui.dialog.close(); });
      ui.dialog.addEventListener("close", function () {
        renderLog(function () {
          var target = !ui.input.disabled ? ui.input : ui.panel.hidden ? ui.orb : ui.panel.querySelector(".ask-setup button") || ui.close;
          target.focus();
        });
      });
      ui.dialog.addEventListener("keydown", function (e) { e.stopPropagation(); });
      document.body.appendChild(ui.dialog);
    }
    function note(text) { ui.keyNote.textContent = text || ""; ui.keyNote.hidden = !text; }
    note(message);
    if (!ui.dialog.open) ui.dialog.showModal();
    ui.keyField.focus();
  }

  // MARK: Talking to Mistral

  /** Sends one request, calls onDelta with each piece of text as it streams, and resolves to { content, toolCalls }. Replaceable for tests. */
  function mistral(body, key, onDelta, signal) {
    var content = "", calls = [];
    return fetch(ENDPOINT, {
      method: "POST", signal: signal,
      headers: { "Content-Type": "application/json", Accept: "text/event-stream", Authorization: "Bearer " + key },
      body: JSON.stringify(body)
    }).then(function (res) {
      if (!res.ok) return res.text().then(function (t) { var e = new Error(t.slice(0, 300)); e.status = res.status; throw e; });
      var reader = res.body.getReader(), decoder = new TextDecoder(), buffer = "";
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) return { content: content, toolCalls: calls.filter(function (c) { return c && c["function"] && c["function"].name; }) };
          buffer += decoder.decode(r.value, { stream: true });
          var lines = buffer.split("\n");
          buffer = lines.pop();
          lines.forEach(function (line) {
            line = line.trim();
            if (line.indexOf("data:") !== 0) return;
            var data = line.slice(5).trim();
            if (!data || data === "[DONE]") return;
            try {
              var delta = ((JSON.parse(data).choices || [])[0] || {}).delta || {}, c = delta.content;
              if (Array.isArray(c)) c = c.filter(function (p) { return p && p.type === "text"; }).map(function (p) { return p.text; }).join("");
              if (c) { content += c; onDelta(c); }
              (delta.tool_calls || []).forEach(function (tc) {
                var known = tc.id ? calls.findIndex(function (x) { return x.id === tc.id; }) : -1;
                var at = typeof tc.index === "number" ? tc.index : known >= 0 ? known : tc.id ? calls.length : Math.max(0, calls.length - 1);
                var call = calls[at] || (calls[at] = { id: "", type: "function", "function": { name: "", arguments: "" } });
                if (tc.id) call.id = tc.id;
                if (tc["function"]) {
                  if (tc["function"].name) call["function"].name = tc["function"].name;
                  if (tc["function"].arguments) call["function"].arguments += typeof tc["function"].arguments === "string" ? tc["function"].arguments : JSON.stringify(tc["function"].arguments);
                }
              });
            } catch (e) { /* a partial line: the next read completes it */ }
          });
          return pump();
        });
      }
      return pump();
    });
  }

  function canRead(p) { return !!(p && p.tools && p.map && p.tool); }
  /** The first request for a question: the house rules, then on an explorer its reading rules, its map, its tools and
   *  the selection, each in the explorer's own words; elsewhere the page. */
  function request(config, ctx, p) {
    p = p || reading().p;
    var code = ctx.kind === "code" && canRead(p);
    var system = code ? SYSTEM + "\n" + p.voice.reading + "\n\n" + p.voice.mapHeading + "\n\n" + p.map() + "\n\n" + p.voice.selectedHeading + "\n\n" + ctx.text
                      : SYSTEM + "\n\n" + PAGE_VOICE.selectedHeading + "\n\n" + ctx.text;
    var body = {
      model: config.model, stream: true, temperature: 0.3, max_tokens: 900,
      messages: [{ role: "system", content: system }].concat(
        state.messages.filter(function (m) { return m.role === "user" || (m.role === "assistant" && m.text); }).slice(-HISTORY)
          .map(function (m) { return { role: m.role, content: m.text }; }))
    };
    if (code) { body.tools = p.tools; body.tool_choice = "auto"; }
    if (config.reasoning) body.reasoning_effort = config.reasoning;
    return body;
  }

  function send(text) {
    text = (text || "").trim();
    if (!text || state.busy) return;
    withConfig(function (config) {
      if (!config) { renderLog(); askForKey(); return; }
      var now = reading(), ctx = now.ctx, p = now.p;
      state.messages.push({ role: "user", text: text, about: ctx.label });
      var reply = { role: "assistant", text: "", draft: "", reads: [], pending: true };
      state.messages.push(reply);
      ui.input.value = "";
      fitInput();
      var controller = window.AbortController ? new AbortController() : null;
      state.busy = controller || {};
      renderLog();
      var queued = false;
      function paint() { if (!queued) { queued = true; requestAnimationFrame(function () { queued = false; paintLast(); }); } }
      function onDelta(piece) { reply.draft += piece; reply.pending = false; paint(); }
      var body = request(config, ctx, p), rounds = 0, refused = false;
      // A round that asks to read runs those reads here, from the data this page holds, and asks again; its own words are dropped.
      function round() {
        return V.ask.transport(body, config.key, onDelta, controller && controller.signal).then(function (got) {
          var calls = (got && got.toolCalls) || [];
          if (!calls.length || !body.tools) { reply.text += reply.draft; reply.draft = ""; return; }
          reply.draft = "";
          rounds++;
          body.messages.push({ role: "assistant", content: (got && got.content) || "", tool_calls: calls });
          calls.forEach(function (call) {
            var out = p.tool(call["function"].name, call["function"].arguments);
            if (out.read && !reply.reads.some(function (r) { return r.label === out.read.label; })) reply.reads.push(out.read);
            body.messages.push({ role: "tool", name: call["function"].name, tool_call_id: call.id, content: out.text });
          });
          reply.pending = true;
          paint();
          if (rounds >= ROUNDS) body.tool_choice = "none";
          return round();
        });
      }
      Promise.resolve().then(round).then(function () {
        if (!reply.text) reply.error = "Mistral sent no answer. Ask again, or rephrase.";
      }, function (e) {
        if (e && e.name === "AbortError") reply.note = "Stopped.";
        else if (e && e.status === 401 && config.source === PASTED) { forgetKey(); reply.error = "Mistral refused that key, so it was forgotten."; refused = true; }
        else if (e && e.status === 401) reply.error = "Mistral refused this Mac's key. Run scripts/site.command again to refresh it.";
        else if (e && e.status === 429) reply.error = "Mistral is limiting this key for now. Try again in a moment.";
        else if (e && e.status) reply.error = "Mistral answered " + e.status + ": " + e.message;
        else reply.error = "No answer from Mistral. The chat needs the network; the rest of the site does not.";
      }).then(function () {
        reply.pending = false;
        state.busy = null;
        renderLog();
        if (refused) askForKey("Mistral refused the last key. Check it, or make a new one, and paste it again.");
      });
    });
  }

  // MARK: Showing replies, as text

  /** A place in the code: on an explorer, a link on this page, which holds every file; elsewhere, into the change explorer. */
  function linkFor(hash) { return explorerHere() ? hash : V.root() + "code.html" + hash; }
  function readTitle() { var x = explorerHere(); return x ? x.voice.readTitle : PAGE_VOICE.readTitle; }
  function codeHref(name, line) {
    var m = V.model(), hit = m ? m.files.filter(function (f) { return f.name === name; }) : [];
    if (hit.length !== 1) return null;
    return linkFor("#" + hit[0].path + ":" + line);
  }
  function inline(s) {
    var out = [];
    s.split(/(`[^`\n]+`|\*\*[^*\n]+\*\*|\b[\w+-]+\.(?:swift|py|sh|md|js|json|html|css):\d+\b)/).forEach(function (t) {
      if (!t) return;
      if (/^`[^`]+`$/.test(t)) out.push(h("code", null, t.slice(1, -1)));
      else if (/^\*\*[^*]+\*\*$/.test(t)) out.push(h("b", null, t.slice(2, -2)));
      else if (/\.\w+:\d+$/.test(t)) {
        var href = codeHref(t.split(":")[0], t.split(":")[1]);
        out.push(href ? h("a", { href: href, title: readTitle() }, t) : t);
      } else out.push(t);
    });
    return out;
  }
  function markup(text) {
    var frag = document.createDocumentFragment();
    text.split("```").forEach(function (block, i) {
      if (i % 2) {
        var lang = (block.match(/^([\w+-]*)\n/) || [])[1] || "swift", code = block.replace(/^[\w+-]*\n/, "").replace(/\n$/, ""), st = {};
        var pre = h("pre", { class: "ask-code" });
        code.split("\n").forEach(function (line, k) { if (k) pre.appendChild(document.createTextNode("\n")); pre.appendChild(h("span", null, V.highlight(line, lang === "swift" || lang === "python" || lang === "shell" ? lang : "swift", st))); });
        frag.appendChild(pre);
        return;
      }
      block.split(/\n{2,}/).forEach(function (para) {
        para = para.replace(/^\n+|\n+$/g, "");
        if (!para.trim()) return;
        var lines = para.split("\n");
        if (lines.every(function (l) { return /^\s*([-*•]|\d+[.)])\s+/.test(l); })) {
          var list = h(/^\s*\d/.test(lines[0]) ? "ol" : "ul");
          lines.forEach(function (l) { list.appendChild(h("li", null, inline(l.replace(/^\s*([-*•]|\d+[.)])\s+/, "")))); });
          frag.appendChild(list);
        } else if (/^#{1,4}\s/.test(lines[0]) && lines.length === 1) {
          frag.appendChild(h("p", null, h("b", null, inline(lines[0].replace(/^#+\s*/, "")))));
        } else {
          var p = h("p");
          lines.forEach(function (l, k) { if (k) p.appendChild(h("br")); p.appendChild(h("span", null, inline(l))); });
          frag.appendChild(p);
        }
      });
    });
    return frag;
  }
  function bubble(m) {
    if (m.role === "user") return h("div", { class: "ask-msg user" }, m.text);
    var div = h("div", { class: "ask-msg bot" + (m.error ? " error" : "") });
    if (m.reads && m.reads.length) div.appendChild(h("p", { class: "ask-reads" }, ["Read ", m.reads.map(function (r, i) {
      var href = r.href ? linkFor(r.href) : null;
      return [i ? " · " : "", href ? h("a", { href: href, title: readTitle() }, r.label) : h("span", null, r.label)];
    })]));
    var shown = (m.text || "") + (m.draft || "");
    if (m.pending && !shown) div.appendChild(h("span", { class: "ask-wait" }, m.reads && m.reads.length ? "Reading more…" : "Reading…"));
    if (shown) div.appendChild(markup(shown));
    if (m.error) div.appendChild(h("p", null, m.error));
    if (m.note) div.appendChild(h("p", { class: "ask-aside" }, m.note));
    return div;
  }
  function paintLast() {
    var last = ui.log.lastElementChild, m = state.messages[state.messages.length - 1];
    if (!last || !m) return;
    last.replaceWith(bubble(m));
    ui.log.scrollTop = ui.log.scrollHeight;
  }
  function renderLog(after) {
    var log = ui.log;
    log.textContent = "";
    withConfig(function (config) {
      state.config = config;
      log.textContent = "";
      if (!config) {
        // No key: the conversation so far stays, a refused key's reply among it, above the way back to the dialog.
        state.messages.forEach(function (m) { log.appendChild(bubble(m)); });
        log.appendChild(setup());
        syncControls();
        if (after) after();
        return;
      }
      var voice = reading().p.voice, lastAbout = null;
      if (!state.messages.length) {
        log.appendChild(h("p", { class: "ask-msg note" }, voice.emptyNote));
        log.appendChild(h("div", { class: "ask-starters" }, voice.starters.map(function (q) {
          var b = h("button", { type: "button" }, q);
          b.addEventListener("click", function () { send(q); });
          return b;
        })));
      }
      state.messages.forEach(function (m) {
        if (m.role === "user" && m.about !== lastAbout) { log.appendChild(h("p", { class: "ask-msg note" }, "About " + m.about)); lastAbout = m.about; }
        log.appendChild(bubble(m));
      });
      ui.foot.textContent = "";
      ui.foot.appendChild(document.createTextNode(config.model + " via Mistral, with " + (config.source || "a key") + ". It reads what you see here, and it can be wrong."));
      if (config.source === PASTED) {
        var forget = h("button", { type: "button", class: "ask-link" }, "Forget the key");
        forget.addEventListener("click", function () { forgetKey(); renderLog(); askForKey(); });
        ui.foot.appendChild(document.createTextNode(" "));
        ui.foot.appendChild(forget);
      }
      log.scrollTop = log.scrollHeight;
      syncControls();
      if (after) after();
    });
  }
  /** What the panel shows while there is no key: a way back to the dialog. */
  function setup() {
    var enter = h("button", { type: "button" }, "Enter your key…");
    enter.addEventListener("click", function () { askForKey(); });
    ui.foot.textContent = "";
    return h("div", { class: "ask-setup" }, [
      h("p", null, "The chat needs a Mistral key: your own, kept in this browser. On the Mac that holds the project's key, scripts/site.command opens the site with it."),
      h("div", { class: "ask-keyrow" }, [enter])
    ]);
  }
  /** Forgets the conversation, stopping an answer in progress. Each question reads the page afresh, so nothing else carries over. */
  function newChat() {
    if (state.busy && state.busy.abort) state.busy.abort();
    state.messages = [];
    renderLog(function () { if (!ui.input.disabled) ui.input.focus(); });
  }
  function syncControls() {
    var busy = !!state.busy, ready = !!state.config;
    ui.reset.disabled = !state.messages.length;
    ui.send.textContent = busy ? "Stop" : "Send";
    ui.send.setAttribute("aria-label", busy ? "Stop the answer" : "Send");
    ui.input.disabled = !ready;
    ui.send.disabled = !ready;
  }

  // MARK: The orb and the panel

  function updateAbout() {
    if (!ui.about) return;
    var now = reading();
    ui.about.textContent = "About " + (now.p.voice.aboutPrefix || "") + now.ctx.label;
    ui.input.placeholder = now.p.voice.placeholder;
  }
  function fitInput() { ui.input.style.height = "auto"; ui.input.style.height = Math.min(ui.input.scrollHeight + 2, 128) + "px"; }
  function open() {
    ui.panel.hidden = false;
    ui.orb.hidden = true;
    ui.orb.setAttribute("aria-expanded", "true");
    updateAbout();
    renderLog(function () {
      if (!state.config) { askForKey(); return; }
      ui.input.focus();
    });
  }
  function close() {
    ui.panel.hidden = true;
    ui.orb.hidden = false;
    ui.orb.setAttribute("aria-expanded", "false");
    ui.orb.focus();
  }
  function mount() {
    if (ui.orb || !document.body || document.body.classList.contains("embed")) return;
    ui.orb = h("button", { type: "button", class: "ask-orb", "aria-label": "Ask about what you are reading", title: "Ask about what you are reading",
                           "aria-expanded": "false", "aria-controls": "ask-panel" });
    ui.about = h("span", { class: "ask-about" });
    ui.close = h("button", { type: "button", class: "ask-close", "aria-label": "Close the chat", title: "Close (Esc)" }, "×");
    ui.reset = h("button", { type: "button", class: "ask-new", title: "Forget this conversation and start again", disabled: true }, "New chat");
    ui.log = h("div", { class: "ask-log", "aria-live": "polite" });
    ui.input = h("textarea", { rows: 1, "aria-label": "Your question", spellcheck: "true" });
    ui.send = h("button", { type: "submit" }, "Send");
    ui.foot = h("p", { class: "ask-foot" });
    var form = h("form", { class: "ask-form" }, [ui.input, ui.send]);
    ui.panel = h("section", { class: "ask", id: "ask-panel", role: "dialog", "aria-label": "Ask about what you are reading", hidden: true }, [
      h("div", { class: "ask-head" }, [h("span", { class: "ask-dot", "aria-hidden": "true" }), h("span", { class: "ask-title" }, [h("b", null, "Ask"), ui.about]), ui.reset, ui.close]),
      ui.log, form, ui.foot
    ]);
    ui.orb.addEventListener("click", open);
    ui.close.addEventListener("click", close);
    ui.reset.addEventListener("click", newChat);
    ui.panel.addEventListener("keydown", function (e) { if (e.key === "Escape") { close(); e.preventDefault(); } e.stopPropagation(); });
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (state.busy) { if (state.busy.abort) state.busy.abort(); return; }
      send(ui.input.value);
    });
    ui.input.addEventListener("keydown", function (e) { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); if (form.requestSubmit) form.requestSubmit(); else form.dispatchEvent(new Event("submit")); } });
    ui.input.addEventListener("input", fitInput);
    window.addEventListener("veilgarde:context", updateAbout);
    document.body.appendChild(ui.orb);
    document.body.appendChild(ui.panel);
  }

  V.ask = {
    transport: mistral, mount: mount, context: context, provider: function () { return reading().p; },
    open: function () { if (ui.orb) open(); }, close: function () { if (ui.orb) close(); }, newChat: function () { if (ui.orb) newChat(); },
    askForKey: function (message) { if (ui.orb) askForKey(message); }, noLocalKey: NO_LOCAL,
    request: function (ctx) { var now = reading(); return request(DEFAULTS, ctx || now.ctx, now.p); },
    selfCheck: function () {
      var now = reading(), ctx = now.ctx, p = now.p, body = request(DEFAULTS, ctx, p), reads = ctx.kind === "code" && canRead(p);
      return [
        { name: "the chat reads what the reader is looking at", ok: !!(ctx && ctx.text && ctx.text.length > 40 && ctx.text.length < 40000), detail: ctx ? ctx.kind + ", " + ctx.text.length + " characters" : "" },
        { name: "a request carries the context and the house rules, and nothing calls the network until a message is sent",
          ok: body.messages[0].role === "system" && body.messages[0].content.indexOf(ctx.text.slice(0, 60)) >= 0 && !state.messages.length && body.stream === true && body.reasoning_effort === "none" },
        { name: "on an explorer, a request also carries its map and the tools that read the rest, in the explorer's own words",
          ok: !reads || (body.tools && body.tools.length >= 4 && body.tools.length === p.tools.length && body.messages[0].content.indexOf(p.voice.mapHeading) >= 0),
          detail: reads ? Math.round(body.messages[0].content.length / 1000) + " thousand characters of system message, " + body.tools.length + " tools" : "not on an explorer" }
      ];
    }
  };
  V.extraChecks.push({ name: "ask", run: V.ask.selfCheck });
})();
