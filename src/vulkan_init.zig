const std = @import("std");
const c = @import("clibs.zig");

const log = std.log.scoped(.vulkan_init);

/// Instance initialisation settings.
///
pub const VkiInstanceOpts = struct {
    application_name: [:0]const u8 = "vki",
    application_version: u32 = c.VK_MAKE_VERSION(1, 0, 0),
    engine_name: ?[:0]const u8 = null,
    engine_version: u32 = c.VK_MAKE_VERSION(1, 0, 0),
    api_version: u32 = c.VK_MAKE_VERSION(1, 0, 0),
    debug: bool = false,
    debug_callback: c.PFN_vkDebugUtilsMessengerCallbackEXT = null,
    required_extensions: [][*c]const u8 = &.{},
    alloc_cb: ?*c.VkAllocationCallbacks = null,
};

/// Result of a call to create_instance.
/// Contains the instance and an optional debug messengera, if
/// VkiInstanceOpts.debug was true and the validation layer was available.
pub const Instance = struct {
    handle: c.VkInstance = null,
    debug_messenger: c.VkDebugUtilsMessengerEXT = null,
};

/// Create a vulkan instance and otpional debug functionalities.
///
/// # Allocations
///
/// Initialization code does not require persistent allocations.
/// All the allocation are automatically cleared when the function returns.
pub fn create_instance(alloc: std.mem.Allocator, opts: VkiInstanceOpts) !Instance {
    // Check the api version is supported
    if (opts.api_version > c.VK_MAKE_VERSION(1, 0, 0)) {
        var api_requested = opts.api_version;
        try check_vk(c.vkEnumerateInstanceVersion(@ptrCast(&api_requested)));
    }

    var enable_validation = opts.debug;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Get supported layers and extensions
    var layer_count: u32 = undefined;
    try check_vk(c.vkEnumerateInstanceLayerProperties(&layer_count, null));
    const layer_props = try arena.alloc(c.VkLayerProperties, layer_count);
    try check_vk(c.vkEnumerateInstanceLayerProperties(&layer_count, layer_props.ptr));

    var extension_count: u32 = undefined;
    try check_vk(c.vkEnumerateInstanceExtensionProperties(null, &extension_count, null));
    const extension_props = try arena.alloc(c.VkExtensionProperties, extension_count);
    try check_vk(c.vkEnumerateInstanceExtensionProperties(null, &extension_count, extension_props.ptr));

    // Check if the validation layer is supported
    var layers = std.ArrayListUnmanaged([*c]const u8){};
    if (enable_validation) {
        enable_validation = blk: for (layer_props) |layer_prop| {
            const layer_name: [*c]const u8 = @ptrCast(layer_prop.layerName[0..]);
            const validation_layer_name: [*c]const u8 = "VK_LAYER_KHRONOS_validation";
            if (std.mem.eql(u8, std.mem.span(validation_layer_name), std.mem.span(layer_name))) {
                try layers.append(arena, validation_layer_name);
                break :blk true;
            }
        } else false;
    }

    // Check if the required extensions are supported
    var extensions = std.ArrayListUnmanaged([*c]const u8){};

    const ExtensionFinder = struct {
        fn find(name: [*c]const u8, props: []c.VkExtensionProperties) bool {
            for (props) |prop| {
                const prop_name: [*c]const u8 = @ptrCast(prop.extensionName[0..]);
                if (std.mem.eql(u8, std.mem.span(name), std.mem.span(prop_name))) {
                    return true;
                }
            }
            return false;
        }
    };

    // Start ensuring all SDL required extensions are supported
    for (opts.required_extensions) |required_ext| {
        if (ExtensionFinder.find(required_ext, extension_props)) {
            try extensions.append(arena, required_ext);
        } else {
            log.err("Required vulkan extension not supported: {s}", .{ required_ext });
            return error.vulkan_extension_not_supported;
        }
    }

    // If we need validation, also add the debug utils extension
    if (enable_validation and ExtensionFinder.find("VK_EXT_debug_utils", extension_props)) {
        try extensions.append(arena, "VK_EXT_debug_utils");
    } else {
        enable_validation = false;
    }

    const app_info = std.mem.zeroInit(c.VkApplicationInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .apiVersion = opts.api_version,
        .pApplicationName = opts.application_name,
        .pEngineName = opts.engine_name orelse opts.application_name,
    });

    const instance_info = std.mem.zeroInit(c.VkInstanceCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = @as(u32, @intCast(layers.items.len)),
        .ppEnabledLayerNames = layers.items.ptr,
        .enabledExtensionCount = @as(u32, @intCast(extensions.items.len)),
        .ppEnabledExtensionNames = extensions.items.ptr,
    });

    var instance: c.VkInstance = undefined;
    try check_vk(c.vkCreateInstance(&instance_info, opts.alloc_cb, &instance));
    log.info("Created vulkan instance.", .{});

    // Create the debug messenger if needed
    const debug_messenger = if (enable_validation)
        try create_debug_callback(instance, opts)
    else
        null;

    return .{ .handle = instance, .debug_messenger = debug_messenger };
}

