// The page for web/app.py. No libraries and nothing fetched from anywhere
// else: the computers this runs on have no network.
"use strict";

const $ = (id) => document.getElementById(id);
const RTL = ["ar", "he", "fa", "ur"];
const TEXT_TYPES = ["txt", "text", "md", "markdown"];

let config = null;
let doc = null; // what /api/inspect said about the chosen document
let polling = null;

function el(tag, props, ...children) {
  const node = Object.assign(document.createElement(tag), props || {});
  for (const child of children) if (child != null) node.append(child);
  return node;
}

async function api(path, options) {
  let reply;
  try {
    reply = await fetch(path, options);
  } catch (err) {
    throw new Error("The translation page's own service isn't answering. Check in Docker Desktop that its container is running.");
  }
  const body = await reply.json().catch(() => ({}));
  if (!reply.ok) throw new Error(body.error || `The request failed (HTTP ${reply.status}).`);
  return body;
}

function show(id, on) { $(id).hidden = !on; }
function engine() { return document.querySelector("input[name=engine]:checked")?.value; }

function languageName(code) {
  if (!code || code === "auto") return "detected automatically";
  const all = [...config.libre.languages, ...config.gemma.languages];
  const found = all.find((l) => l.code === code);
  return found ? found.name : code;
}

// ------------------------------------------------------------------- start-up
async function start() {
  config = await api("/api/config");
  $("status").replaceChildren(
    el("li", { className: config.gemma.ok ? "up" : "", title: config.gemma.error || "" },
      config.gemma.ok ? "TranslateGemma ready" : "TranslateGemma not available"),
    el("li", { className: config.libre.ok ? "up" : "" },
      config.libre.ok ? "LibreTranslate ready" : "LibreTranslate not available"),
  );
  const types = [...new Set([...config.gemma.formats, ...config.libre.formats])].join(" ");
  $("formats").textContent = types;
  $("model").replaceChildren(...config.gemma.models.map((m) => el("option", { value: m, selected: m === config.gemma.default_model }, m)));
  show("model-field", false);
  $("folder").textContent = config.folder;
  $("about").textContent = config.tool;
  $("help-folder").textContent = config.folder;
  const down = !config.gemma.ok || !config.libre.ok;
  const message = !config.gemma.ok && config.gemma.error ? config.gemma.error
    : !config.libre.ok ? "LibreTranslate isn't answering."
      : "Both translators are ready on this computer.";
  $("help-status").className = "box " + (down ? "bad" : "good");
  $("help-status").replaceChildren(
    el("span", { className: "msg-label" }, down ? "The page is reporting:" : "Right now:"),
    el("span", {}, message),
  );
  $("help-build").textContent = "Version " + config.version
    + (config.build ? " \u2014 " + config.build : " \u2014 running from source, no build recorded.");
  loadHistory();
}

// ---------------------------------------------------------- choosing a document
function selectTab(text) {
  $("tab-file").setAttribute("aria-selected", String(!text));
  $("tab-text").setAttribute("aria-selected", String(text));
  show("by-file", !text);
  show("by-text", text);
}
$("tab-file").onclick = () => selectTab(false);
$("tab-text").onclick = () => selectTab(true);

$("help-open").onclick = () => $("help").showModal();
$("help-close").onclick = () => $("help").close();
$("help").addEventListener("click", (e) => { if (e.target === $("help")) $("help").close(); });

// Clicking a path can't open Finder from a page served over http, so offer the
// next best thing: copy it for Finder's Go to Folder (Cmd-Shift-G).
function wireCopy(buttonId, getText) {
  const btn = $(buttonId);
  if (!btn) return;
  btn.onclick = async () => {
    try {
      await navigator.clipboard.writeText(getText());
      const was = btn.textContent;
      btn.textContent = "Copied \u2713";
      setTimeout(() => { btn.textContent = was; }, 1500);
    } catch { /* clipboard blocked; the path stays on screen to copy by hand */ }
  };
}
wireCopy("folder-copy", () => config.folder);
wireCopy("help-folder-copy", () => config.folder);

