# Hub and edge

One machine runs the graph as a hub: Postgres, the ingestion workers, and the HTTP server. Every other machine runs an edge that captures its own transcripts and sends them to the hub, so agents on every machine share one graph.

## Hub

Pick a long random token and run `graf serve` with it. The hub listens on loopback; a reverse proxy or Tailscale Serve publishes it with TLS.

```sh
mkdir -p ~/.config/graf
printf 'GRAF_SERVE_TOKEN=%s
' "$(openssl rand -hex 32)" > ~/.config/graf/env
chmod 600 ~/.config/graf/env
install -m 755 zig-out/bin/graf ~/.local/bin/graf
graf init
```

Run it as a user service with [contrib/systemd/graf.service](../contrib/systemd/graf.service), which reads `~/.config/graf/env`:

```sh
install -Dm 644 contrib/systemd/graf.service ~/.config/systemd/user/graf.service
systemctl --user daemon-reload
systemctl --user enable --now graf
loginctl enable-linger "$USER"
curl -fsS http://127.0.0.1:7420/v1/health
```

Publish it on your tailnet. Tailscale Serve terminates TLS and forwards to loopback:

```sh
tailscale serve --bg 7420
curl -fsS https://hub.example.ts.net/v1/health
```

If port 443 already serves another app, use `tailscale serve --bg --https=7443 http://127.0.0.1:7420` and open the URL with `:7443`. If Serve already proxies that port to graf, keep the existing mapping.

Open the HTTPS address in a browser to [explore the graph](graph-viewer.md). The viewer ships inside `graf`; it doesn't load code, fonts, or graph data from a third party. By default, sign in with the hub bearer token. The viewer keeps it in this tab's session storage. The token still has its full API privileges, so give it only to trusted operators.

The viewer shell, static assets, `GET /v1/health`, and the session bootstrap are public. An anonymous session reports only `{"mode":"anonymous"}`. With a token configured, TCP requests for graph data, MCP, ingestion, and hooks otherwise need `Authorization: Bearer <token>`. Local clients can use the permission-restricted Unix socket without a token. Never publish that socket through a proxy.

`/mcp` speaks MCP Streamable HTTP: `POST` a JSON-RPC message or batch and get one JSON response, or `202 Accepted` for notifications. The server keeps no sessions and opens no server-initiated streams, so `GET` and `DELETE` answer `405`.

### Sign in with Tailscale Serve

To grant read-only viewer access without sharing the hub token, set the exact HTTPS origin printed by `tailscale serve status` (including any non-default port, without a trailing slash) and restart `graf serve`:

```toml
# ~/.config/graf/config.toml
[serve]
listen = "127.0.0.1:7420"
tailscale_origin = "https://hub.example.ts.net"
tailscale_logins = ["user@example.org"]
```

`GRAF_SERVE_TAILSCALE_ORIGIN` overrides the origin. The login list matches exact Tailscale user logins. If you omit it or leave it empty, **every untagged user allowed to reach Serve by the tailnet policy** can read the entire graph, including evidence quotes. Project filters are navigation, not access controls. Tagged devices, Funnel requests, and users outside the list do not get header-authenticated access. Tagged automation can keep using its bearer token.

Point Tailscale **Serve** directly at the loopback TCP listener. Graf checks that both the listener and the connecting peer are loopback, the request Host and forwarded HTTPS host match the configured origin, and Serve supplied a user login. The identity grants access only to the viewer's four read-only graph operations, never to MCP, writes, hooks, or the older API. Loopback is a **host trust boundary**: another process on the hub could impersonate Serve. Enable this mode only when you trust all local users and applications, and no other proxy passes client-supplied identity headers to this port.

Keep a bearer token configured on any published hub. Without one, a direct loopback client can use a standalone local hub, but enabling `tailscale_origin` disables tokenless TCP access to the older API even from localhost. Graf refuses a non-loopback listener without a token and refuses Tailscale header authentication on a non-loopback listener. Other reverse proxies should preserve the public Host, serve over HTTPS, and use bearer sign-in; do not enable identity-header authentication for them.

## Edge

On a laptop, point graf at the hub instead of a database:

```toml
# ~/.config/graf/config.toml
[edge]
upstream = "https://hub.example.ts.net"
token = "<the hub's token>"
```

or set `GRAF_UPSTREAM_URL` and `GRAF_UPSTREAM_TOKEN`, then run `graf serve` (or `graf serve --edge --upstream https://hub.example.ts.net`). The same systemd unit works. An edge:

- runs no database and makes no model calls;
- tails local Claude Code, Codex, pi and fx transcripts, redacts each entry, and appends it to `~/.local/state/graf/edge/spool.jsonl` before pushing it to the hub's `POST /v1/entries`. While the hub is unreachable entries wait there and are retried with backoff; the hub's content hash makes a repeated push a no-op. Entries the hub rejects as malformed move to `edge/rejected.jsonl`;
- keeps transcript cursors in `edge/cursors.jsonl`, so a restart resumes where it stopped;
- answers `graf hook` on its local socket: flushes run locally, briefs and recall come from the hub, and a hook gives up silently when the hub is slow or offline.

With an upstream configured, `graf mcp` and `graf search|entity|remember|forget` talk to the hub directly. `graf doctor` reports whether the hub is reachable and how many entries are waiting.

## Backfill

Live capture starts at the first `graf serve` on each machine and records that moment in `~/.local/state/graf/capture-since`. `graf backfill` covers everything before it, so the two never overlap:

```sh
graf backfill --dry-run                 # count files, turns, new entries and the estimated cost; writes nothing
graf backfill --since 30d --max-entries 2000
graf backfill --harness claude-code,codex --cap-usd 15
```

On a hub it enqueues entries straight into Postgres; on an edge (with an upstream configured) it redacts locally and pushes them to the hub's `POST /v1/entries`, without touching the edge spool. Both scan every `~/.claude*` and `~/.codex*` profile plus `~/.pi/agent` and `~/.fx`; a hub also reads Capy history when `sources.capy` is enabled. Entries go out oldest first with their original timestamps, and the content hash makes a rerun skip what is already stored, so `--max-entries` and `--cap-usd` (checked against the estimated cost) can split a large history across several runs.

Backfilled entries are marked as such. Workers always claim live entries first, and stop claiming backfilled ones once they have spent `limits.backfill_daily_usd` (default $250) in the current UTC day. The overall `limits.daily_usd` still caps the total, so set `backfill_daily_usd` below it when live ingestion should always keep some of the day's budget.

## Remote MCP clients

Clients that speak Streamable HTTP connect to `https://hub.example.ts.net/mcp` with the bearer header, for example:

```sh
claude mcp add --transport http graf https://hub.example.ts.net/mcp --header "Authorization: Bearer $GRAF_HUB_TOKEN"
```

[contrib/plugin](../contrib/plugin) is an Agent Plugins package for the hub's remote server. It asks for the `Authorization` header as a secret; enter `Bearer <token>` as its value and replace the URL with your hub's. A client that cannot reach the tailnet can instead run `graf mcp` over stdio on a machine that can, with `GRAF_UPSTREAM_URL` and `GRAF_UPSTREAM_TOKEN` set.