/// Selection criteria for a physical device.
///
pub const PhysicalDeviceSelectionCriteria = enum {
    /// Select the first device that matches the criteria.
    First,
    /// Prefer a discrete gpu.
    PreferDiscrete,
};

/// Device selector options
///
pub const PhysicalDeviceSelectOpts = struct {
    /// Minimum required vulkan api version.
    min_api_version: u32 = c.VK_MAKE_VERSION(1, 0, 0),
    /// Required device extensions.
    required_extensions: []const [*c]const u8 = &.{},
    /// Presentation surface.
    surface: c.VkSurfaceKHR,
    /// Selection criteria.
    criteria: PhysicalDeviceSelectionCriteria = .PreferDiscrete,
};

/// Result of a call to select_physical_device.
///
pub const PhysicalDevice = struct {
    /// The selected physical device.
    handle: c.VkPhysicalDevice = null,
    /// The selected physical device properties.
    props: c.VkPhysicalDeviceProperties = undefined,
    /// Queue family indices.
    graphics_queue_family: u32 = undefined,
    present_queue_family: u32 = undefined,
    compute_queue_family: u32 = undefined,
    transfer_queue_family: u32 = undefined,

    const INVALID_QUEUE_FAMILY_INDEX = std.math.maxInt(u32);
};

/// Find suitable physical device.
///
/// # Allocations
/// This function does not require persistent allocations.
///
pub fn select_physical_device(
    a: std.mem.Allocator,
    instance: c.VkInstance,
    opts: PhysicalDeviceSelectOpts
) !PhysicalDevice {
    var physical_device_count: u32 = undefined;
    try check_vk(c.vkEnumeratePhysicalDevices(instance, &physical_device_count, null));

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const physical_devices = try arena.alloc(c.VkPhysicalDevice, physical_device_count);
    try check_vk(c.vkEnumeratePhysicalDevices(instance, &physical_device_count, physical_devices.ptr));

    var suitable_pd: ?PhysicalDevice = null;

    for (physical_devices) |device| {
        const pd = make_physical_device(a, device, opts.surface) catch continue;
        _ = is_physical_device_suitable(a, pd, opts) catch continue;

        if (opts.criteria == PhysicalDeviceSelectionCriteria.First) {
            suitable_pd = pd;
            break;
        }

        if (pd.props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
            suitable_pd = pd;
            break;
        } else if (suitable_pd == null) {
            suitable_pd = pd;
        }
    }

    if (suitable_pd == null) {
        log.err("No suitable physical device found.", .{});
        return error.vulkan_no_suitable_physical_device;
    }
    const res = suitable_pd.?;

    const device_name = @as([*:0]const u8, @ptrCast(@alignCast(res.props.deviceName[0..])));
    log.info("Selected physical device: {s}", .{ device_name });

    return res;
}

/// Options for creating a logical device.
///
const DeviceCreateOpts = struct {
    /// The physical device.
    physical_device: PhysicalDevice,
    /// The logical device features.
    features: c.VkPhysicalDeviceFeatures = undefined,
    /// The logical device allocation callbacks.
    alloc_cb: ?*const c.VkAllocationCallbacks = null,
};

/// Result from the creation of a logical device.
///
pub const Device = struct {
    handle: c.VkDevice = null,
    graphics_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,
    compute_queue: c.VkQueue = null,
    transfer_queue: c.VkQueue = null,
};

