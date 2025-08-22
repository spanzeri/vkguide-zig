const std = @import("std");
const c = @import("clibs.zig");
const vki = @import("vulkan_init.zig");
const check_vk = vki.check_vk;
const mesh_mod = @import("mesh.zig");
const Mesh = mesh_mod.Mesh;

const math3d = @import("math3d.zig");
const Vec2 = math3d.Vec2;
const Vec3 = math3d.Vec3;
const Vec4 = math3d.Vec4;
const Mat4 = math3d.Mat4;

const texs = @import("textures.zig");
const Texture = texs.Texture;

const log = std.log.scoped(.vulkan_engine);

const Self = @This();

const window_extent = c.vk.Extent2D{ .width = 1600, .height = 900 };

const VK_NULL_HANDLE = null;

const vk_alloc_cbs: ?*c.vk.AllocationCallbacks = null;

pub const AllocatedBuffer = struct {
    buffer: c.vk.Buffer,
    allocation: c.vma.Allocation,
};

pub const AllocatedImage = struct {
    image: c.vk.Image,
    allocation: c.vma.Allocation,
};

// Scene management
const Material = struct {
    texture_set: c.vk.DescriptorSet = VK_NULL_HANDLE,
    pipeline: c.vk.Pipeline,
    pipeline_layout: c.vk.PipelineLayout,
};

const RenderObject = struct {
    mesh: *Mesh,
    material: *Material,
    transform: Mat4,
};

const FrameData = struct {
    present_semaphore: c.vk.Semaphore = VK_NULL_HANDLE,
    render_semaphore: c.vk.Semaphore = VK_NULL_HANDLE,
    render_fence: c.vk.Fence = VK_NULL_HANDLE,
    command_pool: c.vk.CommandPool = VK_NULL_HANDLE,
    main_command_buffer: c.vk.CommandBuffer = VK_NULL_HANDLE,

    object_buffer: AllocatedBuffer = .{ .buffer = VK_NULL_HANDLE, .allocation = VK_NULL_HANDLE },
    object_descriptor_set: c.vk.DescriptorSet = VK_NULL_HANDLE,
};

const GPUCameraData = struct {
    view: Mat4,
    proj: Mat4,
    view_proj: Mat4,
};

const GPUSceneData = struct {
    fog_color: Vec4,
    fog_distance: Vec4, // x = start, y = end
    ambient_color: Vec4,
    sunlight_dir: Vec4,
    sunlight_color: Vec4,
};

const GPUObjectData = struct {
    model_matrix: Mat4,
};

const UploadContext = struct {
    upload_fence: c.vk.Fence = VK_NULL_HANDLE,
    command_pool: c.vk.CommandPool = VK_NULL_HANDLE,
    command_buffer: c.vk.CommandBuffer = VK_NULL_HANDLE,
};

const FRAME_OVERLAP = 2;

// Data
//
frame_number: i32 = 0,
selected_shader: i32 = 0,
selected_mesh: i32 = 0,

window: *c.SDL.Window = undefined,

// Keep this around for long standing allocations
allocator: std.mem.Allocator = undefined,

// Vulkan data
instance: c.vk.Instance = VK_NULL_HANDLE,
debug_messenger: c.vk.DebugUtilsMessengerEXT = VK_NULL_HANDLE,

physical_device: c.vk.PhysicalDevice = VK_NULL_HANDLE,
physical_device_properties: c.vk.PhysicalDeviceProperties = undefined,

device: c.vk.Device = VK_NULL_HANDLE,
surface: c.vk.SurfaceKHR = VK_NULL_HANDLE,

swapchain: c.vk.SwapchainKHR = VK_NULL_HANDLE,
swapchain_format: c.vk.Format = undefined,
swapchain_extent: c.vk.Extent2D = undefined,
swapchain_images: []c.vk.Image = undefined,
swapchain_image_views: []c.vk.ImageView = undefined,

graphics_queue: c.vk.Queue = VK_NULL_HANDLE,
graphics_queue_family: u32 = undefined,
present_queue: c.vk.Queue = VK_NULL_HANDLE,
present_queue_family: u32 = undefined,

render_pass: c.vk.RenderPass = VK_NULL_HANDLE,
framebuffers: []c.vk.Framebuffer = undefined,

depth_image_view: c.vk.ImageView = VK_NULL_HANDLE,
depth_image: AllocatedImage = undefined,
depth_format: c.vk.Format = undefined,

upload_context: UploadContext = .{},

frames: [FRAME_OVERLAP]FrameData = .{ FrameData{} } ** FRAME_OVERLAP,

camera_and_scene_set: c.vk.DescriptorSet = VK_NULL_HANDLE,
camera_and_scene_buffer: AllocatedBuffer = undefined,

global_set_layout: c.vk.DescriptorSetLayout = VK_NULL_HANDLE,
object_set_layout: c.vk.DescriptorSetLayout = VK_NULL_HANDLE,
single_texture_set_layout: c.vk.DescriptorSetLayout = VK_NULL_HANDLE,
descriptor_pool: c.vk.DescriptorPool = VK_NULL_HANDLE,

vma_allocator: c.vma.Allocator = undefined,

renderables: std.ArrayList(RenderObject),
materials: std.StringHashMap(Material),
meshes: std.StringHashMap(Mesh),
textures: std.StringHashMap(Texture),

camera_pos: Vec3 = Vec3.make(0.0, -3.0, -10.0),
camera_input: Vec3 = Vec3.make(0.0, 0.0, 0.0),

deletion_queue: std.ArrayList(VulkanDeleter) = undefined,
buffer_deletion_queue: std.ArrayList(VmaBufferDeleter) = undefined,
image_deletion_queue: std.ArrayList(VmaImageDeleter) = undefined,

pub const MeshPushConstants = struct {
    data: Vec4,
    render_matrix: Mat4,
};

