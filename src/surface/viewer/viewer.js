"use strict";

const $ = (id) => document.getElementById(id);
const svgNS = "http://www.w3.org/2000/svg";
const number = new Intl.NumberFormat();
const dates = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
const typeOrder = ["project", "person", "organization", "concept", "software", "document", "repository", "task", "decision", "event", "code", "environment", "ai_model", "change", "dataset", "problem", "run", "session", "other"];
const colors = ["#90dfac", "#f6c582", "#b6a3eb", "#84cbdc", "#edaa9a", "#d4d996", "#9ab6ef", "#eda9c3", "#a4d1b8", "#edbd99", "#96b5c3", "#d9a6df", "#d4ab89", "#a9c1f2", "#b0cb88", "#f89992", "#9acbd0", "#b5b5d1", "#b2c1b7"];
const nodeCap = 140, edgeCap = 360;
const requests = new Map();
const canvas = $("map");
const ctx = canvas.getContext("2d");
let overview = null, graph = { nodes: [], edges: [], truncated: false }, nodes = new Map();
let selected = null, root = null, session = { mode: "anonymous" }, credential = "";
let width = 1, height = 1, scale = 1, fitScale = 1, ox = 0, oy = 0, frame = 0;
let hover = null, hoverAt = null, drag = null, searchTimer = 0, labels = [];
let activeFacts = null, overviewRequest = 0, mapRequest = 0, entityRequest = 0, searchRequest = 0;

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function svg(tag, attrs) {
  const e = document.createElementNS(svgNS, tag);
  for (const [key, value] of Object.entries(attrs)) e.setAttribute(key, value);
  return e;
}

function icon(name) {
  const e = svg("svg", { class: "icon", "aria-hidden": "true" });
  e.append(svg("use", { href: "#i-" + name }));
  return e;
}

function typeIndex(type) {
  const i = typeOrder.indexOf(type);
  return i === -1 ? colors.length - 1 : i;
}

function pretty(value) {
  return String(value || "other").replaceAll("_", " ");
}

function dot(type) {
  return el("span", "dot tint-" + typeIndex(type));
}

function stored() {
  try { return sessionStorage.getItem("graf.viewer.token") || ""; }
  catch { return ""; }
}

function storeToken(value) {
  credential = value;
  try {
    if (value) sessionStorage.setItem("graf.viewer.token", value);
    else sessionStorage.removeItem("graf.viewer.token");
  } catch {}
}

function abort(key) {
  requests.get(key)?.abort();
  requests.delete(key);
}

function filters() {
  const out = {};
  for (const key of ["project", "type", "relation"]) if ($(key).value) out[key] = $(key).value;
  if ($("confidence").value) out.min_confidence = Number($("confidence").value);
  if ($("as-of").value) out.as_of = new Date($("as-of").value).toISOString();
  if ($("history").checked) out.include_history = true;
  return out;
}

async function api(key, extra, token = credential) {
  abort(key);
  const controller = new AbortController();
  requests.set(key, controller);
  const headers = new Headers({ Accept: "application/json" });
  if (token) headers.set("Authorization", "Bearer " + token);
  const init = { headers, signal: controller.signal, credentials: "omit", mode: "same-origin", redirect: "error", cache: "no-store" };

  if (key !== "session") {
    init.method = "POST";
    headers.set("Content-Type", "application/json");
    init.body = JSON.stringify({ ...filters(), ...extra });
  }

  try {
    const res = await fetch("/v1/graph/" + key, init);
    if (!res.ok) {
      const err = new Error(res.status === 404 ? "That entity is no longer available." : "The hub could not complete this request (" + res.status + ").");
      err.status = res.status;
      throw err;
    }
    return await res.json();
  } finally {
    if (requests.get(key) === controller) requests.delete(key);
  }
}

function showNotice(text) {
  $("notice").textContent = text;
  $("notice").hidden = !text;
}

function setSession(s) {
  session = s;
  $("identity").textContent = s.mode === "tailscale" ? (s.login || "Tailnet identity") : s.mode === "bearer" ? "Token session" : s.mode === "local" ? "Local session" : "Sign in";
  $("session").title = s.mode === "tailscale" ? "Tailnet session: " + (s.login || "authenticated") : $("identity").textContent;
}

function openAuth(message = "") {
  const logged = session.mode !== "anonymous";
  $("auth-title").textContent = logged ? "Workspace access" : "Connect to the hub";
  $("auth-description").textContent = logged ? "Connected as " + $("identity").textContent + ". Graph exploration is read-only." : "Use your hub’s bearer token to open its graph. The token stays in this browser tab.";
  $("token-label").hidden = logged;
  $("connect").hidden = logged;
  $("disconnect").hidden = !credential;
  $("auth-error").textContent = message;
  if (!$("auth").open) $("auth").showModal();
  if (!logged) $("token").focus();
}