$("file").onchange = () => { if ($("file").files[0]) inspect({ file: $("file").files[0] }); };
$("use-text").onclick = () => inspect({ text: $("text").value });
const drop = $("drop");
for (const type of ["dragenter", "dragover"]) drop.addEventListener(type, (e) => { e.preventDefault(); drop.classList.add("over"); });
for (const type of ["dragleave", "drop"]) drop.addEventListener(type, (e) => { e.preventDefault(); drop.classList.remove("over"); });
drop.addEventListener("drop", (e) => { if (e.dataTransfer.files[0]) inspect({ file: e.dataTransfer.files[0] }); });

async function inspect(what) {
  const form = new FormData();
  if (what.file) form.append("file", what.file);
  if (what.text != null) form.append("text", what.text);
  if (what.upload) form.append("upload", what.upload);
  if (what.encoding) form.append("encoding", what.encoding);
  show("pick-error", false);
  show("result", false);
  show("progress", false);
  $("summary").hidden = false;
  $("summary").textContent = "Reading the document…";
  try {
    doc = await api("/api/inspect", { method: "POST", body: form });
  } catch (err) {
    doc = null;
    show("summary", false);
    show("choose", false);
    $("pick-error").textContent = err.message;
    show("pick-error", true);
    return;
  }
  if (!what.upload) $("encoding").value = "";
  renderSummary();
  renderChoices();
}

function renderSummary() {
  const facts = [];
  if (doc.gemma.ok) facts.push(`${doc.gemma.words.toLocaleString()} words`);
  if (doc.detected) {
    const sure = doc.detected.confidence != null ? ` (confidence ${Math.round(doc.detected.confidence)} out of 100)` : "";
    facts.push(`looks like ${languageName(doc.detected.code)}${sure}`);
  }
  $("summary").replaceChildren(
    el("div", { className: "file" }, doc.pasted ? "Pasted text" : doc.name),
    el("div", { className: "hint" }, facts.join(" · ")),
  );
}

function renderChoices() {
  const able = { gemma: config.gemma.ok && doc.gemma.ok, libre: config.libre.ok && doc.libre.ok };
  const why = {
    gemma: !config.gemma.ok ? (config.gemma.error || "TranslateGemma isn't available.") : (doc.gemma.error || ""),
    libre: !config.libre.ok ? "LibreTranslate isn't answering." : (doc.libre.error || ""),
  };
  for (const name of ["gemma", "libre"]) {
    const card = $("card-" + name);
    const radio = card.querySelector("input");
    radio.disabled = !able[name];
    card.classList.toggle("off", !able[name]);
    card.querySelector(".why-not").textContent = able[name] ? "" : why[name];
  }
  const current = engine();
  const pick = able[current] ? current : able.gemma ? "gemma" : able.libre ? "libre" : null;
  for (const radio of document.querySelectorAll("input[name=engine]")) radio.checked = radio.value === pick;
  show("encoding-field", TEXT_TYPES.includes(doc.ext) && (doc.gemma.need_encoding || $("encoding").value !== ""));
  show("choose", true);
  $("go").disabled = !pick;
  renderLanguages();
}

function renderLanguages() {
  const which = engine();
  const keep = { source: $("source").value || "auto", target: $("target").value || "en" };
  let languages;
  if (which === "libre") {
    languages = config.libre.languages.map((l) => ({ ...l, common: true }));
  } else {
    languages = config.gemma.languages;
  }
  const label = (l) => `${l.name} (${l.code})`;
  const options = (wanted) => {
    const common = languages.filter((l) => l.common).sort((a, b) => a.name.localeCompare(b.name));
    const rest = languages.filter((l) => !l.common);
    const make = (l) => el("option", { value: l.code, selected: l.code === wanted }, label(l));
    if (!rest.length) return common.map(make);
    return [el("optgroup", { label: "Most used" }, ...common.map(make)), el("optgroup", { label: "All languages" }, ...rest.map(make))];
  };
  const detected = doc && doc.detected ? `Detect automatically: ${languageName(doc.detected.code)}` : "Detect automatically";
  $("source").replaceChildren(el("option", { value: "auto", selected: keep.source === "auto" }, detected), ...options(keep.source));
  $("target").replaceChildren(...options(keep.target));
  if (!$("target").value) $("target").selectedIndex = 0;
  show("model-field", which === "gemma" && config.gemma.models.length > 1);
  renderAdvice();
}