pub const VulkanDeleter = struct {
    object: ?*anyopaque,
    delete_fn: *const fn(entry: *VulkanDeleter, self: *Self) void,

    fn delete(self: *VulkanDeleter, engine: *Self) void {
        self.delete_fn(self, engine);
    }

    fn make(object: anytype, func: anytype) VulkanDeleter {
        const T = @TypeOf(object);
        comptime {
            std.debug.assert(@typeInfo(T) == .optional);
            const Ptr = @typeInfo(T).optional.child;
            std.debug.assert(@typeInfo(Ptr) == .pointer);
            std.debug.assert(@typeInfo(Ptr).pointer.size == .one);

            const Fn = @TypeOf(func);
            std.debug.assert(@typeInfo(Fn) == .@"fn");
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

pub const VmaBufferDeleter = struct {
    buffer: AllocatedBuffer,

    fn delete(self: *VmaBufferDeleter, engine: *Self) void {
        c.vma.DestroyBuffer(engine.vma_allocator, self.buffer.buffer, self.buffer.allocation);
    }
};

pub const VmaImageDeleter = struct {
    image: AllocatedImage,

    fn delete(self: *VmaImageDeleter, engine: *Self) void {
        c.vma.DestroyImage(engine.vma_allocator, self.image.image, self.image.allocation);
    }
};

    pub fn init(a: std.mem.Allocator) Self {
        check_sdl(c.SDL.Init(c.SDL.INIT_VIDEO));

    const window = c.SDL.CreateWindow(
        "Vulkan",
        window_extent.width,
        window_extent.height,
        c.SDL.WINDOW_VULKAN | c.SDL.WINDOW_RESIZABLE
    ) orelse @panic("Failed to create SDL window");

    _ = c.SDL.ShowWindow(window);

    var engine = Self{
        .window = window,
        .allocator = a,
        .deletion_queue = std.ArrayList(VulkanDeleter){},
        .buffer_deletion_queue = std.ArrayList(VmaBufferDeleter){},
        .image_deletion_queue = std.ArrayList(VmaImageDeleter){},
        .renderables = std.ArrayList(RenderObject){},
        .materials = std.StringHashMap(Material).init(a),
        .meshes = std.StringHashMap(Mesh).init(a),
        .textures = std.StringHashMap(Texture).init(a),
    };

    engine.init_instance();

    // Create the window surface
    check_sdl_bool(c.SDL.Vulkan_CreateSurface(window, engine.instance, vk_alloc_cbs, &engine.surface));

    engine.init_device();

    // Create a VMA allocator
    const allocator_ci = std.mem.zeroInit(c.vma.AllocatorCreateInfo, .{
        .physicalDevice = engine.physical_device,
        .device = engine.device,
        .instance = engine.instance,
    });
    check_vk(c.vma.CreateAllocator(&allocator_ci, &engine.vma_allocator))
        catch @panic("Failed to create VMA allocator");

    engine.init_swapchain();
    engine.init_commands();
    engine.init_default_renderpass();
    engine.init_framebuffers();
    engine.init_sync_structures();
    engine.init_descriptors();
    engine.init_pipelines();
    engine.load_textures();
    engine.load_meshes();
    engine.init_scene();
    engine.init_imgui();

    return engine;
}

fn init_instance(self: *Self) void {
    var sdl_required_extension_count: u32 = undefined;
    const sdl_extensions = c.SDL.Vulkan_GetInstanceExtensions(&sdl_required_extension_count);
    const sdl_extension_slice = sdl_extensions[0..sdl_required_extension_count];

    // Instance creation and optional debug utilities
    const instance = vki.create_instance(std.heap.page_allocator, .{
        .application_name = "VkGuide",
        .application_version = c.vk.MAKE_VERSION(0, 1, 0),
        .engine_name = "VkGuide",
        .engine_version = c.vk.MAKE_VERSION(0, 1, 0),
        .api_version = c.vk.MAKE_VERSION(1, 1, 0),
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
        .min_api_version = c.vk.MAKE_VERSION(1, 1, 0),
        .required_extensions = required_device_extensions,
        .surface = self.surface,
        .criteria = .PreferDiscrete,
    }) catch |err| {
        log.err("Failed to select physical device with error: {s}", .{ @errorName(err) });
        unreachable;
    };

    self.physical_device = physical_device.handle;
    self.physical_device_properties = physical_device.properties;

    log.info("The GPU has a minimum buffer alignment of {} bytes", .{ physical_device.properties.limits.minUniformBufferOffsetAlignment });

    self.graphics_queue_family = physical_device.graphics_queue_family;
    self.present_queue_family = physical_device.present_queue_family;

    const shader_draw_parameters_features = std.mem.zeroInit(c.vk.PhysicalDeviceShaderDrawParametersFeatures, .{
        .sType = c.vk.STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES,
        .shaderDrawParameters = c.vk.TRUE,
    });

    // Create a logical device
    const device = vki.create_logical_device(self.allocator, .{
        .physical_device = physical_device,
        .features = std.mem.zeroInit(c.vk.PhysicalDeviceFeatures, .{}),
        .alloc_cb = vk_alloc_cbs,
        .pnext = &shader_draw_parameters_features,
    }) catch @panic("Failed to create logical device");

    self.device = device.handle;
    self.graphics_queue = device.graphics_queue;
    self.present_queue = device.present_queue;
}

fn init_swapchain(self: *Self) void {
    var win_width: c_int = undefined;
    var win_height: c_int = undefined;
    check_sdl(c.SDL.GetWindowSize(self.window, &win_width, &win_height));

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

    for (self.swapchain_image_views) |view| {
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(view, c.vk.DestroyImageView),
        ) catch @panic("Out of memory");
    }
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(swapchain.handle, c.vk.DestroySwapchainKHR),
    ) catch @panic("Out of memory");

    log.info("Created swapchain", .{});

    // Create depth image to associate with the swapchain
    const extent = c.vk.Extent3D {
        .width = self.swapchain_extent.width,
        .height = self.swapchain_extent.height,
        .depth = 1,
    };

    // Hard-coded 32-bit float depth format
    self.depth_format = c.vk.FORMAT_D32_SFLOAT;

    const depth_image_ci = std.mem.zeroInit(c.vk.ImageCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.vk.IMAGE_TYPE_2D,
        .format = self.depth_format,
        .extent = extent,
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.vk.SAMPLE_COUNT_1_BIT,
        .tiling = c.vk.IMAGE_TILING_OPTIMAL,
        .usage = c.vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        .sharingMode = c.vk.SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.vk.IMAGE_LAYOUT_UNDEFINED,
    });

    const depth_image_ai = std.mem.zeroInit(c.vma.AllocationCreateInfo, .{
        .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
        .requiredFlags = c.vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    });

    check_vk(c.vma.CreateImage(self.vma_allocator, &depth_image_ci, &depth_image_ai, &self.depth_image.image, &self.depth_image.allocation, null))
        catch @panic("Failed to create depth image");

    const depth_image_view_ci = std.mem.zeroInit(c.vk.ImageViewCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = self.depth_image.image,
        .viewType = c.vk.IMAGE_VIEW_TYPE_2D,
        .format = self.depth_format,
        .subresourceRange = .{
            .aspectMask = c.vk.IMAGE_ASPECT_DEPTH_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    });

    check_vk(c.vk.CreateImageView(self.device, &depth_image_view_ci, vk_alloc_cbs, &self.depth_image_view))
        catch @panic("Failed to create depth image view");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.depth_image_view, c.vk.DestroyImageView),
    ) catch @panic("Out of memory");
    self.image_deletion_queue.append(
        self.allocator,
        VmaImageDeleter{ .image = self.depth_image },
    ) catch @panic("Out of memory");

    log.info("Created depth image", .{});
}

fn init_commands(self: *Self) void {
    // Create a command pool
    const command_pool_ci = std.mem.zeroInit(c.vk.CommandPoolCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.graphics_queue_family,
    });

    for (&self.frames) |*frame| {
        check_vk(c.vk.CreateCommandPool(self.device, &command_pool_ci, vk_alloc_cbs, &frame.command_pool))
            catch log.err("Failed to create command pool", .{});
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(frame.command_pool, c.vk.DestroyCommandPool),
        ) catch @panic("Out of memory");

        // Allocate a command buffer from the command pool
        const command_buffer_ai = std.mem.zeroInit(c.vk.CommandBufferAllocateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = frame.command_pool,
            .level = c.vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        });

        check_vk(c.vk.AllocateCommandBuffers(self.device, &command_buffer_ai, &frame.main_command_buffer))
            catch @panic("Failed to allocate command buffer");

        log.info("Created command pool and command buffer", .{});
    }

    // =================================
    // Upload context
    //

    // For the time being this is submitting on the graphics queue
    const upload_command_pool_ci = std.mem.zeroInit(c.vk.CommandPoolCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = 0,
        .queueFamilyIndex = self.graphics_queue_family,
    });

    check_vk(c.vk.CreateCommandPool(self.device, &upload_command_pool_ci, vk_alloc_cbs, &self.upload_context.command_pool))
        catch @panic("Failed to create upload command pool");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.upload_context.command_pool, c.vk.DestroyCommandPool),
    ) catch @panic("Out of memory");

    const upload_command_buffer_ai = std.mem.zeroInit(c.vk.CommandBufferAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.upload_context.command_pool,
        .level = c.vk.COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    });

    check_vk(c.vk.AllocateCommandBuffers(self.device, &upload_command_buffer_ai, &self.upload_context.command_buffer))
        catch @panic("Failed to allocate upload command buffer");
}

fn init_default_renderpass(self: *Self) void {
    // Color attachement
    const color_attachment = std.mem.zeroInit(c.vk.AttachmentDescription, .{
        .format         = self.swapchain_format,
        .samples        = c.vk.SAMPLE_COUNT_1_BIT,
        .loadOp         = c.vk.ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp        = c.vk.ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp  = c.vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = c.vk.IMAGE_LAYOUT_UNDEFINED,
        .finalLayout    = c.vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
    });

    const color_attachment_ref = std.mem.zeroInit(c.vk.AttachmentReference, .{
        .attachment = 0,
        .layout = c.vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    });

    // Depth attachment
    const depth_attachment = std.mem.zeroInit(c.vk.AttachmentDescription, .{
        .format         = self.depth_format,
        .samples        = c.vk.SAMPLE_COUNT_1_BIT,
        .loadOp         = c.vk.ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp        = c.vk.ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp  = c.vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = c.vk.IMAGE_LAYOUT_UNDEFINED,
        .finalLayout    = c.vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    });

    const depth_attachement_ref = std.mem.zeroInit(c.vk.AttachmentReference, .{
        .attachment = 1,
        .layout = c.vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    });

    // Subpass
    const subpass = std.mem.zeroInit(c.vk.SubpassDescription, .{
        .pipelineBindPoint = c.vk.PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
        .pDepthStencilAttachment = &depth_attachement_ref,
    });

    const attachment_descriptions = [_]c.vk.AttachmentDescription{
        color_attachment,
        depth_attachment,
    };

    // Subpass color and depth depencies
    const color_dependency = std.mem.zeroInit(c.vk.SubpassDependency, .{
        .srcSubpass    = c.vk.SUBPASS_EXTERNAL,
        .dstSubpass    = 0,
        .srcStageMask  = c.vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask  = c.vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = c.vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    });

    const depth_dependency = std.mem.zeroInit(c.vk.SubpassDependency, .{
        .srcSubpass    = c.vk.SUBPASS_EXTERNAL,
        .dstSubpass    = 0,
        .srcStageMask  = c.vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = c.vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask  = c.vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .dstAccessMask = c.vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    });

    const dependecies = [_]c.vk.SubpassDependency{
        color_dependency,
        depth_dependency,
    };

    const render_pass_create_info = std.mem.zeroInit(c.vk.RenderPassCreateInfo, .{
        .sType           = c.vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = @as(u32, @intCast(attachment_descriptions.len)),
        .pAttachments    = attachment_descriptions[0..].ptr,
        .subpassCount    = 1,
        .pSubpasses      = &subpass,
        .dependencyCount = @as(u32, @intCast(dependecies.len)),
        .pDependencies   = &dependecies[0],
    });

    check_vk(c.vk.CreateRenderPass(self.device, &render_pass_create_info, vk_alloc_cbs, &self.render_pass))
        catch @panic("Failed to create render pass");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.render_pass, c.vk.DestroyRenderPass)
    ) catch @panic("Out of memory");

    log.info("Created render pass", .{});
}

