pub const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GL/gl.h");
    @cInclude("SDL3/SDL.h");
    @cInclude("vulkan/vulkan.h");
});
