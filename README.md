# VkGuide tutorial implemented in the zig programming language.

Vulkan book: [VulkanGuide](https://vkguide.dev/)
Zig language: [Zig](https://ziglang.org/)

Most of the code is implemented from scratch.

Few notable exceptions:
 - Media layer: [SDL3](https://www.libsdl.org/)

__NOTE__: This code has not been tested on windows yet.

I expect the code would work, but it fails to compile due to SDL and vulkan dependecies.k

If you are trying to run this on windows before I get around to fix it, consider fixing build.zig to find SDL.

## NOTES

### VkBoostrap

For the sake of reducing dependecies (especially c++ ones that cannot directly bind to zig), we are not using a boostrapping library.

Instead, we develop a simple and __not production ready__ alternative directly in zig.

It can be found in src/vulkan_init.zig.

## C libraries

All the c libraries are cImported in a single zig file to avoid multiple redifinitions.

If you want to take just some of the files, you'll need to cImport the required c dependencies.