// What the user guide says about the combinations that give trouble, said at
// the moment someone is about to choose one.
function renderAdvice() {
  const which = engine();
  const chosen = $("source").value;
  const from = (chosen === "auto" ? doc.detected?.code : chosen) || "";
  const rtl = RTL.includes(from.split("-")[0]);
  const lines = [];
  if (which === "gemma") {
    for (const note of doc.gemma.notes || []) lines.push(note);
    if (doc.ext === "pdf" && rtl) {
      lines.push("Text taken out of Arabic and Hebrew PDFs is often damaged: letters swapped inside words, punctuation moved to the wrong end of a line. In testing, the translation of an Arabic PDF lost a heading and was vaguer than the translation of the same text from Word. If there is a Word version of this document, use that.");
    }
    if (chosen === "auto" && !doc.detected) {
      lines.push("The language couldn't be detected because LibreTranslate, which does the detecting, isn't answering. Choose the language the document is written in.");
    }
    if (chosen === "auto" && doc.detected && doc.detected.confidence != null && doc.detected.confidence < 60) {
      lines.push(`The language was detected with low confidence. If this isn't ${languageName(doc.detected.code)}, choose the language yourself: TranslateGemma is told which language it is reading and translates badly when told wrong.`);
    }
    if (/27b/.test($("model").value)) {
      lines.push("The 27b model is slower and has not proved better. In testing it left out part of an Arabic text that 12b translated in full, and gave different results on a second run. Check anything it produces against 12b.");
    }
    if (doc.gemma.ok && doc.gemma.pieces > 1) {
      lines.push(`This will go to the model in ${doc.gemma.pieces} pieces.`);
    }
  } else if (which === "libre") {
    if (doc.ext === "pdf" && rtl) {
      lines.push("LibreTranslate scrambles Arabic and Hebrew PDFs badly enough that the result can't be relied on at all. Use a Word version of the document, or TranslateGemma.");
    } else if (doc.ext === "pdf") {
      lines.push("LibreTranslate translates a PDF one printed line at a time, so sentences that run over a line come out broken. A Word version of the document gives a much better result.");
    }
    if (["ar", "he"].includes(from.split("-")[0])) {
      lines.push("Arabic and Hebrew are LibreTranslate's weakest languages. In testing it dropped whole passages and changed a figure. Use TranslateGemma for anything that matters.");
    }
  }
  $("advice").replaceChildren(...lines.map((line) => el("li", null, line)));
  show("advice", lines.length > 0);
}

for (const radio of document.querySelectorAll("input[name=engine]")) radio.onchange = renderLanguages;
$("source").onchange = renderAdvice;
$("model").onchange = renderAdvice;
$("encoding").onchange = () => inspect({ upload: doc.upload, encoding: $("encoding").value });

// ----------------------------------------------------------------- translating
$("go").onclick = () => translate(false);

async function translate(force, withEngine) {
  show("go-error", false);
  const ask = {
    upload: doc.upload,
    engine: withEngine || engine(),
    model: $("model").value,
    source: $("source").value,
    target: $("target").value,
    encoding: $("encoding").value,
    force,
  };
  let job;
  try {
    job = await api("/api/translate", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(ask) });
  } catch (err) {
    $("go-error").textContent = err.message;
    show("go-error", true);
    return;
  }
  show("choose", false);
  show("result", false);
  show("progress", true);
  $("cancel").disabled = false;
  $("cancel").onclick = async () => { $("cancel").disabled = true; await api(`/api/jobs/${job.id}/cancel`, { method: "POST" }).catch(() => {}); };
  follow(job);
}