function failed(err) {
  if (err.name === "AbortError") return;
  if (err.status === 401 || err.status === 403) {
    signedOut();
    openAuth("A valid hub token is required.");
  } else {
    showNotice(err.message || "The hub is unavailable.");
  }
}

function formatDate(value, fallback = "Open") {
  if (value == null || value === "") return fallback;
  let v = value;
  if (typeof v === "number") v = Math.abs(v) > 1e14 ? v / 1000 : Math.abs(v) < 1e11 ? v * 1000 : v;
  const d = new Date(v);
  return Number.isFinite(d.valueOf()) ? dates.format(d) : String(value);
}

function options(id, values, empty) {
  const select = $(id), current = select.value;
  const choices = new Set(values || []);
  if (current) choices.add(current);
  select.replaceChildren(new Option(empty, ""), ...Array.from(choices).sort().map(x => new Option(id === "project" ? x : pretty(x), x)));
  select.value = current;
}

function section(title, count) {
  const box = el("section"), head = el("h3", "subhead", title);
  if (count != null) head.append(el("span", "count", number.format(count)));
  box.append(head);
  return box;
}

function renderOverview() {
  $("side-title").textContent = "Graph index";
  $("side-code").hidden = false;
  $("close-inspector").hidden = true;
  const body = $("side-body");
  body.replaceChildren();
  body.scrollTop = 0;
  if (!overview) {
    body.append(el("p", "muted", session.mode === "anonymous" ? "Sign in to view the graph index." : "Loading the graph index…"));
    return;
  }

  const types = [...overview.types].filter(t => t.count > 0).sort((a, b) => b.count - a.count);
  const typeSection = section("Entity composition", types.length);
  const strip = svg("svg", { viewBox: "0 0 100 2", preserveAspectRatio: "none", class: "strip", "aria-hidden": "true" });
  const total = types.reduce((sum, t) => sum + t.count, 0);
  let x = 0;
  for (const t of types) {
    const w = (t.count / total) * 100;
    strip.append(svg("rect", { x, y: 0, width: Math.max(0.1, w - .4), height: 2, fill: colors[typeIndex(t.type)] }));
    x += w;
  }
  if (total) typeSection.append(strip);

  for (const t of types.slice(0, 5)) {
    const item = el("button", "type-row");
    item.title = "Filter by " + pretty(t.type);
    item.append(dot(t.type), el("span", "", pretty(t.type)), el("span", "row-meta", number.format(t.count)));
    item.onclick = () => { $("type").value = t.type; togglePanel("filters", true); applyFilters(); };
    typeSection.append(item);
  }
  if (types.length > 5) {
    const more = el("button", "text-button", "Browse all " + types.length + " types");
    more.onclick = () => { togglePanel("filters", true); $("type").focus(); };
    typeSection.append(more);
  }
  if (!types.length) typeSection.append(el("p", "muted", "No matching entities."));

  const hubSection = section("Top hubs");
  for (const [i, hub] of overview.hubs.slice(0, 5).entries()) {
    const item = el("button", "hub");
    item.append(el("span", "rank", String(i + 1).padStart(2, "0")), el("span", "row-title", hub.name), icon("arrow"));
    item.onclick = () => focusEntity(hub.id);
    hubSection.append(item);
  }
  if (!overview.hubs.length) hubSection.append(el("p", "muted", "No matching hubs."));

  const activity = section("Hub activity");
  const q = el("div", "queue");
  q.append(el("span", "", "Queue depth"), el("strong", "", number.format(overview.queue)));
  activity.append(q);
  for (const entry of overview.recent.slice(0, 3)) {
    const row = el("div", "recent");
    row.append(el("span", "", "Commit #" + entry.seq), el("time", "", formatDate(entry.committed_at)));
    activity.append(row);
  }
  body.append(typeSection, hubSection, activity);
}

function updateMetrics(data) {
  $("entity-count").textContent = data ? number.format(data.entities) : "—";
  $("fact-count").textContent = data ? number.format(data.facts) : "—";
  $("type-count").textContent = data ? number.format(data.types.filter(t => t.count > 0).length) : "—";
}

async function loadOverview() {
  const rev = ++overviewRequest;
  try {
    const data = await api("overview");
    if (rev !== overviewRequest) return;
    overview = data;
    updateMetrics(data);
    options("type", data.types.map(t => t.type), "All types");
    options("project", data.projects, "All projects");
    options("relation", data.relations, "All relations");
    if (!selected) renderOverview();
  } catch (err) {
    if (rev === overviewRequest) failed(err);
  }
}

