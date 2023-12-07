// Copyright (c) Samuele Panzeri
// SPDX-License-Identifier: MIT OR Apache-2.0
//
// This file is made specifically for this zig implementation of the vk guide.
// As such, you should be able to use it for another project.
// I have tried to write it such as to not have dependencies on the rest of the project.
//
// NOTE: Keep in mind this is not yet a fully compliant obj loader. Some work
// is needed to add support for at least materials.
// Consider it more of a starting point than a finished product.
// Also, keep in mind this is simply a parser for objs. It does not triangulate
// the faces, nor does it try to optimize the data or generate an index buffer.
//
// This code was originally part of: https://github.com/spanzeri/vkguide-zig
// For simple use and triangulation, check src/mesh.zig in the same repo.
//
const std = @import("std");

const log = std.log.scoped(.obj_loader);

pub const Index = struct {
    vertex: u32,
    normal: u32,
    uv: u32,
};

pub const Object = struct {
    name: []const u8,
    vertices: [][3]f32,
    normals: [][3]f32,
    uvs: [][2]f32,
    face_vertices: []u32,
    indices: []Index,
};

pub const Mesh = struct {
    allocator: std.mem.Allocator,
    objects: []Object,

    pub fn deinit(self: *@This()) void {
        for (self.objects) |object| {
            self.allocator.free(object.name);
            self.allocator.free(object.vertices);
            self.allocator.free(object.normals);
            self.allocator.free(object.uvs);
            self.allocator.free(object.face_vertices);
            self.allocator.free(object.indices);
        }

        self.allocator.free(self.objects);
    }
};

pub const ParseError = error {
    unexpected_end_of_file,
    invalid_token,
    invalid_entry,
    invalid_number,
    invalid_index,
};

const ParseContext = struct {
    temp_alloc: std.mem.Allocator,
    allocator: std.mem.Allocator,
    line: u32,
    line_content: []const u8,
    filename: []const u8,

    objects: std.ArrayListUnmanaged(Object) = .{},

    object_name: []const u8 = "",
    vertices: std.ArrayListUnmanaged([3]f32) = std.ArrayListUnmanaged([3]f32){},
    normals: std.ArrayListUnmanaged([3]f32) = std.ArrayListUnmanaged([3]f32){},
    uvs: std.ArrayListUnmanaged([2]f32) = std.ArrayListUnmanaged([2]f32){},
    face_vertices: std.ArrayListUnmanaged(u32) = std.ArrayListUnmanaged(u32){},
    indeces: std.ArrayListUnmanaged(Index) = std.ArrayListUnmanaged(Index){},
    face_parsing_state: FaceParsingState = .undefined,

    vertex_count_at_start_of_face: usize = 0,
    normal_count_at_start_of_face: usize = 0,
    uv_count_at_start_of_face: usize = 0,

    fn end_object(self: *ParseContext) void {
        self.vertex_count_at_start_of_face = self.vertices.items.len;
        self.normal_count_at_start_of_face = self.normals.items.len;
        self.uv_count_at_start_of_face = self.uvs.items.len;
    }

    fn start_object(self: *ParseContext) !void {
        // Obj is 1 indexed
        self.vertices.shrinkRetainingCapacity(0);
        self.normals.shrinkRetainingCapacity(0);
        self.uvs.shrinkRetainingCapacity(0);
        try self.vertices.append(self.allocator, .{0, 0, 0});
        try self.normals.append(self.allocator, .{0, 0, 0});
        try self.uvs.append(self.allocator, .{0, 0});
    }

    fn deinit(self: *ParseContext) void {
        self.temp_alloc.deinit();
        self.vertices.deinit(self.allocator);
        self.normals.deinit(self.allocator);
        self.uvs.deinit(self.allocator);
    }
};

const FaceParsingState = enum {
    undefined,
    uvs,
    no_uvs,
};

pub fn parse_file(a: std.mem.Allocator, filepath: []const u8) !Mesh {
    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();

    var ctx = ParseContext{
        .temp_alloc = arena_state.allocator(),
        .allocator = a,
        .line = 0,
        .line_content = "",
        .filename = filepath,
    };

    const file_content = try file.readToEndAlloc(ctx.temp_alloc, file_size);
    defer ctx.temp_alloc.free(file_content);

    try ctx.start_object();
    try parse_content(&ctx, file_content);

    // Make sure the last object is added
    try add_current_object(&ctx);

    return Mesh{
        .allocator = a,
        .objects = try ctx.objects.toOwnedSlice(a),
    };
}

