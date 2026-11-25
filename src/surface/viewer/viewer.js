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
  $("hops").disabled = !root;
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
  $("plot-state").textContent = id ? "Mapping neighborhood…" : "Loading sector…";
  $("plot-state").hidden = false;
  try {
    const data = await api(id ? "neighborhood" : "map", params);
    if (rev !== mapRequest) return;
    nextSector = id ? null : data.next_before;
    sector = id ? 0 : before ? sector + 1 : 1;
    setGraph(data, append, id);
    if (id) flyToEntity(id);
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
const flightKeys = new Set();
let stars = [], landmarks = [], cells = new Map(), bounds, cellSize = 1;
let targetCamera = null, lastFrame = 0, mini = null;

function hash(value) {
  let h = 2166136261;
  for (const c of String(value)) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  return h >>> 0;
}

function mapArea() {
  const rect = canvas.getBoundingClientRect(), dock = $("sidebar").getBoundingClientRect();
  const docked = width > 710 && dock.left > rect.left + width / 2 && dock.left < rect.right;
  const right = docked ? dock.left - rect.left - 16 : width;
  const top = Math.min(84, height * .14), bottom = height - Math.min(128, height * .18);
  return { x: right / 2, y: (top + bottom) / 2, w: right, h: bottom - top };
}

function layout() {
  stars = [...nodes.values()].sort((a, b) => b.degree - a.degree || a.id.localeCompare(b.id));
  landmarks = []; cells = new Map(); bounds = null; mini = null;
  if (!stars.length) { world.upload([], new Float32Array()); if (locator) locator.hidden = true; return; }
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
      n.radius = n.landmark ? 12 + 6 / (1 + n.index * .2) : 4.1 + Math.min(5, Math.log2(1 + n.degree)) + n.seed * 1.4;
      n.tile = n.tint + (n.landmark || stars.length < 60 && n.degree > 1 ? 0 : 2 * colors.length);
      if (n.landmark) landmarks.push(n);
    }
    seed.sectorRadius = radius * Math.max(1, stretch);
  }

  bounds = { x1: Infinity, x2: -Infinity, y1: Infinity, y2: -Infinity };
  for (const n of stars) {
    bounds.x1 = Math.min(bounds.x1, n.x); bounds.x2 = Math.max(bounds.x2, n.x);
    bounds.y1 = Math.min(bounds.y1, n.y); bounds.y2 = Math.max(bounds.y2, n.y);
  }
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
      segments.push(x1, y1, a.index, b.index, level, x2, y2, a.index, b.index, level);
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
  world.upload(stars, new Float32Array(segments));
  rebuildLocator();
}

function rebuildLocator() {
  if (!locator || !bounds) return;
  locator.hidden = false;
  const w = locator.width, h = locator.height;
  const z = Math.min((w - 20) / Math.max(64, bounds.x2 - bounds.x1), (h - 16) / Math.max(48, bounds.y2 - bounds.y1));
  mini = { z, x: (w - (bounds.x1 + bounds.x2) * z) / 2, y: (h - (bounds.y1 + bounds.y2) * z) / 2 };
  locatorImage.width = w; locatorImage.height = h;
  const c = locatorImage.getContext("2d"), r = stars.length > 1200 ? 1 : 2;
  for (const n of stars) {
    c.fillStyle = colors[n.tint];
    c.fillRect(mini.x + n.x * z - r / 2, mini.y + n.y * z - r / 2, r, r);
  }
}

function drawLocator(area, light) {
  if (!locator || !mini || !locator.clientWidth) return;
  const c = locator.getContext("2d"), w = locator.width, h = locator.height;
  c.clearRect(0, 0, w, h);
  c.drawImage(locatorImage, 0, 0);
  c.strokeStyle = light ? "#297789" : "#75d5dd"; c.lineWidth = 1;
  const x = mini.x + ((area.x - area.w / 2 - ox) / scale) * mini.z;
  const y = mini.y + ((area.y - area.h / 2 - oy) / scale) * mini.z;
  const left = Math.max(1, x), top = Math.max(1, y);
  c.strokeRect(left, top, Math.max(0, Math.min(w - 1, x + area.w / scale * mini.z) - left), Math.max(0, Math.min(h - 1, y + area.h / scale * mini.z) - top));
}