function profile(data, factId, before) {
  const { entity, aliases, facts, merges } = data;
  const body = $("side-body"), top = el("section"), type = el("span", "tag");
  type.append(dot(entity.type), el("span", "", pretty(entity.type)));
  top.append(type, el("h3", "profile-name", entity.name));
  if (entity.summary) top.append(el("p", "profile-copy", entity.summary));
  if (entity.description && entity.description !== entity.summary) top.append(el("p", "profile-copy", entity.description));
  if (aliases.length) {
    const row = el("div", "aliases");
    row.setAttribute("aria-label", "Aliases");
    for (const name of aliases) row.append(el("span", "tag", name));
    top.append(row);
  }
  const expand = el("button", "expand");
  expand.append(icon("expand"), el("span", "", "Expand neighborhood"));
  expand.onclick = () => loadMap(entity.id, true);
  top.append(expand);

  const page = facts.slice(0, 64);
  const list = section("Related facts", page.length);
  if (before || data.next_before) {
    const nav = el("nav", "fact-pages");
    nav.setAttribute("aria-label", "Fact pages");
    if (before) {
      const newest = el("button", "text-button", "← Newest facts");
      newest.onclick = () => inspect(entity.id);
      nav.append(newest);
    }
    if (data.next_before) {
      const older = el("button", "text-button", "Older facts →");
      older.onclick = () => inspect(entity.id, null, data.next_before);
      nav.append(older);
    }
    list.append(nav);
  }
  let target = null;
  for (const [i, f] of page.entries()) {
    const details = el("details", "fact"), summary = el("summary");
    const outgoing = f.subject_id === entity.id;
    summary.append(el("span", "muted", outgoing ? "OUT → " : "IN ← "), el("span", "", pretty(f.relation)), el("span", "fact-text", f.text));
    details.append(summary);
    const meta = el("dl", "meta");
    const endpoint = (label, id, name) => {
      const dd = el("dd");
      if (id && id !== entity.id) {
        const link = el("button", "", name || id);
        link.onclick = () => focusEntity(id);
        dd.append(link);
      } else dd.textContent = name || id || "—";
      meta.append(el("dt", "", label), dd);
    };
    endpoint("Subject", f.subject_id, f.subject_name);
    endpoint("Object", f.object_id, f.object_name ?? f.object_value);
    for (const [label, value] of [
      ["Qualifier", f.qualifier],
      ["Valid", formatDate(f.valid_from, "Unbounded") + " → " + formatDate(f.valid_to)],
      ["Known", formatDate(f.known_from, "Unbounded") + " → " + formatDate(f.known_to)],
      ["Ended", f.end_kind], ["Confidence", f.confidence == null ? null : Math.round(f.confidence * 100) + "%"],
      ["Scope", f.scope], ["Project", f.project], ["Author", f.author], ["Rationale", f.rationale],
    ]) {
      if (value != null && value !== "") meta.append(el("dt", "", label), el("dd", "", value));
    }
    details.append(meta);
    for (const e of f.evidence) {
      const citation = [e.kind, e.entry_id].filter(Boolean).join(" · ");
      if (e.quote?.trim()) {
        const quote = el("blockquote", "", e.quote);
        if (citation) quote.append(el("cite", "", citation));
        details.append(quote);
      } else if (citation) details.append(el("p", "source-ref", citation));
    }
    details.open = factId ? f.id === factId : i === 0;
    if (factId === f.id) target = details;
    list.append(details);
  }
  if (!facts.length) list.append(el("p", "muted", "No facts match the current filters."));
  body.replaceChildren(top, list);

  if (merges.length) {
    const log = section("Merge history", merges.length);
    for (const m of merges) {
      const item = el("div", "merge", m.reason || "Entity merged");
      item.append(el("p", "muted", m.from_id + " → " + m.into_id), el("time", "row-meta", formatDate(m.created_at)));
      log.append(item);
    }
    body.append(log);
  }
  body.scrollTop = 0;
  if (target || before) body.scrollTop = (target || list).getBoundingClientRect().top - body.getBoundingClientRect().top - 8;
}

async function inspect(id, factId = null, before = null) {
  if (!id) return;
  const rev = ++entityRequest;
  selected = id;
  activeFacts = factId;
  $("side-title").textContent = "Entity inspector";
  $("side-code").hidden = true;
  $("close-inspector").hidden = false;
  $("side-body").replaceChildren(el("p", "muted", "Loading entity…"));
  paint();
  try {
    const params = { id };
    if (factId) params.fact_id = factId;
    if (before) params.before = before;
    const data = await api("entity", params);
    if (rev !== entityRequest) return;
    profile(data, factId, before);
  } catch (err) {
    if (rev === entityRequest && err.name !== "AbortError") {
      $("side-body").replaceChildren(el("p", "muted", "Entity details are unavailable."));
      failed(err);
    }
  }
}