fn parse_content(ctx: *ParseContext, content: []const u8) !void {
    var lines = std.mem.tokenizeAny(u8, content, "\n\r");
    while (lines.next()) |raw_line| {
        ctx.line += 1;
        ctx.line_content = raw_line;
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0) {
            continue;
        }

        if (line[0] == '#') {
            continue;
        }

        switch (line[0]) {
            'v' => {
                if (line.len < 2) {
                    log_err(ctx, "Unexpected end of file", .{});
                    return ParseError.unexpected_end_of_file;
                }
                switch (line[1]) {
                    ' ' => try parse_vertex(ctx, line[1..]),
                    'n' => try parse_normal(ctx, line[2..]),
                    't' => try parse_texture_coords(ctx, line[2..]),
                    'p' => {
                        log_warn(ctx, "Points are not supported", .{});
                    },
                    else => {
                        log_err(ctx, "Unknown token: {s}", .{ line[0..2] });
                        return ParseError.invalid_token;
                    },
                }
            },
            'f' => try parse_face(ctx, line[1..]),
            'o' => try parse_object(ctx, line[1..]),
            'm' => {
                if (std.mem.startsWith(u8, line, "mtllib")) {
                    try parse_material(ctx, line);
                } else {
                    log_err(ctx, "Unknown token at beginning of line: {s}", .{ line });
                    return ParseError.invalid_token;
                }
            },
            'l' => {
                log_warn(ctx, "Lines are not supported", .{});
            },
            's' => {
                log_warn(ctx, "Smoothing groups are not supported", .{});
            },
            else => {
                log_err(ctx, "Unknown token: {c}", .{ line[0] });
                return ParseError.invalid_token;
            },
        }
    }
}

fn parse_values(ctx: *ParseContext, line: []const u8, values: []f32, type_name: []const u8) !u32 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var count: u32 = 0;
    while (it.next()) |pos| {
        if (count > values.len) {
            log_err(ctx, "Too many values for {s}. Expected: {}, Found: {}", .{ type_name, values.len, count });
            return ParseError.invalid_entry;
        }

        values[count] = std.fmt.parseFloat(f32, pos) catch {
            log_err(ctx, "Invalid number: {s}", .{ pos });
            return ParseError.invalid_number;
        };

        count += 1;
    }

    return count;
}

fn parse_vertex(ctx: *ParseContext, line: []const u8) callconv(.Inline) !void {
    var values = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    const read = try parse_values(ctx, line, values[0..], "vertex");

    if (read < 3) {
        log_err(ctx, "Invalid vertex. Expected at least 3 values", .{});
        return ParseError.invalid_entry;
    }

    if (read > 3) {
        log_warn(ctx, "Ignoring w component of vertex", .{});
    }

    try ctx.vertices.append(ctx.allocator, .{ values[0], values[1], values[2] });
}

fn parse_normal(ctx: *ParseContext, line: []const u8) callconv(.Inline) !void {
    var values = [3]f32{ 0.0, 0.0, 0.0 };
    const read = try parse_values(ctx, line, values[0..], "normal");

    if (read < 3) {
        log_err(ctx, "Invalid normal. Expected 3 values, found: {}", .{ read });
        return ParseError.invalid_entry;
    }

    try ctx.normals.append(ctx.allocator, .{ values[0], values[1], values[2] });
}

fn parse_texture_coords(ctx: *ParseContext, line: []const u8) callconv(.Inline) !void {
    var values = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
    const read = try parse_values(ctx, line, values[0..], "texture coordinates");

    if (read > 2) {
        log_warn(ctx, "Ignoring z component of texture coordinate", .{});
    }

    try ctx.uvs.append(ctx.allocator, values[0..2].*);
}

