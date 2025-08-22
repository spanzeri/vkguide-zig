const std = @import("std");
pub const c = @import("clibs.zig");

const log = std.log.scoped(.vulkan_init);

/// Instance initialisation settings.
///
pub const VkiInstanceOpts = struct {
    application_name: [:0]const u8 = "vki",
    application_version: u32 = c.vk.MAKE_VERSION(1, 0, 0),
    engine_name: ?[:0]const u8 = null,
    engine_version: u32 = c.vk.MAKE_VERSION(1, 0, 0),
    api_version: u32 = c.vk.MAKE_VERSION(1, 0, 0),
    debug: bool = false,
    debug_callback: c.vk.PFN_DebugUtilsMessengerCallbackEXT = null,
    required_extensions: []const [*c]const u8 = &.{},
    alloc_cb: ?*c.vk.AllocationCallbacks = null,
};

/// Result of a call to create_instance.
/// Contains the instance and an optional debug messengera, if
/// VkiInstanceOpts.debug was true and the validation layer was available.
pub const Instance = struct {
    handle: c.vk.Instance = null,
    debug_messenger: c.vk.DebugUtilsMessengerEXT = null,
};

/// Create a vulkan instance and otpional debug functionalities.
///
/// # Allocations
///
/// Initialization code does not require persistent allocations.
/// All the allocation are automatically cleared when the function returns.
pub fn create_instance(alloc: std.mem.Allocator, opts: VkiInstanceOpts) !Instance {
    // Check the api version is supported
    if (opts.api_version > c.vk.MAKE_VERSION(1, 0, 0)) {
        var api_requested = opts.api_version;
        try check_vk(c.vk.EnumerateInstanceVersion(@ptrCast(&api_requested)));
    }

    var enable_validation = opts.debug;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Get supported layers and extensions
    var layer_count: u32 = undefined;
    try check_vk(c.vk.EnumerateInstanceLayerProperties(&layer_count, null));
    const layer_props = try arena.alloc(c.vk.LayerProperties, layer_count);
    try check_vk(c.vk.EnumerateInstanceLayerProperties(&layer_count, layer_props.ptr));

    var extension_count: u32 = undefined;
    try check_vk(c.vk.EnumerateInstanceExtensionProperties(null, &extension_count, null));
    const extension_props = try arena.alloc(c.vk.ExtensionProperties, extension_count);
    try check_vk(c.vk.EnumerateInstanceExtensionProperties(null, &extension_count, extension_props.ptr));

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
        fn find(name: [*c]const u8, props: []c.vk.ExtensionProperties) bool {
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

    const app_info = std.mem.zeroInit(c.vk.ApplicationInfo, .{
        .sType            = c.vk.STRUCTURE_TYPE_APPLICATION_INFO,
        .apiVersion       = opts.api_version,
        .pApplicationName = opts.application_name,
        .pEngineName      = opts.engine_name orelse opts.application_name,
    });

    const instance_info = std.mem.zeroInit(c.vk.InstanceCreateInfo, .{
        .sType                   = c.vk.STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo        = &app_info,
        .enabledLayerCount       = @as(u32, @intCast(layers.items.len)),
        .ppEnabledLayerNames     = layers.items.ptr,
        .enabledExtensionCount   = @as(u32, @intCast(extensions.items.len)),
        .ppEnabledExtensionNames = extensions.items.ptr,
    });

    var instance: c.vk.Instance = undefined;
    try check_vk(c.vk.CreateInstance(&instance_info, opts.alloc_cb, &instance));
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
    min_api_version: u32 = c.vk.MAKE_VERSION(1, 0, 0),
    /// Required device extensions.
    required_extensions: []const [*c]const u8 = &.{},
    /// Presentation surface.
    surface: c.vk.SurfaceKHR,
    /// Selection criteria.
    criteria: PhysicalDeviceSelectionCriteria = .PreferDiscrete,
};

/// Result of a call to select_physical_device.
///
pub const PhysicalDevice = struct {
    /// The selected physical device.
    handle: c.vk.PhysicalDevice = null,
    /// The selected physical device properties.
    properties: c.vk.PhysicalDeviceProperties = undefined,
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
    instance: c.vk.Instance,
    opts: PhysicalDeviceSelectOpts
) !PhysicalDevice {
    var physical_device_count: u32 = undefined;
    try check_vk(c.vk.EnumeratePhysicalDevices(instance, &physical_device_count, null));

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const physical_devices = try arena.alloc(c.vk.PhysicalDevice, physical_device_count);
    try check_vk(c.vk.EnumeratePhysicalDevices(instance, &physical_device_count, physical_devices.ptr));

    var suitable_pd: ?PhysicalDevice = null;

    for (physical_devices) |device| {
        const pd = make_physical_device(a, device, opts.surface) catch continue;
        _ = is_physical_device_suitable(a, pd, opts) catch continue;

        if (opts.criteria == PhysicalDeviceSelectionCriteria.First) {
            suitable_pd = pd;
            break;
        }

        if (pd.properties.deviceType == c.vk.PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
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

    const device_name = @as([*:0]const u8, @ptrCast(@alignCast(res.properties.deviceName[0..])));
    log.info("Selected physical device: {s}", .{ device_name });

    return res;
}

/// Options for creating a logical device.
///
const DeviceCreateOpts = struct {
    /// The physical device.
    physical_device: PhysicalDevice,
    /// The logical device features.
    features: c.vk.PhysicalDeviceFeatures = undefined,
    /// The logical device allocation callbacks.
    alloc_cb: ?*const c.vk.AllocationCallbacks = null,
    /// Optional pnext chain for VkDeviceCreateInfo.
    pnext: ?*const anyopaque = null,
};

/// Result from the creation of a logical device.
///
pub const Device = struct {
    handle: c.vk.Device = null,
    graphics_queue: c.vk.Queue = null,
    present_queue: c.vk.Queue = null,
    compute_queue: c.vk.Queue = null,
    transfer_queue: c.vk.Queue = null,
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

    var queue_create_infos = std.ArrayListUnmanaged(c.vk.DeviceQueueCreateInfo){};
    const queue_priorities: f32 = 1.0;

    var queue_family_set = std.AutoArrayHashMapUnmanaged(u32, void){};
    try queue_family_set.put(arena, opts.physical_device.graphics_queue_family, {});
    try queue_family_set.put(arena, opts.physical_device.present_queue_family, {});
    try queue_family_set.put(arena, opts.physical_device.compute_queue_family, {});
    try queue_family_set.put(arena, opts.physical_device.transfer_queue_family, {});

    var qfi_iter = queue_family_set.iterator();
    try queue_create_infos.ensureTotalCapacity(arena, queue_family_set.count());
    while (qfi_iter.next()) |qfi| {
        try queue_create_infos.append(arena, std.mem.zeroInit(c.vk.DeviceQueueCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = qfi.key_ptr.*,
            .queueCount = 1,
            .pQueuePriorities = &queue_priorities,
        }));
    }

    const device_extensions: []const [*c]const u8 = &.{
        "VK_KHR_swapchain",
    };

    const device_info = std.mem.zeroInit(c.vk.DeviceCreateInfo, .{
        .sType = c.vk.STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = opts.pnext,
        .queueCreateInfoCount = @as(u32, @intCast(queue_create_infos.items.len)),
        .pQueueCreateInfos = queue_create_infos.items.ptr,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = @as(u32, @intCast(device_extensions.len)),
        .ppEnabledExtensionNames = device_extensions.ptr,
        .pEnabledFeatures = &opts.features,
    });

    var device: c.vk.Device = undefined;
    try check_vk(c.vk.CreateDevice(opts.physical_device.handle, &device_info, opts.alloc_cb, &device));

    var graphics_queue: c.vk.Queue = undefined;
    c.vk.GetDeviceQueue(device, opts.physical_device.graphics_queue_family, 0, &graphics_queue);
    var present_queue: c.vk.Queue = undefined;
    c.vk.GetDeviceQueue(device, opts.physical_device.present_queue_family, 0, &present_queue);
    var compute_queue: c.vk.Queue = undefined;
    c.vk.GetDeviceQueue(device, opts.physical_device.compute_queue_family, 0, &compute_queue);
    var transfer_queue: c.vk.Queue = undefined;
    c.vk.GetDeviceQueue(device, opts.physical_device.transfer_queue_family, 0, &transfer_queue);

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
    physical_device: c.vk.PhysicalDevice,
    graphics_queue_family: u32,
    present_queue_family: u32,
    device: c.vk.Device,
    surface: c.vk.SurfaceKHR,
    old_swapchain: c.vk.SwapchainKHR = null,
    vsync: bool = false,
    triple_buffer: bool = false,
    window_width: u32 = 0,
    window_height: u32 = 0,
    alloc_cb: ?*c.vk.AllocationCallbacks = null,
};

/// Swapchain.
/// Creation needs to be done through init.
pub const Swapchain = struct {
    handle: c.vk.SwapchainKHR = null,
    images: []c.vk.Image = &.{},
    image_views: []c.vk.ImageView = &.{},
    format: c.vk.Format = undefined,
    extent: c.vk.Extent2D = undefined,
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

    var swapchain_info = std.mem.zeroInit(c.vk.SwapchainCreateInfoKHR, .{
        .sType            = c.vk.STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface          = opts.surface,
        .minImageCount    = image_count,
        .imageFormat      = format,
        .imageColorSpace  = c.vk.COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent      = extent,
        .imageArrayLayers = 1,
        .imageUsage       = c.vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform     = support_info.capabilities.currentTransform,
        .compositeAlpha   = c.vk.COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode      = present_mode,
        .clipped          = c.vk.TRUE,
        .oldSwapchain     = opts.old_swapchain,
    });

    if (opts.graphics_queue_family != opts.present_queue_family) {
        const queue_family_indices: []const u32 = &.{
            opts.graphics_queue_family,
            opts.present_queue_family,
        };
        swapchain_info.imageSharingMode = c.vk.SHARING_MODE_CONCURRENT;
        swapchain_info.queueFamilyIndexCount = 2;
        swapchain_info.pQueueFamilyIndices = queue_family_indices.ptr;
    } else {
        swapchain_info.imageSharingMode = c.vk.SHARING_MODE_EXCLUSIVE;
    }

    var swapchain: c.vk.SwapchainKHR = undefined;
    try check_vk(c.vk.CreateSwapchainKHR(opts.device, &swapchain_info, opts.alloc_cb, &swapchain));
    errdefer c.vk.DestroySwapchainKHR(opts.device, swapchain, opts.alloc_cb);
    log.info("Created vulkan swapchain.", .{});

    // Try and fetch the images from the swpachain.
    var swapchain_image_count: u32 = undefined;
    try check_vk(c.vk.GetSwapchainImagesKHR(opts.device, swapchain, &swapchain_image_count, null));
    const swapchain_images = try a.alloc(c.vk.Image, swapchain_image_count);
    errdefer a.free(swapchain_images);
    try check_vk(c.vk.GetSwapchainImagesKHR(opts.device, swapchain, &swapchain_image_count, swapchain_images.ptr));

    // Create image views for the swapchain images.
    const swapchain_image_views = try a.alloc(c.vk.ImageView, swapchain_image_count);
    errdefer a.free(swapchain_image_views);

    for (swapchain_images, swapchain_image_views) |image, *view| {
        view.* = try create_image_view(opts.device, image, format, c.vk.IMAGE_ASPECT_COLOR_BIT, opts.alloc_cb);
    }

    return .{
        .handle = swapchain,
        .images = swapchain_images,
        .image_views = swapchain_image_views,
        .format = format,
        .extent = extent,
    };
}

fn pick_swapchain_format(formats: []const c.vk.SurfaceFormatKHR, opts: SwapchainCreateOpts) c.vk.Format {
    // TODO: Add support for specifying desired format.
    _ = opts;
    for (formats) |format| {
        if (format.format == c.vk.FORMAT_B8G8R8A8_SRGB and
            format.colorSpace == c.vk.COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return format.format;
        }
    }

    return formats[0].format;
}

fn pick_swapchain_present_mode(modes: []const c.vk.PresentModeKHR, opts: SwapchainCreateOpts) c.vk.PresentModeKHR {
    if (opts.vsync == false) {
        // Prefer immediate mode if present.
        for (modes) |mode| {
            if (mode == c.vk.PRESENT_MODE_IMMEDIATE_KHR) {
                return mode;
            }
        }
        log.info("Immediate present mode is not possible. Falling back to vsync", .{});
    }

    // Prefer triple buffering if possible.
    for (modes) |mode| {
        if (mode == c.vk.PRESENT_MODE_MAILBOX_KHR and opts.triple_buffer) {
            return mode;
        }
    }

    // If nothing else is present, FIFO is guaranteed to be available by the specs.
    return c.vk.PRESENT_MODE_FIFO_KHR;
}

fn make_swapchain_extent(capabilities: c.vk.SurfaceCapabilitiesKHR, opts: SwapchainCreateOpts) c.vk.Extent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }

    var extent = c.vk.Extent2D{
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
    device: c.vk.PhysicalDevice,
    surface: c.vk.SurfaceKHR
) !PhysicalDevice {
    var props = std.mem.zeroInit(c.vk.PhysicalDeviceProperties, .{});
    c.vk.GetPhysicalDeviceProperties(device, &props);

    var graphics_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
    var present_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
    var compute_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
    var transfer_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;

    var queue_family_count: u32 = undefined;
    c.vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
    const queue_families = try a.alloc(c.vk.QueueFamilyProperties, queue_family_count);
    defer a.free(queue_families);
    c.vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    for (queue_families, 0..) |queue_family, i| {
        const index: u32 = @intCast(i);

        if (graphics_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            queue_family.queueFlags & c.vk.QUEUE_GRAPHICS_BIT != 0)
        {
            graphics_queue_family= index;
        }

        if (present_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX) {
            var present_support: c.vk.Bool32 = undefined;
            try check_vk(c.vk.GetPhysicalDeviceSurfaceSupportKHR(device, index, surface, &present_support));
            if (present_support == c.vk.TRUE) {
                present_queue_family = index;
            }
        }

        if (compute_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            queue_family.queueFlags & c.vk.QUEUE_COMPUTE_BIT != 0)
        {
            compute_queue_family = index;
        }

        if (transfer_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
            queue_family.queueFlags & c.vk.QUEUE_TRANSFER_BIT != 0) {
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
        .properties = props,
        .graphics_queue_family = graphics_queue_family,
        .present_queue_family = present_queue_family,
        .compute_queue_family = compute_queue_family,
        .transfer_queue_family = transfer_queue_family,
    };
}

fn is_physical_device_suitable(a: std.mem.Allocator, device: PhysicalDevice, opts: PhysicalDeviceSelectOpts) !bool {
    if (device.properties.apiVersion < opts.min_api_version) {
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
        try check_vk(c.vk.EnumerateDeviceExtensionProperties(device.handle, null, &device_extension_count, null));
        const device_extensions = try arena.alloc(c.vk.ExtensionProperties, device_extension_count);
        try check_vk(c.vk.EnumerateDeviceExtensionProperties(device.handle, null, &device_extension_count, device_extensions.ptr));

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
    capabilities: c.vk.SurfaceCapabilitiesKHR = undefined,
    formats: []c.vk.SurfaceFormatKHR = &.{},
    present_modes: []c.vk.PresentModeKHR = &.{},

    fn init(a: std.mem.Allocator, device: c.vk.PhysicalDevice, surface: c.vk.SurfaceKHR) !SwapchainSupportInfo {
        var capabilities: c.vk.SurfaceCapabilitiesKHR = undefined;
        try check_vk(c.vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capabilities));

        var format_count: u32 = undefined;
        try check_vk(c.vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null));
        const formats = try a.alloc(c.vk.SurfaceFormatKHR, format_count);
        try check_vk(c.vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.ptr));

        var present_mode_count: u32 = undefined;
        try check_vk(c.vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null));
        const present_modes = try a.alloc(c.vk.PresentModeKHR, present_mode_count);
        try check_vk(c.vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, present_modes.ptr));

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
    device: c.vk.Device,
    image: c.vk.Image,
    format: c.vk.Format,
    aspect_flags: c.vk.ImageAspectFlags,
    alloc_cb: ?*c.vk.AllocationCallbacks
) !c.vk.ImageView {
    const view_info = std.mem.zeroInit(c.vk.ImageViewCreateInfo, .{
        .sType    = c.vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image    = image,
        .viewType = c.vk.IMAGE_VIEW_TYPE_2D,
        .format   = format,
        .components = .{
            .r = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .g = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .b = c.vk.COMPONENT_SWIZZLE_IDENTITY,
            .a = c.vk.COMPONENT_SWIZZLE_IDENTITY
        },
        .subresourceRange = .{
            .aspectMask     = aspect_flags,
            .baseMipLevel   = 0,
            .levelCount     = 1,
            .baseArrayLayer = 0,
            .layerCount     = 1,
        },
    });

    var image_view: c.vk.ImageView = undefined;
    try check_vk(c.vk.CreateImageView(device, &view_info, alloc_cb, &image_view));
    return image_view;
}