/// Create logical device
///
/// # Allocations
/// This function does not require persistent allocations.
pub fn create_logical_device(
    a: std.mem.Allocator,
    opts: DeviceCreateOpts
) !Device {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var queue_create_infos = std.ArrayListUnmanaged(c.VkDeviceQueueCreateInfo){};
    const queue_priorities: f32 = 1.0;

    var queue_family_set = std.AutoArrayHashMapUnmanaged(u32, void){};
    try queue_family_set.put(arena, opts.physical_device.graphics_queue_family, {});
    try queue_family_set.put(arena, opts.physical_device.present_queue_family, {});
    try queue_family_set.put(arena, opts.physical_device.compute_queue_family, {});
    try queue_family_set.put(arena, opts.physical_device.transfer_queue_family, {});

    var qfi_iter = queue_family_set.iterator();
    try queue_create_infos.ensureTotalCapacity(arena, queue_family_set.count());
    while (qfi_iter.next()) |qfi| {
        try queue_create_infos.append(arena, std.mem.zeroInit(c.VkDeviceQueueCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = qfi.key_ptr.*,
            .queueCount = 1,
            .pQueuePriorities = &queue_priorities,
        }));
    }

    const device_extensions: []const [*c]const u8 = &.{
        "VK_KHR_swapchain",
    };

    const device_info = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = @as(u32, @intCast(queue_create_infos.items.len)),
        .pQueueCreateInfos = queue_create_infos.items.ptr,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = @as(u32, @intCast(device_extensions.len)),
        .ppEnabledExtensionNames = device_extensions.ptr,
        .pEnabledFeatures = &opts.features,
    });

    var device: c.VkDevice = undefined;
    try check_vk(c.vkCreateDevice(opts.physical_device.handle, &device_info, opts.alloc_cb, &device));

    var graphics_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, opts.physical_device.graphics_queue_family, 0, &graphics_queue);
    var present_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, opts.physical_device.present_queue_family, 0, &present_queue);
    var compute_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, opts.physical_device.compute_queue_family, 0, &compute_queue);
    var transfer_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, opts.physical_device.transfer_queue_family, 0, &transfer_queue);

    return .{
        .handle = device,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
        .compute_queue = compute_queue,
        .transfer_queue = transfer_queue,
    };
}

/// Options for creating a swapchain.
pub const SwapchainCreateOpts = struct {
    physical_device: c.VkPhysicalDevice,
    graphics_queue_family: u32,
    present_queue_family: u32,
    device: c.VkDevice,
    surface: c.VkSurfaceKHR,
    old_swapchain: c.VkSwapchainKHR = null,
    vsync: bool = false,
    triple_buffer: bool = false,
    window_width: u32 = 0,
    window_height: u32 = 0,
    alloc_cb: ?*c.VkAllocationCallbacks = null,
};

/// Swapchain.
/// Creation needs to be done through init.
pub const Swapchain = struct {
    handle: c.VkSwapchainKHR = null,
    images: []c.VkImage = &.{},
    image_views: []c.VkImageView = &.{},
    format: c.VkFormat = undefined,
    extent: c.VkExtent2D = undefined,
};

pub fn create_swapchain(a: std.mem.Allocator, opts: SwapchainCreateOpts) !Swapchain {
    const support_info = try SwapchainSupportInfo.init(a, opts.physical_device, opts.surface);
    defer support_info.deinit(a);

    const format = pick_swapchain_format(support_info.formats, opts);
    const present_mode = pick_swapchain_present_mode(support_info.present_modes, opts);
    const extent = make_swapchain_extent(support_info.capabilities, opts);

    const image_count = blk: {
        const desired_count = support_info.capabilities.minImageCount + 1;
        if (support_info.capabilities.maxImageCount > 0) {
            break :blk @min(desired_count, support_info.capabilities.maxImageCount);
        }
        break :blk desired_count;
    };

    var swapchain_info = std.mem.zeroInit(c.VkSwapchainCreateInfoKHR, .{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = opts.surface,
        .minImageCount = image_count,
        .imageFormat = format,
        .imageColorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = support_info.capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = c.VK_TRUE,
        .oldSwapchain = opts.old_swapchain,
    });

    if (opts.graphics_queue_family != opts.present_queue_family) {
        const queue_family_indices: []const u32 = &.{
            opts.graphics_queue_family,
            opts.present_queue_family,
        };
        swapchain_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
        swapchain_info.queueFamilyIndexCount = 2;
        swapchain_info.pQueueFamilyIndices = queue_family_indices.ptr;
    } else {
        swapchain_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    }

    var swapchain: c.VkSwapchainKHR = undefined;
    try check_vk(c.vkCreateSwapchainKHR(opts.device, &swapchain_info, opts.alloc_cb, &swapchain));
    errdefer c.vkDestroySwapchainKHR(opts.device, swapchain, opts.alloc_cb);
    log.info("Created vulkan swapchain.", .{});

    // Try and fetch the images from the swpachain.
    var swapchain_image_count: u32 = undefined;
    try check_vk(c.vkGetSwapchainImagesKHR(opts.device, swapchain, &swapchain_image_count, null));
    const swapchain_images = try a.alloc(c.VkImage, swapchain_image_count);
    errdefer a.free(swapchain_images);
    try check_vk(c.vkGetSwapchainImagesKHR(opts.device, swapchain, &swapchain_image_count, swapchain_images.ptr));

    // Create image views for the swapchain images.
    const swapchain_image_views = try a.alloc(c.VkImageView, swapchain_image_count);
    errdefer a.free(swapchain_image_views);

    for (swapchain_images, swapchain_image_views) |image, *view| {
        view.* = try create_image_view(opts.device, image, format, c.VK_IMAGE_ASPECT_COLOR_BIT, opts.alloc_cb);
    }

    return .{
        .handle = swapchain,
        .images = swapchain_images,
        .image_views = swapchain_image_views,
        .format = format,
        .extent = extent,
    };
}