fn parse_face(ctx: *ParseContext, line: []const u8) callconv(.Inline) !void {
    var vertices_it = std.mem.tokenizeAny(u8, line, " \t");
    var vertices_count: u32 = 0;
    while (vertices_it.next()) |vertex| {
        var index_it = std.mem.splitScalar(u8, vertex, '/');
        const pos = index_it.next() orelse {
            log_err(ctx, "Invalid face. Position index is missing for vertex: {s}", .{ vertex });
            return ParseError.invalid_entry;
        };

        const uv = index_it.next() orelse {
            log_err(ctx, "Invalid face. UV index is missing for vertex: {s}", .{ vertex });
            return ParseError.invalid_entry;
        };

        const norm = index_it.next() orelse {
            log_err(ctx, "Invalid face. Normal index is missing for vertex: {s}", .{ vertex });
            return ParseError.invalid_entry;
        };

        // Ensure consistency between faces with and without uv coordinates
        if (norm.len == 0) {
            if (ctx.face_parsing_state == .uvs) {
                log_err(ctx, "Invalid face. Mismatch between face with and without uv coordinates.", .{});
                return ParseError.invalid_entry;
            }
            else ctx.face_parsing_state = .no_uvs;
        } else {
            if (ctx.face_parsing_state == .no_uvs) {
                log_err(ctx, "Invalid face. Mismatch between face with and without uv coordinates.", .{});
                return ParseError.invalid_entry;
            }
            else ctx.face_parsing_state = .uvs;
        }

        var pos_index = std.fmt.parseInt(i32, pos, 10) catch {
            log_err(ctx, "Invalid face. Invalid position index: {s}", .{ pos });
            return ParseError.invalid_index;
        };

        var uv_index = if (uv.len == 0) blk: {
            if (ctx.uvs.items.len == 0) {
                const zero: f32 = 0.0;
                try ctx.uvs.append(ctx.allocator, .{ zero, zero });
            }
            break :blk 0;
        } else std.fmt.parseInt(i32, uv, 10) catch {
            log_err(ctx, "Invalid face. Invalid uv index: {s}", .{ uv });
            return ParseError.invalid_index;
        };

        // FIXME:This is not technically correct, as normals are optional. Revise this later.
        var norm_index = std.fmt.parseInt(i32, norm, 10) catch {
            log_err(ctx, "Invalid face. Invalid normal index: {s}", .{ norm });
            return ParseError.invalid_index;
        };

        if (pos_index < 0) {
            pos_index = @as(i32, @intCast(ctx.vertices.items.len)) + pos_index;
            if (pos_index < ctx.vertex_count_at_start_of_face) {
                log_err(ctx, "Invalid face. Position index out of bounds: {s}", .{ pos });
                return ParseError.invalid_index;
            }
        }

        if (uv_index < 0) {
            uv_index = @as(i32, @intCast(ctx.uvs.items.len)) + uv_index;
            if (uv_index < ctx.uv_count_at_start_of_face) {
                log_err(ctx, "Invalid face. UV index out of bounds: {s}", .{ uv });
                return ParseError.invalid_index;
            }
        }

        if (norm_index < 0) {
            norm_index = @as(i32, @intCast(ctx.normals.items.len)) + norm_index;
            if (norm_index < ctx.normal_count_at_start_of_face) {
                log_err(ctx, "Invalid face. Normal index out of bounds: {s}", .{ norm });
                return ParseError.invalid_index;
            }
        }

        const index = Index{
            .vertex = @as(u32, @intCast(pos_index)),
            .uv = @as(u32, @intCast(uv_index)),
            .normal = @as(u32, @intCast(norm_index)),
        };
        try ctx.indeces.append(ctx.allocator, index);
        vertices_count += 1;
    }

    if (vertices_count < 3) {
        log_err(ctx, "Invalid face. Expected at least 3 vertices, found: {}", .{ vertices_count });
        return ParseError.invalid_entry;
    }

    try ctx.face_vertices.append(ctx.allocator, vertices_count);
}

fn parse_object(ctx: *ParseContext, line: []const u8) callconv(.Inline) !void {
    try add_current_object(ctx);
    try ctx.start_object();
    ctx.object_name = std.mem.trim(u8, line, " \t\r");
}

fn parse_material(ctx: *ParseContext, line: []const u8) callconv(.Inline) !void {
    _ = line;
    log_warn(ctx, "Materials are not yet supported", .{});
}

fn add_current_object(ctx: *ParseContext) !void {
    if (ctx.face_vertices.items.len > 0) {
        ctx.end_object();
        try ctx.objects.append(ctx.allocator, .{
            .name = try ctx.allocator.dupe(u8, ctx.object_name),
            .vertices = try ctx.vertices.toOwnedSlice(ctx.allocator),
            .normals = try ctx.normals.toOwnedSlice(ctx.allocator),
            .uvs = try ctx.uvs.toOwnedSlice(ctx.allocator),
            .face_vertices = try ctx.face_vertices.toOwnedSlice(ctx.allocator),
            .indices = try ctx.indeces.toOwnedSlice(ctx.allocator),
        });
    }
}

fn log_err(ctx: *ParseContext, comptime msg: []const u8, args: anytype) callconv(.Inline) void {
    log.err("{s}: {}: " ++ msg ++ "\nLine content: {s}",  .{ ctx.filename, ctx.line } ++ args ++ .{ ctx.line_content });
}

fn log_warn(ctx: *ParseContext, comptime msg: []const u8, args: anytype) callconv(.Inline) void {
    log.warn("{s}: {}: " ++ msg, .{ ctx.filename, ctx.line } ++ args);
}