fn get_vulkan_instance_funct(comptime Fn: type, instance: c.vk.Instance, name: [*c]const u8) Fn {
    const get_proc_addr: c.vk.PFN_GetInstanceProcAddr = @ptrCast(c.SDL.Vulkan_GetVkGetInstanceProcAddr());
    if (get_proc_addr) |get_proc_addr_fn| {
        return @ptrCast(get_proc_addr_fn(instance, name));
    }

    @panic("SDL_Vulkan_GetVkGetInstanceProcAddr returned null");
}

fn create_debug_callback(instance: c.vk.Instance, opts: VkiInstanceOpts) !c.vk.DebugUtilsMessengerEXT {
    const create_fn_opt = get_vulkan_instance_funct(
        c.vk.PFN_CreateDebugUtilsMessengerEXT, instance, "vkCreateDebugUtilsMessengerEXT");
    if (create_fn_opt) |create_fn| {
        const create_info = std.mem.zeroInit(c.vk.DebugUtilsMessengerCreateInfoEXT, .{
            .sType           = c.vk.STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.vk.DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                               c.vk.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                               c.vk.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType     = c.vk.DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                               c.vk.DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                               c.vk.DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = opts.debug_callback orelse default_debug_callback,
            .pUserData       = null,
        });
        var debug_messenger: c.vk.DebugUtilsMessengerEXT = undefined;
        try check_vk(create_fn(instance, &create_info, opts.alloc_cb, &debug_messenger));
        log.info("Created vulkan debug messenger.", .{});
        return debug_messenger;
    }
    return null;
}

