# Exploring the graph

Open the [hub](hub.md) in a browser. The world map starts with one sector of real relationships. Load another sector to explore more of the graph without downloading it all at once. Drag to pan, scroll to zoom, or use the keyboard. Select an entity for its evidence; double-click to expand its neighborhood. Search reaches the entire graph, including entities outside the loaded sectors and entities with only scalar facts.

The renderer uses WebGPU on supported hardware, then WebGL2 or Canvas 2D when needed. The status bar shows which one is active. On a large map, clusters group the loaded entities by type; proximity is not evidence of a relationship. Select an entity to highlight its actual links. The browser keeps a rolling window of at most 8,192 entities and 16,384 links. Loading more sectors gives priority to the new data. Selecting a search result takes you to its neighborhood; return to the world map to start surveying again.

Use **Timeline** to choose an instant in local time. A fact is visible when both its validity range and its knowledge range contain that instant. **Include historical facts** also shows facts that ended or were superseded before the instant; it doesn't reveal facts learned later. The inspector shows both ranges, the reason a fact ended, and the source entry and quote when available. Entity descriptions, aliases, merge records, and the inventory counts are current, not reconstructed historical profiles.

## Read API

The viewer uses read-only `POST` routes. Send a JSON object; no query invokes a model. Each route is scoped to the graph configured on the hub.

| Route | Example body | Response |
| --- | --- | --- |
| `/v1/graph/overview` | `{}` | Graph-wide counts, types, projects and relations, top hubs, recent commits, and pending entries. |
| `/v1/graph/map` | `{}` | One sector of at most 2,048 directed edges and their endpoints. Pass `next_before` back as `before` for the next sector; a null cursor marks the end. |
| `/v1/graph/neighborhood` | `{"hops":2,"project":"harbor"}` | Nodes and directed entity-to-entity edges. Pass an entity UUID as `id` to start there instead of at hubs. |
| `/v1/graph/search` | `{"query":"Mooring"}` | Matching entities (including aliases) and facts. Use an entity ID or a fact's subject ID to focus the map. |
| `/v1/graph/entity` | `{"id":"00000000-0000-0000-0000-000000000001"}` | Entity profile, aliases, incident facts with their endpoints and evidence, and merge history. Scalar facts appear here rather than as artificial graph nodes. |

Optional filters are `project`, `type`, `relation`, `min_confidence` (0–1), `as_of` (ISO 8601), and `include_history`. Omit a filter to leave it unrestricted. Hubs rank by the number of incident entity-to-entity facts, including historical facts. A filtered map is a bounded selection of relevant neighborhoods, not a global degree ranking recomputed across every matching fact. The inventory counts always describe the whole graph.

Search returns at most 24 entities and 24 facts. The neighborhood visits up to 12 starting hubs and returns at most 96 edges; `truncated` indicates a work or response limit was reached. The inspector pages through facts by descending ID, with up to 64 facts per page and eight evidence entries per fact. Pass its `next_before` value as `before` to read the next page, or supply a search result's `fact_id` along with its subject's `id` to inspect that fact directly.
