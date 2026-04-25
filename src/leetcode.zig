const std = @import("std");

const config = @import("config.zig");
const model = @import("model.zig");

pub const JudgeMode = enum {
    run,
    submit,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    site: config.Site,
    auth: ?config.Auth = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        site: config.Site,
        auth: ?config.Auth,
    ) Client {
        return .{ .allocator = allocator, .io = io, .site = site, .auth = auth };
    }

    pub fn fetchProblems(self: Client) ![]model.ProblemSummary {
        const url = try self.site.problemsUrl(self.allocator, "algorithms");
        const body = try self.fetchText(.GET, url, null, null);
        return parseProblems(self.allocator, body);
    }

    pub fn fetchProblemDetail(self: Client, slug: []const u8) !model.ProblemDetail {
        const request = GraphqlRequest{
            .operationName = "getQuestionDetail",
            .variables = .{ .titleSlug = slug },
            .query =
            \\query getQuestionDetail($titleSlug: String!) { question(titleSlug: $titleSlug) { questionFrontendId questionId title titleSlug content sampleTestCase exampleTestcases enableRunCode codeSnippets { lang langSlug code } codeDefinition } }
            ,
        };
        const payload = try std.json.Stringify.valueAlloc(self.allocator, request, .{});
        const referer = try self.site.problemUrl(self.allocator, slug);
        const body = try self.fetchText(.POST, self.site.graphqlUrl(), referer, payload);
        return parseProblemDetail(self.allocator, slug, body);
    }

    pub fn judge(
        self: Client,
        mode: JudgeMode,
        problem: model.ProblemSummary,
        code: []const u8,
        input: ?[]const u8,
    ) ![]const u8 {
        if (self.auth == null) return error.MissingAuth;
        const payload = try renderJudgeStartPayload(self.allocator, mode, problem, code, input);
        const url = switch (mode) {
            .run => try self.site.runUrl(self.allocator, problem.slug),
            .submit => try self.site.submitUrl(self.allocator, problem.slug),
        };
        const referer = try self.site.problemUrl(self.allocator, problem.slug);
        const body = try self.fetchText(.POST, url, referer, payload);
        const id = try parseJudgeStart(self.allocator, mode, body);

        var attempt: usize = 0;
        while (attempt < 120) : (attempt += 1) {
            const check_url = try self.site.verifyUrl(self.allocator, id);
            const check_body = try self.fetchText(.GET, check_url, null, null);
            const parsed = try std.json.parseFromSliceLeaky(
                std.json.Value,
                self.allocator,
                check_body,
                .{ .ignore_unknown_fields = true },
            );
            if (std.mem.eql(u8, stringField(parsed, "state") orelse "", "SUCCESS")) {
                return renderJudgeResult(self.allocator, mode, problem, input orelse "", parsed);
            }
            try std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(350), .awake);
        }

        return error.JudgeTimedOut;
    }

    fn fetchText(
        self: Client,
        method: std.http.Method,
        url: []const u8,
        referer: ?[]const u8,
        payload: ?[]const u8,
    ) ![]u8 {
        var http_client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer http_client.deinit();

        var extra: std.ArrayList(std.http.Header) = .empty;
        try extra.append(self.allocator, .{ .name = "x-requested-with", .value = "XMLHttpRequest" });
        try extra.append(self.allocator, .{ .name = "origin", .value = self.site.baseUrl() });
        if (referer) |value| try extra.append(self.allocator, .{ .name = "referer", .value = value });
        if (self.auth) |auth| {
            try extra.append(self.allocator, .{ .name = "cookie", .value = try auth.cookieHeader(self.allocator) });
            try extra.append(self.allocator, .{ .name = "x-csrftoken", .value = auth.csrf });
        }

        var response: std.Io.Writer.Allocating = .init(self.allocator);
        const result = try http_client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &response.writer,
            .headers = .{
                .user_agent = .{ .override = "gg-zig" },
                .content_type = if (payload == null) .default else .{ .override = "application/json" },
            },
            .extra_headers = extra.items,
        });
        const status: u16 = @intFromEnum(result.status);
        if (status < 200 or status >= 300) return error.HttpStatus;
        return response.toOwnedSlice();
    }
};