function closeInspector() {
  ++entityRequest;
  abort("entity");
  selected = null;
  activeFacts = null;
  renderOverview();
  paint();
}

function focusEntity(id, factId = null) {
  if (!id) return;
  closeSearch();
  inspect(id, factId);
  loadMap(id, false);
}

function togglePanel(id, open) {
  const trigger = $(id === "filters" ? "filters-button" : "time-button");
  $(id).hidden = !open;
  trigger.setAttribute("aria-expanded", String(open));
}

function applyFilters() {
  const applied = filters();
  const count = Object.keys(applied).filter(k => k !== "as_of" && k !== "include_history").length;
  $("filter-count").textContent = count;
  $("filter-count").hidden = !count;
  $("time-dot").hidden = !applied.as_of && !applied.include_history;
  closeSearch();
  showNotice("");
  if (session.mode === "anonymous") return;
  loadOverview();
  loadMap(root, false);
  if (selected) inspect(selected, activeFacts);
}

function closeSearch() {
  clearTimeout(searchTimer);
  ++searchRequest;
  abort("search");
  $("results").hidden = true;
}

async function runSearch(query) {
  closeSearch();
  if (!query || session.mode === "anonymous") return;
  const rev = searchRequest, results = $("results");
  results.replaceChildren(el("p", "muted", "Searching…"));
  results.hidden = false;
  try {
    const data = await api("search", { query });
    if (rev !== searchRequest) return;
    results.replaceChildren();
    for (const [title, items] of [["Entities", data.entities], ["Facts", data.facts]]) {
      if (!items.length) continue;
      results.append(el("h3", "subhead", title));
      for (const hit of items) {
        const item = el("button");
        item.append(dot(hit.type), el("span", "row-title", hit.name || hit.text), el("span", "row-meta", pretty(hit.type || hit.relation)));
        item.onclick = () => focusEntity(hit.subject_id || hit.id, hit.subject_id ? hit.id : null);
        results.append(item);
      }
    }
    if (!results.childElementCount) results.append(el("p", "muted", "No matching entities or facts."));
  } catch (err) {
    if (rev === searchRequest && err.name !== "AbortError") {
      results.replaceChildren(el("p", "muted", "Search is unavailable."));
      failed(err);
    }
  }
}

function setGraph(data, append, id) {
  const ordered = new Map(), kept = new Map();
  const anchor = id && data.nodes.find(n => n.id === id);
  if (anchor) ordered.set(anchor.id, anchor);
  for (const n of [...data.nodes, ...(append ? graph.nodes : [])]) {
    if (!ordered.has(n.id)) ordered.set(n.id, n);
  }
  let limited = ordered.size > nodeCap || data.truncated || (append && graph.truncated);
  const list = [...ordered.values()].slice(0, nodeCap);
  nodes = new Map(list.map(n => [n.id, { ...n, degree: 0, neighbors: new Set() }]));

  for (const e of [...data.edges, ...(append ? graph.edges : [])]) {
    const a = nodes.get(e.subject_id), b = nodes.get(e.object_id);
    if (!a || !b || kept.has(e.id)) continue;
    if (kept.size >= edgeCap) { limited = true; break; }
    kept.set(e.id, e);
    a.neighbors.add(b.id);
    b.neighbors.add(a.id);
    a.degree++;
    b.degree++;
  }
  graph = { nodes: list, edges: [...kept.values()], truncated: limited };
  root = id;
  hover = null;
  $("map-reset").hidden = !root;
  $("map-mode").textContent = root ? nodes.get(root)?.name || "Focused neighborhood" : "Hub neighborhood";
  $("plot-state").textContent = "No entities match this view.";
  $("plot-state").hidden = list.length > 0;
  $("shown").textContent = number.format(list.length) + " nodes · " + number.format(kept.size) + " edges" + (limited ? " · Capped" : "");
  const entries = [...nodes.values()].sort((a, b) => a.name.localeCompare(b.name)).map(n => {
    const item = el("button");
    item.append(dot(n.type), el("span", "row-title", n.name), el("span", "row-meta", pretty(n.type)));
    item.onclick = () => inspectFromMap(n.id);
    return item;
  });
  $("node-list").replaceChildren(...entries);
  layout();
  fit();
}

