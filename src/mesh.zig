const std = @import("std");
const AllocatedBuffer = @import("VulkanEngine.zig").AllocatedBuffer;
const math3d = @import("math3d.zig");
const c = @import("clibs.zig");
const Vec3 = math3d.Vec3;

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