if (locator) locator.onclick = e => {
  if (!mini) return;
  const rect = locator.getBoundingClientRect(), area = mapArea();
  const x = ((e.clientX - rect.left) * locator.width / rect.width - mini.x) / mini.z;
  const y = ((e.clientY - rect.top) * locator.height / rect.height - mini.y) / mini.z;
  steer(scale, area.x - x * scale, area.y - y * scale);
};

function fit(animate) {
  const area = mapArea(), b = bounds || { x1: 0, x2: 0, y1: 0, y2: 0 };
  fitScale = Math.max(.005, Math.min(2.15, (area.w - Math.min(120, area.w * .18)) / Math.max(1, b.x2 - b.x1),
    (area.h - Math.min(95, area.h * .16)) / Math.max(1, b.y2 - b.y1)));
  const x = area.x - (b.x1 + b.x2) * fitScale / 2, y = area.y - (b.y1 + b.y2) * fitScale / 2;
  if (animate) steer(fitScale, x, y);
  else { targetCamera = null; scale = fitScale; ox = x; oy = y; paint(); }
}

function resize() {
  const rect = canvas.getBoundingClientRect(), z = Math.min(2.5, devicePixelRatio || 1);
  if (width === rect.width && height === rect.height && canvas.width === Math.round(width * z)) return;
  width = Math.max(1, rect.width); height = Math.max(1, rect.height);
  for (const layer of [canvas, $("world-gpu")]) {
    if (!layer) continue;
    layer.width = Math.round(width * z); layer.height = Math.round(height * z);
  }
  ctx.setTransform(canvas.width / width, 0, 0, canvas.height / height, 0, 0);
  fit();
}

function paint() {
  if (!frame) frame = requestAnimationFrame(draw);
}

function steer(next, x, y) {
  hover = null;
  if (reducedMotion.matches) { scale = next; ox = x; oy = y; targetCamera = null; }
  else targetCamera = { scale: next, x, y };
  paint();
}

function flyToEntity(id) {
  const n = nodes.get(id);
  if (!n) return false;
  const area = mapArea(), next = Math.min(4, Math.max(scale, fitScale * 2.2, 1.5));
  steer(next, area.x - n.x * next, area.y - n.y * next);
  return true;
}