fn pick_swapchain_format(formats: []const c.VkSurfaceFormatKHR, opts: SwapchainCreateOpts) c.VkFormat {
    // TODO: Add support for specifying desired format.
    _ = opts;
    for (formats) |format| {
        if (format.format == c.VK_FORMAT_B8G8R8A8_SRGB and
            format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return format.format;
        }
    }

    return formats[0].format;
}

fn pick_swapchain_present_mode(modes: []const c.VkPresentModeKHR, opts: SwapchainCreateOpts) c.VkPresentModeKHR {
    if (opts.vsync == false) {
        // Prefer immediate mode if present.
        for (modes) |mode| {
            if (mode == c.VK_PRESENT_MODE_IMMEDIATE_KHR) {
                return mode;
            }
        }
        log.info("Immediate present mode is not possible. Falling back to vsync", .{});
    }

    // Prefer triple buffering if possible.
    for (modes) |mode| {
        if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR and opts.triple_buffer) {
            return mode;
        }
    }

    // If nothing else is present, FIFO is guaranteed to be available by the specs.
    return c.VK_PRESENT_MODE_FIFO_KHR;
}

fn make_swapchain_extent(capabilities: c.VkSurfaceCapabilitiesKHR, opts: SwapchainCreateOpts) c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }

    var extent = c.VkExtent2D{
        .width = opts.window_width,
        .height = opts.window_height,
    };

    extent.width = @max(
        capabilities.minImageExtent.width,
        @min(capabilities.maxImageExtent.width, extent.width));
    extent.height = @max(
        capabilities.minImageExtent.height,
        @min(capabilities.maxImageExtent.height, extent.height));

    return extent;
}

fn make_physical_device(
    a: std.mem.Allocator,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR
) !PhysicalDevice {
    var props = std.mem.zeroInit(c.VkPhysicalDeviceProperties, .{});
    c.vkGetPhysicalDeviceProperties(device, &props);

    var graphics_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
    var present_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
    var compute_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
    var transfer_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;

    var queue_family_count: u32 = undefined;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
    const queue_families = try a.alloc(c.VkQueueFamilyProperties, queue_family_count);
    defer a.free(queue_families);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queue_family, i| {
        const index: u32 = @intCast(i);

        if (graphics_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            queue_family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0)
        {
            graphics_queue_family= index;
        }

        if (present_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX) {
            var present_support: c.VkBool32 = undefined;
            try check_vk(c.vkGetPhysicalDeviceSurfaceSupportKHR(device, index, surface, &present_support));
            if (present_support == c.VK_TRUE) {
                present_queue_family = index;
            }
        }

        if (compute_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            queue_family.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0)
        {
            compute_queue_family = index;
        }

        if (transfer_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            queue_family.queueFlags & c.VK_QUEUE_TRANSFER_BIT != 0) {
            transfer_queue_family = index;
        }

        if (graphics_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            present_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            compute_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            transfer_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX) {
            break;
        }
    }

    return .{
        .handle = device,
        .props = props,
        .graphics_queue_family = graphics_queue_family,
        .present_queue_family = present_queue_family,
        .compute_queue_family = compute_queue_family,
        .transfer_queue_family = transfer_queue_family,
    };
}

