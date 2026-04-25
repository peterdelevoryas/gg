const std = @import("std");

const cache = @import("cache.zig");
const config = @import("config.zig");
const leetcode = @import("leetcode.zig");
const model = @import("model.zig");
const workspace = @import("workspace.zig");

pub const Cli = struct {
    site: ?config.Site = null,
    auth: config.AuthOverride = .{},
    command: Command,
};

pub const Command = union(enum) {
    list: ListArgs,
    view: ProblemArgs,
    open: OpenArgs,
    run: RunArgs,
    submit: ProblemArgs,
    help,
};

pub const ListArgs = struct {
    query: ?[]const u8 = null,
    refresh: bool = false,
};

pub const OpenArgs = struct {
    problem: []const u8,
    no_editor: bool = false,
};

pub const RunArgs = struct {
    problem: []const u8,
    input: ?[]const u8 = null,
};

pub const ProblemArgs = struct {
    problem: []const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const parsed = parseArgs(args) catch |err| {
        try writeUsage(stderr);
        return err;
    };
    if (parsed.command == .help) {
        try writeUsage(stdout);
        return;
    }

    const loaded = try config.load(allocator, io, env);
    const site = try loaded.config.resolveSite(env, parsed.site);
    const app = App{
        .allocator = allocator,
        .io = io,
        .env = env,
        .stdout = stdout,
        .stderr = stderr,
        .cfg = loaded.config,
        .paths = loaded.paths,
        .site = site,
        .auth_override = parsed.auth,
    };

    switch (parsed.command) {
        .list => |list_args| try app.list(list_args),
        .view => |view_args| try app.view(view_args),
        .open => |open_args| try app.open(open_args),
        .run => |run_args| try app.runRemote(run_args),
        .submit => |submit_args| try app.submit(submit_args),
        .help => unreachable,
    }
}

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    cfg: config.Config,
    paths: config.AppPaths,
    site: config.Site,
    auth_override: config.AuthOverride,

    fn list(self: App, args: ListArgs) !void {
        const problems = try self.problemList(args.refresh);
        for (problems) |problem| {
            if (args.query) |query| {
                if (!problem.matchesQuery(query)) continue;
            }
            try self.stdout.print(
                "{s: >6}  {s: <7}  {s: <3}  {s} ({s})\n",
                .{
                    problem.frontend_id,
                    problem.difficulty.text(),
                    statusMarker(problem.status),
                    problem.title,
                    problem.slug,
                },
            );
        }
    }

    fn view(self: App, args: ProblemArgs) !void {
        const problem = try self.resolveProblem(args.problem);
        const detail = try self.problemDetail(problem);
        const problem_url = try self.site.problemUrl(self.allocator, problem.slug);
        const statement = try htmlToText(self.allocator, detail.content_html);

        try self.stdout.print(
            "{s}. {s}\nDifficulty: {s}\nURL: {s}\n\n{s}\n",
            .{
                problem.frontend_id,
                problem.title,
                problem.difficulty.text(),
                problem_url,
                statement,
            },
        );
    }

    fn open(self: App, args: OpenArgs) !void {
        const problem = try self.resolveProblem(args.problem);
        const detail = try self.problemDetail(problem);
        const project = try workspace.ensureProblemProject(
            self.allocator,
            self.io,
            self.paths.workspace_root,
            problem,
            detail,
        );
        const problem_url = try self.site.problemUrl(self.allocator, problem.slug);

        try self.stdout.print(
            "Workspace: {s}\nProblem: {s}\nSource: {s}\n",
            .{ project.dir, problem_url, project.solution_path },
        );

        if (args.no_editor) return;
        const editor = try self.cfg.resolveEditor(self.allocator, self.io, self.env);
        if (editor) |ed| {
            try launchEditor(self.allocator, self.io, ed, project.solution_path);
        } else {
            try self.stderr.print(
                "No editor configured. Set `editor` in {s}, export EDITOR, or install hx.\n",
                .{self.paths.config_file},
            );
        }
    }

    fn runRemote(self: App, args: RunArgs) !void {
        const problem = try self.resolveProblem(args.problem);
        const detail = try self.problemDetail(problem);
        const project = try workspace.ensureProblemProject(
            self.allocator,
            self.io,
            self.paths.workspace_root,
            problem,
            detail,
        );
        const input = args.input orelse detail.sample_test_case;
        if (input.len == 0) return error.MissingInput;
        const code = try std.Io.Dir.cwd().readFileAlloc(self.io, project.solution_path, self.allocator, .limited(8 * 1024 * 1024));

        const auth = try config.resolveAuth(self.cfg, self.env, self.auth_override);
        const client = leetcode.Client.init(self.allocator, self.io, self.site, auth);
        const result = try client.judge(.run, problem, code, input);
        try self.stdout.print("{s}\n", .{result});
    }

    fn submit(self: App, args: ProblemArgs) !void {
        const problem = try self.resolveProblem(args.problem);
        const detail = try self.problemDetail(problem);
        const project = try workspace.ensureProblemProject(
            self.allocator,
            self.io,
            self.paths.workspace_root,
            problem,
            detail,
        );
        const code = try std.Io.Dir.cwd().readFileAlloc(self.io, project.solution_path, self.allocator, .limited(8 * 1024 * 1024));

        const auth = try config.resolveAuth(self.cfg, self.env, self.auth_override);
        const client = leetcode.Client.init(self.allocator, self.io, self.site, auth);
        const result = try client.judge(.submit, problem, code, null);
        try self.stdout.print("{s}\n", .{result});
    }

    fn problemList(self: App, refresh: bool) ![]const model.ProblemSummary {
        if (!refresh) {
            if (try cache.loadProblemList(self.allocator, self.io, self.paths)) |cached| {
                if (!cached.isStale(model.nowSeconds(self.io), cache.list_ttl_seconds)) {
                    return cached.value;
                }
            }
        }

        const auth = try config.resolveOptionalAuth(self.cfg, self.env, self.auth_override);
        const client = leetcode.Client.init(self.allocator, self.io, self.site, auth);
        const problems = try client.fetchProblems();
        try cache.storeProblemList(self.allocator, self.io, self.paths, problems);
        return problems;
    }

    fn resolveProblem(self: App, query: []const u8) !model.ProblemSummary {
        var problems = try self.problemList(false);
        if (findProblem(problems, query)) |problem| return problem;

        problems = try self.problemList(true);
        return findProblem(problems, query) orelse error.ProblemNotFound;
    }

    fn problemDetail(self: App, problem: model.ProblemSummary) !model.ProblemDetail {
        if (try cache.loadProblemDetail(self.allocator, self.io, self.paths, problem.slug)) |cached| {
            return cached.value;
        }
        const auth = try config.resolveOptionalAuth(self.cfg, self.env, self.auth_override);
        const client = leetcode.Client.init(self.allocator, self.io, self.site, auth);
        const detail = try client.fetchProblemDetail(problem.slug);
        try cache.storeProblemDetail(self.allocator, self.io, self.paths, detail);
        return detail;
    }
};

