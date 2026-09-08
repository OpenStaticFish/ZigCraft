//! Pure contracts for the image that is ready for display and screenshot
//! readback. Vulkan calls live in the pass orchestration layer.

const c = @import("c").c;

pub const AttachmentUse = enum {
    /// A full-screen shader replaces every pixel. Previous color must not be
    /// loaded, even when the display image has a valid prior layout.
    full_screen_replace,
    /// UI draws are alpha-blended over a completed display image.
    overlay,
};

pub const AttachmentContract = struct {
    load_op: c.VkAttachmentLoadOp,
    store_op: c.VkAttachmentStoreOp = c.VK_ATTACHMENT_STORE_OP_STORE,
    initial_layout: c.VkImageLayout,
    final_layout: c.VkImageLayout,
};

pub fn displayLayout(skip_present: bool) c.VkImageLayout {
    return if (skip_present) c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL else c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
}

pub fn attachmentContract(use: AttachmentUse, layout: c.VkImageLayout) AttachmentContract {
    return .{
        .load_op = switch (use) {
            .full_screen_replace => c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .overlay => c.VK_ATTACHMENT_LOAD_OP_LOAD,
        },
        .initial_layout = layout,
        .final_layout = layout,
    };
}

/// Actual state, updated only after a final-color render pass ends. A screenshot
/// must consume this state instead of reconstructing it from presentation mode.
pub const FinalComposedImage = struct {
    image: c.VkImage = null,
    image_index: u32 = 0,
    layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,

    pub fn clear(self: *FinalComposedImage) void {
        self.* = .{};
    }

    pub fn set(self: *FinalComposedImage, image: c.VkImage, image_index: u32, layout: c.VkImageLayout) void {
        self.* = .{ .image = image, .image_index = image_index, .layout = layout };
    }

    pub fn isCurrentImage(self: FinalComposedImage, image_index: u32) bool {
        return self.image != null and self.image_index == image_index and self.layout != c.VK_IMAGE_LAYOUT_UNDEFINED;
    }
};

test "full-screen replacement and overlay have distinct load contracts" {
    const layout = displayLayout(true);
    const replacement = attachmentContract(.full_screen_replace, layout);
    const overlay = attachmentContract(.overlay, layout);

    try @import("std").testing.expectEqual(@as(c.VkAttachmentLoadOp, c.VK_ATTACHMENT_LOAD_OP_DONT_CARE), replacement.load_op);
    try @import("std").testing.expectEqual(@as(c.VkAttachmentLoadOp, c.VK_ATTACHMENT_LOAD_OP_LOAD), overlay.load_op);
    try @import("std").testing.expectEqual(layout, replacement.final_layout);
    try @import("std").testing.expectEqual(layout, overlay.initial_layout);
}

test "final composition records the actual image and layout" {
    var final_image = FinalComposedImage{};
    try @import("std").testing.expect(!final_image.isCurrentImage(2));

    final_image.set(@ptrFromInt(1), 2, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
    try @import("std").testing.expect(final_image.isCurrentImage(2));
    try @import("std").testing.expect(!final_image.isCurrentImage(1));
    try @import("std").testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL), final_image.layout);

    final_image.clear();
    try @import("std").testing.expect(!final_image.isCurrentImage(2));
}