fn init_framebuffers(self: *Self) void {
    var framebuffer_ci = std.mem.zeroInit(c.vk.FramebufferCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = self.render_pass,
        .attachmentCount = 2,
        .width = self.swapchain_extent.width,
        .height = self.swapchain_extent.height,
        .layers = 1,
    });

    self.framebuffers = self.allocator.alloc(c.vk.Framebuffer, self.swapchain_image_views.len) catch @panic("Out of memory");

    for (self.swapchain_image_views, self.framebuffers) |view, *framebuffer| {
        const attachements = [2]c.vk.ImageView{
            view,
            self.depth_image_view,
        };
        framebuffer_ci.pAttachments = &attachements[0];
        check_vk(c.vk.CreateFramebuffer(self.device, &framebuffer_ci, vk_alloc_cbs, framebuffer))
            catch @panic("Failed to create framebuffer");
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(framebuffer.*, c.vk.DestroyFramebuffer),
        ) catch @panic("Out of memory");
    }

    log.info("Created {} framebuffers", .{ self.framebuffers.len });
}

fn init_sync_structures(self: *Self) void {
    const semaphore_ci = std.mem.zeroInit(c.vk.SemaphoreCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    });

    const fence_ci = std.mem.zeroInit(c.vk.FenceCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.vk.FENCE_CREATE_SIGNALED_BIT,
    });

    for (&self.frames) |*frame| {
        check_vk(c.vk.CreateSemaphore(self.device, &semaphore_ci, vk_alloc_cbs, &frame.present_semaphore))
            catch @panic("Failed to create present semaphore");
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(frame.present_semaphore, c.vk.DestroySemaphore),
        ) catch @panic("Out of memory");
        check_vk(c.vk.CreateSemaphore(self.device, &semaphore_ci, vk_alloc_cbs, &frame.render_semaphore))
            catch @panic("Failed to create render semaphore");
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(frame.render_semaphore, c.vk.DestroySemaphore),
        ) catch @panic("Out of memory");

        check_vk(c.vk.CreateFence(self.device, &fence_ci, vk_alloc_cbs, &frame.render_fence))
            catch @panic("Failed to create render fence");
        self.deletion_queue.append(
            self.allocator,
            VulkanDeleter.make(frame.render_fence, c.vk.DestroyFence),
        ) catch @panic("Out of memory");
    }

    // Upload context
    const upload_fence_ci = std.mem.zeroInit(c.vk.FenceCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
    });

    check_vk(c.vk.CreateFence(self.device, &upload_fence_ci, vk_alloc_cbs, &self.upload_context.upload_fence))
        catch @panic("Failed to create upload fence");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.upload_context.upload_fence, c.vk.DestroyFence),
    ) catch @panic("Out of memory");

    log.info("Created sync structures", .{});
}

const PipelineBuilder = struct {
    shader_stages: []c.vk.PipelineShaderStageCreateInfo,
    vertex_input_state: c.vk.PipelineVertexInputStateCreateInfo,
    input_assembly_state: c.vk.PipelineInputAssemblyStateCreateInfo,
    viewport: c.vk.Viewport,
    scissor: c.vk.Rect2D,
    rasterization_state: c.vk.PipelineRasterizationStateCreateInfo,
    color_blend_attachment_state: c.vk.PipelineColorBlendAttachmentState,
    multisample_state: c.vk.PipelineMultisampleStateCreateInfo,
    pipeline_layout: c.vk.PipelineLayout,
    depth_stencil_state: c.vk.PipelineDepthStencilStateCreateInfo,

    fn build(self: PipelineBuilder, device: c.vk.Device, render_pass: c.vk.RenderPass) c.vk.Pipeline {
        const viewport_state = std.mem.zeroInit(c.vk.PipelineViewportStateCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &self.viewport,
            .scissorCount = 1,
            .pScissors = &self.scissor,
        });

        const color_blend_state = std.mem.zeroInit(c.vk.PipelineColorBlendStateCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = c.vk.FALSE,
            .logicOp = c.vk.LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &self.color_blend_attachment_state,
        });

        const pipeline_ci = std.mem.zeroInit(c.vk.GraphicsPipelineCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
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

        var pipeline: c.vk.Pipeline = undefined;
        check_vk(c.vk.CreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeline_ci, vk_alloc_cbs, &pipeline)) catch {
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
    defer c.vk.DestroyShaderModule(self.device, red_vert_module, vk_alloc_cbs);
    const red_frag_module = create_shader_module(self, &red_frag_code) orelse VK_NULL_HANDLE;
    defer c.vk.DestroyShaderModule(self.device, red_frag_module, vk_alloc_cbs);

    if (red_vert_module != VK_NULL_HANDLE) log.info("Vert module loaded successfully", .{});
    if (red_frag_module != VK_NULL_HANDLE) log.info("Frag module loaded successfully", .{});

    const pipeline_layout_ci = std.mem.zeroInit(c.vk.PipelineLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    });
    var triangle_pipeline_layout: c.vk.PipelineLayout = undefined;
    check_vk(c.vk.CreatePipelineLayout(self.device, &pipeline_layout_ci, vk_alloc_cbs, &triangle_pipeline_layout))
        catch @panic("Failed to create pipeline layout");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(triangle_pipeline_layout, c.vk.DestroyPipelineLayout),
    ) catch @panic("Out of memory");

    const vert_stage_ci = std.mem.zeroInit(c.vk.PipelineShaderStageCreateInfo, .{
        .sType  = c.vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage  = c.vk.SHADER_STAGE_VERTEX_BIT,
        .module = red_vert_module,
        .pName  = "main",
    });

    const frag_stage_ci = std.mem.zeroInit(c.vk.PipelineShaderStageCreateInfo, .{
        .sType  = c.vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage  = c.vk.SHADER_STAGE_FRAGMENT_BIT,
        .module = red_frag_module,
        .pName  = "main",
    });

    const vertex_input_state_ci = std.mem.zeroInit(c.vk.PipelineVertexInputStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    });

    const input_assembly_state_ci = std.mem.zeroInit(c.vk.PipelineInputAssemblyStateCreateInfo, .{
        .sType                  = c.vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology               = c.vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = c.vk.FALSE,
    });

    const rasterization_state_ci = std.mem.zeroInit(c.vk.PipelineRasterizationStateCreateInfo, .{
        .sType       = c.vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.vk.POLYGON_MODE_FILL,
        .cullMode    = c.vk.CULL_MODE_NONE,
        .frontFace   = c.vk.FRONT_FACE_CLOCKWISE,
        .lineWidth   = 1.0,
    });

    const multisample_state_ci = std.mem.zeroInit(c.vk.PipelineMultisampleStateCreateInfo, .{
        .sType                = c.vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = c.vk.SAMPLE_COUNT_1_BIT,
        .minSampleShading     = 1.0,
    });

    const depth_stencil_state_ci = std.mem.zeroInit(c.vk.PipelineDepthStencilStateCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = c.vk.TRUE,
        .depthWriteEnable = c.vk.TRUE,
        .depthCompareOp = c.vk.COMPARE_OP_LESS_OR_EQUAL,
        .depthBoundsTestEnable = c.vk.FALSE,
        .stencilTestEnable = c.vk.FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
    });

    const color_blend_attachment_state = std.mem.zeroInit(c.vk.PipelineColorBlendAttachmentState, .{
        .colorWriteMask = c.vk.COLOR_COMPONENT_R_BIT | c.vk.COLOR_COMPONENT_G_BIT | c.vk.COLOR_COMPONENT_B_BIT | c.vk.COLOR_COMPONENT_A_BIT,
    });

    var shader_stages = [_]c.vk.PipelineShaderStageCreateInfo{
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
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(red_triangle_pipeline, c.vk.DestroyPipeline),
    ) catch @panic("Out of memory");
    if (red_triangle_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create red triangle pipeline", .{});
    } else {
        log.info("Created red triangle pipeline", .{});
    }

    _ = self.create_material(red_triangle_pipeline, triangle_pipeline_layout, "red_triangle_mat");


    const rgb_vert_code align(4) = @embedFile("colored_triangle.vert").*;
    const rgb_frag_code align(4) = @embedFile("colored_triangle.frag").*;
    const rgb_vert_module = create_shader_module(self, &rgb_vert_code) orelse VK_NULL_HANDLE;
    defer c.vk.DestroyShaderModule(self.device, rgb_vert_module, vk_alloc_cbs);
    const rgb_frag_module = create_shader_module(self, &rgb_frag_code) orelse VK_NULL_HANDLE;
    defer c.vk.DestroyShaderModule(self.device, rgb_frag_module, vk_alloc_cbs);

    if (rgb_vert_module != VK_NULL_HANDLE) log.info("Vert module loaded successfully", .{});
    if (rgb_frag_module != VK_NULL_HANDLE) log.info("Frag module loaded successfully", .{});

    pipeline_builder.shader_stages[0].module = rgb_vert_module;
    pipeline_builder.shader_stages[1].module = rgb_frag_module;

    const rgb_triangle_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(rgb_triangle_pipeline, c.vk.DestroyPipeline),
    ) catch @panic("Out of memory");
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
    defer c.vk.DestroyShaderModule(self.device, tri_mesh_vert_module, vk_alloc_cbs);

    if (tri_mesh_vert_module != VK_NULL_HANDLE) log.info("Tri-mesh vert module loaded successfully", .{});

    // Default lit shader
    const default_lit_frag_code align(4) = @embedFile("default_lit.frag").*;
    const default_lit_frag_module = create_shader_module(self, &default_lit_frag_code) orelse VK_NULL_HANDLE;
    defer c.vk.DestroyShaderModule(self.device, default_lit_frag_module, vk_alloc_cbs);

    if (default_lit_frag_module != VK_NULL_HANDLE) log.info("Default lit frag module loaded successfully", .{});

    pipeline_builder.shader_stages[0].module = tri_mesh_vert_module;
    pipeline_builder.shader_stages[1].module = default_lit_frag_module;

    // New layout for push constants
    const push_constant_range = std.mem.zeroInit(c.vk.PushConstantRange, .{
        .stageFlags = c.vk.SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = @sizeOf(MeshPushConstants),
    });

    const set_layouts = [_]c.vk.DescriptorSetLayout{
        self.global_set_layout,
        self.object_set_layout,
    };

    const mesh_pipeline_layout_ci = std.mem.zeroInit(c.vk.PipelineLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = @as(u32, @intCast(set_layouts.len)),
        .pSetLayouts = &set_layouts[0],
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_constant_range,
    });

    var mesh_pipeline_layout: c.vk.PipelineLayout = undefined;
    check_vk(c.vk.CreatePipelineLayout(self.device, &mesh_pipeline_layout_ci, vk_alloc_cbs, &mesh_pipeline_layout))
        catch @panic("Failed to create mesh pipeline layout");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(mesh_pipeline_layout, c.vk.DestroyPipelineLayout),
    ) catch @panic("Out of memory");

    pipeline_builder.pipeline_layout = mesh_pipeline_layout;

    const mesh_pipeline = pipeline_builder.build(self.device, self.render_pass);
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(mesh_pipeline, c.vk.DestroyPipeline),
    ) catch @panic("Out of memory");
    if (mesh_pipeline == VK_NULL_HANDLE) {
        log.err("Failed to create mesh pipeline", .{});
    } else {
        log.info("Created mesh pipeline", .{});
    }

    _ = self.create_material(mesh_pipeline, mesh_pipeline_layout, "default_mesh");

    // Textured mesh shader
    var textured_pipe_layout_ci = mesh_pipeline_layout_ci;
    const textured_set_layoyts = [_]c.vk.DescriptorSetLayout{
        self.global_set_layout,
        self.object_set_layout,
        self.single_texture_set_layout,
    };
    textured_pipe_layout_ci.setLayoutCount = @as(u32, @intCast(textured_set_layoyts.len));
    textured_pipe_layout_ci.pSetLayouts = &textured_set_layoyts[0];

    var textured_pipe_layout: c.vk.PipelineLayout = undefined;
    check_vk(c.vk.CreatePipelineLayout(self.device, &textured_pipe_layout_ci, vk_alloc_cbs, &textured_pipe_layout))
        catch @panic("Failed to create textured mesh pipeline layout");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(textured_pipe_layout, c.vk.DestroyPipelineLayout),
    ) catch @panic("Out of memory");

    const textured_lit_frag_code align(4) = @embedFile("textured_lit.frag").*;
    const textured_lit_frag = create_shader_module(self, &textured_lit_frag_code) orelse VK_NULL_HANDLE;
    defer c.vk.DestroyShaderModule(self.device, textured_lit_frag, vk_alloc_cbs);

    pipeline_builder.shader_stages[1].module = textured_lit_frag;
    pipeline_builder.pipeline_layout = textured_pipe_layout;
    const textured_mesh_pipeline = pipeline_builder.build(self.device, self.render_pass);

    _ = self.create_material(textured_mesh_pipeline, textured_pipe_layout, "textured_mesh");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(textured_mesh_pipeline, c.vk.DestroyPipeline),
    ) catch @panic("Out of memory");
}

