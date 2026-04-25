const std = @import("std");

const config = @import("config.zig");
const model = @import("model.zig");

pub const list_ttl_seconds: u64 = 60 * 60 * 24;

pub fn loadProblemList(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: config.AppPaths,
) !?model.Cached([]const model.ProblemSummary) {
    return readJson(model.Cached([]const model.ProblemSummary), allocator, io, try listPath(allocator, paths));
}

pub fn storeProblemList(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: config.AppPaths,
    problems: []const model.ProblemSummary,
) !void {
    const cached = model.Cached([]const model.ProblemSummary).fresh(model.nowSeconds(io), problems);
    try writeJson(allocator, io, try listPath(allocator, paths), cached);
}

pub fn loadProblemDetail(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: config.AppPaths,
    slug: []const u8,
) !?model.Cached(model.ProblemDetail) {
    return readJson(model.Cached(model.ProblemDetail), allocator, io, try detailPath(allocator, paths, slug));
}

pub fn storeProblemDetail(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: config.AppPaths,
    detail: model.ProblemDetail,
) !void {
    const cached = model.Cached(model.ProblemDetail).fresh(model.nowSeconds(io), detail);
    try writeJson(allocator, io, try detailPath(allocator, paths, detail.slug), cached);
}

fn listPath(allocator: std.mem.Allocator, paths: config.AppPaths) ![]u8 {
    return config.pathJoin(allocator, &.{ paths.cache_dir, "problems.json" });
}

fn detailPath(allocator: std.mem.Allocator, paths: config.AppPaths, slug: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{slug});
    return config.pathJoin(allocator, &.{ paths.detail_dir, file_name });
}

fn readJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?T {
    const cwd = std.Io.Dir.cwd();
    const raw = cwd.readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    return try std.json.parseFromSliceLeaky(
        T,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

fn writeJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    value: anytype,
) !void {
    const raw = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = raw });
}

test "problem list cache round trips as json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try config.pathJoin(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    var env = std.process.Environ.Map.init(allocator);
    try env.put("HOME", "/home/test");
    const paths = try config.AppPaths.fromRoots(
        allocator,
        std.testing.io,
        try config.pathJoin(allocator, &.{ root, "cfg" }),
        try config.pathJoin(allocator, &.{ root, "data" }),
        .{},
        &env,
    );

    const problems = &[_]model.ProblemSummary{.{
        .frontend_id = "1",
        .question_id = 1,
        .slug = "two-sum",
        .title = "Two Sum",
        .difficulty = .easy,
    }};
    try storeProblemList(allocator, std.testing.io, paths, problems);
    const loaded = (try loadProblemList(allocator, std.testing.io, paths)).?;
    try std.testing.expectEqual(@as(usize, 1), loaded.value.len);
    try std.testing.expectEqualStrings("two-sum", loaded.value[0].slug);
}
