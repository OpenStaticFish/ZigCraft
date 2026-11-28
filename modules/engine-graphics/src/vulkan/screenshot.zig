const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const log = @import("engine-core").log;
const Utils = @import("utils.zig");

/// A readback recorded after all composition (including UI) and completed once
/// the frame submission fence signals.
pub const PendingCapture = struct {
    staging: ?Utils.VulkanBuffer = null,
    path: []const u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    row_pitch: usize = 0,
    format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    source_layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    source_image: c.VkImage = null,
    frame_index: usize = 0,
    path_owned: bool = false,
};

/// Queues a readback of the active frame. Frame orchestration records it after
/// all composition, including UI and post-processing, has completed.
pub fn requestCapture(ctx: anytype, path: []const u8) bool {
    const device = &ctx.vulkan_device;

    if (!ctx.frames.frame_in_progress) {
        log.log.err("screenshot: capture must be requested before endFrame", .{});
        return false;
    }
    if (ctx.screenshot_capture.staging != null) {
        log.log.err("screenshot: a capture is already pending", .{});
        return false;
    }
    if (ctx.swapchain.swapchain.images.items.len == 0) {
        log.log.err("screenshot: no swapchain images available", .{});
        return false;
    }
    if (detectScreenshotFormat(path) == null) {
        log.log.err("screenshot: unsupported image path '{s}' (use .png, .jpg, .jpeg, .gif, or .webp)", .{path});
        return false;
    }
    if (!ctx.swapchain.swapchain.screenshot_capture_supported) {
        log.log.err("screenshot: active surface does not support transfer-source swapchain images", .{});
        return false;
    }

    const extent = ctx.swapchain.getExtent();
    const image_format = ctx.swapchain.getImageFormat();
    const width = extent.width;
    const height = extent.height;
    if (width == 0 or height == 0) {
        log.log.err("screenshot: invalid rendered output extent", .{});
        return false;
    }

    const row_pitch = tightRowPitch(width);
    const image_size = row_pitch * @as(usize, height);

    const staging = Utils.createVulkanBuffer(
        device,
        image_size,
        c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    ) catch {
        log.log.err("screenshot: failed to create staging buffer", .{});
        return false;
    };
    const owned_path = ctx.allocator.dupe(u8, path) catch {
        c.vkDestroyBuffer(device.vk_device, staging.buffer, null);
        c.vkFreeMemory(device.vk_device, staging.memory, null);
        log.log.err("screenshot: failed to retain output path", .{});
        return false;
    };
    ctx.screenshot_capture = .{
        .staging = staging,
        .path = owned_path,
        .width = width,
        .height = height,
        .row_pitch = row_pitch,
        .format = image_format,
        .frame_index = ctx.frames.current_frame,
        .path_owned = true,
    };

    return true;
}