fn init_descriptors(self: *Self) void {
    // Descriptor pool
    const pool_sizes = [_]c.vk.DescriptorPoolSize{
        .{ .type = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 10, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .descriptorCount = 10, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 10, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 10, },
    };

    const pool_ci = std.mem.zeroInit(c.vk.DescriptorPoolCreateInfo, .{
        .sType         = c.vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags         = 0,
        .maxSets       = 10,
        .poolSizeCount = @as(u32, @intCast(pool_sizes.len)),
        .pPoolSizes    = &pool_sizes[0],
    });

    check_vk(c.vk.CreateDescriptorPool(self.device, &pool_ci, vk_alloc_cbs, &self.descriptor_pool))
        catch @panic("Failed to create descriptor pool");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.descriptor_pool, c.vk.DestroyDescriptorPool),
    ) catch @panic("Out of memory");

    // =========================================================================
    // Information about the binding
    // =========================================================================

    // =================================
    // Global set layout
    //

    // Camera binding
    const camera_buffer_binding = std.mem.zeroInit(c.vk.DescriptorSetLayoutBinding, .{
        .binding         = 0,
        .descriptorType  = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .descriptorCount = 1,
        .stageFlags      = c.vk.SHADER_STAGE_VERTEX_BIT,
    });

    // Scene param binding
    const scene_parameters_binding = std.mem.zeroInit(c.vk.DescriptorSetLayoutBinding, .{
        .binding         = 1,
        .descriptorType  = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .descriptorCount = 1,
        .stageFlags      = c.vk.SHADER_STAGE_VERTEX_BIT | c.vk.SHADER_STAGE_FRAGMENT_BIT,
    });

    const bindings = [_]c.vk.DescriptorSetLayoutBinding{
        camera_buffer_binding,
        scene_parameters_binding,
    };

    const global_set_ci = std.mem.zeroInit(c.vk.DescriptorSetLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = @as(u32, @intCast(bindings.len)),
        .pBindings = &bindings[0],
    });

    check_vk(c.vk.CreateDescriptorSetLayout(self.device, &global_set_ci, vk_alloc_cbs, &self.global_set_layout))
        catch @panic("Failed to create global descriptor set layout");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.global_set_layout, c.vk.DestroyDescriptorSetLayout),
    ) catch @panic("Out of memory");

    log.info("Created global set layout", .{});

    // =================================
    // Object set layout
    //

    // Object buffer binding
    const object_buffer_binding = std.mem.zeroInit(c.vk.DescriptorSetLayoutBinding, .{
        .binding         = 0,
        .descriptorType  = c.vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags      = c.vk.SHADER_STAGE_VERTEX_BIT,
    });

    const object_set_ci = std.mem.zeroInit(c.vk.DescriptorSetLayoutCreateInfo, .{
        .sType        = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings    = &object_buffer_binding,
    });

    check_vk(c.vk.CreateDescriptorSetLayout(self.device, &object_set_ci, vk_alloc_cbs, &self.object_set_layout))
        catch @panic("Failed to create object descriptor set layout");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.object_set_layout, c.vk.DestroyDescriptorSetLayout),
    ) catch @panic("Out of memory");

    log.info("Created object set layout", .{});

    // Scene and camera (per-frame) in a single buffer
    // Only one buffer and we get multiple offset of of it
    const camera_and_scene_buffer_size =
        FRAME_OVERLAP * self.pad_uniform_buffer_size(@sizeOf(GPUCameraData)) +
        FRAME_OVERLAP * self.pad_uniform_buffer_size(@sizeOf(GPUSceneData));

    self.camera_and_scene_buffer = self.create_buffer(
        camera_and_scene_buffer_size,
        c.vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        c.vma.MEMORY_USAGE_CPU_TO_GPU);
    self.buffer_deletion_queue.append(
        self.allocator,
        VmaBufferDeleter{ .buffer = self.camera_and_scene_buffer },
    ) catch @panic("Out of memory");

    // Camera and scene descriptor set
    const global_set_alloc_info = std.mem.zeroInit(c.vk.DescriptorSetAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.global_set_layout,
    });

    // Allocate a single set for multiple frame worth of camera and scene data
    check_vk(c.vk.AllocateDescriptorSets(self.device, &global_set_alloc_info, &self.camera_and_scene_set))
        catch @panic("Failed to allocate global descriptor set");

    // Camera
    const camera_buffer_info = std.mem.zeroInit(c.vk.DescriptorBufferInfo, .{
        .buffer = self.camera_and_scene_buffer.buffer,
        .range = @sizeOf(GPUCameraData),
    });

    const camera_write = std.mem.zeroInit(c.vk.WriteDescriptorSet, .{
        .sType = c.vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self.camera_and_scene_set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .pBufferInfo = &camera_buffer_info,
    });

    // Scene parameters
    const scene_parameters_buffer_info = std.mem.zeroInit(c.vk.DescriptorBufferInfo, .{
        .buffer = self.camera_and_scene_buffer.buffer,
        .range = @sizeOf(GPUSceneData),
    });

    const scene_parameters_write = std.mem.zeroInit(c.vk.WriteDescriptorSet, .{
        .sType = c.vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = self.camera_and_scene_set,
        .dstBinding = 1,
        .descriptorCount = 1,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
        .pBufferInfo = &scene_parameters_buffer_info,
    });

    const camera_and_scene_writes = [_]c.vk.WriteDescriptorSet {
        camera_write,
        scene_parameters_write,
    };

    c.vk.UpdateDescriptorSets(
        self.device, @as(u32, @intCast(camera_and_scene_writes.len)), &camera_and_scene_writes[0], 0, null);

    // =================================
    // Texture set layout
    //
    const texture_bind = std.mem.zeroInit(c.vk.DescriptorSetLayoutBinding, .{
        .binding = 0,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = c.vk.SHADER_STAGE_FRAGMENT_BIT,
    });

    const texture_set_ci = std.mem.zeroInit(c.vk.DescriptorSetLayoutCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &texture_bind,
    });

    check_vk(c.vk.CreateDescriptorSetLayout(self.device, &texture_set_ci, vk_alloc_cbs, &self.single_texture_set_layout))
        catch @panic("Failed to create texture descriptor set layout");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.single_texture_set_layout, c.vk.DestroyDescriptorSetLayout),
    ) catch @panic("Out of memory");

    for (0..FRAME_OVERLAP) |i| {
        // ======================================================================
        // Allocate descriptor sets
        // ======================================================================

        // Object descriptor set
        const object_set_alloc_info = std.mem.zeroInit(c.vk.DescriptorSetAllocateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.object_set_layout,
        });

        check_vk(c.vk.AllocateDescriptorSets(self.device, &object_set_alloc_info, &self.frames[i].object_descriptor_set))
            catch @panic("Failed to allocate object descriptor set");

        // ======================================================================
        // Buffer allocations
        // ======================================================================

        // Object buffer
        const MAX_OBJECTS = 10000;
        self.frames[i].object_buffer = self.create_buffer(
            MAX_OBJECTS * @sizeOf(GPUObjectData),
            c.vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.vma.MEMORY_USAGE_CPU_TO_GPU);
        self.buffer_deletion_queue.append(
            self.allocator,
            VmaBufferDeleter{ .buffer = self.frames[i].object_buffer },
        ) catch @panic("Out of memory");

        // ======================================================================
        // Write descriptors
        // ======================================================================

        // =============================
        // Object descriptor set
        //
        const object_buffer_info = std.mem.zeroInit(c.vk.DescriptorBufferInfo, .{
            .buffer = self.frames[i].object_buffer.buffer,
            .offset = 0,
            .range = MAX_OBJECTS * @sizeOf(GPUObjectData),
        });

        const object_buffer_write = std.mem.zeroInit(c.vk.WriteDescriptorSet, .{
            .sType = c.vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self.frames[i].object_descriptor_set,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = c.vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &object_buffer_info,
        });

        const writes = [_]c.vk.WriteDescriptorSet{
            object_buffer_write,
        };

        c.vk.UpdateDescriptorSets(self.device, @as(u32, @intCast(writes.len)), &writes[0], 0, null);
    }
}