function follow(job) {
  clearTimeout(polling);
  renderProgress(job);
  if (["done", "failed", "cancelled"].includes(job.state)) {
    show("progress", false);
    if (job.state === "done") {
      renderResult(job.result, job);
      loadHistory();
    } else {
      show("choose", true);
      if (job.state === "failed") {
        $("go-error").textContent = job.error;
        show("go-error", true);
      }
    }
    return;
  }
  polling = setTimeout(async () => {
    try {
      follow(await api(`/api/jobs/${job.id}`));
    } catch (err) {
      show("progress", false);
      show("choose", true);
      $("go-error").textContent = err.message;
      show("go-error", true);
    }
  }, 1000);
}

function renderProgress(job) {
  const took = job.seconds ? ` · ${clock(job.seconds)}` : "";
  let text;
  if (job.state === "queued") {
    text = job.waiting ? `Waiting for ${job.waiting} earlier translation${job.waiting > 1 ? "s" : ""} to finish` : "Starting";
    $("bar").removeAttribute("value");
  } else if (job.engine === "gemma" && job.pieces) {
    text = `TranslateGemma is on part ${job.piece} of ${job.pieces}${took}`;
    $("bar").max = job.pieces;
    $("bar").value = job.piece - 1;
  } else {
    text = (job.engine === "gemma" ? "TranslateGemma is reading the document" : "LibreTranslate is translating the document") + took;
    $("bar").removeAttribute("value");
  }
  $("progress-text").textContent = text;
  $("progress-hint").textContent = job.engine === "gemma"
    ? "Stopping takes effect when the part being translated is finished."
    : "LibreTranslate can't be stopped part-way; this is usually quick.";
  show("cancel", job.engine === "gemma");
}

function clock(seconds) {
  const s = Math.round(seconds);
  return s < 60 ? `${s} s` : `${Math.floor(s / 60)} min ${s % 60} s`;
}

// --------------------------------------------------------------------- results
function lines(text) { return text.split("\n").filter((line) => line.trim() !== ""); }

// What the dropped-text check did, in the words the provenance file records
function checkedLine(side) {
  const did = side.dropped_text_check;
  if (!did) return "Dropped-text check: not run. This translation was made before the page had it.";
  if (did.startsWith("not checked")) {
    return `Dropped-text check: ${did}. Nothing compared this translation's length with the original's.`;
  }
  return `Dropped-text check: ${did}. It compares lengths and sentence counts. It can miss a short sentence, and knows nothing about whether the words are right.`;
}

