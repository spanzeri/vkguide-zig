const std = @import("std");
const c = @import("clibs.zig");

const vki = @import("vulkan_init.zig");
const check_vk = vki.check_vk;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;

const m3d = @import("math3d.zig");

const log = std.log.scoped(.vulkan_engine);

const Self = @This();

const window_extent = c.VkExtent2D{ .width = 1600, .height = 900 };

const VK_NULL_HANDLE = null;

const vk_alloc_cbs: ?*c.VkAllocationCallbacks = null;

pub const AllocatedBuffer = struct {
    buffer: c.VkBuffer,
    allocation: c.VmaAllocation,
};

pub const AllocatedImage = struct {
    image: c.VkImage,
    allocation: c.VmaAllocation,
};

// Scene management
const Material = struct {
    pipeline: c.VkPipeline,
    pipeline_layout: c.VkPipelineLayout,
};

const RenderObject = struct {
    mesh: *Mesh,
    material: *Material,
    transform: m3d.Mat4,
};

const FrameData = struct {
    present_semaphore: c.VkSemaphore = VK_NULL_HANDLE,
    render_semaphore: c.VkSemaphore = VK_NULL_HANDLE,
    render_fence: c.VkFence = VK_NULL_HANDLE,
    command_pool: c.VkCommandPool = VK_NULL_HANDLE,
    main_command_buffer: c.VkCommandBuffer = VK_NULL_HANDLE,
};

const FRAME_OVERLAP = 2;

// Data
//
frame_number: i32 = 0,
selected_shader: i32 = 0,
selected_mesh: i32 = 0,

window: *c.SDL_Window = undefined,

// Keep this around for long standing allocations
allocator: std.mem.Allocator = undefined,

// Vulkan data
instance: c.VkInstance = VK_NULL_HANDLE,
debug_messenger: c.VkDebugUtilsMessengerEXT = VK_NULL_HANDLE,
physical_device: c.VkPhysicalDevice = VK_NULL_HANDLE,
device: c.VkDevice = VK_NULL_HANDLE,
surface: c.VkSurfaceKHR = VK_NULL_HANDLE,

swapchain: c.VkSwapchainKHR = VK_NULL_HANDLE,
swapchain_format: c.VkFormat = undefined,
swapchain_extent: c.VkExtent2D = undefined,
swapchain_images: []c.VkImage = undefined,
swapchain_image_views: []c.VkImageView = undefined,

graphics_queue: c.VkQueue = VK_NULL_HANDLE,
graphics_queue_family: u32 = undefined,
present_queue: c.VkQueue = VK_NULL_HANDLE,
present_queue_family: u32 = undefined,

render_pass: c.VkRenderPass = VK_NULL_HANDLE,
framebuffers: []c.VkFramebuffer = undefined,

depth_image_view: c.VkImageView = VK_NULL_HANDLE,
depth_image: AllocatedImage = undefined,
depth_format: c.VkFormat = undefined,

frames: [FRAME_OVERLAP]FrameData = .{ FrameData{} } ** FRAME_OVERLAP,

vma_allocator: c.VmaAllocator = undefined,

renderables: std.ArrayList(RenderObject),
materials: std.StringHashMap(Material),
meshes: std.StringHashMap(Mesh),

camera_pos: m3d.Vec3 = m3d.vec3(0.0, -3.0, -10.0),
camera_input: m3d.Vec3 = m3d.vec3(0.0, 0.0, 0.0),

deletion_queue: std.ArrayList(VulkanDeleter) = undefined,
buffer_deletion_queue: std.ArrayList(VmaBufferDeleter) = undefined,
image_deletion_queue: std.ArrayList(VmaImageDeleter) = undefined,

const MeshPushConstants = struct {
    data: m3d.Vec4,
    render_matrix: m3d.Mat4,
};

const VulkanDeleter = struct {
    object: ?*anyopaque,
    delete_fn: *const fn(entry: *VulkanDeleter, self: *Self) void,

    fn delete(self: *VulkanDeleter, engine: *Self) void {
        self.delete_fn(self, engine);
    }

    fn make(object: anytype, func: anytype) VulkanDeleter {
        const T = @TypeOf(object);
        comptime {
            std.debug.assert(@typeInfo(T) == .Optional);
            const Ptr = @typeInfo(T).Optional.child;
            std.debug.assert(@typeInfo(Ptr) == .Pointer);
            std.debug.assert(@typeInfo(Ptr).Pointer.size == .One);

            const Fn = @TypeOf(func);
            std.debug.assert(@typeInfo(Fn) == .Fn);
        }

        return VulkanDeleter {
            .object = object,
            .delete_fn = struct {
                fn destroy_impl(entry: *VulkanDeleter, self: *Self) void {
                    const obj: @TypeOf(object) = @ptrCast(entry.object);
                    func(self.device, obj, vk_alloc_cbs);
                }
            }.destroy_impl,
        };
    }
};

const VmaBufferDeleter = struct {
    buffer: AllocatedBuffer,

    fn delete(self: *VmaBufferDeleter, engine: *Self) void {
        c.vmaDestroyBuffer(engine.vma_allocator, self.buffer.buffer, self.buffer.allocation);
    }
};

const VmaImageDeleter = struct {
    image: AllocatedImage,

    fn delete(self: *VmaImageDeleter, engine: *Self) void {
        c.vmaDestroyImage(engine.vma_allocator, self.image.image, self.image.allocation);
    }
};