fn create_shader_module(self: *Self, code: []const u8) ?c.vk.ShaderModule {
    // NOTE: This being a better language than C/C++, means we don´t need to load
    // the SPIR-V code from a file, we can just embed it as an array of bytes.
    // To reflect the different behaviour from the original code, we also changed
    // the function name.
    std.debug.assert(code.len % 4 == 0);

    const data: *const u32 = @alignCast(@ptrCast(code.ptr));

    const shader_module_ci = std.mem.zeroInit(c.vk.ShaderModuleCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = data,
    });

    var shader_module: c.vk.ShaderModule = undefined;
    check_vk(c.vk.CreateShaderModule(self.device, &shader_module_ci, vk_alloc_cbs, &shader_module)) catch |err| {
        log.err("Failed to create shader module with error: {s}", .{ @errorName(err) });
        return null;
    };

    return shader_module;
}

fn init_scene(self: *Self) void {
    const monkey = RenderObject {
        .mesh = self.meshes.getPtr("monkey") orelse @panic("Failed to get monkey mesh"),
        .material = self.materials.getPtr("default_mesh") orelse @panic("Failed to get default mesh material"),
        .transform = Mat4.IDENTITY,
    };
    self.renderables.append(self.allocator, monkey) catch @panic("Out of memory");

    // const diorama = RenderObject {
    //     .mesh = self.meshes.getPtr("diorama") orelse @panic("Failed to get diorama mesh"),
    //     .material = self.materials.getPtr("default_mesh") orelse @panic("Failed to get default mesh material"),
    //     .transform = Mat4.mul(
    //         Mat4.mul(
    //             m3d.translation(m3d.vec3(3.0, 1, 0)),
    //             m3d.rotation(m3d.vec3(0, 1, 0), std.math.degreesToRadians(f32, -60)),
    //         ),
    //         m3d.scale(m3d.vec3(2.0, 2.0, 2.0))
    //     ),
    // };
    // self.renderables.append(diorama) catch @panic("Out of memory");
    //
    // const body = RenderObject {
    //     .mesh = self.meshes.getPtr("body") orelse @panic("Failed to get body mesh"),
    //     .material = self.materials.getPtr("default_mesh") orelse @panic("Failed to get default mesh material"),
    //     .transform = Mat4.mul(
    //         Mat4.mul(
    //             m3d.translation(m3d.vec3(-3.0, -0.5, 0)),
    //             m3d.rotation(m3d.vec3(0, 1, 0), std.math.degreesToRadians(f32, 45)),
    //         ),
    //         m3d.scale(m3d.vec3(2.0, 2.0, 2.0))
    //     ),
    // };
    // self.renderables.append(body) catch @panic("Out of memory");

    var material = self.materials.getPtr("textured_mesh") orelse @panic("Failed to get default mesh material");

    // Allocate descriptor set for signle-texture to use on the material
    const descriptor_set_alloc_info = std.mem.zeroInit(c.vk.DescriptorSetAllocateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.single_texture_set_layout,
    });

    check_vk(c.vk.AllocateDescriptorSets(self.device, &descriptor_set_alloc_info, &material.texture_set))
        catch @panic("Failed to allocate descriptor set");

    // Sampler
    const sampler_ci = std.mem.zeroInit(c.vk.SamplerCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.vk.FILTER_NEAREST,
        .minFilter = c.vk.FILTER_NEAREST,
        .addressModeU = c.vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = c.vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = c.vk.SAMPLER_ADDRESS_MODE_REPEAT,
    });

    var sampler: c.vk.Sampler = undefined;
    check_vk(c.vk.CreateSampler(self.device, &sampler_ci, vk_alloc_cbs, &sampler))
        catch @panic("Failed to create sampler");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(sampler, c.vk.DestroySampler),
    ) catch @panic("Out of memory");

    const lost_empire_tex = (self.textures.get("empire_diffuse") orelse @panic("Failed to get empire texture"));

    const descriptor_image_info = std.mem.zeroInit(c.vk.DescriptorImageInfo, .{
        .sampler = sampler,
        .imageView = lost_empire_tex.image_view,
        .imageLayout = c.vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    });

    const write_descriptor_set = std.mem.zeroInit(c.vk.WriteDescriptorSet, .{
        .sType = c.vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = material.texture_set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = c.vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &descriptor_image_info,
    });

    c.vk.UpdateDescriptorSets(self.device, 1, &write_descriptor_set, 0, null);

    const lost_empire = RenderObject {
        .mesh = self.meshes.getPtr("lost_empire") orelse @panic("Failed to get triangle mesh"),
        .transform = Mat4.translation(Vec3.make(5.0, -10.0, 0.0)),
        .material = material,
    };
    self.renderables.append(self.allocator, lost_empire) catch @panic("Out of memory");

    var x: i32 = -20;
    while (x <= 20) : (x += 1) {
        var y: i32 = -20;
        while (y <= 20) : (y += 1) {
            const translation = Mat4.translation(Vec3.make(@floatFromInt(x), 0.0, @floatFromInt(y)));
            const scale = Mat4.scale(Vec3.make(0.2, 0.2, 0.2));
            const transform = Mat4.mul(translation, scale);

            const tri = RenderObject {
                .mesh = self.meshes.getPtr("triangle") orelse @panic("Failed to get triangle mesh"),
                .material = self.materials.getPtr("default_mesh") orelse @panic("Failed to get default mesh material"),
                .transform = transform,
            };

            self.renderables.append(self.allocator, tri) catch @panic("Out of memory");
        }
    }
}

