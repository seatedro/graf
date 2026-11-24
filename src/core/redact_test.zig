const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const redactor = @import("redact.zig");
const redact = redactor.redact;
const Kind = redactor.Kind;

const b62 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const b64 = b62 ++ "+/";
const b64url = b62 ++ "-_";
const hex = "0123456789abcdef";
const upper36 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const digits = "0123456789";

const Gen = struct {
    arena: Allocator,
    prng: std.Random.DefaultPrng,

    fn init(arena: Allocator, seed: u64) Gen {
        return .{ .arena = arena, .prng = .init(seed) };
    }

    fn chars(g: *Gen, alphabet: []const u8, n: usize) ![]const u8 {
        const out = try g.arena.alloc(u8, n);
        const r = g.prng.random();
        for (out) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        return out;
    }

    fn cat(g: *Gen, parts: []const []const u8) ![]const u8 {
        return std.mem.concat(g.arena, u8, parts);
    }

    fn below(g: *Gen, n: usize) usize {
        return g.prng.random().uintLessThan(usize, n);
    }
};

fn fail(comptime what: []const u8, input: []const u8, out: []const u8, detail: []const u8) error{TestUnexpectedResult} {
    std.debug.print("\n" ++ what ++ ": {s}\n  in:  {s}\n  out: {s}\n", .{ detail, input, out });
    return error.TestUnexpectedResult;
}

fn expectIdempotent(arena: Allocator, once: []const u8) !void {
    const twice = try redact(arena, once);
    if (twice.ptr != once.ptr) return fail("not idempotent", once, twice, "");
}

fn expectRedacted(arena: Allocator, input: []const u8, secrets: []const []const u8, kind: Kind, kept: []const []const u8) !void {
    const out = try redact(arena, input);
    for (secrets) |secret| {
        if (std.mem.indexOf(u8, out, secret) != null) return fail("leaked", input, out, secret);
    }

    const marker = try std.fmt.allocPrint(arena, "[REDACTED:{s}]", .{@tagName(kind)});
    if (std.mem.indexOf(u8, out, marker) == null) return fail("missing marker", input, out, marker);
    for (kept) |k| {
        if (std.mem.indexOf(u8, out, k) == null) return fail("lost context", input, out, k);
    }

    try expectIdempotent(arena, out);
}

fn expectExact(arena: Allocator, input: []const u8, expected: []const u8) !void {
    const out = try redact(arena, input);
    if (!std.mem.eql(u8, out, expected)) return fail("unexpected output", input, out, expected);
    try expectIdempotent(arena, out);
}

fn expectUnchanged(arena: Allocator, input: []const u8) !void {
    const out = try redact(arena, input);
    if (out.ptr != input.ptr) return fail("false positive", input, out, "");
}

fn marked(g: *Gen, before: []const u8, kind: Kind, after: []const u8) ![]const u8 {
    return g.cat(&.{ before, "[REDACTED:", @tagName(kind), "]", after });
}

test "returns the input slice itself when nothing matched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = "nothing secret in here";
    const out = try redact(arena.allocator(), input);
    try testing.expect(out.ptr == input.ptr and out.len == input.len);
    try testing.expectEqualStrings("", try redact(arena.allocator(), ""));
}