pub fn init(a: std.mem.Allocator) Self {
    check_sdl(c.SDL_Init(c.SDL_INIT_VIDEO));

    const window = c.SDL_CreateWindow(
        "Vulkan",
        window_extent.width,
        window_extent.height,
        c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE
    ) orelse @panic("Failed to create SDL window");

    _ = c.SDL_ShowWindow(window);

    var engine = Self{
        .window = window,
        .allocator = a,
        .deletion_queue = std.ArrayList(VulkanDeleter).init(a),
        .buffer_deletion_queue = std.ArrayList(VmaBufferDeleter).init(a),
        .image_deletion_queue = std.ArrayList(VmaImageDeleter).init(a),
        .renderables = std.ArrayList(RenderObject).init(a),
        .materials = std.StringHashMap(Material).init(a),
        .meshes = std.StringHashMap(Mesh).init(a),
    };

    engine.init_instance();

    // Create the window surface
    check_sdl_bool(c.SDL_Vulkan_CreateSurface(window, engine.instance, vk_alloc_cbs, &engine.surface));

    engine.init_device();

    // Create a VMA allocator
    const allocator_ci = std.mem.zeroInit(c.VmaAllocatorCreateInfo, .{
        .physicalDevice = engine.physical_device,
        .device = engine.device,
        .instance = engine.instance,
    });
    check_vk(c.vmaCreateAllocator(&allocator_ci, &engine.vma_allocator))
        catch @panic("Failed to create VMA allocator");

    engine.init_swapchain();
    engine.init_commands();
    engine.init_default_renderpass();
    engine.init_framebuffers();
    engine.init_sync_structures();
    engine.init_pipelines();
    engine.load_meshes();
    engine.init_scene();

    return engine;
}

fn init_instance(self: *Self) void {
    var sdl_required_extension_count: u32 = undefined;
    const sdl_extensions = c.SDL_Vulkan_GetInstanceExtensions(&sdl_required_extension_count);
    const sdl_extension_slice = sdl_extensions[0..sdl_required_extension_count];

    // Instance creation and optional debug utilities
    const instance = vki.create_instance(std.heap.page_allocator, .{
        .application_name = "VkGuide",
        .application_version = c.VK_MAKE_VERSION(0, 1, 0),
        .engine_name = "VkGuide",
        .engine_version = c.VK_MAKE_VERSION(0, 1, 0),
        .api_version = c.VK_MAKE_VERSION(1, 1, 0),
        .debug = true,
        .required_extensions = sdl_extension_slice,
    }) catch |err| {
        log.err("Failed to create vulkan instance with error: {s}", .{ @errorName(err) });
        unreachable;
    };

    self.instance = instance.handle;
    self.debug_messenger = instance.debug_messenger;
}

fn init_device(self: *Self) void {
    // Physical device selection
    const required_device_extensions: []const [*c]const u8 = &.{
        "VK_KHR_swapchain",
    };
    const physical_device = vki.select_physical_device(std.heap.page_allocator, self.instance, .{
        .min_api_version = c.VK_MAKE_VERSION(1, 1, 0),
        .required_extensions = required_device_extensions,
        .surface = self.surface,
        .criteria = .PreferDiscrete,
    }) catch |err| {
        log.err("Failed to select physical device with error: {s}", .{ @errorName(err) });
        unreachable;
    };

    self.physical_device = physical_device.handle;
    self.graphics_queue_family = physical_device.graphics_queue_family;
    self.present_queue_family = physical_device.present_queue_family;

    // Create a logical device
    const device = vki.create_logical_device(self.allocator, .{
        .physical_device = physical_device,
        .features = std.mem.zeroInit(c.VkPhysicalDeviceFeatures, .{}),
        .alloc_cb = vk_alloc_cbs
    }) catch @panic("Failed to create logical device");

    self.device = device.handle;
    self.graphics_queue = device.graphics_queue;
    self.present_queue = device.present_queue;
}