/// Appends the copy after final composition but before the command buffer is
/// submitted or (on normal paths) the swapchain image is presented.
pub fn recordCapture(ctx: anytype) void {
    const capture = &ctx.screenshot_capture;
    const staging = capture.staging orelse return;
    const final_image = ctx.runtime.final_composed;
    if (!final_image.isCurrentImage(ctx.frames.current_image_index)) {
        log.log.err("screenshot: no final composed image is available for this frame", .{});
        discardCapture(ctx);
        return;
    }

    capture.source_image = final_image.image;
    capture.source_layout = final_image.layout;
    const cmd_buffer = ctx.frames.getCurrentCommandBuffer();
    const dst_layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
    barrier.oldLayout = capture.source_layout;
    barrier.newLayout = dst_layout;
    barrier.image = capture.source_image;
    barrier.subresourceRange = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };

    c.vkCmdPipelineBarrier(
        cmd_buffer,
        c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );

    var region = std.mem.zeroes(c.VkBufferImageCopy);
    region.bufferOffset = 0;
    region.bufferRowLength = 0;
    region.bufferImageHeight = 0;
    region.imageSubresource = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .mipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    region.imageOffset = .{ .x = 0, .y = 0, .z = 0 };
    region.imageExtent = .{ .width = capture.width, .height = capture.height, .depth = 1 };

    c.vkCmdCopyImageToBuffer(
        cmd_buffer,
        capture.source_image,
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        staging.buffer,
        1,
        &region,
    );

    var host_barrier = std.mem.zeroes(c.VkBufferMemoryBarrier);
    host_barrier.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    host_barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
    host_barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
    host_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    host_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    host_barrier.buffer = staging.buffer;
    host_barrier.offset = 0;
    host_barrier.size = @intCast(capture.row_pitch * @as(usize, capture.height));
    c.vkCmdPipelineBarrier(
        cmd_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        0,
        null,
        1,
        &host_barrier,
        0,
        null,
    );

    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
    const skip_present = ctx.swapchain.skip_present;
    barrier.dstAccessMask = if (skip_present)
        c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
    else
        0;
    barrier.oldLayout = dst_layout;
    barrier.newLayout = capture.source_layout;

    c.vkCmdPipelineBarrier(
        cmd_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        if (skip_present) c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT else c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

/// Encodes the capture after the frame submission containing the copy has
/// completed. Called by frame orchestration, never by application code.
pub fn completeCapture(ctx: anytype) bool {
    const capture = &ctx.screenshot_capture;
    const staging = capture.staging orelse return true;
    const vk = ctx.vulkan_device.vk_device;
    const fence = ctx.frames.in_flight_fences[capture.frame_index];
    const fence_result = c.vkWaitForFences(vk, 1, &fence, c.VK_TRUE, 5_000_000_000);
    if (fence_result != c.VK_SUCCESS) {
        log.log.err("screenshot: fence wait failed or timed out ({})", .{fence_result});
        return false;
    }
    defer discardCapture(ctx);

    const mapped_ptr = staging.mapped_ptr orelse {
        log.log.err("screenshot: staging buffer not mapped", .{});
        return false;
    };
    const bytes: [*]const u8 = @ptrCast(@alignCast(mapped_ptr));
    return writeImage(bytes, capture.width, capture.height, capture.row_pitch, capture.path, capture.format);
}

pub fn discardCapture(ctx: anytype) void {
    if (ctx.screenshot_capture.staging) |staging| {
        if (staging.mapped_ptr != null) c.vkUnmapMemory(ctx.vulkan_device.vk_device, staging.memory);
        c.vkDestroyBuffer(ctx.vulkan_device.vk_device, staging.buffer, null);
        c.vkFreeMemory(ctx.vulkan_device.vk_device, staging.memory, null);
    }
    if (ctx.screenshot_capture.path_owned) ctx.allocator.free(ctx.screenshot_capture.path);
    ctx.screenshot_capture = .{};
}

const ScreenshotFormat = enum {
    png,
    jpeg,
    gif,
    webp,
};

fn tightRowPitch(width: u32) usize {
    return @as(usize, width) * 4;
}

fn writeImage(data: [*]const u8, width: u32, height: u32, source_row_pitch: usize, path: []const u8, format: c.VkFormat) bool {
    const output_format = detectScreenshotFormat(path) orelse {
        log.log.err("screenshot: unsupported image path '{s}' (use .png, .jpg, .jpeg, .gif, or .webp)", .{path});
        return false;
    };

    return switch (output_format) {
        .png => writePNG(data, width, height, source_row_pitch, path, format),
        .jpeg, .gif, .webp => unsupportedEncoder(path, output_format),
    };
}

fn unsupportedEncoder(path: []const u8, format: ScreenshotFormat) bool {
    log.log.err("screenshot: {s} output is allowed but not implemented yet for '{s}'; use .png", .{ @tagName(format), path });
    return false;
}

fn detectScreenshotFormat(path: []const u8) ?ScreenshotFormat {
    if (hasExtension(path, ".png")) return .png;
    if (hasExtension(path, ".jpg") or hasExtension(path, ".jpeg")) return .jpeg;
    if (hasExtension(path, ".gif")) return .gif;
    if (hasExtension(path, ".webp")) return .webp;
    return null;
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    const tail = path[path.len - ext.len ..];
    for (tail, ext) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

fn writePNG(data: [*]const u8, width: u32, height: u32, source_row_pitch: usize, path: []const u8, format: c.VkFormat) bool {
    if (width > 16384) {
        log.log.err("screenshot: width {} exceeds max supported 16384", .{width});
        return false;
    }

    const allocator = std.heap.page_allocator;
    const row_bytes: usize = @as(usize, width) * 3;
    if (source_row_pitch < tightRowPitch(width)) {
        log.log.err("screenshot: source row pitch {} is smaller than {} RGBA pixels", .{ source_row_pitch, width });
        return false;
    }
    const raw_size: usize = (@as(usize, height) * (row_bytes + 1));
    const raw = allocator.alloc(u8, raw_size) catch {
        log.log.err("screenshot: failed to allocate PNG scanlines", .{});
        return false;
    };
    defer allocator.free(raw);

    const is_bgra = format == c.VK_FORMAT_B8G8R8A8_UNORM or format == c.VK_FORMAT_B8G8R8A8_SRGB;
    const needs_srgb_encode = format == c.VK_FORMAT_B8G8R8A8_UNORM or format == c.VK_FORMAT_R8G8B8A8_UNORM;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_start = @as(usize, y) * (row_bytes + 1);
        raw[row_start] = 0;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src_offset: usize = @as(usize, y) * source_row_pitch + @as(usize, x) * 4;
            const dst_offset: usize = row_start + 1 + @as(usize, x) * 3;
            const rgb = finalDisplayRgb(data[src_offset..][0..4], is_bgra);
            raw[dst_offset] = if (needs_srgb_encode) linearByteToSrgb(rgb[0]) else rgb[0];
            raw[dst_offset + 1] = if (needs_srgb_encode) linearByteToSrgb(rgb[1]) else rgb[1];
            raw[dst_offset + 2] = if (needs_srgb_encode) linearByteToSrgb(rgb[2]) else rgb[2];
        }
    }

    const block_count = (raw_size + 65534) / 65535;
    const zlib_capacity = 2 + raw_size + block_count * 5 + 4;
    const zlib = allocator.alloc(u8, zlib_capacity) catch {
        log.log.err("screenshot: failed to allocate PNG zlib stream", .{});
        return false;
    };
    defer allocator.free(zlib);

    const zlib_len = writeStoredZlib(zlib, raw);

    const file = fs.cwd().createFile(path, .{}) catch {
        log.log.err("screenshot: failed to create file '{s}'", .{path});
        return false;
    };
    defer file.close();

    file.writeAll(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }) catch return false;

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;

    writePngChunk(file, "IHDR", &ihdr) catch return false;
    writePngChunk(file, "sRGB", &.{0}) catch return false;
    writePngChunk(file, "IDAT", zlib[0..zlib_len]) catch return false;
    writePngChunk(file, "IEND", &.{}) catch return false;

    log.log.info("screenshot: saved {}x{} PNG to '{s}'", .{ width, height, path });
    return true;
}