const GraphqlRequest = struct {
    operationName: []const u8,
    variables: struct { titleSlug: []const u8 },
    query: []const u8,
};

pub fn parseProblems(allocator: std.mem.Allocator, raw: []const u8) ![]model.ProblemSummary {
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    const category = stringField(value, "category_slug") orelse "algorithms";
    const pairs = (field(value, "stat_status_pairs") orelse return error.MissingProblems).array.items;

    var problems: std.ArrayList(model.ProblemSummary) = .empty;
    for (pairs) |pair| {
        const stat = field(pair, "stat") orelse return error.MissingProblemStat;
        const frontend_id = try parseFrontendId(allocator, field(stat, "frontend_question_id") orelse return error.MissingFrontendId);
        const question_id = try parseU32(field(stat, "question_id") orelse return error.MissingQuestionId);
        const slug = stringField(stat, "question__title_slug") orelse return error.MissingSlug;
        const title = stringField(stat, "question__title") orelse return error.MissingTitle;
        const level = if (field(pair, "difficulty")) |difficulty|
            intField(difficulty, "level") orelse 0
        else
            0;

        try problems.append(allocator, .{
            .frontend_id = frontend_id,
            .question_id = question_id,
            .slug = slug,
            .title = title,
            .difficulty = model.Difficulty.fromLevel(level),
            .paid_only = boolField(pair, "paid_only") orelse false,
            .status = stringField(pair, "status"),
            .category = category,
        });
    }

    std.mem.sort(model.ProblemSummary, problems.items, {}, struct {
        fn lessThan(_: void, a: model.ProblemSummary, b: model.ProblemSummary) bool {
            return compareFrontendIds(a.frontend_id, b.frontend_id) == .lt;
        }
    }.lessThan);
    return problems.toOwnedSlice(allocator);
}

pub fn parseProblemDetail(
    allocator: std.mem.Allocator,
    fallback_slug: []const u8,
    raw: []const u8,
) !model.ProblemDetail {
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    const data = field(value, "data") orelse return error.MissingData;
    const question = field(data, "question") orelse return error.MissingQuestion;
    if (question == .null) return error.MissingQuestion;
    if (field(question, "content")) |content| {
        if (content == .null) return error.PremiumOrAuthOnlyProblem;
    }

    return .{
        .frontend_id = if (field(question, "questionFrontendId")) |v|
            try parseFrontendId(allocator, v)
        else
            fallback_slug,
        .question_id = if (field(question, "questionId")) |v| try parseU32(v) else 0,
        .slug = stringField(question, "titleSlug") orelse fallback_slug,
        .title = stringField(question, "title") orelse fallback_slug,
        .content_html = stringField(question, "content") orelse "",
        .sample_test_case = stringField(question, "sampleTestCase") orelse "",
        .example_testcases = stringField(question, "exampleTestcases"),
        .enable_run_code = boolField(question, "enableRunCode") orelse false,
        .code_snippets = try parseCodeSnippets(allocator, question),
    };
}

fn parseCodeSnippets(allocator: std.mem.Allocator, question: std.json.Value) ![]model.CodeSnippet {
    var snippets: std.ArrayList(model.CodeSnippet) = .empty;

    if (field(question, "codeSnippets")) |value| {
        if (value == .array) {
            for (value.array.items) |snippet| {
                try snippets.append(allocator, .{
                    .lang = stringField(snippet, "lang") orelse "",
                    .lang_slug = stringField(snippet, "langSlug") orelse "",
                    .code = stringField(snippet, "code") orelse "",
                });
            }
            return snippets.toOwnedSlice(allocator);
        }
    }

    const raw = stringField(question, "codeDefinition") orelse return error.MissingCodeSnippets;
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    if (parsed != .array) return error.MissingCodeSnippets;
    for (parsed.array.items) |snippet| {
        try snippets.append(allocator, .{
            .lang = stringField(snippet, "text") orelse "",
            .lang_slug = stringField(snippet, "value") orelse "",
            .code = stringField(snippet, "code") orelse stringField(snippet, "defaultCode") orelse "",
        });
    }
    return snippets.toOwnedSlice(allocator);
}