fn init_swapchain(self: *Self) void {
    var win_width: c_int = undefined;
    var win_height: c_int = undefined;
    check_sdl(c.SDL_GetWindowSize(self.window, &win_width, &win_height));

    // Create a swapchain
    const swapchain = vki.create_swapchain(self.allocator, .{
        .physical_device = self.physical_device,
        .graphics_queue_family = self.graphics_queue_family,
        .present_queue_family = self.graphics_queue_family,
        .device = self.device,
        .surface = self.surface,
        .old_swapchain = null ,
        .vsync = true,
        .window_width = @intCast(win_width),
        .window_height = @intCast(win_height),
        .alloc_cb = vk_alloc_cbs,
    }) catch @panic("Failed to create swapchain");

    self.swapchain = swapchain.handle;
    self.swapchain_format = swapchain.format;
    self.swapchain_extent = swapchain.extent;
    self.swapchain_images = swapchain.images;
    self.swapchain_image_views = swapchain.image_views;

    for (self.swapchain_image_views) |view|
        self.deletion_queue.append(VulkanDeleter.make(view, c.vkDestroyImageView)) catch @panic("Out of memory");
    self.deletion_queue.append(VulkanDeleter.make(swapchain.handle, c.vkDestroySwapchainKHR)) catch @panic("Out of memory");

    log.info("Created swapchain", .{});

    // Create depth image to associate with the swapchain
    const extent = c.VkExtent3D {
        .width = self.swapchain_extent.width,
        .height = self.swapchain_extent.height,
        .depth = 1,
    };

    // Hard-coded 32-bit float depth format
    self.depth_format = c.VK_FORMAT_D32_SFLOAT;

    const depth_image_ci = std.mem.zeroInit(c.VkImageCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = self.depth_format,
        .extent = extent,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    });

    const depth_image_ai = std.mem.zeroInit(c.VmaAllocationCreateInfo, .{
        .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
        .requiredFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    });

    check_vk(c.vmaCreateImage(self.vma_allocator, &depth_image_ci, &depth_image_ai, &self.depth_image.image, &self.depth_image.allocation, null))
        catch @panic("Failed to create depth image");

    const depth_image_view_ci = std.mem.zeroInit(c.VkImageViewCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = self.depth_image.image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = self.depth_format,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    });

    check_vk(c.vkCreateImageView(self.device, &depth_image_view_ci, vk_alloc_cbs, &self.depth_image_view))
        catch @panic("Failed to create depth image view");

    self.deletion_queue.append(VulkanDeleter.make(self.depth_image_view, c.vkDestroyImageView)) catch @panic("Out of memory");
    self.image_deletion_queue.append(VmaImageDeleter{ .image = self.depth_image }) catch @panic("Out of memory");

    log.info("Created depth image", .{});
}

fn init_commands(self: *Self) void {
    // Create a command pool
    const command_pool_ci = std.mem.zeroInit(c.VkCommandPoolCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.graphics_queue_family,
    });

    for (&self.frames) |*frame| {
        check_vk(c.vkCreateCommandPool(self.device, &command_pool_ci, vk_alloc_cbs, &frame.command_pool))
            catch log.err("Failed to create command pool", .{});
        self.deletion_queue.append(VulkanDeleter.make(frame.command_pool, c.vkDestroyCommandPool)) catch @panic("Out of memory");

        // Allocate a command buffer from the command pool
        const command_buffer_ai = std.mem.zeroInit(c.VkCommandBufferAllocateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = frame.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        });

        check_vk(c.vkAllocateCommandBuffers(self.device, &command_buffer_ai, &frame.main_command_buffer))
            catch @panic("Failed to allocate command buffer");

        log.info("Created command pool and command buffer", .{});
    }

}

fn init_default_renderpass(self: *Self) void {
    // Color attachement
    const color_attachment = std.mem.zeroInit(c.VkAttachmentDescription, .{
        .format = self.swapchain_format,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    });

    const color_attachment_ref = std.mem.zeroInit(c.VkAttachmentReference, .{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    });

    // Depth attachment
    const depth_attachment = std.mem.zeroInit(c.VkAttachmentDescription, .{
        .format = self.depth_format,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    });

    const depth_attachement_ref = std.mem.zeroInit(c.VkAttachmentReference, .{
        .attachment = 1,
        .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    });

    // Subpass
    const subpass = std.mem.zeroInit(c.VkSubpassDescription, .{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
        .pDepthStencilAttachment = &depth_attachement_ref,
    });

    const attachment_descriptions = [_]c.VkAttachmentDescription{
        color_attachment,
        depth_attachment,
    };

    // Subpass color and depth depencies
    const color_dependency = std.mem.zeroInit(c.VkSubpassDependency, .{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    });

    const depth_dependency = std.mem.zeroInit(c.VkSubpassDependency, .{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .dstAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    });

    const dependecies = [_]c.VkSubpassDependency{
        color_dependency,
        depth_dependency,
    };

    const render_pass_create_info = std.mem.zeroInit(c.VkRenderPassCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = @as(u32, @intCast(attachment_descriptions.len)),
        .pAttachments = attachment_descriptions[0..].ptr,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = @as(u32, @intCast(dependecies.len)),
        .pDependencies = &dependecies[0],
    });

    check_vk(c.vkCreateRenderPass(self.device, &render_pass_create_info, vk_alloc_cbs, &self.render_pass))
        catch @panic("Failed to create render pass");
    self.deletion_queue.append(VulkanDeleter.make(self.render_pass, c.vkDestroyRenderPass)) catch @panic("Out of memory");

    log.info("Created render pass", .{});
}

fn init_framebuffers(self: *Self) void {
    var framebuffer_ci = std.mem.zeroInit(c.VkFramebufferCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = self.render_pass,
        .attachmentCount = 2,
        .width = self.swapchain_extent.width,
        .height = self.swapchain_extent.height,
        .layers = 1,
    });

    self.framebuffers = self.allocator.alloc(c.VkFramebuffer, self.swapchain_image_views.len) catch @panic("Out of memory");

    for (self.swapchain_image_views, self.framebuffers) |view, *framebuffer| {
        const attachements = [2]c.VkImageView{
            view,
            self.depth_image_view,
        };
        framebuffer_ci.pAttachments = &attachements[0];
        check_vk(c.vkCreateFramebuffer(self.device, &framebuffer_ci, vk_alloc_cbs, framebuffer))
            catch @panic("Failed to create framebuffer");
        self.deletion_queue.append(VulkanDeleter.make(framebuffer.*, c.vkDestroyFramebuffer)) catch @panic("Out of memory");
    }

    log.info("Created {} framebuffers", .{ self.framebuffers.len });
}

