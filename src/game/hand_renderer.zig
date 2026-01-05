//! Hand Renderer
//! Renders the held block in the player's hand (first-person view).

const std = @import("std");
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Vertex = rhi_pkg.Vertex;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const BlockType = @import("../world/block.zig").BlockType;
const Inventory = @import("inventory.zig").Inventory;

pub const HandRenderer = struct {
    rhi: RHI,
    buffer_handle: rhi_pkg.BufferHandle,
    last_block: ?BlockType,
    visible: bool,

    // Animation state
    swing_progress: f32,
    swinging: bool,

    pub fn init(rhi: RHI) HandRenderer {
        // Create a dynamic vertex buffer large enough for a cube (36 vertices)
        // Usage: vertex buffer
        const buffer = rhi.createBuffer(36 * @sizeOf(Vertex), .vertex);

        return .{
            .rhi = rhi,
            .buffer_handle = buffer,
            .last_block = null,
            .visible = false,
            .swing_progress = 0,
            .swinging = false,
        };
    }

    pub fn deinit(self: *HandRenderer) void {
        if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
            self.rhi.destroyBuffer(self.buffer_handle);
            self.buffer_handle = rhi_pkg.InvalidBufferHandle;
        }
    }

    pub fn update(self: *HandRenderer, dt: f32) void {
        if (self.swinging) {
            self.swing_progress += dt * 5.0; // Swing speed
            if (self.swing_progress >= 1.0) {
                self.swing_progress = 0.0;
                self.swinging = false;
            }
        }
    }

    pub fn swing(self: *HandRenderer) void {
        self.swinging = true;
        self.swing_progress = 0.0;
    }

    /// Check inventory and update mesh if held block changed
    pub fn updateMesh(self: *HandRenderer, inventory: Inventory, atlas: *const TextureAtlas) void {
        const selected = inventory.getSelectedBlock();

        // If no block selected or air, hide
        if (selected == null or selected == .air) {
            self.visible = false;
            self.last_block = null;
            return;
        }

        const block_type = selected.?;
        self.visible = true;

        // If block changed, rebuild mesh
        if (self.last_block != block_type) {
            self.buildMesh(block_type, atlas);
            self.last_block = block_type;
        }
    }

    fn buildMesh(self: *HandRenderer, block_type: BlockType, atlas: *const TextureAtlas) void {
        var vertices: [36]Vertex = undefined;
        var idx: usize = 0;

        _ = atlas; // Unused if getTilesForBlock is static
        const tiles = TextureAtlas.getTilesForBlock(@intFromEnum(block_type));
        const color = block_type.getColor();

        // Standard cube faces
        // 0: top, 1: bottom, 2: north, 3: south, 4: east, 5: west
        const faces = [6]struct { normal: [3]f32, tile: u8 }{
            .{ .normal = .{ 0, 1, 0 }, .tile = tiles.top }, // Top
            .{ .normal = .{ 0, -1, 0 }, .tile = tiles.bottom }, // Bottom
            .{ .normal = .{ 0, 0, -1 }, .tile = tiles.side }, // North
            .{ .normal = .{ 0, 0, 1 }, .tile = tiles.side }, // South
            .{ .normal = .{ 1, 0, 0 }, .tile = tiles.side }, // East
            .{ .normal = .{ -1, 0, 0 }, .tile = tiles.side }, // West
        };

        // Vertices for a unit cube centered at (0,0,0) with range -0.5 to 0.5
        const p = 0.5;
        const n = -0.5;

        // Top Face (y = p)
        addQuad(&vertices, &idx, .{ n, p, n }, .{ p, p, n }, .{ p, p, p }, .{ n, p, p }, faces[0].normal, faces[0].tile, color);
        // Bottom Face (y = n)
        addQuad(&vertices, &idx, .{ n, n, p }, .{ p, n, p }, .{ p, n, n }, .{ n, n, n }, faces[1].normal, faces[1].tile, color);
        // North Face (z = n)
        addQuad(&vertices, &idx, .{ p, n, n }, .{ n, n, n }, .{ n, p, n }, .{ p, p, n }, faces[2].normal, faces[2].tile, color);
        // South Face (z = p)
        addQuad(&vertices, &idx, .{ n, n, p }, .{ p, n, p }, .{ p, p, p }, .{ n, p, p }, faces[3].normal, faces[3].tile, color);
        // East Face (x = p)
        addQuad(&vertices, &idx, .{ p, n, p }, .{ p, n, n }, .{ p, p, n }, .{ p, p, p }, faces[4].normal, faces[4].tile, color);
        // West Face (x = n)
        addQuad(&vertices, &idx, .{ n, n, n }, .{ n, n, p }, .{ n, p, p }, .{ n, p, n }, faces[5].normal, faces[5].tile, color);

        self.rhi.uploadBuffer(self.buffer_handle, std.mem.asBytes(&vertices));
    }

    fn addQuad(verts: *[36]Vertex, idx: *usize, p0: [3]f32, p1: [3]f32, p2: [3]f32, p3: [3]f32, normal: [3]f32, tile: u8, color: [3]f32) void {
        const v0 = Vertex{ .pos = p0, .color = color, .normal = normal, .uv = .{ 0, 0 }, .tile_id = @floatFromInt(tile), .skylight = 15, .blocklight = 15 };
        const v1 = Vertex{ .pos = p1, .color = color, .normal = normal, .uv = .{ 1, 0 }, .tile_id = @floatFromInt(tile), .skylight = 15, .blocklight = 15 };
        const v2 = Vertex{ .pos = p2, .color = color, .normal = normal, .uv = .{ 1, 1 }, .tile_id = @floatFromInt(tile), .skylight = 15, .blocklight = 15 };
        const v3 = Vertex{ .pos = p3, .color = color, .normal = normal, .uv = .{ 0, 1 }, .tile_id = @floatFromInt(tile), .skylight = 15, .blocklight = 15 };

        verts[idx.*] = v0;
        idx.* += 1;
        verts[idx.*] = v1;
        idx.* += 1;
        verts[idx.*] = v2;
        idx.* += 1;
        verts[idx.*] = v0;
        idx.* += 1;
        verts[idx.*] = v2;
        idx.* += 1;
        verts[idx.*] = v3;
        idx.* += 1;
    }

    pub fn draw(self: *HandRenderer, camera_pos: Vec3, camera_yaw: f32, camera_pitch: f32) void {
        if (!self.visible) return;

        // Position relative to camera:
        // Right: 0.5, Down: -0.5, Forward: 0.8

        // Hand swing animation
        // Simple rotation/dip based on swing_progress
        const swing_val = std.math.sin(self.swing_progress * std.math.pi);
        const swing_offset_y = -swing_val * 0.2;
        const swing_rot_z = swing_val * 0.5;

        // Base transform: Place in front of camera
        // We use the View Matrix to get camera basis vectors, but simpler:
        // Just construct a model matrix relative to the camera position, but rotated with the camera?
        // Actually, for "hand" it's usually easier to render with Identity view matrix (cleared depth),
        // OR construct the world position based on camera orientation.

        // Let's attach it to the camera position and orientation.

        // 1. Translation to hand position relative to eye
        // x=0.5 (right), y=-0.5 (down), z=1.0 (forward)
        // Hand needs to rotate with Yaw, but Pitch usually only affects it slightly or full.
        // Standard FPS: Hand follows view.

        // Easier: Just set Model Matrix relative to Camera Position and Rotation.

        // Rotation: Yaw (Y axis), Pitch (X axis)
        const cos_y = @cos(camera_yaw);
        const sin_y = @sin(camera_yaw);
        const cos_p = @cos(camera_pitch);
        const sin_p = @sin(camera_pitch);

        // Forward vector (must match Player/Camera)
        const fwd = Vec3.init(cos_y * cos_p, sin_p, sin_y * cos_p).normalize();

        // Right vector
        const right = fwd.cross(Vec3.up).normalize();

        // Up vector
        const up = right.cross(fwd).normalize();

        // Calculate world position
        // Pos = CamPos + Right*0.5 + Up*-0.6 + Fwd*0.8
        var pos = camera_pos;
        pos = pos.add(right.scale(0.5));
        pos = pos.add(up.scale(-0.6 + swing_offset_y));
        pos = pos.add(fwd.scale(0.8));

        // Construct Model Matrix
        // Translate to World Pos
        // Rotate to match camera
        // Local rotations/scale

        // Let's construct it manually or via Mat4 helpers
        // Model = Translate(Pos) * Rotate(Orientation) * Scale(0.4)

        const scale_mat = Mat4.scale(Vec3.init(0.4, 0.4, 0.4));

        // Orientation: Block should face roughly forward but maybe tilted slightly?
        // Let's just match camera rotation for now.
        const rot_y = Mat4.rotateY(-camera_yaw);
        const rot_x = Mat4.rotateX(camera_pitch);
        const rot_mat = rot_y.multiply(rot_x); // Combined rotation

        // Additional tilt for "holding" look
        const tilt = Mat4.rotateY(0.4).multiply(Mat4.rotateX(0.2));

        const trans_mat = Mat4.translate(Vec3.init(pos.x - camera_pos.x, pos.y - camera_pos.y, pos.z - camera_pos.z));

        var m = trans_mat;
        m = m.multiply(rot_mat);
        m = m.multiply(tilt);
        m = m.multiply(scale_mat);

        // Also apply swing rotation
        const swing_rot = Mat4.rotateZ(swing_rot_z);
        m = m.multiply(swing_rot);

        self.rhi.setModelMatrix(m, 0);

        // Use solid draw mode (triangles)
        // Pass DrawMode.triangles
        self.rhi.draw(self.buffer_handle, 36, .triangles);
    }
};