fn renderJudgeStartPayload(
    allocator: std.mem.Allocator,
    mode: JudgeMode,
    problem: model.ProblemSummary,
    code: []const u8,
    input: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("lang");
    try js.write("rust");
    try js.objectField("question_id");
    try js.write(problem.question_id);
    try js.objectField("typed_code");
    try js.write(code);
    if (input) |case| {
        try js.objectField("data_input");
        try js.write(case);
    }
    if (mode == .submit) {
        try js.objectField("judge_type");
        try js.write("large");
    }
    try js.endObject();
    return out.toOwnedSlice();
}

fn parseJudgeStart(allocator: std.mem.Allocator, mode: JudgeMode, raw: []const u8) ![]const u8 {
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    switch (mode) {
        .run => {
            const id = stringField(value, "interpret_id") orelse "";
            if (id.len == 0) return error.JudgeRejected;
            return id;
        },
        .submit => {
            const id = intField(value, "submission_id") orelse 0;
            if (id == 0) return error.JudgeRejected;
            return std.fmt.allocPrint(allocator, "{d}", .{id});
        },
    }
}

fn renderJudgeResult(
    allocator: std.mem.Allocator,
    mode: JudgeMode,
    problem: model.ProblemSummary,
    input: []const u8,
    result: std.json.Value,
) ![]const u8 {
    if (stringField(result, "full_compile_error")) |compile_error| {
        if (compile_error.len != 0) {
            return std.fmt.allocPrint(allocator, "Compile Error\n\n{s}", .{compile_error});
        }
    }
    if (stringField(result, "runtime_error")) |runtime_error| {
        if (runtime_error.len != 0) {
            return std.fmt.allocPrint(allocator, "Runtime Error\n\n{s}", .{runtime_error});
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    switch (mode) {
        .run => {
            try w.print(
                "{s}\nRuntime: {s}\n\nInput: {s}\nOutput: {s}\nExpected: {s}",
                .{
                    defaultStatus(stringField(result, "status_msg") orelse "", intField(result, "status_code") orelse 0),
                    blankDash(stringField(result, "status_runtime") orelse ""),
                    blankDash(input),
                    blankDash(firstNonEmpty(result, "code_answer", "code_output")),
                    blankDash(firstNonEmpty(result, "expected_code_answer", "expected_output")),
                },
            );
        },
        .submit => {
            try w.print(
                "{s}\nProblem: {s}\nRuntime: {s}\nMemory: {s}",
                .{
                    defaultStatus(stringField(result, "status_msg") orelse "", intField(result, "status_code") orelse 0),
                    problem.title,
                    blankDash(stringField(result, "status_runtime") orelse ""),
                    blankDash(stringField(result, "status_memory") orelse ""),
                },
            );
        },
    }
    if (firstString(result, "std_output")) |stdout| {
        if (stdout.len != 0) try w.print("\nStdout: {s}", .{stdout});
    }
    return out.toOwnedSlice();
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const v = field(value, name) orelse return null;
    return asString(v);
}

fn intField(value: std.json.Value, name: []const u8) ?i64 {
    const v = field(value, name) orelse return null;
    return asInt(v);
}

fn boolField(value: std.json.Value, name: []const u8) ?bool {
    const v = field(value, name) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => null,
        else => null,
    };
}

fn asInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn firstString(value: std.json.Value, name: []const u8) ?[]const u8 {
    const v = field(value, name) orelse return null;
    return switch (v) {
        .string => |s| s,
        .array => |items| if (items.items.len > 0) asString(items.items[0]) else null,
        else => null,
    };
}

fn firstNonEmpty(value: std.json.Value, a: []const u8, b: []const u8) []const u8 {
    if (firstString(value, a)) |s| {
        if (s.len != 0) return s;
    }
    if (firstString(value, b)) |s| {
        if (s.len != 0) return s;
    }
    return "";
}

fn parseFrontendId(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .string => |s| s,
        .number_string => |s| s,
        else => error.BadFrontendId,
    };
}