fn init_sync_structures(self: *Self) void {
    const semaphore_ci = std.mem.zeroInit(c.VkSemaphoreCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    });

    const fence_ci = std.mem.zeroInit(c.VkFenceCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    });

    for (&self.frames) |*frame| {
        check_vk(c.vkCreateSemaphore(self.device, &semaphore_ci, vk_alloc_cbs, &frame.present_semaphore))
            catch @panic("Failed to create present semaphore");
        self.deletion_queue.append(VulkanDeleter.make(frame.present_semaphore, c.vkDestroySemaphore)) catch @panic("Out of memory");
        check_vk(c.vkCreateSemaphore(self.device, &semaphore_ci, vk_alloc_cbs, &frame.render_semaphore))
            catch @panic("Failed to create render semaphore");
        self.deletion_queue.append(VulkanDeleter.make(frame.render_semaphore, c.vkDestroySemaphore)) catch @panic("Out of memory");


        check_vk(c.vkCreateFence(self.device, &fence_ci, vk_alloc_cbs, &frame.render_fence))
            catch @panic("Failed to create render fence");
        self.deletion_queue.append(VulkanDeleter.make(frame.render_fence, c.vkDestroyFence)) catch @panic("Out of memory");
    }

    log.info("Created sync structures", .{});
}

const PipelineBuilder = struct {
    shader_stages: []c.VkPipelineShaderStageCreateInfo,
    vertex_input_state: c.VkPipelineVertexInputStateCreateInfo,
    input_assembly_state: c.VkPipelineInputAssemblyStateCreateInfo,
    viewport: c.VkViewport,
    scissor: c.VkRect2D,
    rasterization_state: c.VkPipelineRasterizationStateCreateInfo,
    color_blend_attachment_state: c.VkPipelineColorBlendAttachmentState,
    multisample_state: c.VkPipelineMultisampleStateCreateInfo,
    pipeline_layout: c.VkPipelineLayout,
    depth_stencil_state: c.VkPipelineDepthStencilStateCreateInfo,

    fn build(self: PipelineBuilder, device: c.VkDevice, render_pass: c.VkRenderPass) c.VkPipeline {
        const viewport_state = std.mem.zeroInit(c.VkPipelineViewportStateCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &self.viewport,
            .scissorCount = 1,
            .pScissors = &self.scissor,
        });

        const color_blend_state = std.mem.zeroInit(c.VkPipelineColorBlendStateCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = c.VK_FALSE,
            .logicOp = c.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &self.color_blend_attachment_state,
        });

        const pipeline_ci = std.mem.zeroInit(c.VkGraphicsPipelineCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = @as(u32, @intCast(self.shader_stages.len)),
            .pStages = self.shader_stages.ptr,
            .pVertexInputState = &self.vertex_input_state,
            .pInputAssemblyState = &self.input_assembly_state,
            .pViewportState = &viewport_state,
            .pRasterizationState = &self.rasterization_state,
            .pMultisampleState = &self.multisample_state,
            .pColorBlendState = &color_blend_state,
            .pDepthStencilState = &self.depth_stencil_state,
            .layout = self.pipeline_layout,
            .renderPass = render_pass,
            .subpass = 0,
            .basePipelineHandle = VK_NULL_HANDLE,
        });

        var pipeline: c.VkPipeline = undefined;
        check_vk(c.vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeline_ci, vk_alloc_cbs, &pipeline)) catch {
            log.err("Failed to create graphics pipeline", .{});
            return VK_NULL_HANDLE;
        };

        return pipeline;
    }
};