fn init_imgui(self: *Self) void {
    const pool_sizes = [_]c.vk.DescriptorPoolSize{
        .{ .type = c.vk.DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, .descriptorCount = 1000, },
        .{ .type = c.vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT, .descriptorCount = 1000, },
    };

    const pool_ci = std.mem.zeroInit(c.vk.DescriptorPoolCreateInfo, .{
        .sType         = c.vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags         = c.vk.DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets       = 1000,
        .poolSizeCount = @as(u32, @intCast(pool_sizes.len)),
        .pPoolSizes    = &pool_sizes[0],
    });

    var imgui_pool: c.vk.DescriptorPool = undefined;
    check_vk(c.vk.CreateDescriptorPool(self.device, &pool_ci, vk_alloc_cbs, &imgui_pool))
        catch @panic("Failed to create imgui descriptor pool");

    _ = c.cimgui.CreateContext(null);
    _ = c.cimgui.impl_sdl3.InitForVulkan(self.window);

    var init_info = std.mem.zeroInit(c.cimgui.impl_vulkan.InitInfo, .{
        .Instance = self.instance,
        .PhysicalDevice = self.physical_device,
        .Device = self.device,
        .QueueFamily = self.graphics_queue_family,
        .Queue = self.graphics_queue,
        .DescriptorPool = imgui_pool,
        .MinImageCount = FRAME_OVERLAP,
        .ImageCount = FRAME_OVERLAP,
        .MSAASamples = c.vk.SAMPLE_COUNT_1_BIT,
    });

    _ = c.cimgui.impl_vulkan.Init(&init_info, self.render_pass);
    _ = c.cimgui.impl_vulkan.CreateFontsTexture();

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(imgui_pool, c.vk.DestroyDescriptorPool),
    ) catch @panic("Out of memory");
}

pub fn cleanup(self: *Self) void {
    check_vk(c.vk.DeviceWaitIdle(self.device))
        catch @panic("Failed to wait for device idle");

    // TODO: this is a horrible way to keep track of the meshes to free. Quick and dirty hack.
    var mesh_it = self.meshes.iterator();
    while (mesh_it.next()) |entry| {
        self.allocator.free(entry.value_ptr.vertices);
    }

    self.textures.deinit();
    self.meshes.deinit();
    self.materials.deinit();
    self.renderables.deinit(self.allocator);

    c.cimgui.impl_vulkan.Shutdown();

    for (self.buffer_deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.buffer_deletion_queue.deinit(self.allocator);

    for (self.image_deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.image_deletion_queue.deinit(self.allocator);

    for (self.deletion_queue.items) |*entry| {
        entry.delete(self);
    }
    self.deletion_queue.deinit(self.allocator);


    self.allocator.free(self.framebuffers);
    self.allocator.free(self.swapchain_image_views);
    self.allocator.free(self.swapchain_images);

    c.vma.DestroyAllocator(self.vma_allocator);

    c.vk.DestroyDevice(self.device, vk_alloc_cbs);
    c.vk.DestroySurfaceKHR(self.instance, self.surface, vk_alloc_cbs);

    if (self.debug_messenger != VK_NULL_HANDLE) {
        const destroy_fn = vki.get_destroy_debug_utils_messenger_fn(self.instance).?;
        destroy_fn(self.instance, self.debug_messenger, vk_alloc_cbs);
    }

    c.vk.DestroyInstance(self.instance, vk_alloc_cbs);
    c.SDL.DestroyWindow(self.window);
}

fn load_textures(self: *Self) void {
    const lost_empire_image = texs.load_image_from_file(self, "assets/lost_empire-RGBA.png") catch @panic("Failed to load image");
    self.image_deletion_queue.append(
        self.allocator,
        VmaImageDeleter{ .image = lost_empire_image },
    ) catch @panic("Out of memory");
    const image_view_ci = std.mem.zeroInit(c.vk.ImageViewCreateInfo, .{
        .sType    = c.vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .viewType = c.vk.IMAGE_VIEW_TYPE_2D,
        .image    = lost_empire_image.image,
        .format   = c.vk.FORMAT_R8G8B8A8_SRGB,
        .components = .{
            .r = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .g = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .b = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .a = c.vk.COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask     = c.vk.IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel   = 0,
            .levelCount     = 1,
            .baseArrayLayer = 0,
            .layerCount     = 1,
        },
    });

    var lost_empire = Texture{
        .image      = lost_empire_image,
        .image_view = null,
    };

    check_vk(c.vk.CreateImageView(self.device, &image_view_ci, vk_alloc_cbs, &lost_empire.image_view))
        catch @panic("Failed to create image view");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(lost_empire.image_view, c.vk.DestroyImageView),
    ) catch @panic("Out of memory");

    self.textures.put("empire_diffuse", lost_empire) catch @panic("Out of memory");
}

fn load_meshes(self: *Self) void {
    const vertices = [_]mesh_mod.Vertex{
        .{
            .position = Vec3.make(1.0, 1.0, 0.0),
            .normal = undefined,
            .color = Vec3.make(0.0, 1.0, 0.0),
            .uv = Vec2.make(1.0, 1.0),
        },
        .{
            .position = Vec3.make(-1.0, 1.0, 0.0),
            .normal = undefined,
            .color = Vec3.make(0.0, 1.0, 0.0),
            .uv = Vec2.make(0.0, 1.0),
        },
        .{
            .position = Vec3.make(0.0, -1.0, 0.0),
            .normal = undefined,
            .color = Vec3.make(0.0, 1.0, 0.0),
            .uv = Vec2.make(0.5, 0.0),
        }
    };

    var triangle_mesh = Mesh{
        .vertices = self.allocator.dupe(mesh_mod.Vertex, vertices[0..]) catch @panic("Out of memory"),
    };
    self.upload_mesh(&triangle_mesh);
    self.meshes.put("triangle", triangle_mesh) catch @panic("Out of memory");

    var monkey_mesh = mesh_mod.load_from_obj(self.allocator, "assets/suzanne.obj");
    self.upload_mesh(&monkey_mesh);
    self.meshes.put("monkey", monkey_mesh) catch @panic("Out of memory");

    //var cube_diorama = mesh_mod.load_from_obj(self.allocator, "assets/cube_diorama.obj");
    //self.upload_mesh(&cube_diorama);
    //self.meshes.put("diorama", cube_diorama) catch @panic("Out of memory");

    //var body = mesh_mod.load_from_obj(self.allocator, "assets/body_male_realistic.obj");
    //self.upload_mesh(&body);
    //self.meshes.put("body", body) catch @panic("Out of memory");

    var lost_empire = mesh_mod.load_from_obj(self.allocator, "assets/lost_empire.obj");
    self.upload_mesh(&lost_empire);
    self.meshes.put("lost_empire", lost_empire) catch @panic("Out of memory");
}

fn upload_mesh(self: *Self, mesh: *Mesh) void {
    // Create a cpu buffer for staging
    const staging_buffer_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = mesh.vertices.len * @sizeOf(mesh_mod.Vertex),
        .usage = c.vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
    });

    const staging_buffer_ai = std.mem.zeroInit(c.vma.AllocationCreateInfo, .{
        .usage = c.vma.MEMORY_USAGE_CPU_ONLY,
    });

    var staging_buffer: AllocatedBuffer = undefined;
    check_vk(c.vma.CreateBuffer(
        self.vma_allocator,
        &staging_buffer_ci,
        &staging_buffer_ai,
        &staging_buffer.buffer,
        &staging_buffer.allocation,
        null)) catch @panic("Failed to create vertex buffer");

    log.info("Created staging buffer {}", .{ @intFromPtr(mesh.vertex_buffer.buffer) });

    var data: ?*anyopaque = undefined;
    check_vk(c.vma.MapMemory(self.vma_allocator, staging_buffer.allocation, &data))
        catch @panic("Failed to map vertex buffer");
    const aligned_data: [*]mesh_mod.Vertex = @ptrCast(@alignCast(data));
    @memcpy(aligned_data, mesh.vertices);
    c.vma.UnmapMemory(self.vma_allocator, staging_buffer.allocation);

    log.info("Copied mesh data into staging buffer", .{});

    const gpu_buffer_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = mesh.vertices.len * @sizeOf(mesh_mod.Vertex),
        .usage = c.vk.BUFFER_USAGE_VERTEX_BUFFER_BIT | c.vk.BUFFER_USAGE_TRANSFER_DST_BIT,
    });

    const gpu_buffer_ai = std.mem.zeroInit(c.vma.AllocationCreateInfo, .{
        .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
    });

    check_vk(c.vma.CreateBuffer(
        self.vma_allocator,
        &gpu_buffer_ci,
        &gpu_buffer_ai,
        &mesh.vertex_buffer.buffer,
        &mesh.vertex_buffer.allocation,
        null)) catch @panic("Failed to create vertex buffer");

    log.info("Created GPU buffer for mesh", .{});

    self.buffer_deletion_queue.append(
        self.allocator,
        VmaBufferDeleter{ .buffer = mesh.vertex_buffer },
    ) catch @panic("Out of memory");

    // Now we can copy immediate the content of the staging buffer to the gpu
    // only memory.
    self.immediate_submit(struct {
        mesh_buffer: c.vk.Buffer,
        staging_buffer: c.vk.Buffer,
        size: usize,

        fn submit(ctx: @This(), cmd: c.vk.CommandBuffer) void {
            const copy_region = std.mem.zeroInit(c.vk.BufferCopy, .{
                .size = ctx.size,
            });
            c.vk.CmdCopyBuffer(cmd, ctx.staging_buffer, ctx.mesh_buffer, 1, &copy_region);
        }
    }{
        .mesh_buffer = mesh.vertex_buffer.buffer,
        .staging_buffer = staging_buffer.buffer,
        .size = mesh.vertices.len * @sizeOf(mesh_mod.Vertex),
    });

    // We can free the staging buffer at this point.
    c.vma.DestroyBuffer(self.vma_allocator, staging_buffer.buffer, staging_buffer.allocation); 
}

