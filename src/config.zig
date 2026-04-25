const std = @import("std");

pub const site_env = "LEETCODE_SITE";
pub const csrf_env = "LEETCODE_CSRF";
pub const session_env = "LEETCODE_SESSION";

pub const Site = enum {
    com,
    cn,

    pub fn parse(raw: []const u8) !Site {
        if (std.mem.eql(u8, raw, "leetcode.com")) return .com;
        if (std.mem.eql(u8, raw, "leetcode.cn")) return .cn;
        return error.UnsupportedSite;
    }

    pub fn text(self: Site) []const u8 {
        return switch (self) {
            .com => "leetcode.com",
            .cn => "leetcode.cn",
        };
    }

    pub fn baseUrl(self: Site) []const u8 {
        return switch (self) {
            .com => "https://leetcode.com",
            .cn => "https://leetcode.cn",
        };
    }

    pub fn graphqlUrl(self: Site) []const u8 {
        return switch (self) {
            .com => "https://leetcode.com/graphql",
            .cn => "https://leetcode.cn/graphql",
        };
    }

    pub fn problemsUrl(self: Site, allocator: std.mem.Allocator, category: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/api/problems/{s}/", .{ self.baseUrl(), category });
    }

    pub fn problemUrl(self: Site, allocator: std.mem.Allocator, slug: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/problems/{s}/description/", .{ self.baseUrl(), slug });
    }

    pub fn runUrl(self: Site, allocator: std.mem.Allocator, slug: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/problems/{s}/interpret_solution/", .{ self.baseUrl(), slug });
    }

    pub fn submitUrl(self: Site, allocator: std.mem.Allocator, slug: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/problems/{s}/submit/", .{ self.baseUrl(), slug });
    }

    pub fn verifyUrl(self: Site, allocator: std.mem.Allocator, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/submissions/detail/{s}/check/", .{ self.baseUrl(), id });
    }
};

pub const Auth = struct {
    csrf: []const u8,
    session: []const u8,

    pub fn cookieHeader(self: Auth, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "LEETCODE_SESSION={s};csrftoken={s};",
            .{ self.session, self.csrf },
        );
    }
};

pub const AuthOverride = struct {
    csrf: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

pub const Config = struct {
    site: Site = .com,
    workspace_root: ?[]const u8 = null,
    editor: ?[]const u8 = null,
    editor_args: []const []const u8 = &.{},
    csrf: []const u8 = "",
    session: []const u8 = "",

    pub fn resolveSite(self: Config, env: *const std.process.Environ.Map, cli_site: ?Site) !Site {
        if (cli_site) |site| return site;
        if (env.get(site_env)) |raw| return Site.parse(raw);
        return self.site;
    }

    pub fn manualAuth(self: Config) ?Auth {
        if (self.csrf.len == 0 or self.session.len == 0) return null;
        return .{ .csrf = self.csrf, .session = self.session };
    }

    pub fn resolveEditor(
        self: Config,
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
    ) !?Editor {
        if (self.editor) |editor| {
            if (std.mem.trim(u8, editor, " \t\r\n").len != 0) {
                return .{ .program = editor, .args = self.editor_args };
            }
        }

        if (env.get("EDITOR")) |editor_env| {
            if (try parseEditorEnv(allocator, editor_env)) |editor| return editor;
        }

        if (try findInPath(allocator, io, env, "hx")) {
            return .{ .program = "hx", .args = &.{} };
        }

        return null;
    }
};

pub const Editor = struct {
    program: []const u8,
    args: []const []const u8,
};

pub const AppPaths = struct {
    config_root: []const u8,
    config_file: []const u8,
    data_root: []const u8,
    cache_dir: []const u8,
    detail_dir: []const u8,
    workspace_root: []const u8,

    pub fn fromRoots(
        allocator: std.mem.Allocator,
        io: std.Io,
        config_root: []const u8,
        data_root: []const u8,
        cfg: Config,
        env: *const std.process.Environ.Map,
    ) !AppPaths {
        const cache_dir = try pathJoin(allocator, &.{ data_root, "cache" });
        const detail_dir = try pathJoin(allocator, &.{ cache_dir, "details" });
        const workspace_root = try resolveWorkspaceRoot(allocator, cfg.workspace_root, data_root, env);

        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, config_root);
        try cwd.createDirPath(io, data_root);
        try cwd.createDirPath(io, cache_dir);
        try cwd.createDirPath(io, detail_dir);
        try cwd.createDirPath(io, workspace_root);

        return .{
            .config_root = config_root,
            .config_file = try pathJoin(allocator, &.{ config_root, "config.json" }),
            .data_root = data_root,
            .cache_dir = cache_dir,
            .detail_dir = detail_dir,
            .workspace_root = workspace_root,
        };
    }
};

const ConfigFile = struct {
    site: []const u8 = "leetcode.com",
    workspace_root: ?[]const u8 = null,
    editor: ?[]const u8 = null,
    editor_args: []const []const u8 = &.{},
    csrf: []const u8 = "",
    session: []const u8 = "",
};