test "api key prefixes are redacted at token boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 1);

    const xox_body = try g.cat(&.{ try g.chars(digits, 12), "-", try g.chars(digits, 13), "-", try g.chars(b62, 24) });
    const keys = [_][]const u8{
        try g.cat(&.{ "sk-ant-", "api03-", try g.chars(b64url, 93), "AA" }),
        try g.cat(&.{ "sk-", "proj-", try g.chars(b64url, 120) }),
        try g.cat(&.{ "sk-", try g.chars(b62, 48) }),
        try g.cat(&.{ "sk_", "live_", try g.chars(b62, 24) }),
        try g.cat(&.{ "rk_", "test_", try g.chars(b62, 24) }),
        try g.cat(&.{ "ghp", "_", try g.chars(b62, 36) }),
        try g.cat(&.{ "gho", "_", try g.chars(b62, 36) }),
        try g.cat(&.{ "ghu", "_", try g.chars(b62, 36) }),
        try g.cat(&.{ "ghs", "_", try g.chars(b62, 36) }),
        try g.cat(&.{ "ghr", "_", try g.chars(b62, 36) }),
        try g.cat(&.{ "github", "_pat_", try g.chars(b62 ++ "_", 82) }),
        try g.cat(&.{ "glpat", "-", try g.chars(b62, 20) }),
        try g.cat(&.{ "xoxb", "-", xox_body }),
        try g.cat(&.{ "xoxp", "-", xox_body }),
        try g.cat(&.{ "xoxe", "-", xox_body }),
        try g.cat(&.{ "xapp", "-", try g.chars(b62, 30) }),
        try g.cat(&.{ "AK", "IA", try g.chars(upper36, 16) }),
        try g.cat(&.{ "AS", "IA", try g.chars(upper36, 16) }),
        try g.cat(&.{ "AI", "za", try g.chars(b64url, 35) }),
        try g.cat(&.{ "npm", "_", try g.chars(b62, 36) }),
    };

    const contexts = [_][2][]const u8{
        .{ "the key is ", " so rotate it" },
        .{ "(", ")" },
        .{ "\"", "\"," },
        .{ "key:", "\n" },
        .{ "", "" },
    };

    for (keys) |key| {
        for (contexts) |ctx| {
            const input = try g.cat(&.{ ctx[0], key, ctx[1] });
            try expectExact(a, input, try marked(&g, ctx[0], .api_key, ctx[1]));
        }
    }
}

test "api key look-alikes survive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inputs = [_][]const u8{
        "pip install sk-learn and import sk-learn-compat",
        "The task-runner retries three times before giving up.",
        "a risk-assessment-framework-for-teams document",
        "sk-learn-compatible-estimator-wrapper",
        "ask-the-expert-panel-recommendations-list",
        "ghp_short and gho_tiny are too short",
        "AKIA is the prefix to look for, AKIAEXAMPLE is not a key",
        "xoxb-1234 is truncated",
        "AIza is a prefix",
        "the npm_config_cache variable",
    };

    for (inputs) |input| try expectUnchanged(a, input);
}

test "jwts are redacted whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 2);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const payload_json = "{\"sub\":\"user-4821\",\"name\":\"Brackwater Tester\",\"iat\":1700000000}";
    const header = enc.encode(try a.alloc(u8, enc.calcSize(header_json.len)), header_json);
    const payload = enc.encode(try a.alloc(u8, enc.calcSize(payload_json.len)), payload_json);
    const sig = try g.chars(b64url, 43);
    const jwt = try g.cat(&.{ header, ".", payload, ".", sig });
    const unsigned = try g.cat(&.{ header, ".", payload, "." });

    try expectExact(a, try g.cat(&.{ "token from login: ", jwt, " (expires in 1h)" }), "token from login: [REDACTED:jwt] (expires in 1h)");
    try expectExact(a, try g.cat(&.{ "Cookie: session=", jwt, "; Path=/" }), "Cookie: session=[REDACTED:jwt]; Path=/");
    try expectExact(a, try g.cat(&.{ "https://app.example.test/cb?id_token=", jwt, "&state=abc" }), "https://app.example.test/cb?id_token=[REDACTED:jwt]&state=abc");
    try expectExact(a, try g.cat(&.{ "unsigned ", unsigned, " token" }), "unsigned [REDACTED:jwt] token");
    try expectRedacted(a, try g.cat(&.{ "{\"jwt\":\"", jwt, "\"}" }), &.{ payload, sig }, .jwt, &.{"{\"jwt\":\""});
    try expectUnchanged(a, "eyJ is how base64 JSON starts; eyJhbGci.short is not a token");
}