pub fn parseArgs(args: []const []const u8) !Cli {
    var cli = Cli{ .command = .help };
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli.command = .help;
            return cli;
        } else if (std.mem.eql(u8, arg, "--site")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cli.site = try config.Site.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--csrf")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cli.auth.csrf = args[i];
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            cli.auth.session = args[i];
        } else if (std.mem.eql(u8, arg, "list")) {
            cli.command = try parseList(args[i + 1 ..]);
            return cli;
        } else if (std.mem.eql(u8, arg, "view")) {
            cli.command = try parseView(args[i + 1 ..]);
            return cli;
        } else if (std.mem.eql(u8, arg, "open")) {
            cli.command = try parseOpen(args[i + 1 ..]);
            return cli;
        } else if (std.mem.eql(u8, arg, "run")) {
            cli.command = try parseRun(args[i + 1 ..]);
            return cli;
        } else if (std.mem.eql(u8, arg, "submit")) {
            cli.command = try parseSubmit(args[i + 1 ..]);
            return cli;
        } else {
            return error.UnknownCommand;
        }
        i += 1;
    }
    return cli;
}

fn parseList(args: []const []const u8) !Command {
    var out = ListArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--refresh")) {
            out.refresh = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            return error.UnknownOption;
        } else if (out.query == null) {
            out.query = args[i];
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .list = out };
}

fn parseView(args: []const []const u8) !Command {
    if (args.len != 1) return error.MissingProblem;
    return .{ .view = .{ .problem = args[0] } };
}

fn parseOpen(args: []const []const u8) !Command {
    var problem: ?[]const u8 = null;
    var no_editor = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--no-editor")) {
            no_editor = true;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            return error.UnknownOption;
        } else if (problem == null) {
            problem = args[i];
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .open = .{ .problem = problem orelse return error.MissingProblem, .no_editor = no_editor } };
}

fn parseRun(args: []const []const u8) !Command {
    var problem: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--input")) {
            i += 1;
            if (i >= args.len) return error.MissingOptionValue;
            input = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            return error.UnknownOption;
        } else if (problem == null) {
            problem = args[i];
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .run = .{ .problem = problem orelse return error.MissingProblem, .input = input } };
}

fn parseSubmit(args: []const []const u8) !Command {
    if (args.len != 1) return error.MissingProblem;
    return .{ .submit = .{ .problem = args[0] } };
}