pub const Loaded = struct {
    config: Config,
    paths: AppPaths,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
) !Loaded {
    const config_root_base = env.get("XDG_CONFIG_HOME") orelse try homeRelative(allocator, env, ".config");
    const data_root_base = env.get("XDG_DATA_HOME") orelse try homeRelative(allocator, env, ".local/share");
    const config_root = try pathJoin(allocator, &.{ config_root_base, "gg" });
    const data_root = try pathJoin(allocator, &.{ data_root_base, "gg" });
    return loadWithRoots(allocator, io, config_root, data_root, env);
}

pub fn loadWithRoots(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_root: []const u8,
    data_root: []const u8,
    env: *const std.process.Environ.Map,
) !Loaded {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, config_root);
    try cwd.createDirPath(io, data_root);

    const config_file = try pathJoin(allocator, &.{ config_root, "config.json" });
    if (!try pathExists(io, config_file)) {
        const raw = try std.json.Stringify.valueAlloc(
            allocator,
            ConfigFile{},
            .{ .whitespace = .indent_2 },
        );
        try cwd.writeFile(io, .{ .sub_path = config_file, .data = raw });
    }

    const raw = try cwd.readFileAlloc(io, config_file, allocator, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSliceLeaky(
        ConfigFile,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );

    const cfg = Config{
        .site = try Site.parse(parsed.site),
        .workspace_root = parsed.workspace_root,
        .editor = parsed.editor,
        .editor_args = parsed.editor_args,
        .csrf = parsed.csrf,
        .session = parsed.session,
    };
    const paths = try AppPaths.fromRoots(allocator, io, config_root, data_root, cfg, env);
    return .{ .config = cfg, .paths = paths };
}

pub fn resolveAuth(cfg: Config, env: *const std.process.Environ.Map, overrides: AuthOverride) !Auth {
    return (try resolveOptionalAuth(cfg, env, overrides)) orelse error.MissingAuth;
}

pub fn resolveOptionalAuth(
    cfg: Config,
    env: *const std.process.Environ.Map,
    overrides: AuthOverride,
) !?Auth {
    if (try explicitAuth(env, overrides)) |auth| return auth;
    return cfg.manualAuth();
}

pub fn chooseAuth(explicit: ?Auth, manual: ?Auth) ?Auth {
    return explicit orelse manual;
}

fn explicitAuth(env: *const std.process.Environ.Map, overrides: AuthOverride) !?Auth {
    const csrf = overrides.csrf orelse env.get(csrf_env);
    const session = overrides.session orelse env.get(session_env);
    if (csrf == null and session == null) return null;
    if (csrf == null or session == null) return error.PartialAuth;
    return .{ .csrf = csrf.?, .session = session.? };
}

fn resolveWorkspaceRoot(
    allocator: std.mem.Allocator,
    input: ?[]const u8,
    data_root: []const u8,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    const raw = input orelse return pathJoin(allocator, &.{ data_root, "workspace" });
    if (raw.len == 0) return pathJoin(allocator, &.{ data_root, "workspace" });
    if (std.mem.startsWith(u8, raw, "~/")) {
        const home = env.get("HOME") orelse return error.MissingHome;
        return pathJoin(allocator, &.{ home, raw[2..] });
    }
    if (std.fs.path.isAbsolute(raw)) return raw;
    return pathJoin(allocator, &.{ data_root, raw });
}

fn homeRelative(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, rel: []const u8) ![]const u8 {
    const home = env.get("HOME") orelse return error.MissingHome;
    return pathJoin(allocator, &.{ home, rel });
}

pub fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn pathExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn parseEditorEnv(allocator: std.mem.Allocator, raw: []const u8) !?Editor {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (it.next()) |part| try parts.append(allocator, part);
    const owned = try parts.toOwnedSlice(allocator);
    if (owned.len == 0) return null;
    return .{ .program = owned[0], .args = owned[1..] };
}

fn findInPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    exe: []const u8,
) !bool {
    const path = env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir_raw| {
        const dir = if (dir_raw.len == 0) "." else dir_raw;
        const full = try pathJoin(allocator, &.{ dir, exe });
        std.Io.Dir.cwd().access(io, full, .{ .execute = true }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
            else => |e| return e,
        };
        return true;
    }
    return false;
}

test "relative workspace root resolves under data root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    try env.put("HOME", "/home/test");
    const paths = try AppPaths.fromRoots(
        allocator,
        std.testing.io,
        ".zig-cache/test-cfg",
        ".zig-cache/test-data",
        .{ .workspace_root = "custom" },
        &env,
    );

    try std.testing.expectEqualStrings(".zig-cache/test-data/custom", paths.workspace_root);
}

test "auth precedence prefers explicit env over config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    try env.put(csrf_env, "env-csrf");
    try env.put(session_env, "env-session");

    const cfg = Config{ .csrf = "cfg-csrf", .session = "cfg-session" };
    const auth = (try resolveOptionalAuth(cfg, &env, .{})).?;
    try std.testing.expectEqualStrings("env-csrf", auth.csrf);
    try std.testing.expectEqualStrings("env-session", auth.session);
}

test "auth requires csrf and session together" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var env = std.process.Environ.Map.init(allocator);
    try env.put(csrf_env, "only-csrf");
    try std.testing.expectError(error.PartialAuth, resolveOptionalAuth(.{}, &env, .{}));
}
