//! Utility file that imports all the c libraries.
//! Note that this needs to be done is a single place to avoid conflicts.
//!
//! pub usingnamespace means other files can include this as:
//! ```const c = @import("clib");```
//!
//! SDL and vulkan types can then be referred in code as:
//! ```
//! c.SDL_CreateWindow(...);
//! const ci = c.VkInstanceCreateInfo{...};
//! ```

pub usingnamespace @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_vulkan.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("vk_mem_alloc.h");
    @cInclude("stb_image.h");
});

