const std = @import("std");
const c = @import("clibs.zig");

const vki = @import("vulkan_init.zig");
const check_vk = vki.check_vk;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;
const math3d = @import("math3d.zig");
const Vec3 = math3d.Vec3;

const log = std.log.scoped(.vulkan_engine);

const Self = @This();

const window_extent = c.VkExtent2D{ .width = 1600, .height = 900 };

const VK_NULL_HANDLE = null;

const vk_alloc_cbs: ?*c.VkAllocationCallbacks = null;

pub const AllocatedBuffer = struct {
    buffer: c.VkBuffer,
    allocation: c.VmaAllocation,
};

// Data
//
frame_number: i32 = 0,
selected_shader: i32 = 0,

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

command_pool: c.VkCommandPool = VK_NULL_HANDLE,
main_command_buffer: c.VkCommandBuffer = VK_NULL_HANDLE,

render_pass: c.VkRenderPass = VK_NULL_HANDLE,
framebuffers: []c.VkFramebuffer = undefined,

present_semaphore: c.VkSemaphore = VK_NULL_HANDLE,
render_semaphore: c.VkSemaphore = VK_NULL_HANDLE,
render_fence: c.VkFence = VK_NULL_HANDLE,

triangle_pipeline_layout: c.VkPipelineLayout = VK_NULL_HANDLE,
red_triangle_pipeline: c.VkPipeline = VK_NULL_HANDLE,
rgb_triangle_pipeline: c.VkPipeline = VK_NULL_HANDLE,

vma_allocator: c.VmaAllocator = undefined,

mesh_pipeline: c.VkPipeline = VK_NULL_HANDLE,
triangle_mesh: Mesh = undefined,

deletion_queue: std.ArrayList(VulkanDeleter) = undefined,
buffer_deletion_queue: std.ArrayList(VmaBufferDeleter) = undefined,

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
    };

    engine.init_instance();

    // Create the window surface
    check_sdl_bool(c.SDL_Vulkan_CreateSurface(window, engine.instance, &engine.surface));

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

    return engine;
}

fn init_instance(self: *Self) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sdl_required_extension_count: u32 = undefined;
    check_sdl_bool(c.SDL_Vulkan_GetInstanceExtensions(&sdl_required_extension_count, null));
    const sdl_required_extensions = arena.alloc([*c]const u8, sdl_required_extension_count) catch @panic("Out of memory");
    check_sdl_bool(c.SDL_Vulkan_GetInstanceExtensions(&sdl_required_extension_count, sdl_required_extensions.ptr));

    // Instance creation and optional debug utilities
    const instance = vki.create_instance(std.heap.page_allocator, .{
        .application_name = "VkGuide",
        .application_version = c.VK_MAKE_VERSION(0, 1, 0),
        .engine_name = "VkGuide",
        .engine_version = c.VK_MAKE_VERSION(0, 1, 0),
        .api_version = c.VK_MAKE_VERSION(1, 1, 0),
        .debug = true,
        .required_extensions = sdl_required_extensions,
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
}

fn init_commands(self: *Self) void {
    // Create a command pool
    const command_pool_ci = std.mem.zeroInit(c.VkCommandPoolCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.graphics_queue_family,
    });

    check_vk(c.vkCreateCommandPool(self.device, &command_pool_ci, vk_alloc_cbs, &self.command_pool))
        catch log.err("Failed to create command pool", .{});
    self.deletion_queue.append(VulkanDeleter.make(self.command_pool, c.vkDestroyCommandPool)) catch @panic("Out of memory");

    // Allocate a command buffer from the command pool
    const command_buffer_ai = std.mem.zeroInit(c.VkCommandBufferAllocateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    });

    check_vk(c.vkAllocateCommandBuffers(self.device, &command_buffer_ai, &self.main_command_buffer))
        catch @panic("Failed to allocate command buffer");

    log.info("Created command pool and command buffer", .{});
}

