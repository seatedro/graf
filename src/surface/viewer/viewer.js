"use strict";

const $ = (id) => document.getElementById(id);
const svgNS = "http://www.w3.org/2000/svg";
const number = new Intl.NumberFormat();
const dates = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
const typeOrder = ["project", "person", "organization", "concept", "software", "document", "repository", "task", "decision", "event", "code", "environment", "ai_model", "change", "dataset", "problem", "run", "session", "other"];
const colors = ["#6edee1", "#efbc79", "#af98f6", "#82c7fc", "#e294c7", "#ddda8d", "#8caff6", "#f1a29c", "#97d2bb", "#e6a783", "#88b6cd", "#c79ae6", "#d1a380", "#acb5f9", "#a6cf8d", "#ef908e", "#8fcad7", "#acaccd", "#b3c2ca"];
const nodeCap = 8192, edgeCap = 16384;
const requests = new Map();
const canvas = $("map");
const ctx = canvas.getContext("2d");
let overview = null, graph = { nodes: [], edges: [], truncated: false }, nodes = new Map();
let selected = null, root = null, session = { mode: "anonymous" }, credential = "";
let nextSector = null, sector = 0;
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
  return i === -1 ? hash(type) % (colors.length - 1) : i;
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
  $("side-title").textContent = "World index";
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
  const stats = el("dl", "readout");
  for (const [label, value] of [["Facts", number.format(facts.length) + (data.next_before ? "+" : "")], ["Aliases", number.format(aliases.length)], ["Merges", number.format(merges.length)]]) {
    const cell = el("div");
    cell.append(el("dt", "", label), el("dd", "", value));
    stats.append(cell);
  }
  top.append(stats);
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
  $("hops").disabled = false;
  activeFacts = factId;
  $("side-title").textContent = "Entity inspector";
  $("side-code").hidden = true;
  $("close-inspector").hidden = false;
  $("side-body").replaceChildren(el("p", "muted", "Acquiring target…"));
  markRelated();
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
  $("hops").disabled = !root;
  activeFacts = null;
  cycling = null;
  renderOverview();
  markRelated();
  announce(null);
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
  let limited = ordered.size > nodeCap || (id && data.truncated) || (append && graph.truncated);
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
  $("hops").disabled = !root && !selected;
  hover = null;
  cycling = null;
  $("map-reset").hidden = !root && sector < 2;
  $("map-mode").textContent = root ? nodes.get(root)?.name || "Focused neighborhood" : sector > 1 ? "World map · " + sector : "World map";
  $("plot-state").textContent = root ? "No entities match this view." : "No entity links in this sector. Search to inspect individual entities.";
  $("plot-state").hidden = list.length > 0;
  $("shown").textContent = number.format(list.length) + " entities · " + number.format(kept.size) + " links" + (limited ? " · limited view" : "");
  const entries = [...nodes.values()].sort((a, b) => b.degree - a.degree || a.name.localeCompare(b.name)).slice(0, 64).map(n => {
    const item = el("button");
    item.append(dot(n.type), el("span", "row-title", n.name), el("span", "row-meta", pretty(n.type)));
    item.onclick = () => inspectFromMap(n.id);
    return item;
  });
  $("node-list").replaceChildren(...entries);
  if (list.length > entries.length) $("node-list").append(el("p", "muted", "Showing the 64 most connected entities in view. Search to locate any entity."));
  $("load-sector").hidden = !!root || !nextSector;
  $("load-sector").disabled = false;
  layout();
  fit();
}

async function loadMap(id, append) {
  const rev = ++mapRequest;
  const before = !id && append ? nextSector : null;
  const params = id ? { id, hops: Number($("hops").value) } : before ? { before } : {};
  abort(id ? "map" : "neighborhood");
  $("load-sector").disabled = true;
  $("plot-state").textContent = id ? "Plotting a course…" : "Charting sector…";
  $("plot-state").hidden = false;
  try {
    const data = await api(id ? "neighborhood" : "map", params);
    if (rev !== mapRequest) return;
    const known = id && nodes.get(id), prior = known && { x: ox + known.x * scale, y: oy + known.y * scale };
    nextSector = id ? null : data.next_before;
    sector = id ? 0 : before ? sector + 1 : 1;
    setGraph(data, append, id);
    if (id) arrive(id, prior);
  } catch (err) {
    if (rev === mapRequest && err.name !== "AbortError") {
      $("load-sector").disabled = false;
      if (!before) {
        nextSector = null;
        sector = 0;
        setGraph({ nodes: [], edges: [], truncated: false }, false, null);
        $("plot-state").textContent = "This part of the map could not be loaded.";
      } else $("plot-state").hidden = true;
      failed(err);
    }
  }
}

const world = SurveyWorld.create($("world-gpu"), colors, paint);
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const locator = $("locator");
const locatorImage = document.createElement("canvas");
const flightKeys = new Set(), touches = new Map();
const kinds = { person: 0, organization: 0, ai_model: 0, task: 2, decision: 2, event: 2, change: 2, problem: 2, run: 2, session: 2 };
let stars = [], landmarks = [], sectors = [], cells = new Map(), bounds, cellSize = 1;
let targetCamera = null, flight = null, pinch = null, cycling = null, beacon = null, mini = null, tapped = null;
let lastFrame = 0, lastInput = 0, lastPaint = 0, revealStart = 0, reveal = 1, lockStart = 0, gpuRatio = 1, pace = 16;
const readouts = {};

function hash(value) {
  let h = 2166136261;
  for (const c of String(value)) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  return h >>> 0;
}

function tone(hex, alpha) {
  return "rgba(" + [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16)).join(",") + "," + alpha + ")";
}

function readout(id, text) {
  if (readouts[id] === text) return;
  readouts[id] = text;
  $(id).textContent = text;
}

function mapArea() {
  const rect = canvas.getBoundingClientRect(), dock = $("sidebar").getBoundingClientRect();
  const docked = width > 710 && dock.left > rect.left + width / 2 && dock.left < rect.right;
  const right = docked ? dock.left - rect.left - 16 : width;
  const top = Math.min(126, height * .17);
  let bottom = height - Math.min(150, height * .2);
  if (width <= 710 && dock.top > rect.top + height * .35) bottom = Math.min(bottom, dock.top - rect.top - 12);
  return { x: right / 2, y: (top + bottom) / 2, w: right, h: bottom - top };
}

function markRelated() {
  const focus = nodes.get(selected);
  for (const n of stars) n.related = !!focus && focus.neighbors.has(n.id);
  world.relate(stars);
  lockStart = performance.now();
}