test "pem blocks are redacted through the matching END line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 3);

    const l1 = try g.chars(b64, 64);
    const l2 = try g.chars(b64, 64);
    const l3 = try g.chars(b64, 40);
    const labels = [_][]const u8{ "RSA PRIVATE KEY", "OPENSSH PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY", "ENCRYPTED PRIVATE KEY", "CERTIFICATE" };

    for (labels) |label| {
        const block = try g.cat(&.{ "-----BEGIN ", label, "-----\n", l1, "\n", l2, "\n", l3, "==\n-----END ", label, "-----" });
        try expectExact(a, try g.cat(&.{ "Here is the key:\n", block, "\nDone." }), "Here is the key:\n[REDACTED:pem]\nDone.");
    }

    const escaped = try g.cat(&.{ "{\"key\": \"-----BEGIN EC PRIVATE KEY-----\\n", l1, "\\n", l2, "\\n-----END EC PRIVATE KEY-----\\n\"}" });
    try expectExact(a, escaped, "{\"key\": \"[REDACTED:pem]\\n\"}");
    const unterminated = try g.cat(&.{ "cat id_ed25519 output:\n-----BEGIN OPENSSH PRIVATE KEY-----\n", l1, "\n", l2[0..30] });
    try expectExact(a, unterminated, "cat id_ed25519 output:\n[REDACTED:pem]");
    const mismatched = try g.cat(&.{ "-----BEGIN RSA PRIVATE KEY-----\n", l1, "\n-----END CERTIFICATE-----\n", l2 });
    try expectExact(a, mismatched, "[REDACTED:pem]");
    try expectUnchanged(a, "a line of ----- dashes and -----BEGIN lower case-----");
}

test "secret assignments redact only the value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 4);

    const cases = [_][2][]const u8{
        .{ "MOORING_API_KEY=", "" },
        .{ "export DB_PASSWORD=\"", "\"" },
        .{ "export DB_PASSWORD='", "'" },
        .{ "password: ", "\n" },
        .{ "  client_secret: ", " # rotated monthly" },
        .{ "{\"client_secret\": \"", "\"}" },
        .{ "{\"apiKey\":\"", "\",\"region\":\"west\"}" },
        .{ "{\\\"api_key\\\": \\\"", "\\\"}" },
        .{ "{\"cmd\": \"export BRACKWATER_TOKEN=", "\\nrun\"}" },
        .{ "brackwater deploy --api-key ", " --region west" },
        .{ "brackwater deploy --token=", "" },
        .{ "curl https://api.example.test/v1/items?access_token=", "&page=2" },
        .{ "const apiKey = \"", "\";" },
        .{ "BRACKWATER_SIGNING_KEY=", "" },
        .{ "X-Api-Key: ", "" },
        .{ "**Password**: ", "" },
        .{ "secret = '", "'" },
        .{ "db.password=", "\n" },
        .{ "AUTH_TOKEN := \"", "\"" },
        .{ "\"credentials\" => \"", "\"" },
        .{ "PGPASSWORD=", " psql -h db.example.test" },
        .{ "set BRACKWATER_TOKEN=", " && run" },
        .{ "passphrase = ", "\n" },
        .{ "  auth: ", "\n" },
        .{ "brackwater-db --password ", "" },
        .{ "DB_PW=", "" },
        .{ "private_key: ", "" },
        .{ "cloud_secret_access_key = ", "" },
    };

    for (cases) |c| {
        const value = try g.cat(&.{ try g.chars(b62, 10), try g.chars(digits, 2), try g.chars(b62, 6) });
        try expectExact(a, try g.cat(&.{ c[0], value, c[1] }), try marked(&g, c[0], .assignment, c[1]));
    }

    const spaced = "correct horse battery staple";
    try expectExact(a, "export BRACKWATER_PASSWORD=\"" ++ spaced ++ "\"", "export BRACKWATER_PASSWORD=\"[REDACTED:assignment]\"");
    try expectExact(a, "password=hunter2", "password=[REDACTED:assignment]");
    try expectExact(a, "PASSWORD=s3cr3t!", "PASSWORD=[REDACTED:assignment]");
}

test "assignment look-alikes survive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inputs = [_][]const u8{
        "token_count: 1500",
        "max_tokens=4000",
        "\"input_tokens\": 1234, \"output_tokens\": 99",
        "\"prompt_tokens\": \"812\"",
        "password: \"\"",
        "API_KEY=${BRACKWATER_API_KEY}",
        "TOKEN=$BRACKWATER_TOKEN",
        "BRACKWATER_API_KEY=<your-key-here>",
        "PASSWORD=********",
        "auth: true",
        "secret: null",
        "api_key: str = Field(default=None)",
        "  password: string;",
        "token: Option<String>,",
        "secret: []const u8,",
        "token: u32,",
        "const token = getToken();",
        "self.password = password",
        "password = os.environ[\"DB_PASSWORD\"]",
        "api_key = os.getenv(\"BRACKWATER_KEY\")",
        "token => token.trim()",
        "auth_type: oauth",
        "tokenizer: cl100k_base",
        "Author: Alexander Hamilton",
        "Authored-by: Jane Example",
        "PWD=/home/user/src/graf",
        "if token == expected:",
        "token_url = \"https://auth.example.test/oauth/token\"",
        "password_file: /etc/brackwater/db.pass",
        "api_key=[REDACTED:assignment]",
        "Use the --token flag to pass it",
        "use std::auth::login;",
        "npm run auth:login",
        "The password is stored in the vault.",
        "Rotate the token: it expires soon.",
        "secrets: 3 found",
        "Tokens: 14,023 in",
        "auth: { type: \"oauth\" }",
        "password_min_length = 12",
        "expires_in: 3600",
        "AUTH_ENABLED=1",
        "grant_type=client_credentials&scope=read",
    };

    for (inputs) |input| try expectUnchanged(a, input);
}