fn init_pipelines(self: *Self) void {
    // NOTE: we are currently destroying the shader modules as soon as we are done
    // creating the pipeline. This is not great if we needed the modules for multiple pipelines.
    // Howver, for the sake of simplicity, we are doing it this way for now.
    const red_vert_code align(4) = @embedFile("triangle.vert").*;
    const red_frag_code align(4) = @embedFile("triangle.frag").*;
    const red_vert_module = create_shader_module(self, &red_vert_code) orelse VK_NULL_HANDLE;
    defer c.vkDestroyShaderModule(self.device, red_vert_module, vk_alloc_cbs);
    const red_frag_module = create_shader_module(self, &red_frag_code) orelse VK_NULL_HANDLE;
    defer c.vkDestroyShaderModule(self.device, red_frag_module, vk_alloc_cbs);

    if (red_vert_module != VK_NULL_HANDLE) log.info("Vert module loaded successfully", .{});
    if (red_frag_module != VK_NULL_HANDLE) log.info("Frag module loaded successfully", .{});

    const pipeline_layout_ci = std.mem.zeroInit(c.VkPipelineLayoutCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    });
    var triangle_pipeline_layout: c.VkPipelineLayout = undefined;
    check_vk(c.vkCreatePipelineLayout(self.device, &pipeline_layout_ci, vk_alloc_cbs, &triangle_pipeline_layout))
        catch @panic("Failed to create pipeline layout");
    self.deletion_queue.append(VulkanDeleter.make(triangle_pipeline_layout, c.vkDestroyPipelineLayout)) catch @panic("Out of memory");

    const vert_stage_ci = std.mem.zeroInit(c.VkPipelineShaderStageCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
        .module = red_vert_module,
        .pName = "main",
    });

    const frag_stage_ci = std.mem.zeroInit(c.VkPipelineShaderStageCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = red_frag_module,
        .pName = "main",
    });

    const vertex_input_state_ci = std.mem.zeroInit(c.VkPipelineVertexInputStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    });

    const input_assembly_state_ci = std.mem.zeroInit(c.VkPipelineInputAssemblyStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = c.VK_FALSE,
    });

    const rasterization_state_ci = std.mem.zeroInit(c.VkPipelineRasterizationStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = c.VK_CULL_MODE_NONE,
        .frontFace = c.VK_FRONT_FACE_CLOCKWISE,
        .lineWidth = 1.0,
    });

    const multisample_state_ci = std.mem.zeroInit(c.VkPipelineMultisampleStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        .minSampleShading = 1.0,
    });

    const depth_stencil_state_ci = std.mem.zeroInit(c.VkPipelineDepthStencilStateCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = c.VK_TRUE,
        .depthWriteEnable = c.VK_TRUE,
        .depthCompareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL,
        .depthBoundsTestEnable = c.VK_FALSE,
        .stencilTestEnable = c.VK_FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
    });

    const color_blend_attachment_state = std.mem.zeroInit(c.VkPipelineColorBlendAttachmentState, .{
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    });

    var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
        vert_stage_ci,
        frag_stage_ci,
    };
    var pipeline_builder = PipelineBuilder{
        .shader_stages = shader_stages[0..],
        .vertex_input_state = vertex_input_state_ci,
        .input_assembly_state = input_assembly_state_ci,
        .viewport = .{
            .x = 0.0,
            .y = 0.0,
            .width = @as(f32, @floatFromInt(self.swapchain_extent.width)),
            .height = @as(f32, @floatFromInt(self.swapchain_extent.height)),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        },
        .scissor = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        },
        .rasterization_state = rasterization_state_ci,
        .color_blend_attachment_state = color_blend_attachment_state,
        .multisample_state = multisample_state_ci,
        .pipeline_layout = triangle_pipeline_layout,
        .depth_stencil_state = depth_stencil_state_ci,
    };

    const red_triangle_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(VulkanDeleter.make(red_triangle_pipeline, c.vkDestroyPipeline)) catch @panic("Out of memory");
    if (red_triangle_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create red triangle pipeline", .{});
    } else {
        log.info("Created red triangle pipeline", .{});
    }

    _ = self.create_material(red_triangle_pipeline, triangle_pipeline_layout, "red_triangle_mat");


    const rgb_vert_code align(4) = @embedFile("colored_triangle.vert").*;
    const rgb_frag_code align(4) = @embedFile("colored_triangle.frag").*;
    const rgb_vert_module = create_shader_module(self, &rgb_vert_code) orelse VK_NULL_HANDLE;
    defer c.vkDestroyShaderModule(self.device, rgb_vert_module, vk_alloc_cbs);
    const rgb_frag_module = create_shader_module(self, &rgb_frag_code) orelse VK_NULL_HANDLE;
    defer c.vkDestroyShaderModule(self.device, rgb_frag_module, vk_alloc_cbs);

    if (rgb_vert_module != VK_NULL_HANDLE) log.info("Vert module loaded successfully", .{});
    if (rgb_frag_module != VK_NULL_HANDLE) log.info("Frag module loaded successfully", .{});

    pipeline_builder.shader_stages[0].module = rgb_vert_module;
    pipeline_builder.shader_stages[1].module = rgb_frag_module;

    const rgb_triangle_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(VulkanDeleter.make(rgb_triangle_pipeline, c.vkDestroyPipeline)) catch @panic("Out of memory");
    if (rgb_triangle_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create rgb triangle pipeline", .{});
    } else {
        log.info("Created rgb triangle pipeline", .{});
    }

    _ = self.create_material(rgb_triangle_pipeline, triangle_pipeline_layout, "rgb_triangle_mat");

    // Create pipeline for meshes
    const vertex_descritpion = mesh_mod.Vertex.vertex_input_description;

    pipeline_builder.vertex_input_state.pVertexAttributeDescriptions = vertex_descritpion.attributes.ptr;
    pipeline_builder.vertex_input_state.vertexAttributeDescriptionCount = @as(u32, @intCast(vertex_descritpion.attributes.len));
    pipeline_builder.vertex_input_state.pVertexBindingDescriptions = vertex_descritpion.bindings.ptr;
    pipeline_builder.vertex_input_state.vertexBindingDescriptionCount = @as(u32, @intCast(vertex_descritpion.bindings.len));

    const tri_mesh_vert_code align(4) = @embedFile("tri_mesh.vert").*;
    const tri_mesh_vert_module = create_shader_module(self, &tri_mesh_vert_code) orelse VK_NULL_HANDLE;
    defer c.vkDestroyShaderModule(self.device, tri_mesh_vert_module, vk_alloc_cbs);

    if (tri_mesh_vert_module != VK_NULL_HANDLE) log.info("Tri-mesh vert module loaded successfully", .{});

    pipeline_builder.shader_stages[0].module = tri_mesh_vert_module;
    pipeline_builder.shader_stages[1].module = rgb_frag_module; //NOTE: Use the one above

    // New layout for push constants
    const push_constant_range = std.mem.zeroInit(c.VkPushConstantRange, .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = @sizeOf(MeshPushConstants),
    });
    const mesh_pipeline_layout_ci = std.mem.zeroInit(c.VkPipelineLayoutCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    });

    var mesh_pipeline_layout: c.VkPipelineLayout = undefined;
    check_vk(c.vkCreatePipelineLayout(self.device, &mesh_pipeline_layout_ci, vk_alloc_cbs, &mesh_pipeline_layout))
        catch @panic("Failed to create mesh pipeline layout");
    self.deletion_queue.append(VulkanDeleter.make(mesh_pipeline_layout, c.vkDestroyPipelineLayout))
        catch @panic("Out of memory");

    pipeline_builder.pipeline_layout = mesh_pipeline_layout;

    const mesh_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(VulkanDeleter.make(mesh_pipeline, c.vkDestroyPipeline)) catch @panic("Out of memory");
    if (mesh_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create mesh pipeline", .{});
    } else {
        log.info("Created mesh pipeline", .{});
    }

    _ = self.create_material(mesh_pipeline, mesh_pipeline_layout, "default_mesh");
}

