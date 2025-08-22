const std = @import("std");
const AllocatedBuffer = @import("VulkanEngine.zig").AllocatedBuffer;
const m3d = @import("math3d.zig");
const c = @import("clibs.zig");

const Vec2 = m3d.Vec2;
const Vec3 = m3d.Vec3;

pub const VertexInputDescription = struct {
    bindings: []const c.vk.VertexInputBindingDescription,
    attributes: []const c.vk.VertexInputAttributeDescription,

    flags: c.vk.PipelineVertexInputStateCreateFlags = 0,
};

pub const Vertex = struct {
    position: Vec3,
    normal: Vec3,
    color: Vec3,
    uv: Vec2,

    pub const vertex_input_description = VertexInputDescription{
        .bindings = &.{
            std.mem.zeroInit(c.vk.VertexInputBindingDescription, .{
                .binding = 0,
                .stride = @sizeOf(Vertex),
                .inputRate = c.vk.VERTEX_INPUT_RATE_VERTEX,
            }),
        },
        .attributes = &.{
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 0,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "position"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 1,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "normal"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 2,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 3,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "uv"),
            }),
        },
    };
};

pub const Mesh = struct {
    vertices: []Vertex,
    vertex_buffer: AllocatedBuffer = undefined,
};

const obj_loader = @import("obj_loader.zig");

pub fn load_from_obj(a: std.mem.Allocator, filepath: []const u8) Mesh {
    var obj_mesh = obj_loader.parse_file(a, filepath) catch |err| {
        std.log.err("Failed to load obj file: {s}", .{ @errorName(err) });
        unreachable;
    };
    defer obj_mesh.deinit();

    var vertices = std.ArrayList(Vertex){};

    for (obj_mesh.objects) |object| {
        var index_count: usize = 0;
        for (object.face_vertices) |face_vx_count| {
            if (face_vx_count < 3) {
                @panic("Face has fewer than 3 vertices. Not a valid polygon.");
            }

            for (0..face_vx_count) |vx_index| {
                const obj_index = object.indices[index_count];
                const pos = obj_mesh.vertices[obj_index.vertex];
                const nml = obj_mesh.normals[obj_index.normal];
                const uvs = obj_mesh.uvs[obj_index.uv];

                const vx = Vertex{
                    .position = Vec3.make(pos[0], pos[1], pos[2]),
                    .normal = Vec3.make(nml[0], nml[1], nml[2]),
                    .color = Vec3.make(nml[0], nml[1], nml[2]),
                    .uv = Vec2.make(uvs[0], 1.0 - uvs[1]),
                };

                // Triangulate the polygon
                if (vx_index > 2) {
                    const v0 = vertices.items[vertices.items.len - 3];
                    const v1 = vertices.items[vertices.items.len - 1];
                    vertices.append(a, v0) catch @panic("OOM");
                    vertices.append(a, v1) catch @panic("OOM");
                }

                vertices.append(a, vx) catch @panic("OOM");

                index_count += 1;
            }
        }
    }

    return Mesh{
        .vertices = vertices.toOwnedSlice(a) catch @panic("Failed to make owned slice"),
    };
}