function advanceCamera(time) {
  const dt = Math.min(40, Math.max(1, time - lastFrame));
  lastFrame = time;
  if (targetCamera) {
    const t = 1 - Math.exp(-dt / 69), target = targetCamera;
    ox += (target.x - ox) * t; oy += (target.y - oy) * t; scale += (target.scale - scale) * t;
    if (Math.abs(target.x - ox) + Math.abs(target.y - oy) + Math.abs(target.scale - scale) * 400 < .28) {
      ox = target.x; oy = target.y; scale = target.scale; targetCamera = null;
    } else paint();
  }
  if (flightKeys.size) {
    const dx = Number(flightKeys.has("a") || flightKeys.has("arrowleft")) - Number(flightKeys.has("d") || flightKeys.has("arrowright"));
    const dy = Number(flightKeys.has("w") || flightKeys.has("arrowup")) - Number(flightKeys.has("s") || flightKeys.has("arrowdown"));
    const speed = dt * .62 / Math.max(1, Math.hypot(dx, dy));
    ox += dx * speed; oy += dy * speed;
    paint();
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

function line(x1, y1, x2, y2) {
  ctx.moveTo(x1, y1); ctx.lineTo(x2, y2);
}

function orbits(n, light, focus, primary) {
  const x = ox + n.x * scale, y = oy + n.y * scale, r = world.radius(n, scale, focus);
  if (x < -130 || x > width + 130 || y < -130 || y > height + 130) return;
  const size = Math.max(primary ? 23 : 12, r * (primary ? 1.95 : 1.65));
  const ink = light ? "#355762" : colors[n.tint];
  ctx.save();
  ctx.translate(x, y); ctx.rotate((n.seed - .5) * .9 - .28);
  ctx.strokeStyle = ink + (primary ? "a8" : "88"); ctx.lineWidth = .85;
  ctx.beginPath(); ctx.ellipse(0, 0, size * 1.16, size * .91, 0, .18, 5.99); ctx.stroke();
  ctx.strokeStyle = ink + "45";
  ctx.beginPath(); ctx.ellipse(0, 0, size * 1.39, size, 0, 1.38, 3.9); ctx.stroke();
  if (primary || n.index === focus) {
    ctx.strokeStyle = ink + "70";
    ctx.beginPath();
    for (let i = 0; i < 24; i++) {
      const t = i * Math.PI / 12;
      line(Math.cos(t) * size * 1.62, Math.sin(t) * size * 1.62, Math.cos(t) * (size * 1.62 + (i % 6 ? 2 : 5)), Math.sin(t) * (size * 1.62 + (i % 6 ? 2 : 5)));
    }
    ctx.stroke();
  }
  ctx.restore();
}

function surveyGrid(light) {
  if (!stars.length) return;
  const center = nodes.get(root) || stars[0], x = ox + center.x * scale, y = oy + center.y * scale;
  const size = Math.max(35, Math.min(105, world.radius(center, scale, -1) * 3.2));
  ctx.save(); ctx.translate(x, y);
  ctx.strokeStyle = light ? "#526c802a" : "#88bdbc28"; ctx.lineWidth = .7;
  for (const r of [size * 2.5, size * 4.8, size * 7.3]) {
    ctx.setLineDash([2, 8]);
    ctx.beginPath(); ctx.arc(0, 0, r, 0, Math.PI * 2); ctx.stroke();
  }
  ctx.restore();
}

function labelField(visible, focus, light, area) {
  const ratio = scale / fitScale;
  const budget = Math.ceil(Math.min(58, area.w * area.h / 28000 * Math.min(2.3, Math.max(.6, ratio * .65))));
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

  const local = ratio >= 2 || stars.length < 65;
  const candidates = local ? visible.slice().sort((a, b) => Number(b.index === focus) - Number(a.index === focus) ||
    Number(b.landmark) - Number(a.landmark) || a.index - b.index) : [...landmarks];
  if (!local && focus >= 0) candidates.unshift(stars[focus]);
  labels = [];
  for (const n of candidates) {
    const sx = ox + n.x * scale, sy = oy + n.y * scale;
    if (sx < 0 || sx > area.w || sy < 25 || sy > height - 40) continue;
    const prominent = n.index === focus || n.index === 0;
    const sectorLabel = !local && n.sectorCount && n.index !== focus;
    ctx.font = sectorLabel ? "600 11px ui-monospace, monospace" : prominent ? "600 14px system-ui, sans-serif" : "11px ui-monospace, monospace";
    const title = sectorLabel ? pretty(n.type).toUpperCase() : n.name;
    const name = title.length > 27 ? title.slice(0, 25) + "…" : title;
    const sub = sectorLabel ? number.format(n.sectorCount) + " ENTITIES" : pretty(n.type).toUpperCase();
    const w = Math.max(ctx.measureText(name).width, sectorLabel || prominent ? sub.length * 5.8 + 8 : 0) + 10;
    const h = prominent || sectorLabel ? 36 : 19;
    const r = world.radius(n, scale, focus) * (n.landmark || prominent ? 2.3 : 1.1) + 4;
    const positions = [[sx + r, sy - h / 2], [sx - w - r, sy - h / 2], [sx - w / 2, sy + r], [sx - w / 2, sy - r - h]];
    for (const [x, y] of positions) {
      const box = { x, y, w, h, node: n, sector: Boolean(sectorLabel) };
      if (x < 3 || x + w > area.w - 3 || y < 48 || y + h > height - 72 || intersects(box)) continue;
      const textY = y + (sectorLabel ? 12 : prominent ? 26 : 10);
      ctx.textBaseline = "middle"; ctx.lineJoin = "round"; ctx.lineWidth = 4;
      ctx.strokeStyle = light ? "#eef3f0e0" : "#0c1622e8";
      ctx.strokeText(name, x + 5, textY);
      ctx.fillStyle = light ? "#223948" : sectorLabel ? colors[n.tint] : prominent ? "#f3f6e9" : "#c6d5df";
      ctx.fillText(name, x + 5, textY);
      if (prominent || sectorLabel) {
        ctx.font = "9px ui-monospace, monospace";
        ctx.fillStyle = light ? "#375969" : sectorLabel ? "#b9c6d4" : colors[n.tint];
        ctx.strokeText(sub, x + 5, y + (sectorLabel ? 25 : 10));
        ctx.fillText(sub, x + 5, y + (sectorLabel ? 25 : 10));
      }
      occupy(box); labels.push(box); break;
    }
    if (labels.length >= budget) break;
  }
}

function draw(time) {
  frame = 0;
  advanceCamera(time);
  const area = mapArea(), light = document.documentElement.dataset.theme === "light";
  const focusNode = (!hover?.sector && hover?.node) || nodes.get(selected), focus = focusNode?.index ?? -1;
  const visible = [];
  inCells((-70 - ox) / scale, (-70 - oy) / scale, (width + 70 - ox) / scale, (height + 70 - oy) / scale,
    b => { for (const n of b.nodes) visible.push(n); });
  const alpha = Math.min(.5, (.32 / Math.max(1, Math.sqrt(stars.length / 70))) * Math.max(1, Math.min(8, scale / fitScale)));
  ctx.clearRect(0, 0, width, height);
  surveyGrid(light);
  world.draw(ctx, width, height, ox, oy, scale, light, focus, alpha, visible);
  if (focusNode) {
    ctx.beginPath(); ctx.lineWidth = 1.5; ctx.strokeStyle = light ? "#247988b5" : "#72ddedb0";
    for (const { a, b, distance } of focusNode.routes) {
      if (distance * scale < 28) continue;
      const dx = (b.x - a.x) / distance, dy = (b.y - a.y) / distance;
      const r = world.radius(b, scale, focus) + 3, x = ox + b.x * scale - dx * r, y = oy + b.y * scale - dy * r;
      const start = world.radius(a, scale, focus) + 2;
      line(ox + a.x * scale + dx * start, oy + a.y * scale + dy * start, x, y);
      line(x - 5 * dx + 2 * dy, y - 5 * dy - 2 * dx, x, y);
      line(x - 5 * dx - 2 * dy, y - 5 * dy + 2 * dx, x, y);
    }
    ctx.stroke();
  }
  if (hover?.edge) {
    const a = nodes.get(hover.edge.subject_id), b = nodes.get(hover.edge.object_id);
    ctx.beginPath(); ctx.lineWidth = 1.6; ctx.strokeStyle = light ? "#247988" : "#8bd8e7";
    if (a === b) {
      const r = a.radius * 1.45 * scale;
      ctx.arc(ox + a.x * scale + r, oy + a.y * scale - r, r, 0, Math.PI * 2);
    } else line(ox + a.x * scale, oy + a.y * scale, ox + b.x * scale, oy + b.y * scale);
    ctx.stroke();
  }
  for (const n of landmarks) if (stars.length < 160 || n.index === 0 || n.index === focus) orbits(n, light, focus, n === stars[0]);
  if (focusNode && !focusNode.landmark) orbits(focusNode, light, focus, true);
  labelField(visible, focus, light, area);
  if (hover && hoverAt && !drag) {
    const text = hover.sector ? "Zoom into " + pretty(hover.node.type) : hover.node ? hover.node.name + " · " + pretty(hover.node.type) :
      pretty(hover.edge.relation) + (hover.edge.confidence == null ? "" : " · " + Math.round(hover.edge.confidence * 100) + "%");
    ctx.font = "11px ui-monospace, monospace"; ctx.textBaseline = "middle";
    const w = Math.min(width - 16, ctx.measureText(text).width + 18);
    const x = Math.max(8, Math.min(width - w - 8, hoverAt.x + 12)), y = Math.max(8, Math.min(height - 33, hoverAt.y - 34));
    ctx.fillStyle = light ? "#e7f3f0" : "#172634"; ctx.fillRect(x, y, w, 24);
    ctx.strokeStyle = light ? "#829c9e" : "#405968"; ctx.lineWidth = 1; ctx.strokeRect(x, y, w, 24);
    ctx.fillStyle = light ? "#183340" : "#e1eada"; ctx.fillText(text, x + 9, y + 12, w - 18);
  }
  drawLocator(area, light);
  $("zoom").textContent = Math.round(scale / fitScale * 100) + "%";
}

function hit(x, y) {
  const label = labels.find(l => x >= l.x && x <= l.x + l.w && y >= l.y && y <= l.y + l.h);
  if (label) return { node: label.node, sector: label.sector };
  const wx = (x - ox) / scale, wy = (y - oy) / scale;
  let node = null, distance = Infinity;
  const edges = new Set();
  inCells(wx - 30 / scale, wy - 30 / scale, wx + 30 / scale, wy + 30 / scale, bin => {
    for (const n of bin.nodes) {
      const d = Math.hypot(wx - n.x, wy - n.y) * scale;
      if (d < Math.max(7, world.radius(n, scale, -1) + 3) && d < distance) { distance = d; node = n; }
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
  x ??= area.x; y ??= area.y;
  const next = Math.min(Math.max(6, fitScale * 5), Math.max(fitScale * .22, current.scale * factor));
  steer(next, x - (x - current.x) * next / current.scale, y - (y - current.y) * next / current.scale);
}

new MutationObserver(paint).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
canvas.addEventListener("contextrestored", () => {
  ctx.setTransform(canvas.width / width, 0, 0, canvas.height / height, 0, 0);
  rebuildLocator(); paint();
});

function inspectFromMap(id) {
  inspect(id);
  if (window.matchMedia("(max-width: 710px)").matches) $("sidebar").scrollIntoView({ block: "start" });
}

canvas.onpointerdown = e => {
  if (e.button !== 0 || !e.isPrimary) return;
  targetCamera = null;
  canvas.focus({ preventScroll: true });
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
  if (target?.sector) {
    const n = target.node, area = mapArea();
    const next = Math.max(fitScale * 2.1, Math.min(4, Math.min(area.w, area.h) / (2.2 * n.sectorRadius)));
    steer(next, area.x - n.x * next, area.y - n.y * next);
  } else if (target?.node) inspectFromMap(target.node.id);
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
document.addEventListener("keydown", e => {
  if (e.ctrlKey || e.metaKey || e.altKey || $("auth").open || e.target.closest("input,select,textarea,[contenteditable=true]")) return;
  const key = e.key.toLowerCase();
  if (e.target !== canvas && e.target !== document.body && e.target !== document.documentElement && !["w", "a", "s", "d"].includes(key)) return;
  if (e.key === "+" || e.key === "=") zoomAt(1.25);
  else if (e.key === "-") zoomAt(.8);
  else if (e.key === "Home") fit(true);
  else if (["w", "a", "s", "d", "arrowleft", "arrowright", "arrowup", "arrowdown"].includes(key)) {
    targetCamera = null; hover = null;
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