function layout() {
  stars = [...nodes.values()].sort((a, b) => b.degree - a.degree || a.id.localeCompare(b.id));
  landmarks = []; sectors = []; cells = new Map(); bounds = null; mini = null;
  if (!stars.length) { world.upload([], new Float32Array(), []); if (locator) locator.hidden = true; return; }
  stars.forEach((n, i) => { n.index = i; n.tint = typeIndex(n.type); n.seed = hash(n.id) / 4294967296; n.routes = []; });

  const groups = [];
  if (stars.length < 160) {
    const anchors = [nodes.get(root) || stars[0]];
    const k = Math.min(7, Math.ceil(Math.sqrt(stars.length) * .64));
    for (const n of stars) {
      if (anchors.length >= k || !n.degree) break;
      if (anchors.every(a => a !== n && !n.neighbors.has(a.id))) anchors.push(n);
    }
    const queue = anchors.slice(), seen = new Map();
    anchors.forEach((a, i) => { seen.set(a.id, i); groups.push([]); });
    for (let i = 0; i < queue.length; i++) {
      const a = queue[i], group = seen.get(a.id);
      groups[group].push(a);
      for (const id of a.neighbors) {
        if (seen.has(id)) continue;
        seen.set(id, group); queue.push(nodes.get(id));
      }
    }
    for (const n of stars) if (!seen.has(n.id)) groups[n.tint % groups.length].push(n);
  } else {
    const byType = new Map();
    for (const n of stars) {
      let type = n.type;
      if (!byType.has(type) && byType.size >= 24) type = null;
      if (!byType.has(type)) byType.set(type, []);
      byType.get(type).push(n);
    }
    groups.push(...[...byType.values()].sort((a, b) => b.length - a.length));
  }

  const area = mapArea();
  const stretch = Math.max(.76, Math.min(1.85, area.w / Math.max(1, area.h) * .91));
  const placed = [], maxRadius = Math.max(...groups.map(g => Math.sqrt(g.length) * 45));
  for (const [i, group] of groups.entries()) {
    if (!group.length) continue;
    const radius = 35 + Math.sqrt(group.length - 1) * 45;
    let cx = 0, cy = 0;
    if (i) {
      for (let step = 1; ; step++) {
        const angle = step * 2.399963 + i * .82, dist = Math.sqrt(step) * (maxRadius + 44) * .24;
        cx = dist * Math.cos(angle); cy = dist * Math.sin(angle);
        if (placed.every(p => Math.hypot(cx - p.x, cy - p.y) > .83 * (radius + p.r))) break;
      }
    }
    placed.push({ x: cx, y: cy, r: radius });
    const seed = group[0];
    const member = new Set(group), ordered = [];
    for (const start of group) {
      if (!member.delete(start)) continue;
      const queue = [start];
      for (let j = 0; j < queue.length; j++) {
        const n = queue[j]; ordered.push(n);
        for (const id of n.neighbors) {
          const neighbor = nodes.get(id);
          if (member.delete(neighbor)) queue.push(neighbor);
        }
      }
    }
    for (const [j, n] of ordered.entries()) {
      const t = j * 2.399963 + seed.seed * 6.28 + (n.seed - .5) * .32;
      const r = Math.sqrt(j) * 46 * (.82 + n.seed * .25 + .09 * Math.sin(3 * t + i));
      let sx = Math.cos(t) * r, sy = Math.sin(t) * r;
      if (group.length > 50) {
        const twist = seed.seed * 4.9, bulge = Math.sin(sx / radius * 4.6 + twist);
        sy = sy * (.48 + .19 * Math.cos(sx / radius * 5.3)) + bulge * radius * .19;
        const a = sx * Math.cos(twist) - sy * Math.sin(twist);
        sy = sx * Math.sin(twist) + sy * Math.cos(twist); sx = a;
      }
      n.x = (cx + sx) * stretch;
      n.y = cy + sy;
      n.landmark = j === 0 || n.index === 0;
      n.sectorCount = j === 0 && stars.length >= 160 && group.every(m => m.type === n.type) ? group.length : 0;
      n.kind = kinds[n.type] ?? 1;
      n.radius = (n.landmark ? 12 + 6 / (1 + n.index * .2) : 4.1 + Math.min(5, Math.log2(1 + n.degree)) + n.seed * 1.4) * (n.kind === 0 ? 1.1 : n.kind === 2 ? .92 : 1) * (stars.length < 160 ? 1.4 : 1);
      if (n.kind === 1 && (n.landmark || n.degree >= 8)) n.kind = 3;
      if (n.landmark) landmarks.push(n);
    }
    seed.sectorRadius = radius * Math.max(1, stretch);
    sectors.push({ x: cx * stretch, y: cy, r: seed.sectorRadius, tint: seed.tint, count: group.length, node: seed, typed: seed.sectorCount > 0, rank: sectors.length + 1 });
  }

  bounds = { x1: Infinity, x2: -Infinity, y1: Infinity, y2: -Infinity };
  let far = 1;
  for (const n of stars) {
    bounds.x1 = Math.min(bounds.x1, n.x); bounds.x2 = Math.max(bounds.x2, n.x);
    bounds.y1 = Math.min(bounds.y1, n.y); bounds.y2 = Math.max(bounds.y2, n.y);
    far = Math.max(far, Math.hypot(n.x, n.y));
  }
  for (const n of stars) n.delay = Math.hypot(n.x, n.y) / far * .75;
  cellSize = Math.max(30, Math.max(bounds.x2 - bounds.x1, bounds.y2 - bounds.y1) / 48);
  const bucket = (x, y) => {
    const key = Math.floor(x / cellSize) + ":" + Math.floor(y / cellSize);
    if (!cells.has(key)) cells.set(key, { nodes: [], edges: [] });
    return cells.get(key);
  };
  for (const n of stars) bucket(n.x, n.y).nodes.push(n);

  const segments = [];
  for (const e of graph.edges) {
    const a = nodes.get(e.subject_id), b = nodes.get(e.object_id);
    if (!a || !b) continue;
    const dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy);
    const level = stars.length < 160 ? .75 + .35 * a.seed : Math.max(.035, Math.min(1.3, 250 / Math.max(d, 1)) ** 2);
    const link = { a, b, e, level, distance: d };
    a.routes.push(link);
    if (b !== a) b.routes.push(link);
    const bins = new Set();
    const add = (x1, y1, x2, y2) => {
      segments.push(x1, y1, a.index, b.index, level, a.tint, x2, y2, a.index, b.index, level, b.tint);
      const steps = Math.max(1, Math.ceil(Math.max(Math.abs(x2 - x1), Math.abs(y2 - y1)) / cellSize));
      let px = x1, py = y1;
      bins.add(bucket(px, py));
      for (let i = 1; i <= steps; i++) {
        const x = x1 + (x2 - x1) * i / steps, y = y1 + (y2 - y1) * i / steps;
        bins.add(bucket(x, y));
        if (Math.floor(px / cellSize) !== Math.floor(x / cellSize) && Math.floor(py / cellSize) !== Math.floor(y / cellSize)) {
          bins.add(bucket(px, y)); bins.add(bucket(x, py));
        }
        px = x; py = y;
      }
    };
    if (a === b) {
      const r = a.radius * 1.45, x = a.x + r, y = a.y - r;
      for (let j = 0; j < 20; j++) {
        const t = j * Math.PI / 10, u = t + Math.PI / 10;
        add(x + r * Math.cos(t), y + r * Math.sin(t), x + r * Math.cos(u), y + r * Math.sin(u));
      }
    } else add(a.x, a.y, b.x, b.y);

    for (const bin of bins) bin.edges.push(link);
  }
  for (const n of stars) {
    if (n.routes.length < 2) continue;
    n.routes.sort((a, b) => a.distance - b.distance);
    const seen = new Set();
    n.routes = n.routes.filter(link => {
      const neighbor = link.a === n ? link.b : link.a;
      if (seen.has(neighbor) || seen.size >= 60) return false;
      seen.add(neighbor); return true;
    });
  }
  const focus = nodes.get(selected);
  for (const n of stars) n.related = !!focus && focus.neighbors.has(n.id);
  world.upload(stars, new Float32Array(segments), sectors);
  revealStart = reducedMotion.matches ? 0 : performance.now();
  rebuildLocator();
}