fn create_shader_module(self: *Self, code: []const u8) ?c.VkShaderModule {
    // NOTE: This being a better language than C/C++, means we don´t need to load
    // the SPIR-V code from a file, we can just embed it as an array of bytes.
    // To reflect the different behaviour from the original code, we also changed
    // the function name.
    std.debug.assert(code.len % 4 == 0);

    const data: *const u32 = @alignCast(@ptrCast(code.ptr));

    const shader_module_ci = std.mem.zeroInit(c.VkShaderModuleCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = data,
    });

    var shader_module: c.VkShaderModule = undefined;
    check_vk(c.vkCreateShaderModule(self.device, &shader_module_ci, vk_alloc_cbs, &shader_module)) catch |err| {
        log.err("Failed to create shader module with error: {s}", .{ @errorName(err) });
        return null;
    };

    return shader_module;
}

fn init_scene(self: *Self) void {
    const monkey = RenderObject {
        .mesh = self.meshes.getPtr("monkey") orelse @panic("Failed to get monkey mesh"),
        .material = self.materials.getPtr("default_mesh") orelse @panic("Failed to get default mesh material"),
        .transform = m3d.Mat4.IDENTITY,
    };
    self.renderables.append(monkey) catch @panic("Out of memory");

    var x: i32 = -20;
    while (x <= 20) : (x += 1) {
        var y: i32 = -20;
        while (y <= 20) : (y += 1) {
            const translation = m3d.translation(m3d.vec3(@floatFromInt(x), 0.0, @floatFromInt(y)));
            const scale = m3d.scale(m3d.vec3(0.2, 0.2, 0.2));
            const transform = m3d.Mat4.mul(translation, scale);

            const tri = RenderObject {
                .mesh = self.meshes.getPtr("triangle") orelse @panic("Failed to get triangle mesh"),
                .material = self.materials.getPtr("default_mesh") orelse @panic("Failed to get default mesh material"),
                .transform = transform,
            };

            self.renderables.append(tri) catch @panic("Out of memory");
        }
    }
}