fn is_physical_device_suitable(a: std.mem.Allocator, device: PhysicalDevice, opts: PhysicalDeviceSelectOpts) !bool {
    if (device.props.apiVersion < opts.min_api_version) {
        return false;
    }

    if (device.graphics_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
        device.present_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
        device.compute_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
        device.transfer_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX) {
        return false;
    }

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const swapchain_support = try SwapchainSupportInfo.init(arena, device.handle, opts.surface);
    defer swapchain_support.deinit(arena);
    if (swapchain_support.formats.len == 0 or swapchain_support.present_modes.len == 0) {
        return false;
    }

    if (opts.required_extensions.len > 0) {
        var device_extension_count: u32 = undefined;
        try check_vk(c.vkEnumerateDeviceExtensionProperties(device.handle, null, &device_extension_count, null));
        const device_extensions = try arena.alloc(c.VkExtensionProperties, device_extension_count);
        try check_vk(c.vkEnumerateDeviceExtensionProperties(device.handle, null, &device_extension_count, device_extensions.ptr));

        _ = blk: for (opts.required_extensions) |req_ext| {
            for (device_extensions) |device_ext| {
                const device_ext_name: [*c]const u8 = @ptrCast(device_ext.extensionName[0..]);
                if (std.mem.eql(u8, std.mem.span(req_ext), std.mem.span(device_ext_name))) {
                    break :blk true;
                }
            }
        } else return false;
    }

    return true;
}

const SwapchainSupportInfo = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR = undefined,
    formats: []c.VkSurfaceFormatKHR = &.{},
    present_modes: []c.VkPresentModeKHR = &.{},

    fn init(a: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !SwapchainSupportInfo {
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try check_vk(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capabilities));

        var format_count: u32 = undefined;
        try check_vk(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null));
        const formats = try a.alloc(c.VkSurfaceFormatKHR, format_count);
        try check_vk(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.ptr));

        var present_mode_count: u32 = undefined;
        try check_vk(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null));
        const present_modes = try a.alloc(c.VkPresentModeKHR, present_mode_count);
        try check_vk(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, present_modes.ptr));

        return .{
            .capabilities = capabilities,
            .formats = formats,
            .present_modes = present_modes,
        };
    }

    fn deinit(self: *const SwapchainSupportInfo, a: std.mem.Allocator) void {
        a.free(self.formats);
        a.free(self.present_modes);
    }
};

fn create_image_view(
    device: c.VkDevice,
    image: c.VkImage,
    format: c.VkFormat,
    aspect_flags: c.VkImageAspectFlags,
    alloc_cb: ?*c.VkAllocationCallbacks
) !c.VkImageView {
    const view_info = std.mem.zeroInit(c.VkImageViewCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY
        },
        .subresourceRange = .{
            .aspectMask = aspect_flags,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    });

    var image_view: c.VkImageView = undefined;
    try check_vk(c.vkCreateImageView(device, &view_info, alloc_cb, &image_view));
    return image_view;
}

fn get_vulkan_instance_funct(comptime Fn: type, instance: c.VkInstance, name: [*c]const u8) Fn {
    const get_proc_addr: c.PFN_vkGetInstanceProcAddr = @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr());
    if (get_proc_addr) |get_proc_addr_fn| {
        return @ptrCast(get_proc_addr_fn(instance, name));
    }

    @panic("SDL_Vulkan_GetVkGetInstanceProcAddr returned null");
}

fn create_debug_callback(instance: c.VkInstance, opts: VkiInstanceOpts) !c.VkDebugUtilsMessengerEXT {
    const create_fn_opt = get_vulkan_instance_funct(
        c.PFN_vkCreateDebugUtilsMessengerEXT, instance, "vkCreateDebugUtilsMessengerEXT");
    if (create_fn_opt) |create_fn| {
        const create_info = std.mem.zeroInit(c.VkDebugUtilsMessengerCreateInfoEXT, .{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_DEVICE_ADDRESS_BINDING_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = opts.debug_callback orelse default_debug_callback,
            .pUserData = null,
        });
        var debug_messenger: c.VkDebugUtilsMessengerEXT = undefined;
        try check_vk(create_fn(instance, &create_info, opts.alloc_cb, &debug_messenger));
        log.info("Created vulkan debug messenger.", .{});
        return debug_messenger;
    }
    return null;
}

pub fn get_destroy_debug_utils_messenger_fn(instance: c.VkInstance) c.PFN_vkDestroyDebugUtilsMessengerEXT {
    return get_vulkan_instance_funct(
        c.PFN_vkDestroyDebugUtilsMessengerEXT, instance, "vkDestroyDebugUtilsMessengerEXT");
}