async function loadMap(id, append) {
  const rev = ++mapRequest;
  const params = { hops: Number($("hops").value) };
  if (id) params.id = id;
  $("plot-state").textContent = "Mapping neighborhood…";
  $("plot-state").hidden = false;
  try {
    const data = await api("neighborhood", params);
    if (rev !== mapRequest) return;
    setGraph(data, append, id);
  } catch (err) {
    if (rev === mapRequest && err.name !== "AbortError") {
      setGraph({ nodes: [], edges: [], truncated: false }, false, null);
      $("plot-state").textContent = "The neighborhood could not be loaded.";
      failed(err);
    }
  }
}

function layout() {
  if (!nodes.size) return;
  const ranked = [...nodes.values()].sort((a, b) => b.degree - a.degree || a.id.localeCompare(b.id));
  const center = nodes.get(root) || ranked[0], seen = new Set(), points = [];
  for (const start of [center, ...ranked]) {
    if (seen.has(start.id)) continue;
    const queue = [start];
    seen.add(start.id);
    for (let i = 0; i < queue.length; i++) {
      const n = queue[i];
      points.push(n);
      for (const id of n.neighbors) {
        if (seen.has(id)) continue;
        seen.add(id);
        queue.push(nodes.get(id));
      }
    }
  }

  const aspect = Math.min(1.9, Math.max(.8, width / height));
  for (const [i, n] of points.entries()) {
    const theta = i * 2.399963 + .4, r = Math.sqrt(i) * 68;
    n.x = Math.cos(theta) * r * aspect;
    n.y = Math.sin(theta) * r;
    n.radius = 4.5 + Math.min(8, Math.sqrt(n.degree) * 1.7);
    n.dx = n.dy = 0;
  }

  const pairs = [];
  for (const n of points) for (const id of n.neighbors) if (id > n.id) pairs.push([n, nodes.get(id)]);
  for (let step = 0; step < 85; step++) {
    for (const n of points) {
      n.dx = -n.x * .009 / aspect;
      n.dy = -n.y * .013;
    }
    for (let i = 0; i < points.length; i++) {
      const a = points[i];
      for (let j = i + 1; j < points.length; j++) {
        const b = points[j], dx = (a.x - b.x) / aspect, dy = a.y - b.y;
        const d = Math.max(1, Math.hypot(dx, dy));
        const f = (Math.min(14, 1700 / (d * d)) + Math.max(0, 71 - d) * .17) / d;
        a.dx += dx * f * aspect; a.dy += dy * f;
        b.dx -= dx * f * aspect; b.dy -= dy * f;
      }
    }
    for (const [a, b] of pairs) {
      const dx = (b.x - a.x) / aspect, dy = b.y - a.y, d = Math.max(1, Math.hypot(dx, dy));
      const f = (d - 95) * .038 / d;
      a.dx += dx * f * aspect; a.dy += dy * f;
      b.dx -= dx * f * aspect; b.dy -= dy * f;
    }
    const speed = 1 - .68 * step / 85;
    for (const n of points) {
      n.x += Math.max(-18, Math.min(18, n.dx)) * speed;
      n.y += Math.max(-18, Math.min(18, n.dy)) * speed;
    }
  }
}

function fit() {
  let x1 = 0, y1 = 0, x2 = 0, y2 = 0;
  if (nodes.size) {
    const list = [...nodes.values()];
    x1 = Math.min(...list.map(n => n.x)); x2 = Math.max(...list.map(n => n.x));
    y1 = Math.min(...list.map(n => n.y)); y2 = Math.max(...list.map(n => n.y));
  }
  fitScale = Math.max(.02, Math.min(1.65, (width - Math.min(110, width * .22)) / Math.max(x2 - x1, 1), (height - 120) / Math.max(y2 - y1, 1)));
  scale = fitScale;
  ox = (width - (x1 + x2) * scale) / 2;
  oy = (height - (y1 + y2) * scale) / 2;
  paint();
}

function resize() {
  const r = canvas.getBoundingClientRect();
  const previousAspect = width / height;
  width = Math.max(1, r.width);
  height = Math.max(1, r.height);
  const density = Math.min(2.5, devicePixelRatio || 1);
  canvas.width = Math.round(width * density);
  canvas.height = Math.round(height * density);
  ctx.setTransform(canvas.width / width, 0, 0, canvas.height / height, 0, 0);
  if (Math.abs(previousAspect - width / height) > .12) layout();
  fit();
}

function paint() {
  if (!frame) frame = requestAnimationFrame(draw);
}

function line(x1, y1, x2, y2, stroke, weight = 1) {
  ctx.beginPath();
  ctx.moveTo(x1, y1);
  ctx.lineTo(x2, y2);
  ctx.lineWidth = weight;
  ctx.strokeStyle = stroke;
  ctx.stroke();
}

function circle(x, y, r, fill, stroke) {
  ctx.beginPath();
  ctx.arc(x, y, r, 0, 2 * Math.PI);
  if (fill) { ctx.fillStyle = fill; ctx.fill(); }
  if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = 1; ctx.stroke(); }
}