fn findProblem(problems: []const model.ProblemSummary, query: []const u8) ?model.ProblemSummary {
    const q = std.mem.trim(u8, query, " \t\r\n");
    for (problems) |problem| {
        if (std.mem.eql(u8, problem.frontend_id, q) or std.ascii.eqlIgnoreCase(problem.slug, q)) {
            return problem;
        }
    }
    return null;
}

fn launchEditor(
    allocator: std.mem.Allocator,
    io: std.Io,
    editor: config.Editor,
    path: []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, editor.program);
    for (editor.args) |arg| try argv.append(allocator, arg);
    try argv.append(allocator, path);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.EditorFailed;
}

fn statusMarker(status: ?[]const u8) []const u8 {
    if (status) |s| {
        if (std.mem.eql(u8, s, "ac")) return "ac";
        if (std.mem.eql(u8, s, "notac")) return "wa";
    }
    return "-";
}

fn htmlToText(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var i: usize = 0;
    var in_pre = false;

    while (i < html.len) {
        switch (html[i]) {
            '<' => {
                if (std.mem.indexOfScalarPos(u8, html, i, '>')) |end| {
                    const tag = html[i + 1 .. end];
                    try handleTag(&out, tag, &in_pre);
                    i = end + 1;
                } else {
                    try writeTextByte(&out, html[i], in_pre);
                    i += 1;
                }
            },
            '&' => {
                if (try writeEntity(&out, html, &i, in_pre)) {} else {
                    try writeTextByte(&out, html[i], in_pre);
                    i += 1;
                }
            },
            else => {
                try writeTextByte(&out, html[i], in_pre);
                i += 1;
            },
        }
    }

    trimTrailingWhitespace(&out);
    return out.toOwnedSlice();
}

fn handleTag(out: *std.Io.Writer.Allocating, raw: []const u8, in_pre: *bool) !void {
    const tag = tagName(raw);
    if (tag.len == 0) return;
    const closing = std.mem.indexOfScalar(u8, raw, '/') == 0;

    if (std.ascii.eqlIgnoreCase(tag, "pre")) {
        try ensureNewline(out);
        in_pre.* = !closing;
        if (closing) try ensureNewline(out);
        return;
    }
    if (std.ascii.eqlIgnoreCase(tag, "br")) {
        try ensureNewline(out);
        return;
    }
    if (std.ascii.eqlIgnoreCase(tag, "sup") and !closing) {
        try out.writer.writeByte('^');
        return;
    }
    if (std.ascii.eqlIgnoreCase(tag, "li") and !closing) {
        try ensureNewline(out);
        try out.writer.writeAll("- ");
        return;
    }
    if (isBlockTag(tag)) try ensureNewline(out);
}

fn tagName(raw: []const u8) []const u8 {
    var i: usize = 0;
    while (i < raw.len and (raw[i] == '/' or std.ascii.isWhitespace(raw[i]))) : (i += 1) {}
    const start = i;
    while (i < raw.len and (std.ascii.isAlphanumeric(raw[i]) or raw[i] == '-')) : (i += 1) {}
    return raw[start..i];
}

fn isBlockTag(tag: []const u8) bool {
    const tags = [_][]const u8{
        "p",  "div", "section",    "article", "ul", "ol", "table",
        "tr", "pre", "blockquote", "h1",      "h2", "h3", "h4",
        "h5", "h6",
    };
    for (tags) |block| {
        if (std.ascii.eqlIgnoreCase(tag, block)) return true;
    }
    return false;
}

fn writeEntity(out: *std.Io.Writer.Allocating, html: []const u8, index: *usize, in_pre: bool) !bool {
    const start = index.*;
    const max_end = @min(html.len, start + 16);
    const rel = std.mem.indexOfScalar(u8, html[start..max_end], ';') orelse return false;
    const entity = html[start + 1 .. start + rel];
    index.* = start + rel + 1;

    if (std.mem.eql(u8, entity, "nbsp")) {
        try writeTextByte(out, ' ', in_pre);
    } else if (std.mem.eql(u8, entity, "amp")) {
        try writeTextByte(out, '&', in_pre);
    } else if (std.mem.eql(u8, entity, "lt")) {
        try writeTextByte(out, '<', in_pre);
    } else if (std.mem.eql(u8, entity, "gt")) {
        try writeTextByte(out, '>', in_pre);
    } else if (std.mem.eql(u8, entity, "quot")) {
        try writeTextByte(out, '"', in_pre);
    } else if (std.mem.eql(u8, entity, "apos") or std.mem.eql(u8, entity, "#39")) {
        try writeTextByte(out, '\'', in_pre);
    } else if (std.mem.eql(u8, entity, "le")) {
        try writeText(out, "<=", in_pre);
    } else if (std.mem.eql(u8, entity, "ge")) {
        try writeText(out, ">=", in_pre);
    } else if (std.mem.eql(u8, entity, "ne")) {
        try writeText(out, "!=", in_pre);
    } else if (std.mem.eql(u8, entity, "times")) {
        try writeTextByte(out, '*', in_pre);
    } else if (std.mem.startsWith(u8, entity, "#x")) {
        try writeCodepoint(out, std.fmt.parseInt(u21, entity[2..], 16) catch return true, in_pre);
    } else if (std.mem.startsWith(u8, entity, "#")) {
        try writeCodepoint(out, std.fmt.parseInt(u21, entity[1..], 10) catch return true, in_pre);
    } else {
        try writeTextByte(out, '&', in_pre);
        try writeText(out, entity, in_pre);
        try writeTextByte(out, ';', in_pre);
    }
    return true;
}

