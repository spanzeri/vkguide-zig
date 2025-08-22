const std = @import("std");
const c = @import("clibs.zig");
const Engine = @import("VulkanEngine.zig");
const check_vk = @import("vulkan_init.zig").check_vk;

const log = std.log.scoped(.textures);

pub const Texture = struct {
    image: Engine.AllocatedImage,
    image_view: c.vk.ImageView,
};

pub fn load_image_from_file(engine: *Engine, filepath: []const u8) !Engine.AllocatedImage {
    var width: c_int = undefined;
    var height: c_int = undefined;
    var channels: c_int = undefined;

    // This is just to make the API more zig friendly. Conver to C 0-term string
    // on the stack.
    var buffer: [512]u8 = undefined;
    const filepathz = try std.fmt.bufPrintZ(buffer[0..], "{s}", .{ filepath });

    const image_data = c.stbi.load(filepathz.ptr, &width, &height, &channels, c.stbi.rgb_alpha);
    if (image_data == null) {
        return error.failed_to_load_image;
    }
    defer c.stbi.image_free(image_data);

    log.info("Loaded image from file to ram: {s}", .{ filepath });

    const image_size = @as(c.vk.DeviceSize, @intCast(width * height * 4));
    const format = c.vk.FORMAT_R8G8B8A8_SRGB;

    const staging_buffer = engine.create_buffer(
        image_size, c.vk.BUFFER_USAGE_TRANSFER_SRC_BIT, c.vma.MEMORY_USAGE_CPU_ONLY);
    defer c.vma.DestroyBuffer(engine.vma_allocator, staging_buffer.buffer, staging_buffer.allocation);

    var img_data_slice: []const u8 = undefined;
    img_data_slice.ptr = @as([*]const u8, @ptrCast(image_data));
    img_data_slice.len = @as(usize, image_size);

    var data: ?*anyopaque = null;
    try check_vk(c.vma.MapMemory(engine.vma_allocator, staging_buffer.allocation, &data));
    @memcpy(@as([*]u8, @ptrCast(data orelse unreachable)), img_data_slice);

    c.vma.UnmapMemory(engine.vma_allocator, staging_buffer.allocation);

    const extent = c.vk.Extent3D{
        .width = @as(c_uint, @intCast(width)),
        .height = @as(c_uint, @intCast(height)),
        .depth = 1,
    };

    const img_info = std.mem.zeroInit(c.vk.ImageCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.vk.IMAGE_TYPE_2D,
        .format = format,
        .extent = extent,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.vk.SAMPLE_COUNT_1_BIT,
        .tiling = c.vk.IMAGE_TILING_OPTIMAL,
        .usage = c.vk.IMAGE_USAGE_TRANSFER_DST_BIT | c.vk.IMAGE_USAGE_SAMPLED_BIT
    });

    const alloc_ci = std.mem.zeroInit(c.vma.AllocationCreateInfo, .{
        .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
    });

    var image: c.vk.Image = undefined;
    var allocation: c.vma.Allocation = undefined;
    try check_vk(c.vma.CreateImage(engine.vma_allocator, &img_info, &alloc_ci, &image, &allocation, null));
    if (allocation == null) {
        return error.failed_to_create_image;
    }

    log.info("Create vkimage and gpu memory for image: {s}", .{ filepath });

    // Tranfer CPU memory to GPU memory
    //
    engine.immediate_submit(struct {
        image: c.vk.Image,
        extent: c.vk.Extent3D,
        staging_buffer: Engine.AllocatedBuffer,

        pub fn submit(self: @This(), cmd: c.vk.CommandBuffer) void {
            const range = std.mem.zeroInit(c.vk.ImageSubresourceRange, .{
                .aspectMask     = c.vk.IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel   = 0,
                .levelCount     = 1,
                .baseArrayLayer = 0,
                .layerCount     = 1,
            });

            const barrier_to_transfer = std.mem.zeroInit(c.vk.ImageMemoryBarrier, .{
                .sType               = c.vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .srcAccessMask       = 0,
                .dstAccessMask       = c.vk.ACCESS_TRANSFER_WRITE_BIT,
                .oldLayout           = c.vk.IMAGE_LAYOUT_UNDEFINED,
                .newLayout           = c.vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .srcQueueFamilyIndex = c.vk.QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.vk.QUEUE_FAMILY_IGNORED,
                .image               = self.image,
                .subresourceRange    = range,
            });

            c.vk.CmdPipelineBarrier(
                cmd,
                c.vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                c.vk.PIPELINE_STAGE_TRANSFER_BIT,
                0,
                0, null,
                0, null,
                1, &barrier_to_transfer);

            const copy_region = std.mem.zeroInit(c.vk.BufferImageCopy, .{
                .bufferOffset = 0,
                .bufferRowLength = 0,
                .bufferImageHeight = 0,
                .imageSubresource = .{
                    .aspectMask = c.vk.IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = self.extent,
            });

            c.vk.CmdCopyBufferToImage(
                cmd,
                self.staging_buffer.buffer,
                self.image,
                c.vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1,
                &copy_region);

            const barrier_to_shader_read = std.mem.zeroInit(c.vk.ImageMemoryBarrier, .{
                .sType               = c.vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .srcAccessMask       = c.vk.ACCESS_TRANSFER_WRITE_BIT,
                .dstAccessMask       = c.vk.ACCESS_SHADER_READ_BIT,
                .oldLayout           = c.vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                .newLayout           = c.vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .srcQueueFamilyIndex = c.vk.QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.vk.QUEUE_FAMILY_IGNORED,
                .image               = self.image,
                .subresourceRange    = range,
            });

            c.vk.CmdPipelineBarrier(
                cmd,
                c.vk.PIPELINE_STAGE_TRANSFER_BIT,
                c.vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                0,
                0, null,
                0, null,
                1, &barrier_to_shader_read);
        }
    }{
        .image = image,
        .extent = extent,
        .staging_buffer = staging_buffer,
    });

    return .{
        .image = image,
        .allocation = allocation,
    };
}