test "authorization headers and bare bearer or basic credentials" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 5);

    const tok = try g.chars(b64url, 40);
    const short = try g.cat(&.{ "brackwater", try g.chars(digits, 6) });
    const enc = std.base64.standard.Encoder;
    const pair = "brackwater-user:Zq8vN2rT6pLx";
    const basic = enc.encode(try a.alloc(u8, enc.calcSize(pair.len)), pair);

    try expectExact(a, try g.cat(&.{ "Authorization: Bearer ", tok }), "Authorization: Bearer [REDACTED:bearer]");
    try expectExact(a, try g.cat(&.{ "Authorization: Bearer ", short }), "Authorization: Bearer [REDACTED:bearer]");
    try expectExact(a, "Authorization: Bearer abcdefghij", "Authorization: Bearer [REDACTED:bearer]");
    try expectExact(a, try g.cat(&.{ "curl -H \"Authorization: Bearer ", tok, "\" https://api.example.test/v1" }), "curl -H \"Authorization: Bearer [REDACTED:bearer]\" https://api.example.test/v1");
    try expectExact(a, try g.cat(&.{ "{\"Authorization\": \"Bearer ", tok, "\"}" }), "{\"Authorization\": \"Bearer [REDACTED:bearer]\"}");
    try expectExact(a, try g.cat(&.{ "{\\\"authorization\\\":\\\"Bearer ", tok, "\\\"}" }), "{\\\"authorization\\\":\\\"Bearer [REDACTED:bearer]\\\"}");
    try expectExact(a, try g.cat(&.{ "authorization: Basic ", basic }), "authorization: Basic [REDACTED:bearer]");
    try expectExact(a, try g.cat(&.{ "Authorization: Token ", short }), "Authorization: Token [REDACTED:bearer]");
    try expectExact(a, try g.cat(&.{ "send it as Bearer ", tok, " in the header" }), "send it as Bearer [REDACTED:bearer] in the header");
    try expectExact(a, try g.cat(&.{ "use Basic ", basic, " for the proxy" }), "use Basic [REDACTED:bearer] for the proxy");

    const inputs = [_][]const u8{
        "Bearer tokens are sent in the Authorization header.",
        "Basic usage of the CLI is documented in the README.",
        "Basic Authentication is weak.",
        "Authorization: Bearer <token>",
        "Authorization: Bearer $BRACKWATER_TOKEN",
        "Authorization: Bearer ${TOKEN}",
        "Authorization: Bearer [REDACTED:bearer]",
    };
    for (inputs) |input| try expectUnchanged(a, input);
}

test "credentials in urls keep scheme, user and host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 6);

    const pw = try g.chars(b62, 14);
    try expectExact(a, try g.cat(&.{ "postgres://graf:", pw, "@db.example.test:5432/graf" }), "postgres://graf:[REDACTED:url_credentials]@db.example.test:5432/graf");
    try expectExact(a, try g.cat(&.{ "git clone https://deploy:", pw, "@git.example.test/brackwater/repo.git" }), "git clone https://deploy:[REDACTED:url_credentials]@git.example.test/brackwater/repo.git");
    try expectExact(a, try g.cat(&.{ "REDIS_URL=redis://:", pw, "@cache.example.test:6379/0" }), "REDIS_URL=redis://:[REDACTED:url_credentials]@cache.example.test:6379/0");
    try expectExact(a, try g.cat(&.{ "amqp://brackwater:", pw, "@x", pw, "@mq.example.test" }), "amqp://brackwater:[REDACTED:url_credentials]@mq.example.test");
    try expectExact(a, try g.cat(&.{ "\"dsn\": \"postgresql://root:", pw, "@127.0.0.1/app\"" }), "\"dsn\": \"postgresql://root:[REDACTED:url_credentials]@127.0.0.1/app\"");

    const inputs = [_][]const u8{
        "https://mooring.example.test/v1",
        "http://localhost:8080/path?q=1#frag",
        "git@git.example.test:brackwater/repo.git",
        "postgres://graf:<password>@db.example.test/graf",
        "postgres://graf:$DB_PASSWORD@db.example.test/graf",
        "https://registry.example.test/@brackwater/pkg",
        "ssh://git@git.example.test/brackwater/repo",
        "postgres://graf:[REDACTED:url_credentials]@db.example.test/graf",
    };
    for (inputs) |input| try expectUnchanged(a, input);
}