pub fn get_destroy_debug_utils_messenger_fn(instance: c.vk.Instance) c.vk.PFN_DestroyDebugUtilsMessengerEXT {
    return get_vulkan_instance_funct(
        c.vk.PFN_DestroyDebugUtilsMessengerEXT, instance, "vkDestroyDebugUtilsMessengerEXT");
}

fn default_debug_callback(
    severity: c.vk.DebugUtilsMessageSeverityFlagBitsEXT,
    msg_type: c.vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?* const c.vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque
) callconv(.c) c.vk.Bool32 {
    _ = user_data;
    const severity_str = switch (severity) {
        c.vk.DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => "verbose",
        c.vk.DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => "info",
        c.vk.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => "warning",
        c.vk.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => "error",
        else => "unknown",
    };

    const type_str = switch (msg_type) {
        c.vk.DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT => "general",
        c.vk.DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT => "validation",
        c.vk.DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT => "performance",
        else => "unknown",
    };

    const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.pMessage else "NO MESSAGE!";
    log.err("[{s}][{s}]. Message:\n  {s}", .{ severity_str, type_str, message });

    if (severity >= c.vk.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        @panic("Unrecoverable vulkan error.");
    }

    return c.vk.FALSE;
}

pub fn check_vk(result: c.vk.Result) !void {
    return switch (result) {
        c.vk.SUCCESS => {},
        c.vk.NOT_READY => error.vk_not_ready,
        c.vk.TIMEOUT => error.vk_timeout,
        c.vk.EVENT_SET => error.vk_event_set,
        c.vk.EVENT_RESET => error.vk_event_reset,
        c.vk.INCOMPLETE => error.vk_incomplete,
        c.vk.ERROR_OUT_OF_HOST_MEMORY => error.vk_error_out_of_host_memory,
        c.vk.ERROR_OUT_OF_DEVICE_MEMORY => error.vk_error_out_of_device_memory,
        c.vk.ERROR_INITIALIZATION_FAILED => error.vk_error_initialization_failed,
        c.vk.ERROR_DEVICE_LOST => error.vk_error_device_lost,
        c.vk.ERROR_MEMORY_MAP_FAILED => error.vk_error_memory_map_failed,
        c.vk.ERROR_LAYER_NOT_PRESENT => error.vk_error_layer_not_present,
        c.vk.ERROR_EXTENSION_NOT_PRESENT => error.vk_error_extension_not_present,
        c.vk.ERROR_FEATURE_NOT_PRESENT => error.vk_error_feature_not_present,
        c.vk.ERROR_INCOMPATIBLE_DRIVER => error.vk_error_incompatible_driver,
        c.vk.ERROR_TOO_MANY_OBJECTS => error.vk_error_too_many_objects,
        c.vk.ERROR_FORMAT_NOT_SUPPORTED => error.vk_error_format_not_supported,
        c.vk.ERROR_FRAGMENTED_POOL => error.vk_error_fragmented_pool,
        c.vk.ERROR_UNKNOWN => error.vk_error_unknown,
        c.vk.ERROR_OUT_OF_POOL_MEMORY => error.vk_error_out_of_pool_memory,
        c.vk.ERROR_INVALID_EXTERNAL_HANDLE => error.vk_error_invalid_external_handle,
        c.vk.ERROR_FRAGMENTATION => error.vk_error_fragmentation,
        c.vk.ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => error.vk_error_invalid_opaque_capture_address,
        c.vk.PIPELINE_COMPILE_REQUIRED => error.vk_pipeline_compile_required,
        c.vk.ERROR_SURFACE_LOST_KHR => error.vk_error_surface_lost_khr,
        c.vk.ERROR_NATIVE_WINDOW_IN_USE_KHR => error.vk_error_native_window_in_use_khr,
        c.vk.SUBOPTIMAL_KHR => error.vk_suboptimal_khr,
        c.vk.ERROR_OUT_OF_DATE_KHR => error.vk_error_out_of_date_khr,
        c.vk.ERROR_INCOMPATIBLE_DISPLAY_KHR => error.vk_error_incompatible_display_khr,
        c.vk.ERROR_VALIDATION_FAILED_EXT => error.vk_error_validation_failed_ext,
        c.vk.ERROR_INVALID_SHADER_NV => error.vk_error_invalid_shader_nv,
        c.vk.ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR => error.vk_error_image_usage_not_supported_khr,
        c.vk.ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR => error.vk_error_video_picture_layout_not_supported_khr,
        c.vk.ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR => error.vk_error_video_profile_operation_not_supported_khr,
        c.vk.ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR => error.vk_error_video_profile_format_not_supported_khr,
        c.vk.ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR => error.vk_error_video_profile_codec_not_supported_khr,
        c.vk.ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR => error.vk_error_video_std_version_not_supported_khr,
        c.vk.ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => error.vk_error_invalid_drm_format_modifier_plane_layout_ext,
        c.vk.ERROR_NOT_PERMITTED_KHR => error.vk_error_not_permitted_khr,
        c.vk.ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => error.vk_error_full_screen_exclusive_mode_lost_ext,
        c.vk.THREAD_IDLE_KHR => error.vk_thread_idle_khr,
        c.vk.THREAD_DONE_KHR => error.vk_thread_done_khr,
        c.vk.OPERATION_DEFERRED_KHR => error.vk_operation_deferred_khr,
        c.vk.OPERATION_NOT_DEFERRED_KHR => error.vk_operation_not_deferred_khr,
        c.vk.ERROR_COMPRESSION_EXHAUSTED_EXT => error.vk_error_compression_exhausted_ext,
        c.vk.ERROR_INCOMPATIBLE_SHADER_BINARY_EXT => error.vk_error_incompatible_shader_binary_ext,
        else => error.vk_errror_unknown,
    };
}

