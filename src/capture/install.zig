//! `graf install`: writes graf's MCP server and hook entries into each harness's
//! own config, idempotently.

const std = @import("std");
const core = @import("core");