fn init_default_renderpass(self: *Self) void {
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

    const subpass = std.mem.zeroInit(c.VkSubpassDescription, .{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
    });

    const render_pass_create_info = std.mem.zeroInit(c.VkRenderPassCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
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
        .attachmentCount = 1,
        .width = self.swapchain_extent.width,
        .height = self.swapchain_extent.height,
        .layers = 1,
    });

    self.framebuffers = self.allocator.alloc(c.VkFramebuffer, self.swapchain_image_views.len) catch @panic("Out of memory");

    for (self.swapchain_image_views, self.framebuffers) |view, *framebuffer| {
        framebuffer_ci.pAttachments = &view;
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

    check_vk(c.vkCreateSemaphore(self.device, &semaphore_ci, vk_alloc_cbs, &self.present_semaphore))
        catch @panic("Failed to create present semaphore");
    self.deletion_queue.append(VulkanDeleter.make(self.present_semaphore, c.vkDestroySemaphore)) catch @panic("Out of memory");
    check_vk(c.vkCreateSemaphore(self.device, &semaphore_ci, vk_alloc_cbs, &self.render_semaphore))
        catch @panic("Failed to create render semaphore");
    self.deletion_queue.append(VulkanDeleter.make(self.render_semaphore, c.vkDestroySemaphore)) catch @panic("Out of memory");

    const fence_ci = std.mem.zeroInit(c.VkFenceCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    });

    check_vk(c.vkCreateFence(self.device, &fence_ci, vk_alloc_cbs, &self.render_fence))
        catch @panic("Failed to create render fence");
    self.deletion_queue.append(VulkanDeleter.make(self.render_fence, c.vkDestroyFence)) catch @panic("Out of memory");

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
    check_vk(c.vkCreatePipelineLayout(self.device, &pipeline_layout_ci, vk_alloc_cbs, &self.triangle_pipeline_layout))
        catch @panic("Failed to create pipeline layout");
    self.deletion_queue.append(VulkanDeleter.make(self.triangle_pipeline_layout, c.vkDestroyPipelineLayout)) catch @panic("Out of memory");

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
        .pipeline_layout = self.triangle_pipeline_layout,
    };

    self.red_triangle_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(VulkanDeleter.make(self.red_triangle_pipeline, c.vkDestroyPipeline)) catch @panic("Out of memory");
    if (self.red_triangle_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create red triangle pipeline", .{});
    } else {
        log.info("Created red triangle pipeline", .{});
    }

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

    self.rgb_triangle_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(VulkanDeleter.make(self.rgb_triangle_pipeline, c.vkDestroyPipeline)) catch @panic("Out of memory");
    if (self.rgb_triangle_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create rgb triangle pipeline", .{});
    } else {
        log.info("Created rgb triangle pipeline", .{});
    }

    // Create mesh pipeline for meshes
    const vertex_descritpion = mesh_mod.Vertex.vertex_input_description;

    pipeline_builder.vertex_input_state.pVertexAttributeDescriptions = vertex_descritpion.attributes.ptr;
    pipeline_builder.vertex_input_state.vertexAttributeDescriptionCount = @as(u32, @intCast(vertex_descritpion.attributes.len));
    pipeline_builder.vertex_input_state.pVertexBindingDescriptions = vertex_descritpion.bindings.ptr;
    pipeline_builder.vertex_input_state.vertexBindingDescriptionCount = @as(u32, @intCast(vertex_descritpion.bindings.len));

    const tri_mesh_vert_code align(4) = @embedFile("tri_mesh.vert").*;
    const tri_mesh_vert_module = create_shader_module(self, &tri_mesh_vert_code) orelse VK_NULL_HANDLE;
    defer c.vkDestroyShaderModule(self.device, tri_mesh_vert_module, vk_alloc_cbs);

    if (tri_mesh_vert_module != VK_NULL_HANDLE) log.info("Vert module loaded successfully", .{});

    pipeline_builder.shader_stages[0].module = tri_mesh_vert_module;
    pipeline_builder.shader_stages[1].module = rgb_frag_module; //NOTE: Use the one above

    self.mesh_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(VulkanDeleter.make(self.mesh_pipeline, c.vkDestroyPipeline)) catch @panic("Out of memory");
    if (self.mesh_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create mesh pipeline", .{});
    } else {
        log.info("Created mesh pipeline", .{});
    }
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