test "high-entropy hex and base64 strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 7);

    const sha1 = try g.chars(hex, 40);
    const sha256 = try g.chars(hex, 64);
    try expectExact(a, try g.cat(&.{ "commit ", sha1, " fixed it" }), "commit [REDACTED:high_entropy] fixed it");
    try expectExact(a, try g.cat(&.{ "sha256:", sha256 }), "sha256:[REDACTED:high_entropy]");
    try expectExact(a, try g.cat(&.{ "key 0x", sha256, "." }), "key [REDACTED:high_entropy].");

    const blob = try g.cat(&.{ try g.chars(b64, 42), "==" });
    try expectExact(a, try g.cat(&.{ "{\"blob\": \"", blob, "\"}" }), "{\"blob\": \"[REDACTED:high_entropy]\"}");
    const url_safe = try g.chars(b64url, 43);
    try expectExact(a, try g.cat(&.{ "value ", url_safe, " end" }), "value [REDACTED:high_entropy] end");
    const segment = try g.chars(b62, 48);
    try expectExact(a, try g.cat(&.{ "/var/cache/brackwater/", segment, "/data.bin" }), "/var/cache/brackwater/[REDACTED:high_entropy]/data.bin");
}

test "random secrets of 56 or more characters never leak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 8);

    const alphabets = [_][]const u8{ b62, b64, b64url };
    for (0..600) |n| {
        const secret = try g.chars(alphabets[n % alphabets.len], 56 + g.below(40));
        try expectRedacted(a, try g.cat(&.{ "value ", secret, " end" }), &.{secret}, .high_entropy, &.{ "value ", " end" });
    }

    for (0..300) |n| {
        const secret = try g.chars(hex, 32 + (n % 3) * 16);
        try expectRedacted(a, try g.cat(&.{ "digest ", secret, " end" }), &.{secret}, .high_entropy, &.{ "digest ", " end" });
    }
}

const ordinary = [_][]const u8{
    "/home/user/src/capture/tailer_test_fixture.zig",
    "std.Io.Writer.Allocating",
    "thisIsAVeryLongCamelCaseFunctionName",
    "SCREAMING_SNAKE_CASE_CONSTANT_NAME",
    "550e8400-e29b-41d4-a716-446655440000",
    "F47AC10B-58CC-4372-A567-0E02B2C3D479",
    "https://mooring.example.test/v1/berths?pier=brackwater-north&stream=true",
    "See https://docs.example.test/guides/authentication#bearer-tokens for details.",
    "getUserAuthenticationTokenFromRequestContext(ctx)",
    "AbstractSingletonProxyFactoryBeanImplementation",
    "ReactDOMServerRenderToPipeableStreamOptions",
    "HTTPServerRequestHandlerV2ForStreamingResponses",
    "x86_64-unknown-linux-gnu-toolchain-1.99.0",
    "node_modules/@types/node/globals.d.ts",
    "/Users/jane/Library/Application Support/Code/User/settings.json",
    "C:\\Users\\jane\\AppData\\Local\\brackwater\\cache\\index.json",
    "kubernetes-io-cluster-autoscaler-node-group-2",
    "testRedactLeavesOrdinaryProseUntouchedForAllInputs",
    "io_uring_prep_read_fixed_buffer_registration",
    "src/capture/testdata/redact/false_positive_corpus_long_name.txt",
    "The quick brown fox jumps over the lazy dog, then naps.",
    "fn redact(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {",
    "const max_tokens: u32 = 4096;",
    "git commit -m \"fix: handle empty transcripts\" && git push",
    "commit abc1234 (HEAD -> main)",
    "Ünïcödé prose — with em dashes, emoji 🙂 and 漢字 stays put.",
    "pip install scikit-learn && pip install sk-learn-extras",
    "zig build test-capture --summary all",
    "ERROR: connection refused (os error 111) at 127.0.0.1:54329",
    "2026-11-24T10:15:30.123456Z INFO request_id=req_01HZX3 latency_ms=42",
    "| name | type | default |",
    "import { useInfiniteQueryWithSuspense } from '@brackwater/react-query-extras';",
    "SELECT id, created_at FROM entries WHERE project_id = $1 ORDER BY created_at DESC;",
    "[REDACTED:api_key] and [REDACTED:high_entropy] are markers",
    "version = \"0.17.1\"",
    "https://registry.example.test/@brackwater/pkg/-/pkg-1.2.3.tgz",
    "git@git.example.test:brackwater/graf.git",
    "The tokenizer splits text into tokens; the author documented the authority model.",
    "Set the password policy before you rotate credentials.",
    "Each turn is redacted before storage and before any model call.",
    "https://example.test/a/very/long/path/with/many/segments/that/keeps/going/and/going",
};

