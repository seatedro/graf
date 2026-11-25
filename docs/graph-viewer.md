# Exploring the graph

Open the [hub](hub.md) in a browser. The atlas starts with a neighborhood of hubs, not a download of the entire graph. Click an entity to inspect its incoming and outgoing facts, or double-click to add its neighbors to the map. Change **Depth** to follow relationships two hops. **Browse visible entities** offers the same inspector without using the canvas.

Use **Timeline** to choose an instant in local time. A fact is visible when both its validity range and its knowledge range contain that instant. **Include historical facts** also shows facts that ended or were superseded before the instant; it doesn't reveal facts learned later. The inspector shows both ranges, the reason a fact ended, and the source entry and quote when available. Entity descriptions, aliases, merge records, and the inventory counts are current, not reconstructed historical profiles.

## Read API

The viewer uses four read-only `POST` routes. Send a JSON object; no query invokes a model. Each route is scoped to the graph configured on the hub.

| Route | Example body | Response |
| --- | --- | --- |
| `/v1/graph/overview` | `{}` | Graph-wide counts, types, projects and relations, top hubs, recent commits, and pending entries. |
| `/v1/graph/neighborhood` | `{"hops":2,"project":"harbor"}` | Nodes and directed entity-to-entity edges. Pass an entity UUID as `id` to start there instead of at hubs. |
| `/v1/graph/search` | `{"query":"Mooring"}` | Matching entities (including aliases) and facts. Use an entity ID or a fact's subject ID to focus the map. |
| `/v1/graph/entity` | `{"id":"00000000-0000-0000-0000-000000000001"}` | Entity profile, aliases, incident facts with their endpoints and evidence, and merge history. Scalar facts appear here rather than as artificial graph nodes. |

Optional filters are `project`, `type`, `relation`, `min_confidence` (0–1), `as_of` (ISO 8601), and `include_history`. Omit a filter to leave it unrestricted. Hubs rank by the number of incident entity-to-entity facts, including historical facts. A filtered map is a bounded selection of relevant neighborhoods, not a global degree ranking recomputed across every matching fact. The inventory counts always describe the whole graph.

Search returns at most 24 entities and 24 facts. The neighborhood visits up to 12 starting hubs and returns at most 96 edges; `truncated` indicates a work or response limit was reached. The inspector pages through facts by descending ID, with up to 64 facts per page and eight evidence entries per fact. Pass its `next_before` value as `before` to read the next page, or supply a search result's `fact_id` along with its subject's `id` to inspect that fact directly.