fn parseU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |i| @intCast(i),
        .string => |s| try std.fmt.parseInt(u32, s, 10),
        .number_string => |s| try std.fmt.parseInt(u32, s, 10),
        else => error.BadQuestionId,
    };
}

fn compareFrontendIds(a: []const u8, b: []const u8) std.math.Order {
    const ai = std.fmt.parseInt(u32, a, 10) catch null;
    const bi = std.fmt.parseInt(u32, b, 10) catch null;
    if (ai != null and bi != null) return std.math.order(ai.?, bi.?);
    return std.mem.order(u8, a, b);
}

fn defaultStatus(msg: []const u8, code: i64) []const u8 {
    if (msg.len != 0) return msg;
    return switch (code) {
        10 => "Accepted",
        11 => "Wrong Answer",
        12 => "Memory Limit Exceeded",
        13, 14 => "Time Limit Exceeded",
        15 => "Runtime Error",
        20 => "Compile Error",
        else => "Unknown Result",
    };
}

fn blankDash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}

test "problem list fixture parsing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const raw =
        \\{
        \\  "category_slug": "algorithms",
        \\  "stat_status_pairs": [
        \\    {
        \\      "stat": {
        \\        "frontend_question_id": 1,
        \\        "question_id": 1,
        \\        "question__title_slug": "two-sum",
        \\        "question__title": "Two Sum"
        \\      },
        \\      "difficulty": { "level": 1 },
        \\      "paid_only": false,
        \\      "status": "ac"
        \\    }
        \\  ]
        \\}
    ;

    const problems = try parseProblems(allocator, raw);
    try std.testing.expectEqual(@as(usize, 1), problems.len);
    try std.testing.expectEqualStrings("1", problems[0].frontend_id);
    try std.testing.expectEqualStrings("two-sum", problems[0].slug);
    try std.testing.expectEqual(model.Difficulty.easy, problems[0].difficulty);
}

test "detail fixture supports codeSnippets and legacy codeDefinition" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const current =
        \\{
        \\  "data": {
        \\    "question": {
        \\      "questionFrontendId": "1",
        \\      "questionId": "1",
        \\      "title": "Two Sum",
        \\      "titleSlug": "two-sum",
        \\      "content": "<p>x</p>",
        \\      "sampleTestCase": "[2,7]\n9",
        \\      "enableRunCode": true,
        \\      "codeSnippets": [
        \\        {"lang":"Rust","langSlug":"rust","code":"impl Solution {}"}
        \\      ]
        \\    }
        \\  }
        \\}
    ;
    const detail = try parseProblemDetail(allocator, "two-sum", current);
    try std.testing.expectEqualStrings("impl Solution {}", detail.rustSnippet().?.code);

    const legacy =
        \\{
        \\  "data": {
        \\    "question": {
        \\      "questionFrontendId": "2",
        \\      "questionId": 2,
        \\      "title": "Add Two Numbers",
        \\      "titleSlug": "add-two-numbers",
        \\      "content": "<p>x</p>",
        \\      "codeDefinition": "[{\"value\":\"rust\",\"text\":\"Rust\",\"defaultCode\":\"impl Solution {}\"}]"
        \\    }
        \\  }
        \\}
    ;
    const legacy_detail = try parseProblemDetail(allocator, "add-two-numbers", legacy);
    try std.testing.expectEqualStrings("rust", legacy_detail.rustSnippet().?.lang_slug);
}