test "false-positive corpus comes back byte-identical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (ordinary) |input| try expectUnchanged(a, input);
    const joined = try std.mem.join(a, "\n", &ordinary);
    try expectUnchanged(a, joined);
}

test "eval secret entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 9);

    const mooring_key = try g.cat(&.{ "mr_", "live_", try g.chars(b62, 40) });
    const turn1 = try g.cat(&.{ "Try hitting Mooring with MOORING_API_KEY=", mooring_key, " and verify the staging URL https://mooring.example.test/v1 responds" });
    try expectExact(a, turn1, "Try hitting Mooring with MOORING_API_KEY=[REDACTED:assignment] and verify the staging URL https://mooring.example.test/v1 responds");

    const model_key = try g.cat(&.{ "sk-ant-", "api03-", try g.chars(b64url, 88), "AA" });
    const turn2 = try g.cat(&.{ "Use this key for the fallback booking service: ", model_key, " and keep it out of the repo." });
    try expectExact(a, turn2, "Use this key for the fallback booking service: [REDACTED:api_key] and keep it out of the repo.");

    const tool_args = try g.cat(&.{ "{\"command\":\"curl -s -H \\\"x-api-key: ", model_key, "\\\" https://mooring.example.test/v1/berths\"}" });
    try expectRedacted(a, tool_args, &.{ model_key, model_key[20..60] }, .api_key, &.{ "https://mooring.example.test/v1/berths", "x-api-key: " });
    try expectRedacted(a, mooring_key, &.{mooring_key[8..]}, .high_entropy, &.{});
}

test "utf-8 sequences next to secrets stay intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 10);

    const v = try g.cat(&.{ try g.chars(b62, 12), "7" });
    const tok = try g.chars(b64url, 40);
    const input = try g.cat(&.{ "密钥 password=", v, " ✓ 完成\n🙂 Bearer ", tok, "—ok\n«", tok, "»" });

    const out = try redact(a, input);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
    try testing.expect(std.mem.indexOf(u8, out, v) == null);
    try testing.expect(std.mem.indexOf(u8, out, tok) == null);
    for ([_][]const u8{ "密钥 ", "✓ 完成", "🙂", "—ok", "«", "»" }) |kept| {
        try testing.expect(std.mem.indexOf(u8, out, kept) != null);
    }
    try expectIdempotent(a, out);
}

