# graf

graf is an always-on, bi-temporal knowledge graph for coding agents. One Zig binary tails your agents' session transcripts, extracts entities and facts with any OpenAI- or Anthropic-compatible model, stores them in Postgres with pgvector, and serves them back to every agent over MCP, HTTP, and a CLI.

Status: pre-alpha. See [AGENTS.md](AGENTS.md) for the layout and how work is split.

## Develop

```sh
nix develop                 # Zig 0.17.1, Postgres 17 + pgvector
nix run .#devdb             # start a local Postgres on 127.0.0.1:54329, prints the env vars
eval "$(nix run .#devdb -- env)"
zig build test              # unit tests; integration tests run when GRAF_TEST_DATABASE_URL is set
zig build run -- config     # print the effective configuration
```

Without Nix, install Zig 0.17.1 and run Postgres 17 with pgvector yourself, for example:

```sh
docker run -d -p 54329:5432 -e POSTGRES_USER=graf -e POSTGRES_PASSWORD=graf -e POSTGRES_DB=graf_test pgvector/pgvector:pg17
export GRAF_TEST_DATABASE_URL=postgres://graf:graf@127.0.0.1:54329/graf_test
```

## Configure

graf reads `~/.config/graf/config.toml` (see [config.example.toml](config.example.toml)) and `GRAF_*` environment variables, which take precedence.

To share one graph across machines, run a hub and point the others at it as edges; see [docs/hub.md](docs/hub.md).

## License

MIT. See [LICENSE](LICENSE).
