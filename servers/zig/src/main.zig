const std = @import("std");
const httpz = @import("httpz");

const User = struct {
    id: []const u8,
    name: []const u8,
    tier: []const u8,
};

const Auth = struct {
    pub const Config = struct {};

    pub fn init(_: Config) !Auth {
        return .{};
    }

    pub fn execute(_: *const Auth, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
        const authorization = req.header("authorization") orelse "";
        if (!std.mem.eql(u8, authorization, "Bearer benchmark-token")) {
            res.status = 401;
            res.content_type = .TEXT;
            res.body = "unauthorized\n";
            return;
        }

        const user = try req.arena.create(User);
        user.* = .{ .id = "user-7", .name = "Andre", .tier = "gold" };
        try req.middlewares.put("user", user);
        return executor.next();
    }
};

pub fn main(init: std.process.Init) !void {
    @setEvalBranchQuota(100_000);
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const port = if (args.next()) |value|
        try std.fmt.parseInt(u16, value, 10)
    else
        18080;
    const workers = if (args.next()) |value|
        try std.fmt.parseInt(u16, value, 10)
    else
        1;
    const handler_threads: u16 = if (args.next()) |value|
        try std.fmt.parseInt(u16, value, 10)
    else
        @intCast(@min(@as(u32, workers) * 2, std.math.maxInt(u16)));

    var server = try httpz.Server(void).init(init.io, init.gpa, .{
        .address = .localhost(port),
        .workers = .{ .count = workers },
        .thread_pool = .{ .count = handler_threads },
        .request = .{
            .max_body_size = 65_536,
            .max_header_count = 64,
            .max_param_count = 16,
            .max_query_count = 32,
        },
    }, {});
    defer server.deinit();
    defer server.stop();

    const auth = try server.middleware(Auth, .{});
    var router = try server.router(.{});
    router.get("/plaintext", plaintext, .{});
    router.get("/accounts/:account/items/:item", parameters, .{});
    inline for (0..128) |index| {
        router.get(
            std.fmt.comptimePrint("/ridiculous/decoy-{d}", .{index}),
            decoy,
            .{},
        );
    }
    router.get("/ridiculous/:account/orders/:order", routeTail, .{});
    router.get(
        "/p/:p0/s1/:p1/s2/:p2/s3/:p3/s4/:p4/s5/:p5/s6/:p6/s7/:p7",
        parameters16,
        .{},
    );
    router.get("/headers-32", headers32, .{});
    router.get("/context", context, .{ .middlewares = &.{auth} });
    router.post("/body", echoBody, .{});
    try server.listen();
}

fn plaintext(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .TEXT;
    res.body = "hello, world!\n";
}

fn parameters(req: *httpz.Request, res: *httpz.Response) !void {
    const account = req.param("account") orelse "";
    const item = req.param("item") orelse "";
    const filter = (try req.query()).get("filter") orelse "";
    res.content_type = .TEXT;
    try res.writer().print("{s}:{s}:{s}\n", .{ account, item, filter });
}

fn decoy(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .TEXT;
    res.body = "decoy\n";
}

fn routeTail(req: *httpz.Request, res: *httpz.Response) !void {
    const account = req.param("account") orelse "";
    const order = req.param("order") orelse "";
    const expand = (try req.query()).get("expand") orelse "";
    res.content_type = .TEXT;
    try res.writer().print("{s}:{s}:{s}\n", .{ account, order, expand });
}

fn parameters16(req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    res.content_type = .TEXT;
    try res.writer().print(
        "{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}\n",
        .{
            req.params.values[0], req.params.values[1],
            req.params.values[2], req.params.values[3],
            req.params.values[4], req.params.values[5],
            req.params.values[6], req.params.values[7],
            query.values[0],      query.values[1],
            query.values[2],      query.values[3],
            query.values[4],      query.values[5],
            query.values[6],      query.values[7],
        },
    );
}

fn headers32(req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .TEXT;
    try res.writer().print("{s}:{s}:{s}:{s}:{s}\n", .{
        req.header("x-bench-00") orelse "",
        req.header("x-bench-07") orelse "",
        req.header("x-bench-15") orelse "",
        req.header("x-bench-23") orelse "",
        req.header("x-bench-31") orelse "",
    });
}

fn context(req: *httpz.Request, res: *httpz.Response) !void {
    const raw_user = req.middlewares.get("user") orelse return error.MissingUser;
    const user: *const User = @ptrCast(@alignCast(raw_user));
    res.content_type = .TEXT;
    try res.writer().print("{s}:{s}:{s}\n", .{ user.id, user.name, user.tier });
}

fn echoBody(req: *httpz.Request, res: *httpz.Response) !void {
    res.header("Content-Type", "application/octet-stream");
    res.body = req.body() orelse "";
}