pub fn cleanup(self: *Self) void {
    check_vk(c.vkDeviceWaitIdle(self.device))
        catch @panic("Failed to wait for device idle");

    // TODO: this is a horrible way to keep track of the meshes to free. Quick and dirty hack.
    var mesh_it = self.meshes.iterator();
    while (mesh_it.next()) |entry| {
        self.allocator.free(entry.value_ptr.vertices);
    }

    self.meshes.deinit();
    self.materials.deinit();
    self.renderables.deinit();

    for (self.buffer_deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.buffer_deletion_queue.deinit();

    for (self.image_deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.image_deletion_queue.deinit();

    for (self.deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.deletion_queue.deinit();


    self.allocator.free(self.framebuffers);
    self.allocator.free(self.swapchain_image_views);
    self.allocator.free(self.swapchain_images);

    c.vmaDestroyAllocator(self.vma_allocator);

    c.vkDestroyDevice(self.device, vk_alloc_cbs);
    c.vkDestroySurfaceKHR(self.instance, self.surface, vk_alloc_cbs);

    if (self.debug_messenger != VK_NULL_HANDLE) {
        const destroy_fn = vki.get_destroy_debug_utils_messenger_fn(self.instance).?;
        destroy_fn(self.instance, self.debug_messenger, vk_alloc_cbs);
    }

    c.vkDestroyInstance(self.instance, vk_alloc_cbs);
    c.SDL_DestroyWindow(self.window);
}

fn load_meshes(self: *Self) void {
    const vertices = [_]mesh_mod.Vertex{
        .{
            .position = m3d.vec3(1.0, 1.0, 0.0),
            .normal = undefined,
            .color = m3d.vec3(0.0, 1.0, 0.0),
        },
        .{
            .position = m3d.vec3(-1.0, 1.0, 0.0),
            .normal = undefined,
            .color = m3d.vec3(0.0, 1.0, 0.0),
        },
        .{
            .position = m3d.vec3(0.0, -1.0, 0.0),
            .normal = undefined,
            .color = m3d.vec3(0.0, 1.0, 0.0),
        }
    };

    var triangle_mesh = Mesh{
        .vertices = self.allocator.dupe(mesh_mod.Vertex, vertices[0..]) catch @panic("Out of memory"),
    };

    var monkey_mesh = mesh_mod.load_from_obj(self.allocator, "assets/suzanne.obj");

    self.upload_mesh(&triangle_mesh);
    self.upload_mesh(&monkey_mesh);
    self.meshes.put("triangle", triangle_mesh) catch @panic("Out of memory");
    self.meshes.put("monkey", monkey_mesh) catch @panic("Out of memory");
}

fn 
upload_mesh(self: *Self, mesh: *Mesh) void {
    const buffer_ci = std.mem.zeroInit(c.VkBufferCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = mesh.vertices.len * @sizeOf(mesh_mod.Vertex),
        .usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    });

    const vma_alloc_info = std.mem.zeroInit(c.VmaAllocationCreateInfo, .{
        .usage = c.VMA_MEMORY_USAGE_CPU_TO_GPU,
    });

    check_vk(c.vmaCreateBuffer(
        self.vma_allocator,
        &buffer_ci,
        &vma_alloc_info,
        &mesh.vertex_buffer.buffer,
        &mesh.vertex_buffer.allocation,
        null)) catch @panic("Failed to create vertex buffer");

    log.info("Created buffer {}", .{ @intFromPtr(mesh.vertex_buffer.buffer) });

    self.buffer_deletion_queue.append(
        VmaBufferDeleter{ .buffer = mesh.vertex_buffer }
    ) catch @panic("Out of memory");

    var data: ?*align(@alignOf(mesh_mod.Vertex)) anyopaque = undefined;
    check_vk(c.vmaMapMemory(self.vma_allocator, mesh.vertex_buffer.allocation, &data))
        catch @panic("Failed to map vertex buffer");
    @memcpy(@as([*]mesh_mod.Vertex, @ptrCast(data)), mesh.vertices);
    c.vmaUnmapMemory(self.vma_allocator, mesh.vertex_buffer.allocation);
}

pub fn run(self: *Self) void {
    var timer = std.time.Timer.start() catch @panic("Failed to start timer");
    var delta: f32 = 0.016;

    var quit = false;
    var event: c.SDL_Event = undefined;
    while (!quit) {
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_EVENT_QUIT) {
                quit = true;
            } else if (event.type == c.SDL_EVENT_KEY_DOWN) {
                switch (event.key.keysym.scancode) {
                    c.SDL_SCANCODE_SPACE => {
                        self.selected_shader = if (self.selected_shader == 1) 0 else 1;
                    },
                    c.SDL_SCANCODE_M => {
                        self.selected_mesh = if (self.selected_mesh == 1) 0 else 1;
                    },

                    // WASD for camera
                    c.SDL_SCANCODE_W => {
                        self.camera_input.z = 1.0;
                    },
                    c.SDL_SCANCODE_S => {
                        self.camera_input.z = -1.0;
                    },
                    c.SDL_SCANCODE_A => {
                        self.camera_input.x = 1.0;
                    },
                    c.SDL_SCANCODE_D => {
                        self.camera_input.x = -1.0;
                    },
                    c.SDL_SCANCODE_E => {
                        self.camera_input.y = 1.0;
                    },
                    c.SDL_SCANCODE_Q => {
                        self.camera_input.y = -1.0;
                    },

                    else => {},
                }
            } else if (event.type == c.SDL_EVENT_KEY_UP) {
                switch (event.key.keysym.scancode) {
                    c.SDL_SCANCODE_W => {
                        self.camera_input.z = 0.0;
                    },
                    c.SDL_SCANCODE_S => {
                        self.camera_input.z = 0.0;
                    },
                    c.SDL_SCANCODE_A => {
                        self.camera_input.x = 0.0;
                    },
                    c.SDL_SCANCODE_D => {
                        self.camera_input.x = 0.0;
                    },
                    c.SDL_SCANCODE_E => {
                        self.camera_input.y = 0.0;
                    },
                    c.SDL_SCANCODE_Q => {
                        self.camera_input.y = 0.0;
                    },

                    else => {},
                }
            }
        }

        if (self.camera_input.square_norm() > (0.1 * 0.1)) {
            var camera_delta = self.camera_input.normalized().mul(delta * 5.0);
            self.camera_pos = m3d.Vec3.add(self.camera_pos, camera_delta);
        }

        self.draw();
        delta = @floatCast(@as(f64, @floatFromInt(timer.lap())) / 1_000_000_000.0);

        const TitleDelay = struct {
            var accumulator: f32 = 0.0;
        };

        TitleDelay.accumulator += delta;
        if (TitleDelay.accumulator > 0.1) {
            TitleDelay.accumulator = 0.0;
            const fps = 1.0 / delta;
            const new_title = std.fmt.allocPrintZ(
                self.allocator, "Vulkan - FPS: {d:6.3}, ms: {d:6.3}", .{ fps, delta * 1000.0 }
            ) catch @panic("Out of memory");
            defer self.allocator.free(new_title);
            _ = c.SDL_SetWindowTitle(self.window, new_title.ptr);
        }
    }
}

fn get_current_frame(self: *Self) FrameData {
    return self.frames[@intCast(@mod(self.frame_number, FRAME_OVERLAP))];
}