fn writeCodepoint(out: *std.Io.Writer.Allocating, cp: u21, in_pre: bool) !void {
    if (cp < 128) {
        try writeTextByte(out, @intCast(cp), in_pre);
        return;
    }
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buf);
    try writeText(out, buf[0..len], in_pre);
}

fn writeText(out: *std.Io.Writer.Allocating, text: []const u8, in_pre: bool) !void {
    for (text) |c| try writeTextByte(out, c, in_pre);
}

fn writeTextByte(out: *std.Io.Writer.Allocating, c: u8, in_pre: bool) !void {
    if (in_pre) {
        try out.writer.writeByte(c);
        return;
    }
    if (std.ascii.isWhitespace(c)) {
        const written = out.written();
        if (written.len != 0 and written[written.len - 1] != '\n' and written[written.len - 1] != ' ') {
            try out.writer.writeByte(' ');
        }
        return;
    }
    try out.writer.writeByte(c);
}

fn ensureNewline(out: *std.Io.Writer.Allocating) !void {
    trimTrailingSpaces(out);
    const written = out.written();
    if (written.len == 0 or written[written.len - 1] == '\n') return;
    try out.writer.writeByte('\n');
}

fn trimTrailingSpaces(out: *std.Io.Writer.Allocating) void {
    var written = out.written();
    while (written.len > 0 and written[written.len - 1] == ' ') {
        out.shrinkRetainingCapacity(written.len - 1);
        written = out.written();
    }
}

fn trimTrailingWhitespace(out: *std.Io.Writer.Allocating) void {
    var written = out.written();
    while (written.len > 0 and std.ascii.isWhitespace(written[written.len - 1])) {
        out.shrinkRetainingCapacity(written.len - 1);
        written = out.written();
    }
}

fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  gg list [query] [--refresh]
        \\  gg view <id-or-slug>
        \\  gg open <id-or-slug> [--no-editor]
        \\  gg run <id-or-slug> [--input <case>]
        \\  gg submit <id-or-slug>
        \\
        \\Global options:
        \\  --site <leetcode.com|leetcode.cn>
        \\  --csrf <token>
        \\  --session <cookie>
        \\
    );
}

test "parses list command with global flags" {
    const parsed = try parseArgs(&.{ "gg", "--site", "leetcode.com", "--csrf", "c", "--session", "s", "list", "two", "--refresh" });
    try std.testing.expectEqual(config.Site.com, parsed.site.?);
    try std.testing.expectEqualStrings("c", parsed.auth.csrf.?);
    try std.testing.expect(parsed.command == .list);
    try std.testing.expect(parsed.command.list.refresh);
    try std.testing.expectEqualStrings("two", parsed.command.list.query.?);
}

test "parses open no editor" {
    const parsed = try parseArgs(&.{ "gg", "open", "1", "--no-editor" });
    try std.testing.expect(parsed.command == .open);
    try std.testing.expect(parsed.command.open.no_editor);
    try std.testing.expectEqualStrings("1", parsed.command.open.problem);
}

test "parses view command" {
    const parsed = try parseArgs(&.{ "gg", "view", "two-sum" });
    try std.testing.expect(parsed.command == .view);
    try std.testing.expectEqualStrings("two-sum", parsed.command.view.problem);
}

test "parses run input" {
    const parsed = try parseArgs(&.{ "gg", "run", "two-sum", "--input", "[2,7]\n9" });
    try std.testing.expect(parsed.command == .run);
    try std.testing.expectEqualStrings("[2,7]\n9", parsed.command.run.input.?);
}

test "renders leetcode html as terminal text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const text = try htmlToText(
        allocator,
        "<p>Given&nbsp;nums &amp; target.</p><p><strong>Example:</strong></p><pre>Input: nums = [2,7]\nOutput: [0,1]</pre><ul><li>1 &lt;= n &lt;= 10<sup>4</sup></li></ul>",
    );

    try std.testing.expectEqualStrings(
        "Given nums & target.\nExample:\nInput: nums = [2,7]\nOutput: [0,1]\n- 1 <= n <= 10^4",
        text,
    );
}