pub fn run(self: *Self) void {
    var timer = std.time.Timer.start() catch @panic("Failed to start timer");
    var delta: f32 = 0.016;

    var quit = false;
    var event: c.SDL.Event = undefined;
    while (!quit) {
        while (c.SDL.PollEvent(&event) != 0) {
            if (event.type == c.SDL.EVENT_QUIT) {
                quit = true;
            } else if (c.cimgui.impl_sdl3.ProcessEvent(&event)) {
                // Nothing to do here
            } else if (event.type == c.SDL.EVENT_KEY_DOWN) {
                switch (event.key.keysym.scancode) {
                    c.SDL.SCANCODE_SPACE => {
                        self.selected_shader = if (self.selected_shader == 1) 0 else 1;
                    },
                    c.SDL.SCANCODE_M => {
                        self.selected_mesh = if (self.selected_mesh == 1) 0 else 1;
                    },

                    // WASD for camera
                    c.SDL.SCANCODE_W => {
                        self.camera_input.z = 1.0;
                    },
                    c.SDL.SCANCODE_S => {
                        self.camera_input.z = -1.0;
                    },
                    c.SDL.SCANCODE_A => {
                        self.camera_input.x = 1.0;
                    },
                    c.SDL.SCANCODE_D => {
                        self.camera_input.x = -1.0;
                    },
                    c.SDL.SCANCODE_E => {
                        self.camera_input.y = 1.0;
                    },
                    c.SDL.SCANCODE_Q => {
                        self.camera_input.y = -1.0;
                    },

                    else => {},
                }
            } else if (event.type == c.SDL.EVENT_KEY_UP) {
                switch (event.key.keysym.scancode) {
                    c.SDL.SCANCODE_W => {
                        self.camera_input.z = 0.0;
                    },
                    c.SDL.SCANCODE_S => {
                        self.camera_input.z = 0.0;
                    },
                    c.SDL.SCANCODE_A => {
                        self.camera_input.x = 0.0;
                    },
                    c.SDL.SCANCODE_D => {
                        self.camera_input.x = 0.0;
                    },
                    c.SDL.SCANCODE_E => {
                        self.camera_input.y = 0.0;
                    },
                    c.SDL.SCANCODE_Q => {
                        self.camera_input.y = 0.0;
                    },

                    else => {},
                }
            }

        }

        if (self.camera_input.squared_norm() > (0.1 * 0.1)) {
            const camera_delta = self.camera_input.normalized().mul(delta * 5.0);
            self.camera_pos = Vec3.add(self.camera_pos, camera_delta);
        }

        {
            var open = true;
            // Imgui frame
            c.cimgui.impl_vulkan.NewFrame();
            c.cimgui.impl_sdl3.NewFrame();
            c.cimgui.NewFrame();
            c.cimgui.ShowDemoWindow(&open);

            c.cimgui.Render();
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
            const new_title = std.fmt.allocPrintSentinel(
                self.allocator, "Vulkan - FPS: {d:6.3}, ms: {d:6.3}", .{ fps, delta * 1000.0 }, 0
            ) catch @panic("Out of memory");
            defer self.allocator.free(new_title);
            _ = c.SDL.SetWindowTitle(self.window, new_title.ptr);
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

    check_vk(c.vk.WaitForFences(self.device, 1, &frame.render_fence, c.vk.TRUE, timeout))
        catch @panic("Failed to wait for render fence");
    check_vk(c.vk.ResetFences(self.device, 1, &frame.render_fence))
        catch @panic("Failed to reset render fence");

    var swapchain_image_index: u32 = undefined;
    check_vk(c.vk.AcquireNextImageKHR(self.device, self.swapchain, timeout, frame.present_semaphore, VK_NULL_HANDLE, &swapchain_image_index))
        catch @panic("Failed to acquire swapchain image");

    var cmd = frame.main_command_buffer;

    check_vk(c.vk.ResetCommandBuffer(cmd, 0))
        catch @panic("Failed to reset command buffer");

    const cmd_begin_info = std.mem.zeroInit(c.vk.CommandBufferBeginInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });

    check_vk(c.vk.BeginCommandBuffer(cmd, &cmd_begin_info))
        catch @panic("Failed to begin command buffer");

    // Make a claer color that changes with each frame (120*pi frame period)
    // 0.11 and 0.12 fix for change in fabs
    const color = math3d.abs(std.math.sin(@as(f32, @floatFromInt(self.frame_number)) / 120.0));

    const color_clear: c.vk.ClearValue = .{
        .color = .{ .float32 = [_]f32{ 0.0, 0.0, color, 1.0 } },
    };

    const depth_clear = c.vk.ClearValue{
        .depthStencil = .{
            .depth = 1.0,
            .stencil = 0,
        },
    };

    const clear_values = [_]c.vk.ClearValue{
        color_clear,
        depth_clear,
    };

    const render_pass_begin_info = std.mem.zeroInit(c.vk.RenderPassBeginInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = self.render_pass,
        .framebuffer = self.framebuffers[swapchain_image_index],
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        },
        .clearValueCount = @as(u32, @intCast(clear_values.len)),
        .pClearValues = &clear_values[0],
    });
    c.vk.CmdBeginRenderPass(cmd, &render_pass_begin_info, c.vk.SUBPASS_CONTENTS_INLINE);

    // Objects
    self.draw_objects(cmd, self.renderables.items);

    // UI
    c.cimgui.impl_vulkan.RenderDrawData(c.cimgui.GetDrawData(), cmd);


    c.vk.CmdEndRenderPass(cmd);
    check_vk(c.vk.EndCommandBuffer(cmd))
        catch @panic("Failed to end command buffer");

    const wait_stage = @as(u32, @intCast(c.vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT));
    const submit_info = std.mem.zeroInit(c.vk.SubmitInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &frame.present_semaphore,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &frame.render_semaphore,
    });
    check_vk(c.vk.QueueSubmit(self.graphics_queue, 1, &submit_info, frame.render_fence))
        catch @panic("Failed to submit to graphics queue");

    const present_info = std.mem.zeroInit(c.vk.PresentInfoKHR, .{
        .sType = c.vk.STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &frame.render_semaphore,
        .swapchainCount = 1,
        .pSwapchains = &self.swapchain,
        .pImageIndices = &swapchain_image_index,
    });
    check_vk(c.vk.QueuePresentKHR(self.present_queue, &present_info))
        catch @panic("Failed to present swapchain image");

    self.frame_number +%= 1;
}

