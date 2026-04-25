const std = @import("std");

pub const Difficulty = enum {
    easy,
    medium,
    hard,
    unknown,

    pub fn fromLevel(level: i64) Difficulty {
        return switch (level) {
            1 => .easy,
            2 => .medium,
            3 => .hard,
            else => .unknown,
        };
    }

    pub fn text(self: Difficulty) []const u8 {
        return switch (self) {
            .easy => "easy",
            .medium => "medium",
            .hard => "hard",
            .unknown => "unknown",
        };
    }
};

pub const ProblemSummary = struct {
    frontend_id: []const u8,
    question_id: u32,
    slug: []const u8,
    title: []const u8,
    difficulty: Difficulty = .unknown,
    paid_only: bool = false,
    status: ?[]const u8 = null,
    category: []const u8 = "algorithms",

    pub fn matchesQuery(self: ProblemSummary, query: []const u8) bool {
        const q = std.mem.trim(u8, query, " \t\r\n");
        if (q.len == 0) return true;
        if (std.ascii.eqlIgnoreCase(self.frontend_id, q)) return true;
        return containsIgnoreCase(self.slug, q) or containsIgnoreCase(self.title, q);
    }
};

pub const CodeSnippet = struct {
    lang: []const u8,
    lang_slug: []const u8,
    code: []const u8,
};

pub const ProblemDetail = struct {
    frontend_id: []const u8,
    question_id: u32,
    slug: []const u8,
    title: []const u8,
    content_html: []const u8 = "",
    sample_test_case: []const u8 = "",
    example_testcases: ?[]const u8 = null,
    code_snippets: []const CodeSnippet = &.{},
    enable_run_code: bool = false,

    pub fn rustSnippet(self: ProblemDetail) ?CodeSnippet {
        for (self.code_snippets) |snippet| {
            if (std.mem.eql(u8, snippet.lang_slug, "rust")) return snippet;
        }
        return null;
    }
};

pub fn Cached(comptime T: type) type {
    return struct {
        fetched_at: u64,
        value: T,

        pub fn fresh(fetched_at: u64, value: T) @This() {
            return .{ .fetched_at = fetched_at, .value = value };
        }

        pub fn isStale(self: @This(), now: u64, ttl_seconds: u64) bool {
            return now > self.fetched_at and now - self.fetched_at > ttl_seconds;
        }
    };
}

pub fn nowSeconds(io: std.Io) u64 {
    const ts = std.Io.Clock.real.now(io);
    if (ts.nanoseconds <= 0) return 0;
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "problem query matching checks id slug and title" {
    const p = ProblemSummary{
        .frontend_id = "1",
        .question_id = 1,
        .slug = "two-sum",
        .title = "Two Sum",
    };

    try std.testing.expect(p.matchesQuery("1"));
    try std.testing.expect(p.matchesQuery("sum"));
    try std.testing.expect(p.matchesQuery("TWO"));
    try std.testing.expect(!p.matchesQuery("window"));
}

test "cache staleness compares fetched timestamp against ttl" {
    const cached = Cached(u32).fresh(100, 42);
    try std.testing.expect(!cached.isStale(110, 20));
    try std.testing.expect(cached.isStale(130, 20));
}