function guides() {
  const cx = width * .51, cy = height * .5;
  const base = Math.max(62, Math.min(width, height) * .22);
  for (const r of [base, base * 1.7, base * 2.4]) circle(cx, cy, r, null, "#a4d3ad10");
  ctx.setLineDash([3, 7]);
  line(0, cy, width, cy, "#b0d9b515");
  line(cx, 0, cx, height, "#b0d9b515");
  ctx.setLineDash([]);
  for (let i = 0; i < 48; i++) {
    const theta = i * Math.PI / 24, r = base * 1.7;
    const dx = Math.cos(theta), dy = Math.sin(theta);
    line(cx + dx * r, cy + dy * r, cx + dx * (r + (i % 4 ? 3 : 7)), cy + dy * (r + (i % 4 ? 3 : 7)), "#b1d4bc22");
  }
  const ax = 27, ay = height - 25;
  line(ax - 8, ay, ax + 8, ay, "#729380");
  line(ax, ay - 8, ax, ay + 8, "#729380");
  circle(ax, ay, 3, "#152720", "#729380");
}

function intersect(a, b) {
  return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
}

function draw() {
  frame = 0;
  ctx.clearRect(0, 0, width, height);
  guides();
  const focus = hover?.node?.id || selected;
  const sorted = [...nodes.values()].sort((a, b) => Number(b.id === focus) - Number(a.id === focus) || b.degree - a.degree);
  for (const n of sorted) {
    n.sx = ox + n.x * scale;
    n.sy = oy + n.y * scale;
    n.sr = Math.max(3, Math.min(17, n.radius * Math.sqrt(scale)));
  }

  for (const e of graph.edges) {
    const a = nodes.get(e.subject_id), b = nodes.get(e.object_id);
    const lit = focus === a.id || focus === b.id || hover?.edge === e;
    const stroke = lit ? "#addbb8b5" : "#769c8685";
    if (a === b) {
      circle(a.sx + a.sr, a.sy - a.sr, a.sr, null, stroke);
      continue;
    }
    line(a.sx, a.sy, b.sx, b.sy, stroke, lit ? 1.5 : 1);
    if (lit) {
      const theta = Math.atan2(b.sy - a.sy, b.sx - a.sx), x = b.sx - Math.cos(theta) * (b.sr + 4), y = b.sy - Math.sin(theta) * (b.sr + 4);
      for (const delta of [-.48, .48]) line(x, y, x - 6 * Math.cos(theta + delta), y - 6 * Math.sin(theta + delta), stroke);
    }
  }

  const occupied = [
    { x: width - 137, y: height - 51, w: 135, h: 51 },
    { x: 8, y: 6, w: $("map-mode").parentElement.offsetWidth + 16, h: 30 },
  ];
  for (const n of sorted) {
    const { sx: x, sy: y, sr: r } = n, color = colors[typeIndex(n.type)], lit = n.id === focus;
    if (x < -20 || x > width + 20 || y < -20 || y > height + 20) continue;
    if (lit || n.degree >= 3) circle(x, y, r + (lit ? 5 : 3), color + "12", color + (lit ? "c9" : "70"));
    circle(x, y, r, color + "32", color);
    circle(x, y, Math.max(2, r * .53), color);
    occupied.push({ x: x - r - 2, y: y - r - 2, w: r * 2 + 4, h: r * 2 + 4 });
  }

  ctx.font = "12px system-ui, sans-serif";
  ctx.textBaseline = "middle";
  labels = [];
  for (const n of sorted) {
    const name = n.name.length > 25 ? n.name.slice(0, 23) + "…" : n.name;
    const w = ctx.measureText(name).width + 7, h = 16, r = n.sr + 5;
    const candidates = [[n.sx - w / 2, n.sy + r], [n.sx + r, n.sy - h / 2], [n.sx - w - r, n.sy - h / 2], [n.sx - w / 2, n.sy - h - r]];
    for (const [x, y] of candidates) {
      const rect = { x, y, w, h };
      if (x < 4 || x + w > width - 4 || y < 4 || y + h > height - 4 || occupied.some(b => intersect(rect, b))) continue;
      occupied.push(rect);
      labels.push({ ...rect, node: n });
      ctx.lineJoin = "round"; ctx.lineWidth = 3.5; ctx.strokeStyle = "#192a22";
      ctx.strokeText(name, x + 3.5, y + h / 2);
      ctx.fillStyle = n.id === focus ? "#f4ffe9" : "#d4e1d6";
      ctx.fillText(name, x + 3.5, y + h / 2);
      break;
    }
  }

  if (hover && hoverAt && !drag) {
    const text = hover.node ? hover.node.name + " · " + pretty(hover.node.type) : pretty(hover.edge.relation) + (hover.edge.confidence == null ? "" : " · " + Math.round(hover.edge.confidence * 100) + "%");
    ctx.font = "12px system-ui, sans-serif";
    const w = Math.min(width - 16, ctx.measureText(text).width + 20);
    const x = Math.max(8, Math.min(width - w - 8, hoverAt.x + 10)), y = Math.max(8, Math.min(height - 35, hoverAt.y - 36));
    ctx.fillStyle = "#deeadb";
    ctx.fillRect(x, y, w, 25);
    ctx.fillStyle = "#17291d";
    ctx.fillText(text, x + 10, y + 12.5, w - 20);
  }
  $("zoom").textContent = Math.round(scale / fitScale * 100) + "%";
}