pub fn cleanup(self: *Self) void {
    check_vk(c.vkDeviceWaitIdle(self.device))
        catch @panic("Failed to wait for device idle");

    for (self.buffer_deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.buffer_deletion_queue.deinit();
    for (self.deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.deletion_queue.deinit();

    self.allocator.free(self.triangle_mesh.vertices);

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
    var vertices = self.allocator.alloc(mesh_mod.Vertex, 3) catch @panic("Out of memory");

    vertices[0] = .{
        .position = .{ .x =  1.0, .y =  1.0, .z = 0.0 },
        .normal = undefined,
        .color = .{ .x = 0.0, .y = 1.0, .z = 0.0 }
    };

    vertices[1] = .{
        .position = .{ .x = -1.0, .y =  1.0, .z = 0.0 },
        .normal = undefined,
        .color = .{ .x = 0.0, .y = 1.0, .z = 0.0 }
    };

    vertices[2] = .{
        .position = .{ .x =  0.0, .y = -1.0, .z = 0.0 },
        .normal = undefined,
        .color = .{ .x = 0.0, .y = 1.0, .z = 0.0 }
    };

    self.triangle_mesh = Mesh{
        .vertices = vertices,
    };

    upload_mesh(self, &self.triangle_mesh);
}

fn upload_mesh(self: *Self, mesh: *Mesh) void {
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
                    else => {},
                }
            }
        }

        self.draw();
    }
}

fn draw(self: *Self) void {
    // Wait until the GPU has finished rendering the last frame
    const timeout: u64 = 1_000_000_000; // 1 second in nanonesconds
    check_vk(c.vkWaitForFences(self.device, 1, &self.render_fence, c.VK_TRUE, timeout))
        catch @panic("Failed to wait for render fence");
    check_vk(c.vkResetFences(self.device, 1, &self.render_fence))
        catch @panic("Failed to reset render fence");


    var swapchain_image_index: u32 = undefined;
    check_vk(c.vkAcquireNextImageKHR(self.device, self.swapchain, timeout, self.present_semaphore, VK_NULL_HANDLE, &swapchain_image_index))
        catch @panic("Failed to acquire swapchain image");

    check_vk(c.vkResetCommandBuffer(self.main_command_buffer, 0))
        catch @panic("Failed to reset command buffer");

    var cmd = self.main_command_buffer;

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
    const clear_value: c.VkClearValue = .{
        .color = .{ .float32 = [_]f32{ 0.0, 0.0, color, 1.0 } },
    };

    const render_pass_begin_info = std.mem.zeroInit(c.VkRenderPassBeginInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = self.render_pass,
        .framebuffer = self.framebuffers[swapchain_image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        },
        .clearValueCount = 1,
        .pClearValues = &clear_value,
    });
    c.vkCmdBeginRenderPass(cmd, &render_pass_begin_info, c.VK_SUBPASS_CONTENTS_INLINE);

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.mesh_pipeline);

    const offset: c.VkDeviceSize = 0;
    c.vkCmdBindVertexBuffers(cmd, 0, 1, &self.triangle_mesh.vertex_buffer.buffer, &offset);

    c.vkCmdDraw(cmd, @as(u32, @intCast(self.triangle_mesh.vertices.len)), 1, 0, 0);

    c.vkCmdEndRenderPass(cmd);
    check_vk(c.vkEndCommandBuffer(cmd))
        catch @panic("Failed to end command buffer");

    const wait_stage = @as(u32, @intCast(c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT));
    const submit_info = std.mem.zeroInit(c.VkSubmitInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &self.present_semaphore,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &self.render_semaphore,
    });
    check_vk(c.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.render_fence))
        catch @panic("Failed to submit to graphics queue");

    const present_info = std.mem.zeroInit(c.VkPresentInfoKHR, .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &self.render_semaphore,
        .swapchainCount = 1,
        .pSwapchains = &self.swapchain,
        .pImageIndices = &swapchain_image_index,
    });
    check_vk(c.vkQueuePresentKHR(self.present_queue, &present_info))
        catch @panic("Failed to present swapchain image");

    state.frame_number += 1;
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