fn finalDisplayRgb(pixel: []const u8, is_bgra: bool) [3]u8 {
    std.debug.assert(pixel.len >= 4);
    return if (is_bgra) .{ pixel[2], pixel[1], pixel[0] } else .{ pixel[0], pixel[1], pixel[2] };
}

test "final display screenshot preserves BGRA UNORM byte encoding" {
    try std.testing.expectEqual([3]u8{ 101, 47, 23 }, finalDisplayRgb(&.{ 23, 47, 101, 255 }, true));
    try std.testing.expectEqual([3]u8{ 101, 47, 23 }, finalDisplayRgb(&.{ 101, 47, 23, 255 }, false));
}

fn linearByteToSrgb(value: u8) u8 {
    const linear = @as(f32, @floatFromInt(value)) / 255.0;
    const encoded = if (linear <= 0.0031308)
        linear * 12.92
    else
        1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(encoded, 0.0, 1.0) * 255.0));
}

test "linear final target bytes encode to sRGB PNG values" {
    try std.testing.expectEqual(@as(u8, 0), linearByteToSrgb(0));
    try std.testing.expectEqual(@as(u8, 255), linearByteToSrgb(255));
    try std.testing.expectApproxEqAbs(@as(f32, 118.0), @as(f32, @floatFromInt(linearByteToSrgb(46))), 1.0);
}

fn writeStoredZlib(dest: []u8, raw: []const u8) usize {
    var out: usize = 0;
    dest[out] = 0x78;
    out += 1;
    dest[out] = 0x01;
    out += 1;

    var offset: usize = 0;
    while (offset < raw.len) {
        const remaining = raw.len - offset;
        const len: u16 = @intCast(@min(remaining, 65535));
        const block_len: usize = @intCast(len);
        const final_block = offset + block_len == raw.len;
        dest[out] = if (final_block) 0x01 else 0x00;
        out += 1;
        std.mem.writeInt(u16, dest[out..][0..2], len, .little);
        out += 2;
        std.mem.writeInt(u16, dest[out..][0..2], ~len, .little);
        out += 2;
        @memcpy(dest[out..][0..block_len], raw[offset..][0..block_len]);
        out += block_len;
        offset += block_len;
    }

    std.mem.writeInt(u32, dest[out..][0..4], adler32(raw), .big);
    out += 4;
    return out;
}

fn writePngChunk(file: anytype, chunk_type: []const u8, payload: []const u8) !void {
    std.debug.assert(chunk_type.len == 4);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .big);
    try file.writeAll(&len_buf);
    try file.writeAll(chunk_type);
    try file.writeAll(payload);

    var crc_buf: [4]u8 = undefined;
    const crc = pngCrc(chunk_type, payload);
    std.mem.writeInt(u32, &crc_buf, crc, .big);
    try file.writeAll(&crc_buf);
}

fn pngCrc(chunk_type: []const u8, payload: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    crc = updateCrc(crc, chunk_type);
    crc = updateCrc(crc, payload);
    return crc ^ 0xFFFF_FFFF;
}

fn updateCrc(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    for (bytes) |byte| {
        crc ^= byte;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const mask: u32 = if ((crc & 1) != 0) 0xEDB8_8320 else 0;
            crc = (crc >> 1) ^ mask;
        }
    }
    return crc;
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}