function rebuildLocator() {
  if (!locator || !bounds) return;
  locator.hidden = false;
  const size = 148, ratio = Math.min(2, devicePixelRatio || 1), mid = size / 2;
  locator.width = locator.height = locatorImage.width = locatorImage.height = Math.round(size * ratio);
  const cx = (bounds.x1 + bounds.x2) / 2, cy = (bounds.y1 + bounds.y2) / 2;
  let reach = 48;
  for (const n of stars) reach = Math.max(reach, Math.hypot(n.x - cx, n.y - cy));
  const z = (mid - 14) / reach;
  mini = { z, x: mid - cx * z, y: mid - cy * z, size, ratio };
  const c = locatorImage.getContext("2d"), dot = stars.length > 1200 ? .9 : 1.6;
  c.setTransform(ratio, 0, 0, ratio, 0, 0);
  c.clearRect(0, 0, size, size);
  c.globalAlpha = stars.length > 1200 ? .75 : .95;
  for (const n of stars) {
    c.fillStyle = colors[n.tint];
    const r = n.landmark ? dot * 1.8 : dot;
    c.fillRect(mini.x + n.x * z - r / 2, mini.y + n.y * z - r / 2, r, r);
  }
}

function drawLocator(area, light, time, motion) {
  if (!locator || !mini || !locator.clientWidth) return;
  const c = locator.getContext("2d"), { size, ratio } = mini, mid = size / 2, R = mid - 3;
  const ink = light ? "#1e5f6a" : "#86e6ee";
  c.setTransform(ratio, 0, 0, ratio, 0, 0);
  c.clearRect(0, 0, size, size);
  c.save();
  c.beginPath(); c.arc(mid, mid, R, 0, Math.PI * 2);
  c.fillStyle = light ? "#eef1f6e8" : "#050911e0"; c.fill();
  c.clip();
  c.strokeStyle = tone(ink, .14); c.lineWidth = 1;
  c.beginPath();
  for (const k of [1 / 3, 2 / 3]) { c.moveTo(mid + R * k, mid); c.arc(mid, mid, R * k, 0, Math.PI * 2); }
  c.moveTo(mid - R, mid); c.lineTo(mid + R, mid); c.moveTo(mid, mid - R); c.lineTo(mid, mid + R);
  c.stroke();
  if (motion && c.createConicGradient) {
    const sweep = c.createConicGradient(time / 2400, mid, mid);
    sweep.addColorStop(0, tone(ink, .16)); sweep.addColorStop(.12, tone(ink, 0)); sweep.addColorStop(1, tone(ink, 0));
    c.fillStyle = sweep; c.fillRect(0, 0, size, size);
  }
  c.drawImage(locatorImage, 0, 0, size, size);
  const x = mini.x + ((area.x - area.w / 2 - ox) / scale) * mini.z, y = mini.y + ((area.y - area.h / 2 - oy) / scale) * mini.z;
  const w = area.w / scale * mini.z, h = area.h / scale * mini.z;
  c.strokeStyle = ink; c.lineWidth = 1.2;
  if (w < size * 1.4) {
    const k = Math.min(7, w / 3, h / 3);
    c.beginPath();
    for (const [px, py, dx, dy] of [[x, y, 1, 1], [x + w, y, -1, 1], [x, y + h, 1, -1], [x + w, y + h, -1, -1]]) {
      c.moveTo(px + dx * k, py); c.lineTo(px, py); c.lineTo(px, py + dy * k);
    }
    c.stroke();
    c.fillStyle = tone(ink, .06); c.fillRect(x, y, w, h);
  }
  const target = nodes.get(selected);
  if (target) {
    const tx = mini.x + target.x * mini.z, ty = mini.y + target.y * mini.z;
    c.fillStyle = light ? "#a3520d" : "#ffd28a";
    c.beginPath(); c.arc(tx, ty, 2.6, 0, Math.PI * 2); c.fill();
    c.strokeStyle = tone(light ? "#a3520d" : "#ffd28a", .6);
    c.beginPath(); c.arc(tx, ty, 6 + (motion ? 2 * Math.sin(time / 300) : 0), 0, Math.PI * 2); c.stroke();
  }
  c.restore();
  c.strokeStyle = tone(ink, .5); c.lineWidth = 1;
  c.beginPath(); c.arc(mid, mid, R, 0, Math.PI * 2); c.stroke();
  c.beginPath();
  for (let i = 0; i < 48; i++) {
    const t = i * Math.PI / 24, inner = i % 12 ? R - 2.5 : R - 6;
    c.moveTo(mid + Math.cos(t) * inner, mid + Math.sin(t) * inner); c.lineTo(mid + Math.cos(t) * R, mid + Math.sin(t) * R);
  }
  c.stroke();
}

if (locator) locator.onclick = e => {
  if (!mini) return;
  const rect = locator.getBoundingClientRect();
  const x = ((e.clientX - rect.left) * mini.size / rect.width - mini.x) / mini.z;
  const y = ((e.clientY - rect.top) * mini.size / rect.height - mini.y) / mini.z;
  flyTo(x, y, scale);
};