fn appendSecretLine(g: *Gen, out: *std.ArrayList(u8), secrets: *std.ArrayList([]const u8), n: usize) !void {
    const a = g.arena;
    const secret, const line = switch (n % 8) {
        0 => blk: {
            const s = try g.cat(&.{ "sk-ant-", "api03-", try g.chars(b64url, 90) });
            break :blk .{ s, try g.cat(&.{ "key ", s, " here\n" }) };
        },
        1 => blk: {
            const s = try g.cat(&.{ "ghp", "_", try g.chars(b62, 36) });
            break :blk .{ s, try g.cat(&.{ "GH_TOKEN=", s, "\n" }) };
        },
        2 => blk: {
            const s = try g.chars(b62, 20);
            break :blk .{ s, try g.cat(&.{ "{\"password\": \"", s, "\"}\n" }) };
        },
        3 => blk: {
            const s = try g.chars(b64url, 40);
            break :blk .{ s, try g.cat(&.{ "Authorization: Bearer ", s, "\n" }) };
        },
        4 => blk: {
            const s = try g.chars(b62, 16);
            break :blk .{ s, try g.cat(&.{ "postgres://app:", s, "@db.example.test/app\n" }) };
        },
        5 => blk: {
            const s = try g.chars(hex, 64);
            break :blk .{ s, try g.cat(&.{ "digest ", s, "\n" }) };
        },
        6 => blk: {
            const s = try g.chars(b64, 64);
            break :blk .{ s, try g.cat(&.{ "-----BEGIN PRIVATE KEY-----\n", s, "\n-----END PRIVATE KEY-----\n" }) };
        },
        else => blk: {
            const s = try g.chars(b62, 64);
            break :blk .{ s, try g.cat(&.{ "blob ", s, " end\n" }) };
        },
    };

    try secrets.append(a, secret);
    try out.appendSlice(a, line);
}

test "200 KB mixed corpus is leak-free, idempotent and fast" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 11);

    var corpus: std.ArrayList(u8) = .empty;
    var secrets: std.ArrayList([]const u8) = .empty;
    var n: usize = 0;
    while (corpus.items.len < 200 * 1024) : (n += 1) {
        try corpus.appendSlice(a, ordinary[n % ordinary.len]);
        try corpus.append(a, '\n');
        if (n % 3 == 0) try appendSecretLine(&g, &corpus, &secrets, n / 3);
    }

    const io = testing.io;
    const started = std.Io.Clock.awake.now(io);
    const out = try redact(a, corpus.items);
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io));

    for (secrets.items) |secret| {
        if (std.mem.indexOf(u8, out, secret) != null) return fail("leaked", "200 KB corpus", "", secret);
    }
    for (ordinary) |line| {
        if (std.mem.indexOf(u8, out, line) == null) return fail("lost line", "200 KB corpus", "", line);
    }
    try expectIdempotent(a, out);
    try testing.expect(elapsed.toMilliseconds() < 2000);
}

test "pathological inputs stay linear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 12);

    const units = [_][]const u8{
        "-----BEGIN ",
        "-----BEGIN A-----",
        "-----END A-----",
        "a://",
        "u:p@",
        "token=",
        "token: ",
        "\"password\": \"",
        "--token ",
        "Bearer ",
        "eyJ",
        "x",
        "=",
        "/",
        "sk-",
        "\\\"",
    };

    const io = testing.io;
    for (units) |unit| {
        var buf: std.ArrayList(u8) = .empty;
        while (buf.items.len < 64 * 1024) try buf.appendSlice(a, unit);
        const started = std.Io.Clock.awake.now(io);
        const out = try redact(a, buf.items);
        try testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000);
        try expectIdempotent(a, out);
    }

    const random_run = try g.chars(b64, 64 * 1024);
    try expectExact(a, random_run, "[REDACTED:high_entropy]");
}

test "random mashups of secrets, markers and punctuation are idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Gen.init(a, 13);

    const pieces = [_][]const u8{
        " ",                               "\n",                            "=",        ": ",            "\"",
        "'",                               "\\\"",                          "/",        "://",           "@",
        "-",                               "_",                             ".",        ",",             "[",
        "]",                               "{",                             "}",        "(",             ")",
        "password",                        "token",                         "API_KEY",  "Authorization", "Bearer ",
        "Basic ",                          "sk-ant-api03-",                 "ghp_",     "AKIA",          "eyJ",
        "-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----", "https://", "user:",         "[REDACTED:assignment]",
        "export ",                         "--api-key ",                    "the ",     "path/to/file",  "0x",
        "é",
        "🙂",
        "$",                               "<tok>",                         "**",
    };

    for (0..20000) |_| {
        var buf: std.ArrayList(u8) = .empty;
        for (0..2 + g.below(12)) |_| {
            if (g.below(4) == 0) {
                try buf.appendSlice(a, try g.chars(b62, 4 + g.below(50)));
            } else {
                try buf.appendSlice(a, pieces[g.below(pieces.len)]);
            }
        }

        const once = try redact(a, buf.items);
        try testing.expect(std.unicode.utf8ValidateSlice(once));
        try expectIdempotent(a, once);
    }
}