fn draw(self: *Self) void {
    // Wait until the GPU has finished rendering the last frame
    const timeout: u64 = 1_000_000_000; // 1 second in nanonesconds
    const frame = self.get_current_frame();

    check_vk(c.vkWaitForFences(self.device, 1, &frame.render_fence, c.VK_TRUE, timeout))
        catch @panic("Failed to wait for render fence");
    check_vk(c.vkResetFences(self.device, 1, &frame.render_fence))
        catch @panic("Failed to reset render fence");


    var swapchain_image_index: u32 = undefined;
    check_vk(c.vkAcquireNextImageKHR(self.device, self.swapchain, timeout, frame.present_semaphore, VK_NULL_HANDLE, &swapchain_image_index))
        catch @panic("Failed to acquire swapchain image");

    var cmd = frame.main_command_buffer;

    check_vk(c.vkResetCommandBuffer(cmd, 0))
        catch @panic("Failed to reset command buffer");

    const cmd_begin_info = std.mem.zeroInit(c.VkCommandBufferBeginInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });

    check_vk(c.vkBeginCommandBuffer(cmd, &cmd_begin_info))
        catch @panic("Failed to begin command buffer");

    const state = struct {
        var frame_number: u32 = 0;
    };

    // Make a claer color that changes with each frame (120*pi frame period)
    const color = @fabs(std.math.sin(@as(f32, @floatFromInt(state.frame_number)) / 120.0));
    const color_clear: c.VkClearValue = .{
        .color = .{ .float32 = [_]f32{ 0.0, 0.0, color, 1.0 } },
    };

    const depth_clear = c.VkClearValue{
        .depthStencil = .{
            .depth = 1.0,
            .stencil = 0,
        },
    };

    const clear_values = [_]c.VkClearValue{
        color_clear,
        depth_clear,
    };

    const render_pass_begin_info = std.mem.zeroInit(c.VkRenderPassBeginInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = self.render_pass,
        .framebuffer = self.framebuffers[swapchain_image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        },
        .clearValueCount = @as(u32, @intCast(clear_values.len)),
        .pClearValues = &clear_values[0],
    });
    c.vkCmdBeginRenderPass(cmd, &render_pass_begin_info, c.VK_SUBPASS_CONTENTS_INLINE);

    self.draw_objects(cmd, self.renderables.items);

    c.vkCmdEndRenderPass(cmd);
    check_vk(c.vkEndCommandBuffer(cmd))
        catch @panic("Failed to end command buffer");

    const wait_stage = @as(u32, @intCast(c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT));
    const submit_info = std.mem.zeroInit(c.VkSubmitInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &frame.present_semaphore,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &frame.render_semaphore,
    });
    check_vk(c.vkQueueSubmit(self.graphics_queue, 1, &submit_info, frame.render_fence))
        catch @panic("Failed to submit to graphics queue");

    const present_info = std.mem.zeroInit(c.VkPresentInfoKHR, .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &frame.render_semaphore,
        .swapchainCount = 1,
        .pSwapchains = &self.swapchain,
        .pImageIndices = &swapchain_image_index,
    });
    check_vk(c.vkQueuePresentKHR(self.present_queue, &present_info))
        catch @panic("Failed to present swapchain image");

    state.frame_number += 1;
}

fn draw_objects(self: *Self, cmd: c.VkCommandBuffer, objects: []RenderObject) void {
    const view = m3d.translation(self.camera_pos);
    const aspect = @as(f32, @floatFromInt(self.swapchain_extent.width)) / @as(f32, @floatFromInt(self.swapchain_extent.height));
    var proj = m3d.perspective(std.math.degreesToRadians(f32, 70.0), aspect, 0.1, 200.0);

    proj.j.y *= -1.0;

    for (objects, 0..) |object, index| {
        if (index == 0 or object.material != objects[index - 1].material) {
            c.vkCmdBindPipeline(
                cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, object.material.pipeline);
        }

        const mvp = m3d.Mat4.mul(m3d.Mat4.mul(proj, view), object.transform);
        const push_constants = MeshPushConstants{
            .data = m3d.Vec4.ZERO,
            .render_matrix = mvp,
        };

        c.vkCmdPushConstants(
            cmd,
            object.material.pipeline_layout,
            c.VK_SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(MeshPushConstants),
            &push_constants);

        if (index == 0 or object.mesh != objects[index - 1].mesh) {
            const offset: c.VkDeviceSize = 0;
            c.vkCmdBindVertexBuffers(
                cmd, 0, 1, &object.mesh.vertex_buffer.buffer, &offset);
        }

        c.vkCmdDraw(cmd, @as(u32, @intCast(object.mesh.vertices.len)), 1, 0, 0);
    }
}

fn create_material(self: *Self, pipeline: c.VkPipeline, pipeline_layout: c.VkPipelineLayout, name: []const u8) *Material {
    self.materials.put(name, Material{
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
    }) catch @panic("Out of memory");
    return self.materials.getPtr(name) orelse unreachable;
}

fn get_material(self: *Self, name: []const u8) ?*Material {
    return self.material.getPtr(name);
}

fn get_mesh(self: *Self, name: []const u8) ?*Mesh {
    return self.meshes.getPtr(name);
}

// Error checking for vulkan and SDL
//

fn check_sdl(res: c_int) void {
    if (res != 0) {
        log.err("Detected SDL error: {s}", .{ c.SDL_GetError() });
        @panic("SDL error");
    }
}

fn check_sdl_bool(res: c.SDL_bool) void {
    if (res != c.SDL_TRUE) {
        log.err("Detected SDL error: {s}", .{ c.SDL_GetError() });
        @panic("SDL error");
    }
}
