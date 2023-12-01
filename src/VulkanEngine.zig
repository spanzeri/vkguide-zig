const std = @import("std");
const c = @import("clibs.zig");

const vki = @import("vulkan_init.zig");
const check_vk = vki.check_vk;

const log = std.log.scoped(.vulkan_engine);


const Self = @This();

const window_extent = c.VkExtent2D{ .width = 1600, .height = 900 };

const VK_NULL_HANDLE = null;

const vk_alloc_cbs: ?*c.VkAllocationCallbacks = null;

// Data
//
frame_number: i32 = 0,

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
swapchain_images: []c.VkImage = undefined,
swapchain_image_views: []c.VkImageView = undefined,

pub fn init(a: std.mem.Allocator) Self {
    check_sdl(c.SDL_Init(c.SDL_INIT_VIDEO));

    const window = c.SDL_CreateWindow(
        "Vulkan",
        window_extent.width,
        window_extent.height,
        c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE
    ) orelse @panic("Failed to create SDL window");

    _ = c.SDL_ShowWindow(window);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sdl_required_extension_count: u32 = undefined;
    check_sdl_bool(c.SDL_Vulkan_GetInstanceExtensions(&sdl_required_extension_count, null));
    var sdl_required_extensions = arena.alloc([*c]const u8, sdl_required_extension_count) catch @panic("Out of memory");
    check_sdl_bool(c.SDL_Vulkan_GetInstanceExtensions(&sdl_required_extension_count, sdl_required_extensions.ptr));

    // Instance creation and optional debug utilities
    const init_instance = vki.create_instance(std.heap.page_allocator, .{
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

    // Create the window surface
    var surface: c.VkSurfaceKHR = undefined;
    check_sdl_bool(c.SDL_Vulkan_CreateSurface(window, init_instance.handle, &surface));

    // Physical device selection
    const required_device_extensions: []const [*c]const u8 = &.{
        "VK_KHR_swapchain",
    };
    const init_physical_device = vki.select_physical_device(std.heap.page_allocator, init_instance.handle, .{
        .min_api_version = c.VK_MAKE_VERSION(1, 1, 0),
        .required_extensions = required_device_extensions,
        .surface = surface,
        .criteria = .PreferDiscrete,
    }) catch |err| {
        log.err("Failed to select physical device with error: {s}", .{ @errorName(err) });
        unreachable;
    };

    // Create a logical device
    const init_device = vki.create_logical_device(a, .{
        .physical_device = init_physical_device,
        .features = std.mem.zeroInit(c.VkPhysicalDeviceFeatures, .{}),
        .alloc_cb = vk_alloc_cbs
    }) catch {
        log.err("Failed to create logical device", .{});
        unreachable;
    };

    var win_width: c_int = undefined;
    var win_height: c_int = undefined;
    check_sdl(c.SDL_GetWindowSize(window, &win_width, &win_height));

    // Create a swapchain
    const init_swapchain = vki.create_swapchain(a, .{
        .physical_device = init_physical_device,
        .device = init_device,
        .surface = surface,
        .old_swapchain = null ,
        .vsync = true,
        .window_width = @intCast(win_width),
        .window_height = @intCast(win_height),
        .alloc_cb = vk_alloc_cbs,
    }) catch {
        log.err("Failed to create swapchain", .{});
        unreachable;
    };

    return .{
        .window = window,
        .allocator = a,
        .instance = init_instance.handle,
        .debug_messenger = init_instance.debug_messenger,
        .physical_device = init_physical_device.handle,
        .device = init_device.handle,
        .surface = surface,
        .swapchain = init_swapchain.handle,
        .swapchain_images = init_swapchain.images,
        .swapchain_image_views = init_swapchain.image_views,
    };
}

pub fn cleanup(self: *Self) void {
    c.vkDestroySwapchainKHR(self.device, self.swapchain, vk_alloc_cbs);
    for (self.swapchain_image_views) |view| {
        c.vkDestroyImageView(self.device, view, vk_alloc_cbs);
    }
    self.allocator.free(self.swapchain_image_views);
    self.allocator.free(self.swapchain_images);

    c.vkDestroyDevice(self.device, vk_alloc_cbs);
    c.vkDestroySurfaceKHR(self.instance, self.surface, vk_alloc_cbs);

    if (self.debug_messenger != VK_NULL_HANDLE) {
        const destroy_fn = vki.get_destroy_debug_utils_messenger_fn(self.instance).?;
        destroy_fn(self.instance, self.debug_messenger, vk_alloc_cbs);
    }

    c.vkDestroyInstance(self.instance, vk_alloc_cbs);
    c.SDL_DestroyWindow(self.window);
}

pub fn run(self: *Self) void {
    var quit = false;
    var event: c.SDL_Event = undefined;
    while (!quit) {
        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_EVENT_QUIT) {
                quit = true;
            }
        }

        self.draw();
    }
}

fn draw(self: *Self) void {
    _ = self;
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