fn draw_objects(self: *Self, cmd: c.vk.CommandBuffer, objects: []RenderObject) void {
    const view = Mat4.translation(self.camera_pos);
    const aspect = @as(f32, @floatFromInt(self.swapchain_extent.width)) / @as(f32, @floatFromInt(self.swapchain_extent.height));
    var proj = Mat4.perspective(std.math.degreesToRadians(70.0), aspect, 0.1, 200.0);

    proj.j.y *= -1.0;

    // Create and bind the camera buffer
    const curr_camera_data = GPUCameraData{
        .view = view,
        .proj = proj,
        .view_proj = proj.mul(view),
    };

    const frame_index: usize = @intCast(@mod(self.frame_number, FRAME_OVERLAP));

    // TODO: meta function that deals with alignment and copying of data with
    // map/unmap. We now have two versions, one for a single pointer to struct
    // and one for array/slices (used to copy mesh vertices).
    const padded_camera_data_size = self.pad_uniform_buffer_size(@sizeOf(GPUCameraData));
    const scene_data_base_offset = padded_camera_data_size * FRAME_OVERLAP;
    const padded_scene_data_size = self.pad_uniform_buffer_size(@sizeOf(GPUSceneData));

    const camera_data_offset = padded_camera_data_size * frame_index;
    const scene_data_offset = scene_data_base_offset + padded_scene_data_size * frame_index;

    var data: ?*anyopaque = undefined;
    check_vk(c.vma.MapMemory(self.vma_allocator, self.camera_and_scene_buffer.allocation, &data))
        catch @panic("Failed to map camera buffer");

    const camera_data: *GPUCameraData = @ptrFromInt(@intFromPtr(data) + camera_data_offset);
    const scene_data: *GPUSceneData = @ptrFromInt(@intFromPtr(data) + scene_data_offset);
    camera_data.* = curr_camera_data;
    const framed = @as(f32, @floatFromInt(self.frame_number)) / 120.0;
    scene_data.ambient_color = Vec3.make(@sin(framed), 0.0, @cos(framed)).to_point4();

    c.vma.UnmapMemory(self.vma_allocator, self.camera_and_scene_buffer.allocation);

    // NOTE: In this copy I do conversion. Now, this is generally unsafe as none
    // of the structures involved are c compatible (marked extern). However, we
    // so happen to know it is safe to do so for Mat4.
    // TODO: In the future we should mark all the math structure as extern, so
    // we can more easily pass them back and forth from C and do those kind of
    // conversions.
    var object_data: ?*anyopaque = undefined;
    check_vk(c.vma.MapMemory(self.vma_allocator, self.get_current_frame().object_buffer.allocation, &object_data))
        catch @panic("Failed to map object buffer");
    var object_data_arr: [*]GPUObjectData = @ptrCast(@alignCast(object_data orelse unreachable));
    for (objects, 0..) |object, index| {
        object_data_arr[index] = GPUObjectData{
            .model_matrix = object.transform,
        };
    }
    c.vma.UnmapMemory(self.vma_allocator, self.get_current_frame().object_buffer.allocation);

    for (objects, 0..) |object, index| {
        if (index == 0 or object.material != objects[index - 1].material) {
            c.vk.CmdBindPipeline(
                cmd, c.vk.PIPELINE_BIND_POINT_GRAPHICS, object.material.pipeline);

            // Compute the offset for dynamic uniform buffers (for now just the one containing scene data, the
            // camera data is not dynamic)
            const uniform_offsets = [_]u32{
                @as(u32, @intCast(camera_data_offset)),
                @as(u32, @intCast(scene_data_offset)),
            };

            c.vk.CmdBindDescriptorSets(
                cmd,
                c.vk.PIPELINE_BIND_POINT_GRAPHICS,
                object.material.pipeline_layout,
                0,
                1,
                &self.camera_and_scene_set,
                @as(u32, @intCast(uniform_offsets.len)),
                &uniform_offsets[0]);

            c.vk.CmdBindDescriptorSets(
                cmd,
                c.vk.PIPELINE_BIND_POINT_GRAPHICS,
                object.material.pipeline_layout,
                1,
                1,
                &self.get_current_frame().object_descriptor_set,
                0,
                null);
        }

        if (object.material.texture_set != VK_NULL_HANDLE) {
            c.vk.CmdBindDescriptorSets(
                    cmd,
                    c.vk.PIPELINE_BIND_POINT_GRAPHICS,
                object.material.pipeline_layout,
                2,
                1,
                &object.material.texture_set,
                0,
                null);
        }

        const push_constants = MeshPushConstants{
            .data = Vec4.ZERO,
            .render_matrix = object.transform,
        };

        c.vk.CmdPushConstants(
            cmd,
            object.material.pipeline_layout,
            c.vk.SHADER_STAGE_VERTEX_BIT,
            0,
            @sizeOf(MeshPushConstants),
            &push_constants);

        if (index == 0 or object.mesh != objects[index - 1].mesh) {
            const offset: c.vk.DeviceSize = 0;
            c.vk.CmdBindVertexBuffers(
                cmd, 0, 1, &object.mesh.vertex_buffer.buffer, &offset);
        }

        c.vk.CmdDraw(cmd, @as(u32, @intCast(object.mesh.vertices.len)), 1, 0, @intCast(index));
    }
}

fn create_material(self: *Self, pipeline: c.vk.Pipeline, pipeline_layout: c.vk.PipelineLayout, name: []const u8) *Material {
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

pub fn create_buffer(
    self: *Self,
    alloc_size: usize,
    usage: c.vk.BufferUsageFlags,
    memory_usage: c.vma.MemoryUsage
) AllocatedBuffer {
    const buffer_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = alloc_size,
        .usage = usage,
    });

    const vma_alloc_info = std.mem.zeroInit(c.vma.AllocationCreateInfo, .{
        .usage = memory_usage,
    });

    var buffer: AllocatedBuffer = undefined;
    check_vk(c.vma.CreateBuffer(
        self.vma_allocator,
        &buffer_ci,
        &vma_alloc_info,
        &buffer.buffer,
        &buffer.allocation,
        null)) catch @panic("Failed to create buffer");

    return buffer;
}

fn pad_uniform_buffer_size(self: *Self, original_size: usize) usize {
    const min_ubo_alignment = @as(usize, @intCast(self.physical_device_properties.limits.minUniformBufferOffsetAlignment));
    const aligned_size = (original_size + min_ubo_alignment - 1) & ~(min_ubo_alignment - 1);
    return aligned_size;
}

pub fn immediate_submit(self: *Self, submit_ctx: anytype) void {
    // Check the context is good
    comptime {
        var Context = @TypeOf(submit_ctx);
        var is_ptr = false;
        switch (@typeInfo(Context)) {
            .@"struct", .@"union", .@"enum" => {},
            .pointer => |ptr| {
                if (ptr.size != .one) {
                    @compileError("Context must be a type with a submit function. " ++ @typeName(Context) ++ "is a multi element pointer");
                }
                Context = ptr.child;
                is_ptr = true;
                switch (Context) {
                    .Struct, .Union, .Enum, .Opaque => {},
                    else => @compileError(
                        "Context must be a type with a submit function. "
                        ++ @typeName(Context)
                        ++ "is a pointer to a non struct/union/enum/opaque type"),
                }
            },
            else => @compileError("Context must be a type with a submit method. Cannot use: " ++ @typeName(Context)),
        }

        if (!@hasDecl(Context, "submit")) {
            @compileError("Context should have a submit method");
        }

        const submit_fn_info=  @typeInfo(@TypeOf(Context.submit));
        if (submit_fn_info != .@"fn") {
            @compileError("Context submit method should be a function");
        }

        if (submit_fn_info.@"fn".params.len != 2) {
            @compileError("Context submit method should have two parameters");
        }

        if (submit_fn_info.@"fn".params[0].type != Context) {
            @compileError("Context submit method first parameter should be of type: " ++ @typeName(Context));
        }

        if (submit_fn_info.@"fn".params[1].type != c.vk.CommandBuffer) {
            @compileError("Context submit method second parameter should be of type: " ++ @typeName(c.vk.CommandBuffer));
        }
    }

    const cmd = self.upload_context.command_buffer;

    const commmand_begin_ci = std.mem.zeroInit(c.vk.CommandBufferBeginInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    });
    check_vk(c.vk.BeginCommandBuffer(cmd, &commmand_begin_ci))
        catch @panic("Failed to begin command buffer");

    submit_ctx.submit(cmd);

    check_vk(c.vk.EndCommandBuffer(cmd))
        catch @panic("Failed to end command buffer");

    const submit_info = std.mem.zeroInit(c.vk.SubmitInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    });

    check_vk(c.vk.QueueSubmit(self.graphics_queue, 1, &submit_info, self.upload_context.upload_fence))
        catch @panic("Failed to submit to graphics queue");

    check_vk(c.vk.WaitForFences(self.device, 1, &self.upload_context.upload_fence, c.vk.TRUE, 1_000_000_000))
        catch @panic("Failed to wait for upload fence");
    check_vk(c.vk.ResetFences(self.device, 1, &self.upload_context.upload_fence))
        catch @panic("Failed to reset upload fence");

    check_vk(c.vk.ResetCommandPool(self.device, self.upload_context.command_pool, 0))
        catch @panic("Failed to reset command pool");
}

// Error checking for vulkan and SDL
//

fn check_sdl(res: c_int) void {
    if (res != 0) {
        log.err("Detected SDL error: {s}", .{ c.SDL.GetError() });
        @panic("SDL error");
    }
}

fn check_sdl_bool(res: c.SDL.Bool) void {
    if (res != c.SDL.TRUE) {
        log.err("Detected SDL error: {s}", .{ c.SDL.GetError() });
        @panic("SDL error");
    }
}
