const std = @import("std");
const AllocatedBuffer = @import("VulkanEngine.zig").AllocatedBuffer;
const m3d = @import("math3d.zig");
const c = @import("clibs.zig");

const Vec3 = m3d.Vec3;

pub const VertexInputDescription = struct {
    bindings: []const c.VkVertexInputBindingDescription,
    attributes: []const c.VkVertexInputAttributeDescription,

    flags: c.VkPipelineVertexInputStateCreateFlags = 0,
};

pub const Vertex = struct {
    position: Vec3,
    normal: Vec3,
    color: Vec3,

    pub const vertex_input_description = VertexInputDescription{
        .bindings = &.{
            std.mem.zeroInit(c.VkVertexInputBindingDescription, .{
                .binding = 0,
                .stride = @sizeOf(Vertex),
                .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
            }),
        },
        .attributes = &.{
            std.mem.zeroInit(c.VkVertexInputAttributeDescription, .{
                .location = 0,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "position"),
            }),
            std.mem.zeroInit(c.VkVertexInputAttributeDescription, .{
                .location = 1,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "normal"),
            }),
            std.mem.zeroInit(c.VkVertexInputAttributeDescription, .{
                .location = 2,
                .binding = 0,
                .format = c.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
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

    var vertices = std.ArrayList(Vertex).init(a);

    for (obj_mesh.objects) |object| {
        var index_count: usize = 0;
        for (object.face_vertices) |face_vx_count| {
            if (face_vx_count < 3) {
                @panic("Face has fewer than 3 vertices. Not a valid polygon.");
            }

            for (0..face_vx_count) |vx_index| {
                const obj_index = object.indices[index_count];
                const pos = object.vertices[obj_index.vertex];
                const nml = object.normals[obj_index.normal];

                const vx = Vertex{
                    .position = m3d.vec3(pos[0], pos[1], pos[2]),
                    .normal = m3d.vec3(nml[0], nml[1], nml[2]),
                    .color = m3d.vec3(nml[0], nml[1], nml[2]),
                };

                // Triangulate the polygon
                if (vx_index > 2) {
                    const v0 = vertices.items[vertices.items.len - 3];
                    const v1 = vertices.items[vertices.items.len - 1];
                    vertices.append(v0) catch @panic("OOM");
                    vertices.append(v1) catch @panic("OOM");
                }

                vertices.append(vx) catch @panic("OOM");

                index_count += 1;
            }
        }
    }

    return Mesh{
        .vertices = vertices.toOwnedSlice() catch @panic("Failed to make owned slice"),
    };
}
