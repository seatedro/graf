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

With a token set, every TCP request to `/mcp` and `/v1/*` needs `Authorization: Bearer <token>`; requests over the local Unix socket and `GET /v1/health` do not. `graf serve` refuses to listen on a non-loopback address without a token.

`/mcp` speaks MCP Streamable HTTP: `POST` a JSON-RPC message or batch and get one JSON response, or `202 Accepted` for notifications. The server keeps no sessions and opens no server-initiated streams, so `GET` and `DELETE` answer `405`.

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

Backfilled entries are marked as such. Workers always claim live entries first, and stop claiming backfilled ones once they have spent `limits.backfill_daily_usd` (default $25) in the current UTC day, so a large backfill never starves live ingestion of the overall `limits.daily_usd` budget.

## Remote MCP clients

Clients that speak Streamable HTTP connect to `https://hub.example.ts.net/mcp` with the bearer header, for example:

```sh
claude mcp add --transport http graf https://hub.example.ts.net/mcp --header "Authorization: Bearer $GRAF_HUB_TOKEN"
```

[contrib/plugin](../contrib/plugin) is an Agent Plugins package for the hub's remote server. It asks for the `Authorization` header as a secret; enter `Bearer <token>` as its value and replace the URL with your hub's. A client that cannot reach the tailnet can instead run `graf mcp` over stdio on a machine that can, with `GRAF_UPSTREAM_URL` and `GRAF_UPSTREAM_TOKEN` set.