function renderResult(result, job) {
  const side = result.provenance;
  const box = $("result");
  const parts = [];
  parts.push(el("h2", null, "Translation"));
  if (job && job.reused) {
    parts.push(el("p", { className: "box warn" },
      `This document was already translated this way on ${side.translated_at_utc.replace("T", " ").replace("Z", " UTC")}. This is that translation; nothing was run again. `,
      el("button", { type: "button", onclick: () => translate(true, side.engine) }, "Translate it again")));
  }
  if (side.warnings && side.warnings.length) {
    parts.push(el("div", { className: "box bad" },
      el("strong", null, "Check this translation against the original before using it."),
      el("ul", null, ...side.warnings.map((w) => el("li", null, w))),
      el("span", { className: "hint" }, "A warning marks a place where the translation has a different shape from the original, or is much shorter or longer than it should be. Sometimes the model has only joined or split lines; sometimes text is missing or repeated. Go to that place in the original, and try the other engine on it."
        + (/\.pdf\./i.test(result.output) ? " With a PDF, the commonest harmless cause is a paragraph that ran over a page: the PDF gives it as two pieces and the model joins them up again." : ""))));
  }
  if (side.extraction_notes && side.extraction_notes.length) {
    parts.push(el("ul", { className: "box warn" }, ...side.extraction_notes.map((n) => el("li", null, n))));
  }
  const link = (name, label) => el("li", null,
    el("a", { href: "/files/" + encodeURIComponent(name), download: name }, label),
    el("span", { className: "path" }, name));
  parts.push(el("ul", { className: "files" },
    link(result.output, "Download the translation"),
    side.source_text_file ? link(side.source_text_file, "The text that was translated") : null,
    link(result.output + ".provenance.json", "How it was made (provenance)")));
  parts.push(el("p", { className: "hint" }, "These files are already saved on this computer, in ", el("code", null, result.folder)));

  const from = side.source_lang === "auto" ? "language detected by LibreTranslate" : languageName(side.source_lang);
  const facts = [
    side.engine_detail,
    `${from}${side.source_lang_detected ? " (detected)" : ""} into ${languageName(side.target_lang)}`,
    side.pieces > 1 ? `${side.pieces} pieces` : null,
    job && !job.reused && job.seconds ? `took ${clock(job.seconds)}` : null,
  ].filter(Boolean);
  parts.push(el("p", { className: "facts" }, facts.join(" · ")));
  parts.push(el("p", { className: "hint" }, checkedLine(side)));

  if (result.text != null && result.source_text != null) {
    const theirs = lines(result.source_text);
    const ours = lines(result.text);
    if (theirs.length === ours.length) {
      parts.push(el("table", { className: "pairs" },
        el("thead", null, el("tr", null, el("th", null, "Original"), el("th", null, "Translation"))),
        el("tbody", null, ...theirs.map((line, i) => el("tr", null, el("td", { dir: "auto" }, line), el("td", { dir: "auto" }, ours[i]))))));
    } else {
      parts.push(el("p", { className: "hint" }, `The original has ${theirs.length} lines and the translation ${ours.length}, so they are shown whole and not side by side line for line.`));
      parts.push(el("div", { className: "columns" },
        el("pre", { dir: "auto" }, result.source_text),
        el("pre", { dir: "auto" }, result.text)));
    }
  } else if (result.text != null) {
    parts.push(el("div", { className: "columns" }, el("pre", { dir: "auto" }, result.text)));
  } else if (side.engine === "libre") {
    parts.push(el("p", { className: "hint" }, "LibreTranslate gives no sign of its own when it leaves a sentence out. Read the translation beside the original before relying on it."));
  }

  const actions = el("div", { className: "actions" });
  if (job && doc) {
    const other = side.engine === "gemma" ? "libre" : "gemma";
    const able = other === "gemma" ? config.gemma.ok && doc.gemma.ok : config.libre.ok && doc.libre.ok;
    if (able) {
      actions.append(el("button", { type: "button", onclick: () => {
        for (const radio of document.querySelectorAll("input[name=engine]")) radio.checked = radio.value === other;
        renderLanguages();
        show("result", false);
        show("choose", true);
        $("choose").scrollIntoView({ behavior: "smooth" });
      } }, `Try it with ${other === "gemma" ? "TranslateGemma" : "LibreTranslate"}`));
    }
    actions.append(el("button", { type: "button", onclick: () => { show("result", false); show("choose", true); } }, "Change the settings"));
  }
  actions.append(el("button", { type: "button", onclick: () => {
    doc = null; $("file").value = ""; $("text").value = "";
    for (const id of ["result", "choose", "summary"]) show(id, false);
    $("pick").scrollIntoView({ behavior: "smooth" });
  } }, "Translate something else"));
  parts.push(actions);

  box.replaceChildren(...parts);
  show("result", true);
  box.scrollIntoView({ behavior: "smooth" });
}

async function loadHistory() {
  let past;
  try { past = await api("/api/history"); } catch (err) { return; }
  $("history-rows").replaceChildren(...past.translations.map((row) => el("tr", null,
    el("td", null, el("a", { href: "#", onclick: async (e) => {
      e.preventDefault();
      try { renderResult(await api("/api/result?output=" + encodeURIComponent(row.output)), null); } catch (err) { alert(err.message); }
    } }, row.output)),
    el("td", null, row.source_lang === "auto" ? "auto" : languageName(row.source_lang)),
    el("td", null, languageName(row.target_lang)),
    el("td", null, row.engine_detail || row.engine),
    el("td", null, (row.translated_at_utc || "").replace("T", " ").replace("Z", "")),
    el("td", { className: "flag" }, row.warnings ? `${row.warnings} warning${row.warnings > 1 ? "s" : ""}` : ""))));
  show("history", past.translations.length > 0);
}

start().catch((err) => {
  $("pick-error").textContent = err.message;
  show("pick-error", true);
});