function hit(x, y) {
  for (const n of nodes.values()) if (Math.hypot(x - n.sx, y - n.sy) <= Math.max(9, n.sr + 3)) return { node: n };
  const label = labels.find(l => x >= l.x && x <= l.x + l.w && y >= l.y && y <= l.y + l.h);
  if (label) return { node: label.node };
  let nearest = null, distance = 5;
  for (const e of graph.edges) {
    const a = nodes.get(e.subject_id), b = nodes.get(e.object_id), dx = b.sx - a.sx, dy = b.sy - a.sy;
    let d;
    if (!dx && !dy) d = Math.abs(Math.hypot(x - a.sx - a.sr, y - a.sy + a.sr) - a.sr);
    else {
      const t = Math.max(0, Math.min(1, ((x - a.sx) * dx + (y - a.sy) * dy) / (dx * dx + dy * dy)));
      d = Math.hypot(x - a.sx - t * dx, y - a.sy - t * dy);
    }
    if (d < distance) { nearest = e; distance = d; }
  }
  return nearest ? { edge: nearest } : null;
}

function point(event) {
  const rect = canvas.getBoundingClientRect();
  return { x: event.clientX - rect.left, y: event.clientY - rect.top };
}

function zoomAt(factor, x = width / 2, y = height / 2) {
  const next = Math.min(Math.max(6, fitScale * 4), Math.max(fitScale * .25, scale * factor));
  ox = x - (x - ox) * next / scale;
  oy = y - (y - oy) * next / scale;
  scale = next;
  hover = null;
  paint();
}

function inspectFromMap(id) {
  inspect(id);
  if (window.matchMedia("(max-width: 710px)").matches) $("sidebar").scrollIntoView({ block: "start" });
}

canvas.onpointerdown = e => {
  if (e.button !== 0 || !e.isPrimary) return;
  const p = point(e);
  drag = { ...p, id: e.pointerId, ox, oy, moved: false };
  canvas.setPointerCapture(e.pointerId);
  hover = null;
  paint();
};
canvas.onpointermove = e => {
  const p = point(e);
  if (drag && drag.id === e.pointerId) {
    const dx = p.x - drag.x, dy = p.y - drag.y;
    if (drag.moved || Math.hypot(dx, dy) > 4) {
      drag.moved = true;
      ox = drag.ox + dx; oy = drag.oy + dy;
      canvas.dataset.cursor = "drag";
    }
  } else {
    hover = hit(p.x, p.y);
    hoverAt = p;
    canvas.dataset.cursor = hover?.node ? "pointer" : "";
  }
  paint();
};
canvas.onpointerup = e => {
  if (!drag || drag.id !== e.pointerId) return;
  const moved = drag.moved, p = point(e);
  drag = null;
  canvas.releasePointerCapture(e.pointerId);
  canvas.dataset.cursor = "";
  const target = !moved && hit(p.x, p.y);
  if (target?.node) inspectFromMap(target.node.id);
  paint();
};
canvas.onpointercancel = () => { drag = null; hover = null; canvas.dataset.cursor = ""; paint(); };
canvas.onpointerleave = () => { hover = null; paint(); };
canvas.ondblclick = e => {
  const p = point(e), target = hit(p.x, p.y);
  if (target?.node) loadMap(target.node.id, true);
};
canvas.addEventListener("wheel", e => {
  e.preventDefault();
  const p = point(e), delta = e.deltaY * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? height : 1);
  zoomAt(Math.exp(-Math.max(-180, Math.min(180, delta)) * .0018), p.x, p.y);
}, { passive: false });
canvas.onkeydown = e => {
  if (e.key === "+" || e.key === "=") zoomAt(1.25);
  else if (e.key === "-") zoomAt(.8);
  else if (e.key === "Home") fit();
  else if (e.key === "ArrowLeft") ox += 35;
  else if (e.key === "ArrowRight") ox -= 35;
  else if (e.key === "ArrowUp") oy += 35;
  else if (e.key === "ArrowDown") oy -= 35;
  else return;
  e.preventDefault();
  paint();
};