function fit(animate) {
  const area = mapArea(), b = bounds || { x1: 0, x2: 0, y1: 0, y2: 0 };
  fitScale = Math.max(.005, Math.min(2.15, (area.w - Math.min(120, area.w * .18)) / Math.max(1, b.x2 - b.x1),
    (area.h - Math.min(95, area.h * .16)) / Math.max(1, b.y2 - b.y1)));
  if (animate) flyTo((b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2, fitScale);
  else { targetCamera = null; flight = null; place((b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2, fitScale); paint(); }
}

function resize() {
  const rect = canvas.getBoundingClientRect(), z = Math.min(2.5, devicePixelRatio || 1);
  if (width === rect.width && height === rect.height && canvas.width === Math.round(width * z)) return;
  width = Math.max(1, rect.width); height = Math.max(1, rect.height);
  canvas.width = Math.round(width * z); canvas.height = Math.round(height * z);
  sizeScene(Math.min(1.75, z));
  ctx.setTransform(canvas.width / width, 0, 0, canvas.height / height, 0, 0);
  fit();
}

function sizeScene(ratio) {
  const gpu = $("world-gpu");
  const w = Math.max(1, Math.round(width * ratio)), h = Math.max(1, Math.round(height * ratio));
  gpuRatio = ratio;
  if (gpu.width !== w) gpu.width = w;
  if (gpu.height !== h) gpu.height = h;
}

function paint() {
  if (!frame) frame = requestAnimationFrame(draw);
}

function place(cx, cy, next) {
  const area = mapArea();
  scale = next; ox = area.x - cx * next; oy = area.y - cy * next;
}

function steer(next, x, y) {
  hover = null; flight = null;
  if (!targetCamera) lastFrame = performance.now();
  if (reducedMotion.matches) { scale = next; ox = x; oy = y; targetCamera = null; }
  else targetCamera = { scale: next, x, y };
  paint();
}

function flyTo(cx, cy, next) {
  hover = null; targetCamera = null;
  const area = mapArea();
  if (reducedMotion.matches) { flight = null; place(cx, cy, next); paint(); return; }
  const x0 = (area.x - ox) / scale, y0 = (area.y - oy) / scale, w0 = area.w / scale, w1 = area.w / next;
  const dx = cx - x0, dy = cy - y0, d = Math.hypot(dx, dy), rho = 1.42, r2 = rho * rho;
  let path, length;
  if (d < w0 * 1e-4) {
    length = Math.abs(Math.log(w1 / w0)) / rho;
    path = t => [x0 + dx * t, y0 + dy * t, w0 * (w1 / w0) ** t];
  } else {
    const r0 = -Math.asinh((w1 * w1 - w0 * w0 + r2 * r2 * d * d) / (2 * w0 * r2 * d));
    const r1 = -Math.asinh((w1 * w1 - w0 * w0 - r2 * r2 * d * d) / (2 * w1 * r2 * d));
    length = (r1 - r0) / rho;
    path = t => {
      const s = t * length, u = w0 / r2 * (Math.cosh(r0) * Math.tanh(rho * s + r0) - Math.sinh(r0));
      return [x0 + dx / d * u, y0 + dy / d * u, t === 1 ? w1 : w0 * Math.cosh(r0) / Math.cosh(rho * s + r0)];
    };
  }
  if (!Number.isFinite(length) || length < .02) { flight = null; place(cx, cy, next); paint(); return; }
  flight = { path, area, start: performance.now(), duration: Math.max(420, Math.min(1900, 520 * length ** .7)) };
  paint();
}

function framing(n) {
  const area = mapArea(), reach = n.routes.map(l => l.distance).sort((a, b) => a - b);
  const d = reach.length ? reach[Math.min(reach.length - 1, Math.floor(reach.length * .7))] : 140;
  return Math.min(4, Math.max(fitScale * 1.15, Math.min(area.w, area.h) * .4 / Math.max(d, 40)));
}

function flyToEntity(id) {
  const n = nodes.get(id);
  if (!n) return false;
  flyTo(n.x, n.y, framing(n));
  return true;
}

function arrive(id, prior) {
  const n = nodes.get(id);
  if (!n) return;
  const area = mapArea(), start = Math.min(fitScale * .9, framing(n) * .5);
  if (!reducedMotion.matches) {
    scale = start;
    ox = (prior?.x ?? area.x) - n.x * start;
    oy = (prior?.y ?? area.y) - n.y * start;
  }
  flyToEntity(id);
}

function advanceCamera(time) {
  const elapsed = Math.max(1, time - lastFrame), dt = Math.min(100, elapsed);
  lastFrame = time;
  if (flight) {
    const t = Math.min(1, Math.max(0, (time - flight.start) / flight.duration));
    const e = t < .5 ? 4 * t * t * t : 1 - (2 - 2 * t) ** 3 / 2;
    const [cx, cy, w] = flight.path(e);
    scale = flight.area.w / w; ox = flight.area.x - cx * scale; oy = flight.area.y - cy * scale;
    if (t >= 1) flight = null;
  }
  if (targetCamera) {
    const t = 1 - Math.exp(-elapsed / 69), target = targetCamera;
    ox += (target.x - ox) * t; oy += (target.y - oy) * t; scale += (target.scale - scale) * t;
    if (Math.abs(target.x - ox) + Math.abs(target.y - oy) + Math.abs(target.scale - scale) * 400 < .28) {
      ox = target.x; oy = target.y; scale = target.scale; targetCamera = null;
    }
  }
  if (flightKeys.size) {
    const dx = Number(flightKeys.has("a") || flightKeys.has("arrowleft")) - Number(flightKeys.has("d") || flightKeys.has("arrowright"));
    const dy = Number(flightKeys.has("w") || flightKeys.has("arrowup")) - Number(flightKeys.has("s") || flightKeys.has("arrowdown"));
    const speed = dt * .62 / Math.max(1, Math.hypot(dx, dy));
    ox += dx * speed; oy += dy * speed;
  }
}

function inCells(x1, y1, x2, y2, visit) {
  if (!bounds) return;
  const left = Math.max(Math.floor(bounds.x1 / cellSize) - 2, Math.floor(x1 / cellSize));
  const right = Math.min(Math.floor(bounds.x2 / cellSize) + 2, Math.floor(x2 / cellSize));
  const top = Math.max(Math.floor(bounds.y1 / cellSize) - 2, Math.floor(y1 / cellSize));
  const bottom = Math.min(Math.floor(bounds.y2 / cellSize) + 2, Math.floor(y2 / cellSize));
  for (let y = top; y <= bottom; y++) for (let x = left; x <= right; x++) {
    const bin = cells.get(x + ":" + y);
    if (bin) visit(bin);
  }
}

function routes(n, light, time, motion, focus) {
  ctx.lineWidth = 1.15;
  ctx.setLineDash([3, 7]);
  ctx.lineDashOffset = motion ? -time / 45 : 0;
  const heads = new Path2D();
  for (const { a, b, e, distance } of n.routes) {
    if (a === b || distance * scale < 26) continue;
    const from = e.subject_id === a.id ? a : b, to = from === a ? b : a, other = from === n ? to : from;
    const dx = (to.x - from.x) / distance, dy = (to.y - from.y) / distance;
    const r1 = world.radius(from, scale, focus) + 3, r2 = world.radius(to, scale, focus) + 4;
    const x1 = ox + from.x * scale + dx * r1, y1 = oy + from.y * scale + dy * r1;
    const x2 = ox + to.x * scale - dx * r2, y2 = oy + to.y * scale - dy * r2;
    ctx.strokeStyle = tone(light ? "#25495a" : colors[other.tint], light ? .7 : .62);
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    heads.moveTo(x2 - 7 * dx + 3 * dy, y2 - 7 * dy - 3 * dx); heads.lineTo(x2, y2); heads.lineTo(x2 - 7 * dx - 3 * dy, y2 - 7 * dy + 3 * dx);
  }
  ctx.setLineDash([]);
  ctx.lineWidth = 1.3;
  ctx.strokeStyle = light ? "#1e4a59" : "#d8f6fa";
  ctx.stroke(heads);
}

function reticle(n, light, time, motion, focus) {
  const x = ox + n.x * scale, y = oy + n.y * scale, r = world.radius(n, scale, focus);
  const lock = motion ? Math.min(1, Math.max(0, (time - lockStart) / 420)) : 1, ease = 1 - (1 - lock) ** 3;
  const R = (r * (n.kind === 3 ? 2.35 : 1.45) + 9) * (1 + (1 - ease) * 1.4), arm = Math.max(5, R * .34);
  const ink = light ? "#0b5f69" : "#93f1f4";
  ctx.strokeStyle = tone(ink, .9 * ease + .1); ctx.lineWidth = 1.4;
  ctx.beginPath();
  for (const [sx, sy] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) {
    ctx.moveTo(x + sx * R, y + sy * (R - arm)); ctx.lineTo(x + sx * R, y + sy * R); ctx.lineTo(x + sx * (R - arm), y + sy * R);
  }
  ctx.stroke();
  ctx.save();
  ctx.translate(x, y); ctx.rotate(motion ? time / 5200 : 0);
  ctx.setLineDash([1.5, 6]); ctx.lineWidth = 1; ctx.strokeStyle = tone(ink, .45 * ease);
  ctx.beginPath(); ctx.arc(0, 0, R * 1.3, 0, Math.PI * 2); ctx.stroke();
  ctx.restore();
  ctx.setLineDash([]);

  const text = n.name.length > 34 ? n.name.slice(0, 32) + "…" : n.name;
  const meta = pretty(n.type).toUpperCase() + " · " + number.format(n.degree) + (n.degree === 1 ? " LANE" : " LANES");
  ctx.font = "600 15px " + sans;
  const tw = Math.max(ctx.measureText(text).width, meta.length * 6.4) + 12;
  const area = mapArea(), right = x + R + 18 + tw < area.w - 8;
  const kx = x + (right ? 1 : -1) * R * .7, ky = y - R * .7, ex = x + (right ? 1 : -1) * (R + 18), ey = y - R - 18;
  const shift = Math.max(0, 8 - (right ? ex : ex - tw)), box = { x: (right ? ex : ex - tw) + shift, y: ey - 22, w: tw, h: 36, node: n };
  ctx.strokeStyle = tone(ink, .75 * ease); ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(kx, ky); ctx.lineTo(ex, ey); ctx.lineTo(right ? ex + tw : ex - tw, ey); ctx.stroke();
  ctx.globalAlpha = ease;
  ctx.textBaseline = "alphabetic"; ctx.textAlign = right ? "left" : "right";
  halo(text, ex + shift + (right ? 4 : -4), ey - 6, light ? "#0e1a26" : "#f4f8ff", light);
  ctx.font = "500 9.5px " + mono;
  halo(meta, ex + shift + (right ? 4 : -4), ey + 12, light ? "#2d5865" : colors[n.tint], light);
  ctx.textAlign = "left"; ctx.globalAlpha = 1;
  return box;
}

function halo(text, x, y, fill, light) {
  ctx.lineJoin = "round"; ctx.lineWidth = 3.5;
  ctx.strokeStyle = light ? "rgba(236,240,246,.85)" : "rgba(3,6,14,.8)";
  ctx.strokeText(text, x, y);
  ctx.fillStyle = fill;
  ctx.fillText(text, x, y);
}

function offscreen(n, area, light, time, motion) {
  beacon = null;
  const x = ox + n.x * scale, y = oy + n.y * scale, left = 26, right = area.w - 26, top = 120, bottom = height - 130;
  if (x > left && x < right && y > top && y < bottom) return;
  const cx = area.x, cy = (top + bottom) / 2, dx = x - cx, dy = y - cy;
  const k = Math.min(Math.abs((dx > 0 ? right - cx : left - cx) / (dx || 1e-6)), Math.abs((dy > 0 ? bottom - cy : top - cy) / (dy || 1e-6)));
  const bx = cx + dx * k, by = cy + dy * k, angle = Math.atan2(dy, dx), pulse = motion ? 1 + .12 * Math.sin(time / 240) : 1;
  const ink = light ? "#a3520d" : "#ffd28a";
  ctx.save();
  ctx.translate(bx, by); ctx.rotate(angle);
  ctx.fillStyle = tone(ink, .92); ctx.strokeStyle = tone(ink, .5); ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(9 * pulse, 0); ctx.lineTo(-5, -7); ctx.lineTo(-2, 0); ctx.lineTo(-5, 7); ctx.closePath(); ctx.fill();
  ctx.beginPath(); ctx.arc(0, 0, 15, -1, 1); ctx.stroke();
  ctx.restore();
  const label = n.name.length > 24 ? n.name.slice(0, 22) + "…" : n.name;
  ctx.font = "500 11px " + sans; ctx.textBaseline = "middle";
  ctx.textAlign = dx > 0 ? "right" : "left";
  const tx = bx + (dx > 0 ? -22 : 22), ty = by + (Math.abs(dy * k) > Math.abs(dx * k) - 1 ? (dy > 0 ? -16 : 16) : 0);
  halo(label, tx, ty, light ? "#5a2e05" : "#ffe3b3", light);
  ctx.textAlign = "left";
  beacon = { x: bx, y: by, id: n.id };
}

function ping(light) {
  if (reveal >= 1 || !stars.length) return;
  const x = ox, y = oy, r = reveal * Math.max(width, height) * 1.1;
  ctx.strokeStyle = tone(light ? "#0b5f69" : "#8ee8f0", .35 * (1 - reveal)); ctx.lineWidth = 1.2;
  ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.stroke();
}

const sans = "system-ui, -apple-system, 'Segoe UI', sans-serif", mono = "ui-monospace, 'SFMono-Regular', Consolas, 'Liberation Mono', monospace";

function labelField(visible, focus, light, area, reserved, skip) {
  const ratio = scale / fitScale;
  const budget = Math.ceil(Math.min(58, area.w * area.h / 32000 * Math.min(2.3, Math.max(.6, ratio * .65))));
  const grid = new Map(), cell = 52;
  const keys = function* (x, y, w, h) {
    for (let j = Math.floor(y / cell); j <= Math.floor((y + h) / cell); j++)
      for (let i = Math.floor(x / cell); i <= Math.floor((x + w) / cell); i++) yield i + ":" + j;
  };
  const occupy = box => {
    for (const k of keys(box.x, box.y, box.w, box.h)) {
      if (!grid.has(k)) grid.set(k, []);
      grid.get(k).push(box);
    }
  };
  const intersects = box => {
    for (const k of keys(box.x, box.y, box.w, box.h)) {
      if (grid.get(k)?.some(b => box.x < b.x + b.w && box.x + box.w > b.x && box.y < b.y + b.h && box.y + box.h > b.y)) return true;
    }
    return false;
  };

  labels = [];
  for (const box of reserved) { occupy(box); labels.push(box); }
  const frame = canvas.getBoundingClientRect();
  for (const zone of document.querySelectorAll(".sector, .map-instruments, #locator, #results, #filters, #time-panel, #sidebar, #node-list")) {
    const r = zone.getBoundingClientRect();
    if (r.width) occupy({ x: r.left - frame.left - 10, y: r.top - frame.top - 10, w: r.width + 20, h: r.height + 20 });
  }
  const local = ratio >= 2 || stars.length < 160;
  const candidates = local ? visible.slice().sort((a, b) => Number(b.index === focus) - Number(a.index === focus) ||
    Number(b.landmark) - Number(a.landmark) || a.index - b.index) : [...landmarks];
  if (!local && focus >= 0) candidates.unshift(stars[focus]);
  ctx.textBaseline = "alphabetic";
  for (const n of candidates) {
    if (n === skip || n.delay + .2 > reveal) continue;
    const sx = ox + n.x * scale, sy = oy + n.y * scale;
    const region = !local && n.sectorCount && n.index !== focus;
    if (!region && (sx < 0 || sx > area.w || sy < 25 || sy > height - 40)) continue;
    const prominent = n.index === focus || n.index === 0;
    const sector = region && sectors.find(s => s.node === n);
    const title = region ? pretty(n.type).toUpperCase() : n.name.length > 28 ? n.name.slice(0, 26) + "…" : n.name;
    const sub = region ? "S-" + String(sector.rank).padStart(2, "0") + " · " + number.format(n.sectorCount) + " ENTITIES" : n.index === focus ? bearing(n, skip).toUpperCase() : pretty(n.type).toUpperCase();
    ctx.font = region ? "600 12px " + sans : prominent ? "600 13.5px " + sans : "500 11.5px " + sans;
    if (region && "letterSpacing" in ctx) ctx.letterSpacing = "2.4px";
    const w = Math.max(ctx.measureText(title).width, region || prominent ? sub.length * 6 : 0) + 10;
    if ("letterSpacing" in ctx) ctx.letterSpacing = "0px";
    const h = prominent || region ? 34 : 17;
    let positions;
    if (region) {
      const rr = sector.r * scale * 1.02;
      positions = [[sx - w / 2, sy - rr - h - 6], [sx - w / 2, sy + rr + 6], [sx - w / 2, sy - h / 2]];
    } else {
      const r = world.radius(n, scale, focus) * (n.kind === 3 ? 2.2 : 1.25) + 4;
      positions = [[sx + r, sy - h / 2], [sx - w - r, sy - h / 2], [sx - w / 2, sy + r], [sx - w / 2, sy - r - h]];
    }
    for (const [x, y] of positions) {
      const box = { x, y, w, h, node: n, sector: Boolean(region) };
      if (x < 3 || x + w > area.w - 3 || y < 112 || y + h > height - 64 || intersects(box)) continue;
      if (region) {
        ctx.font = "600 12px " + sans;
        if ("letterSpacing" in ctx) ctx.letterSpacing = "2.4px";
        halo(title, x + 5, y + 14, light ? "#26354a" : colors[n.tint], light);
        if ("letterSpacing" in ctx) ctx.letterSpacing = "0px";
        ctx.font = "500 9px " + mono;
        halo(sub, x + 5, y + 28, light ? "#4b5a70" : "#9fb0c6", light);
      } else if (prominent) {
        halo(title, x + 5, y + 15, light ? "#14202e" : "#f2f6fc", light);
        ctx.font = "500 9px " + mono;
        halo(sub, x + 5, y + 28, light ? "#3c5868" : colors[n.tint], light);
      } else {
        halo(title, x + 5, y + 12.5, light ? "#2a3a4c" : n.related ? "#e4ecf6" : "#b9c6d6", light);
      }
      occupy(box); labels.push(box); break;
    }
    if (labels.length >= budget + reserved.length) break;
  }
}

function bearing(n, selectedNode) {
  const meta = pretty(n.type) + " · " + number.format(n.degree) + (n.degree === 1 ? " lane" : " lanes");
  const link = selectedNode && selectedNode !== n && selectedNode.routes.find(l => l.a === n || l.b === n);
  return link ? (link.e.subject_id === n.id ? "→ " : "← ") + pretty(link.e.relation) + " · " + meta : meta;
}

function tooltip(light, selectedNode) {
  if (!hover || !hoverAt || drag) return;
  let title, meta = "", tint = null;
  if (hover.sector) { title = "Enter the " + pretty(hover.node.type) + " sector"; meta = number.format(hover.node.sectorCount) + " entities"; tint = hover.node.tint; }
  else if (hover.beacon) { title = "Fly to " + nodes.get(hover.beacon)?.name; meta = "Target out of view"; }
  else if (hover.node) {
    const n = hover.node;
    if (labels.some(l => l.node === n && !l.sector)) return;
    title = n.name; meta = bearing(n, selectedNode); tint = n.tint;
  } else {
    const e = hover.edge, a = nodes.get(e.subject_id), b = nodes.get(e.object_id);
    title = pretty(e.relation) + (e.confidence == null ? "" : " · " + Math.round(e.confidence * 100) + "%");
    meta = a.name + " → " + b.name; tint = a.tint;
  }
  ctx.font = "600 12px " + sans;
  const w = Math.min(width - 16, Math.max(ctx.measureText(title).width, meta.length * 6.1) + 24);
  const x = Math.max(8, Math.min(width - w - 8, hoverAt.x + 16)), y = Math.max(8, Math.min(height - 50, hoverAt.y - 50));
  ctx.fillStyle = light ? "rgba(244,247,251,.94)" : "rgba(6,10,20,.88)";
  ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + w - 7, y); ctx.lineTo(x + w, y + 7); ctx.lineTo(x + w, y + 40); ctx.lineTo(x + 7, y + 40); ctx.lineTo(x, y + 33); ctx.closePath(); ctx.fill();
  ctx.strokeStyle = light ? "rgba(60,80,100,.35)" : "rgba(150,210,230,.28)"; ctx.lineWidth = 1; ctx.stroke();
  ctx.fillStyle = tint == null ? (light ? "#a3520d" : "#ffd28a") : light ? "#33475c" : colors[tint];
  ctx.fillRect(x, y + 9, 2, 22);
  ctx.textBaseline = "alphabetic";
  ctx.fillStyle = light ? "#132031" : "#eef3fb"; ctx.fillText(title, x + 11, y + 17, w - 20);
  ctx.font = "500 9.5px " + mono; ctx.fillStyle = light ? "#4c5d70" : "#9fb0c6"; ctx.fillText(meta.toUpperCase(), x + 11, y + 31, w - 20);
}

function instruments(area, inView) {
  const ratio = scale / fitScale, cx = (area.x - ox) / scale, cy = (area.y - oy) / scale;
  readout("zoom", "×" + (ratio < 10 ? ratio.toFixed(1) : Math.round(ratio)));
  const signed = v => (v < 0 ? "−" : "+") + String(Math.abs(Math.round(v))).padStart(4, "0");
  readout("telemetry", "X " + signed(cx) + "  Y " + signed(-cy) + "  ·  " + number.format(inView) + " in view");
  let where = "Open space", zone = null;
  if (!stars.length) where = "No signal";
  else if (ratio < 1.35 && !root) where = sectors.filter(s => s.typed).length + " sectors charted";
  else {
    let best = null, nearest = Infinity;
    for (const s of sectors) {
      const d = Math.hypot(cx - s.x, cy - s.y) / s.r;
      if (d < nearest) { nearest = d; best = s; }
    }
    if (best && nearest < 1.15) {
      const hops = Number($("hops").value);
      const rank = "Sector " + String(best.rank).padStart(2, "0");
      where = best.typed ? rank + " · " + pretty(best.node.type)
        : best.node.id === root ? "Target system · " + hops + (hops === 1 ? " hop" : " hops") : "System · " + best.node.name;
      if (best.typed) zone = [rank, pretty(best.node.type)];
      else if (best.node.id !== root) zone = ["System", best.node.name];
    }
  }
  if (readouts.region !== where && zone && !reducedMotion.matches) {
    const card = $("zone");
    card.replaceChildren(el("span", "", zone[0]), el("strong", "", zone[1]));
    card.classList.remove("show");
    void card.offsetWidth;
    card.classList.add("show");
  }
  readout("region", where);
}

function draw(time) {
  frame = 0;
  const motion = !reducedMotion.matches && document.visibilityState === "visible";
  const ambient = motion && pace < 70;
  const busy = flight || targetCamera || flightKeys.size || drag || pinch || reveal < 1 || (ambient && time - lockStart < 450);
  if (ambient && !busy && time - lastPaint < (time - lastInput > 30000 ? 80 : time - lastInput > 4000 ? 31 : 0)) { paint(); return; }
  if (busy && time - lastPaint < 1000) pace = pace * .9 + (time - lastPaint) * .1;
  lastPaint = time;
  advanceCamera(time);
  const full = Math.min(1.75, devicePixelRatio || 1);
  const moving = flight || targetCamera || flightKeys.size || drag?.moved || pinch;
  sizeScene(moving && (pace > 70 || gpuRatio < full) ? Math.min(.65, full) : full);
  reveal = !revealStart ? 1 : Math.min(1, Math.max(0, (time - revealStart) / 1500));
  const area = mapArea(), light = document.documentElement.dataset.theme === "light";
  const selectedNode = nodes.get(selected);
  const focusNode = (!hover?.sector && hover?.node) || selectedNode, focus = focusNode?.index ?? -1;
  const visible = [];
  inCells((-70 - ox) / scale, (-70 - oy) / scale, (width + 70 - ox) / scale, (height + 70 - oy) / scale,
    b => { for (const n of b.nodes) visible.push(n); });
  const alpha = Math.min(.5, (.32 / Math.max(1, Math.sqrt(stars.length / 70))) * Math.max(1, Math.min(8, scale / fitScale)));
  ctx.clearRect(0, 0, width, height);
  world.draw(ctx, { width, height, ox, oy, scale, light, focus, hover: hover?.node && !hover.sector ? hover.node.index : -1, edgeAlpha: alpha,
    time: (time / 1000) % 3600, fitScale, ratio: gpuRatio, reveal, motion: ambient, dim: !!selectedNode }, visible);
  ping(light);
  if (focusNode && reveal > .5) routes(focusNode, light, time, ambient, focus);
  if (hover?.edge) {
    const a = nodes.get(hover.edge.subject_id), b = nodes.get(hover.edge.object_id);
    ctx.beginPath(); ctx.lineWidth = 1.8; ctx.strokeStyle = light ? "#1b6a78" : "#a5ecf5";
    if (a === b) {
      const r = a.radius * 1.45 * scale;
      ctx.arc(ox + a.x * scale + r, oy + a.y * scale - r, r, 0, Math.PI * 2);
    } else { ctx.moveTo(ox + a.x * scale, oy + a.y * scale); ctx.lineTo(ox + b.x * scale, oy + b.y * scale); }
    ctx.stroke();
  }
  const reserved = selectedNode && reveal > .3 ? [reticle(selectedNode, light, time, ambient, focus)] : [];
  labelField(visible, focus, light, area, reserved, selectedNode);
  if (selectedNode) offscreen(selectedNode, area, light, time, ambient); else beacon = null;
  tooltip(light, selectedNode);
  drawLocator(area, light, time, ambient);
  instruments(area, visible.length);
  if ((ambient && stars.length) || busy) paint();
}

function hit(x, y) {
  if (beacon && Math.hypot(x - beacon.x, y - beacon.y) < 24) return { beacon: beacon.id };
  const label = labels.find(l => x >= l.x && x <= l.x + l.w && y >= l.y && y <= l.y + l.h);
  if (label) return { node: label.node, sector: label.sector };
  const wx = (x - ox) / scale, wy = (y - oy) / scale;
  let node = null, distance = Infinity;
  const edges = new Set();
  inCells(wx - 30 / scale, wy - 30 / scale, wx + 30 / scale, wy + 30 / scale, bin => {
    for (const n of bin.nodes) {
      const d = Math.hypot(wx - n.x, wy - n.y) * scale;
      if (d < Math.max(8, world.radius(n, scale, -1) + 3) && d < distance) { distance = d; node = n; }
    }
  });
  if (node) return { node };
  inCells(wx - 5 / scale, wy - 5 / scale, wx + 5 / scale, wy + 5 / scale,
    bin => { for (const edge of bin.edges) edges.add(edge); });
  let nearest = null;
  distance = 4 / scale;
  for (const { a, b, e, level } of edges) {
    if (stars.length > 160 && level < .18 && scale < fitScale * 2 && a.id !== selected && b.id !== selected) continue;
    const dx = b.x - a.x, dy = b.y - a.y;
    let d;
    if (a === b) {
      const r = a.radius * 1.45;
      d = Math.abs(Math.hypot(wx - a.x - r, wy - a.y + r) - r);
    } else {
      const t = Math.max(0, Math.min(1, ((wx - a.x) * dx + (wy - a.y) * dy) / (dx * dx + dy * dy)));
      d = Math.hypot(wx - a.x - t * dx, wy - a.y - t * dy);
    }
    if (d < distance) { nearest = e; distance = d; }
  }
  return nearest ? { edge: nearest } : null;
}

function point(event) {
  const rect = canvas.getBoundingClientRect();
  return { x: event.clientX - rect.left, y: event.clientY - rect.top };
}

function zoomAt(factor, x, y) {
  const area = mapArea(), current = targetCamera || { scale, x: ox, y: oy };
  flight = null;
  x ??= area.x; y ??= area.y;
  const next = Math.min(Math.max(6, fitScale * 5), Math.max(fitScale * .22, current.scale * factor));
  steer(next, x - (x - current.x) * next / current.scale, y - (y - current.y) * next / current.scale);
}

new MutationObserver(paint).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
canvas.addEventListener("contextrestored", () => {
  ctx.setTransform(canvas.width / width, 0, 0, canvas.height / height, 0, 0);
  rebuildLocator(); paint();
});
document.addEventListener("visibilitychange", paint);
reducedMotion.addEventListener("change", () => { revealStart = 0; paint(); });

function announce(n) {
  $("announce").textContent = n ? "Target " + n.name + ", " + pretty(n.type) + ", " + n.degree + (n.degree === 1 ? " lane" : " lanes") : "";
}

function inspectFromMap(id, glide = true) {
  inspect(id);
  const n = nodes.get(id);
  if (n && glide) flyTo(n.x, n.y, Math.max(scale, Math.min(framing(n), scale * 2.5), stars.length >= 160 ? fitScale * 3.5 : 0));
  announce(n);
  if (window.matchMedia("(max-width: 710px)").matches) $("sidebar").scrollIntoView({ block: "start" });
}

function cycle(step) {
  const from = nodes.get(selected);
  if (!cycling || (from && from !== cycling.origin && !cycling.list.includes(from))) {
    const origin = from || null;
    const list = origin ? [...new Set(origin.routes.map(l => (l.a === origin ? l.b : l.a)))].filter(m => m !== origin) : landmarks.slice();
    if (origin) list.sort((p, q) => Math.atan2(p.y - origin.y, p.x - origin.x) - Math.atan2(q.y - origin.y, q.x - origin.x));
    cycling = { origin, list, i: -1 };
  }
  if (!cycling.list.length) return;
  cycling.i = (cycling.i + step + cycling.list.length) % cycling.list.length;
  inspectFromMap(cycling.list[cycling.i].id);
}

canvas.onpointerdown = e => {
  lastInput = performance.now();
  if (e.button !== 0) return;
  const p = point(e);
  touches.set(e.pointerId, p);
  canvas.setPointerCapture(e.pointerId);
  targetCamera = null; flight = null; hover = null;
  if (touches.size === 2) {
    const [a, b] = [...touches.values()];
    pinch = { d: Math.max(10, Math.hypot(a.x - b.x, a.y - b.y)), scale, ox, oy, x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
    drag = null;
  } else if (e.isPrimary) {
    canvas.focus({ preventScroll: true });
    drag = { ...p, id: e.pointerId, ox, oy, moved: false };
  }
  paint();
};
canvas.onpointermove = e => {
  lastInput = performance.now();
  const p = point(e);
  if (touches.has(e.pointerId)) touches.set(e.pointerId, p);
  if (pinch && touches.size === 2) {
    const [a, b] = [...touches.values()], mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    const next = Math.min(Math.max(6, fitScale * 5), Math.max(fitScale * .22, pinch.scale * Math.hypot(a.x - b.x, a.y - b.y) / pinch.d));
    scale = next; ox = mx - (pinch.x - pinch.ox) * next / pinch.scale; oy = my - (pinch.y - pinch.oy) * next / pinch.scale;
  } else if (drag && drag.id === e.pointerId) {
    const dx = p.x - drag.x, dy = p.y - drag.y;
    if (drag.moved || Math.hypot(dx, dy) > 4) {
      drag.moved = true;
      ox = drag.ox + dx; oy = drag.oy + dy;
      canvas.dataset.cursor = "drag";
    }
  } else if (!touches.size) {
    hover = hit(p.x, p.y);
    hoverAt = p;
    canvas.dataset.cursor = hover?.node || hover?.beacon ? "pointer" : "";
  }
  paint();
};
canvas.onpointerup = e => {
  touches.delete(e.pointerId);
  if (touches.size < 2) pinch = null;
  if (!drag || drag.id !== e.pointerId) return;
  const moved = drag.moved, p = point(e);
  drag = null;
  canvas.releasePointerCapture(e.pointerId);
  canvas.dataset.cursor = "";
  const target = !moved && hit(p.x, p.y);
  if (target?.beacon) flyToEntity(target.beacon);
  else if (target?.sector) {
    const s = sectors.find(s => s.node === target.node), area = mapArea();
    flyTo(s.x, s.y, Math.max(fitScale * 2.1, Math.min(4, Math.min(area.w, area.h) / (2.2 * s.r))));
  } else if (target?.node) {
    tapped = { id: target.node.id, at: performance.now() };
    inspectFromMap(target.node.id);
  }
  paint();
};
canvas.onpointercancel = e => { touches.delete(e.pointerId); pinch = null; drag = null; hover = null; canvas.dataset.cursor = ""; paint(); };
canvas.onpointerleave = () => { hover = null; paint(); };
canvas.ondblclick = e => {
  const p = point(e), target = tapped && performance.now() - tapped.at < 700 ? { node: nodes.get(tapped.id) } : hit(p.x, p.y);
  tapped = null;
  if (target?.node && !target.sector) loadMap(target.node.id, true);
};
canvas.addEventListener("wheel", e => {
  e.preventDefault();
  lastInput = performance.now();
  const p = point(e), delta = e.deltaY * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? height : 1);
  zoomAt(Math.exp(-Math.max(-180, Math.min(180, delta)) * .0018), p.x, p.y);
}, { passive: false });
document.addEventListener("keydown", e => {
  if (e.ctrlKey || e.metaKey || e.altKey || $("auth").open || e.target.closest("input,select,textarea,[contenteditable=true]")) return;
  const key = e.key.toLowerCase();
  if (e.target !== canvas && e.target !== document.body && e.target !== document.documentElement && !["w", "a", "s", "d"].includes(key)) return;
  lastInput = performance.now();
  if (e.key === "+" || e.key === "=") zoomAt(1.25);
  else if (e.key === "-") zoomAt(.8);
  else if (e.key === "Home") fit(true);
  else if (e.key === "]" || e.key === "[") cycle(e.key === "]" ? 1 : -1);
  else if (e.key === "Enter" && selected) flyToEntity(selected);
  else if (e.key === "Escape" && selected && $("results").hidden) closeInspector();
  else if (["w", "a", "s", "d", "arrowleft", "arrowright", "arrowup", "arrowdown"].includes(key)) {
    targetCamera = null; flight = null; hover = null;
    if (!flightKeys.size) lastFrame = performance.now();
    if (!flightKeys.has(key)) {
      if (key === "a" || key === "arrowleft") ox += 12;
      if (key === "d" || key === "arrowright") ox -= 12;
      if (key === "w" || key === "arrowup") oy += 12;
      if (key === "s" || key === "arrowdown") oy -= 12;
    }
    flightKeys.add(key);
  }
  else return;
  e.preventDefault();
  paint();
});
document.addEventListener("keyup", e => flightKeys.delete(e.key.toLowerCase()));
window.addEventListener("blur", () => flightKeys.clear());


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
  nextSector = null;
  sector = 0;
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
$("load-sector").onclick = () => { if (nextSector && !root) loadMap(null, true); };
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