fn default_debug_callback(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    msg_type: c.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?* const c.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque
) callconv(.C) c.VkBool32 {
    _ = user_data;
    const severity_str = switch (severity) {
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => "verbose",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => "info",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => "warning",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => "error",
        else => "unknown",
    };

    const type_str = switch (msg_type) {
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT => "general",
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT => "validation",
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT => "performance",
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_DEVICE_ADDRESS_BINDING_BIT_EXT => "device address",
        else => "unknown",
    };

    const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.pMessage else "NO MESSAGE!";
    log.err("[{s}][{s}]. Message:\n  {s}", .{ severity_str, type_str, message });

    if (severity >= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        @panic("Unrecoverable vulkan error.");
    }

    return c.VK_FALSE;
}

pub fn check_vk(result: c.VkResult) !void {
    return switch (result) {
        c.VK_SUCCESS => {},
        c.VK_NOT_READY => error.vk_not_ready,
        c.VK_TIMEOUT => error.vk_timeout,
        c.VK_EVENT_SET => error.vk_event_set,
        c.VK_EVENT_RESET => error.vk_event_reset,
        c.VK_INCOMPLETE => error.vk_incomplete,
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.vk_error_out_of_host_memory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.vk_error_out_of_device_memory,
        c.VK_ERROR_INITIALIZATION_FAILED => error.vk_error_initialization_failed,
        c.VK_ERROR_DEVICE_LOST => error.vk_error_device_lost,
        c.VK_ERROR_MEMORY_MAP_FAILED => error.vk_error_memory_map_failed,
        c.VK_ERROR_LAYER_NOT_PRESENT => error.vk_error_layer_not_present,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => error.vk_error_extension_not_present,
        c.VK_ERROR_FEATURE_NOT_PRESENT => error.vk_error_feature_not_present,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => error.vk_error_incompatible_driver,
        c.VK_ERROR_TOO_MANY_OBJECTS => error.vk_error_too_many_objects,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => error.vk_error_format_not_supported,
        c.VK_ERROR_FRAGMENTED_POOL => error.vk_error_fragmented_pool,
        c.VK_ERROR_UNKNOWN => error.vk_error_unknown,
        c.VK_ERROR_OUT_OF_POOL_MEMORY => error.vk_error_out_of_pool_memory,
        c.VK_ERROR_INVALID_EXTERNAL_HANDLE => error.vk_error_invalid_external_handle,
        c.VK_ERROR_FRAGMENTATION => error.vk_error_fragmentation,
        c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => error.vk_error_invalid_opaque_capture_address,
        c.VK_PIPELINE_COMPILE_REQUIRED => error.vk_pipeline_compile_required,
        c.VK_ERROR_SURFACE_LOST_KHR => error.vk_error_surface_lost_khr,
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => error.vk_error_native_window_in_use_khr,
        c.VK_SUBOPTIMAL_KHR => error.vk_suboptimal_khr,
        c.VK_ERROR_OUT_OF_DATE_KHR => error.vk_error_out_of_date_khr,
        c.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => error.vk_error_incompatible_display_khr,
        c.VK_ERROR_VALIDATION_FAILED_EXT => error.vk_error_validation_failed_ext,
        c.VK_ERROR_INVALID_SHADER_NV => error.vk_error_invalid_shader_nv,
        c.VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR => error.vk_error_image_usage_not_supported_khr,
        c.VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR => error.vk_error_video_picture_layout_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR => error.vk_error_video_profile_operation_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR => error.vk_error_video_profile_format_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR => error.vk_error_video_profile_codec_not_supported_khr,
        c.VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR => error.vk_error_video_std_version_not_supported_khr,
        c.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => error.vk_error_invalid_drm_format_modifier_plane_layout_ext,
        c.VK_ERROR_NOT_PERMITTED_KHR => error.vk_error_not_permitted_khr,
        c.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => error.vk_error_full_screen_exclusive_mode_lost_ext,
        c.VK_THREAD_IDLE_KHR => error.vk_thread_idle_khr,
        c.VK_THREAD_DONE_KHR => error.vk_thread_done_khr,
        c.VK_OPERATION_DEFERRED_KHR => error.vk_operation_deferred_khr,
        c.VK_OPERATION_NOT_DEFERRED_KHR => error.vk_operation_not_deferred_khr,
        c.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => error.vk_error_compression_exhausted_ext,
        c.VK_ERROR_INCOMPATIBLE_SHADER_BINARY_EXT => error.vk_error_incompatible_shader_binary_ext,
        else => error.vk_errror_unknown,
    };
}