function signedOut() {
  for (const key of requests.keys()) abort(key);
  ++overviewRequest;
  ++mapRequest;
  storeToken("");
  setSession({ mode: "anonymous" });
  overview = null;
  updateMetrics(null);
  $("query").value = "";
  closeSearch();
  $("results").replaceChildren();
  $("filters").reset();
  $("time-panel").reset();
  $("hops").value = "1";
  togglePanel("filters", false);
  togglePanel("time-panel", false);
  options("project", [], "All projects");
  options("type", [], "All types");
  options("relation", [], "All relations");
  $("filter-count").hidden = $("time-dot").hidden = true;
  setGraph({ nodes: [], edges: [], truncated: false }, false, null);
  $("plot-state").textContent = "Sign in to explore this graph.";
  closeInspector();
  showNotice("");
}

async function connect(token, interactive) {
  $("connect").disabled = true;
  $("auth-error").textContent = "";
  try {
    const s = await api("session", null, token);
    if (s.mode === "anonymous") {
      signedOut();
      openAuth(token ? "The hub did not accept that token." : "");
      return;
    }
    if (!["local", "tailscale", "bearer"].includes(s.mode)) throw new Error("Unsupported hub session.");
    storeToken(s.mode === "bearer" ? token : "");
    setSession(s);
    $("token").value = "";
    if ($("auth").open) $("auth").close();
    showNotice("");
    loadOverview();
    loadMap(null, false);
  } catch (err) {
    if (err.name === "AbortError") return;
    if (err.status === 401 || err.status === 403) {
      signedOut();
      openAuth("The hub did not accept that token.");
    } else if (interactive) {
      $("auth-error").textContent = err.message || "Connection failed.";
    } else {
      signedOut();
      showNotice("The hub is unavailable. Select Sign in to retry.");
    }
  } finally {
    $("connect").disabled = false;
  }
}

$("session").onclick = () => openAuth();
$("auth-close").onclick = () => $("auth").close();
$("auth").addEventListener("close", () => { $("token").value = ""; });
$("auth-form").onsubmit = e => {
  e.preventDefault();
  const token = $("token").value.trim();
  if (token && !$("connect").disabled) connect(token, true);
};
$("disconnect").onclick = () => {
  signedOut();
  connect("", true);
};
$("theme").onclick = () => {
  document.documentElement.dataset.theme = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
};
const appearance = matchMedia("(prefers-color-scheme: dark)");
const syncTheme = () => { document.documentElement.dataset.theme = appearance.matches ? "dark" : "light"; };
syncTheme();
appearance.addEventListener("change", syncTheme);

$("filters-button").onclick = () => togglePanel("filters", $("filters").hidden);
$("time-button").onclick = () => togglePanel("time-panel", $("time-panel").hidden);
$("filters").onchange = $("time-panel").onchange = applyFilters;
$("filters").onsubmit = $("time-panel").onsubmit = e => e.preventDefault();
$("clear-filters").onclick = () => { $("filters").reset(); applyFilters(); };
$("clear-time").onclick = () => { $("time-panel").reset(); applyFilters(); };
$("hops").onchange = () => {
  if (session.mode !== "anonymous") loadMap(selected || root, false);
};
$("map-reset").onclick = () => { closeInspector(); loadMap(null, false); };
$("close-inspector").onclick = closeInspector;
$("fit").onclick = fit;
$("zoom-in").onclick = () => zoomAt(1.25);
$("zoom-out").onclick = () => zoomAt(.8);

$("query").oninput = () => {
  closeSearch();
  const q = $("query").value.trim();
  if (q) searchTimer = setTimeout(() => runSearch(q), 220);
};
$("search-form").onsubmit = e => {
  e.preventDefault();
  if (session.mode === "anonymous") openAuth();
  else runSearch($("query").value.trim());
};
document.addEventListener("pointerdown", e => {
  if (!$("results").hidden && !e.target.closest(".search-wrap")) closeSearch();
});
document.addEventListener("keydown", e => {
  if (e.key === "Escape") closeSearch();
  if (e.key === "/" && !e.ctrlKey && !e.altKey && !e.metaKey && !$("auth").open && !e.target.closest("input,select,textarea")) {
    e.preventDefault();
    $("query").focus();
  }
  if (e.key === "ArrowDown" && e.target === $("query") && !$("results").hidden) {
    e.preventDefault();
    $("results").querySelector("button")?.focus();
  }
});

new ResizeObserver(resize).observe(canvas);
resize();
connect(stored(), false);
