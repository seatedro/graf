//! Surface: the `graf` CLI, the MCP stdio server,
//! and `graf serve` (HTTP `/v1/*` + Streamable HTTP `/mcp`, daemon lifecycle, and
//! wiring of ingestion workers, tailers and retrieval into one process). All three
//! front ends call the same handlers.

const std = @import("std");

pub const cli = @import("cli.zig");
pub const mcp = @import("mcp.zig");
pub const http = @import("http.zig");

test {
    std.testing.refAllDecls(@This());
}
