//! Game session - handles active gameplay state.

const std = @import("std");
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const World = @import("../world/world.zig").World;
const WorldMap = @import("../world/worldgen/world_map.zig").WorldMap;
const MapController = @import("map_controller.zig").MapController;
const Player = @import("player.zig").Player;
const Inventory = @import("inventory.zig").Inventory;
const inventory_ui = @import("ui/inventory_ui.zig");
const BlockOutline = @import("block_outline.zig").BlockOutline;
const HandRenderer = @import("hand_renderer.zig").HandRenderer;
const Camera = @import("../engine/graphics/camera.zig").Camera;
const RHI = @import("../engine/graphics/rhi.zig").RHI;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const Input = @import("../engine/input/input.zig").Input;
const LODConfig = @import("../world/lod_chunk.zig").LODConfig;
const log = @import("../engine/core/log.zig");
const input_mapper = @import("input_mapper.zig");
const InputMapper = input_mapper.InputMapper;
const GameAction = input_mapper.GameAction;

const CSM = @import("../engine/graphics/csm.zig");
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Color = @import("../engine/ui/ui_system.zig").Color;
const Font = @import("../engine/ui/font.zig");
const Widgets = @import("../engine/ui/widgets.zig");
const region_pkg = @import("../world/worldgen/region.zig");
const hotbar = @import("ui/hotbar.zig");
const worldToChunk = @import("../world/chunk.zig").worldToChunk;

const ECSManager = @import("../engine/ecs/manager.zig");
const ECSRegistry = ECSManager.Registry;
const ECSComponents = @import("../engine/ecs/components.zig");
const ECSPhysicsSystem = @import("../engine/ecs/systems/physics.zig").PhysicsSystem;
const ECSRenderSystem = @import("../engine/ecs/systems/render.zig").RenderSystem;

const Atmosphere = @import("../engine/atmosphere/atmosphere.zig").Atmosphere;

pub const CloudState = struct {
    wind_offset_x: f32 = 0.0,
    wind_offset_z: f32 = 0.0,
    cloud_scale: f32 = 1.0 / 64.0,
    cloud_coverage: f32 = 0.5,
    cloud_height: f32 = 160.0,
    cloud_thickness: f32 = 12.0,
    base_color: Vec3 = Vec3.init(1.0, 1.0, 1.0),

    pub fn update(self: *CloudState, delta_time: f32) void {
        const wind_dir_x: f32 = 1.0;
        const wind_dir_z: f32 = 0.2;
        const wind_speed: f32 = 2.0;
        self.wind_offset_x += wind_dir_x * wind_speed * delta_time;
        self.wind_offset_z += wind_dir_z * wind_speed * delta_time;
    }

    pub fn getShadowParams(self: *const CloudState) struct {
        wind_offset_x: f32,
        wind_offset_z: f32,
        cloud_scale: f32,
        cloud_coverage: f32,
        cloud_height: f32,
    } {
        return .{
            .wind_offset_x = self.wind_offset_x,
            .wind_offset_z = self.wind_offset_z,
            .cloud_scale = self.cloud_scale,
            .cloud_coverage = self.cloud_coverage,
            .cloud_height = self.cloud_height,
        };
    }
};

pub const GameSession = struct {
    allocator: std.mem.Allocator,
    world: *World,
    world_map: WorldMap,
    map_controller: MapController,

    player: Player,
    inventory: Inventory,
    inventory_ui_state: inventory_ui.InventoryUI,
    block_outline: BlockOutline,
    hand_renderer: HandRenderer,
    camera: Camera, // References player camera, but we might want a decoupled camera if player is null (e.g. spectator) - for now keep it simple and match App

    ecs_registry: ECSRegistry,
    ecs_render_system: ECSRenderSystem,
    rhi: *RHI,

    atmosphere: Atmosphere,
    clouds: CloudState,

    creative_mode: bool,

    debug_show_fps: bool = false,
    debug_show_block_info: bool = false,
    debug_shadows: bool = false,
    debug_cascade_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, rhi: *RHI, atlas: *const TextureAtlas, seed: u64, render_distance: i32, lod_enabled: bool, generator_index: usize) !*GameSession {
        const session = try allocator.create(GameSession);

        const safe_mode_env = std.posix.getenv("ZIGCRAFT_SAFE_MODE");
        const safe_mode = if (safe_mode_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;
        const effective_render_distance: i32 = if (safe_mode) @min(render_distance, 8) else render_distance;
        const effective_lod_enabled = if (safe_mode) false else lod_enabled;

        if (safe_mode) {
            std.log.warn("ZIGCRAFT_SAFE_MODE enabled: render distance capped to {} and LOD disabled", .{effective_render_distance});
        }

        const lod_config = if (safe_mode)
            LODConfig{
                .radii = .{
                    @min(effective_render_distance, 8),
                    12,
                    24,
                    40,
                },
            }
        else
            LODConfig{
                .radii = .{
                    @min(effective_render_distance, 16),
                    40,
                    80,
                    160,
                },
            };

        const world = if (effective_lod_enabled)
            try World.initGenWithLOD(generator_index, allocator, effective_render_distance, seed, rhi.*, lod_config, atlas)
        else
            try World.initGen(generator_index, allocator, effective_render_distance, seed, rhi.*, atlas);

        const world_map = try WorldMap.init(rhi.*, 256, 256);

        // ecs_registry and ecs_render_system are initialized directly in the struct

        const player = Player.init(Vec3.init(8, 100, 8), true); // Default creative for now

        var atmosphere = Atmosphere.init();
        atmosphere.setTimeOfDay(0.25);

        session.* = .{
            .allocator = allocator,
            .world = world,
            .world_map = world_map,
            .map_controller = .{},
            .player = player,
            .inventory = Inventory.init(),
            .inventory_ui_state = .{},
            .block_outline = try BlockOutline.init(rhi.*),
            .hand_renderer = try HandRenderer.init(rhi.*),
            .camera = player.camera,
            .ecs_registry = ECSRegistry.init(allocator),
            .ecs_render_system = try ECSRenderSystem.init(rhi),
            .rhi = rhi,
            .atmosphere = atmosphere,
            .clouds = CloudState{},
            .creative_mode = true,
        };

        // Force map update initially
        session.map_controller.map_needs_update = true;

        // Spawn a test entity
        const test_entity = session.ecs_registry.create();
        try session.ecs_registry.transforms.set(test_entity, .{
            .position = Vec3.init(10, 120, 10), // Start high up
            .scale = Vec3.one,
        });
        try session.ecs_registry.physics.set(test_entity, .{
            .velocity = Vec3.zero,
            .aabb_size = Vec3.init(1.0, 1.0, 1.0),
            .use_gravity = true,
        });
        try session.ecs_registry.meshes.set(test_entity, .{
            .visible = true,
            .color = Vec3.init(1.0, 0.0, 0.0), // Red
        });

        return session;
    }

    pub fn deinit(self: *GameSession) void {
        self.ecs_render_system.deinit();
        self.ecs_registry.deinit();
        self.world.deinit();
        self.world_map.deinit();
        self.block_outline.deinit();
        self.hand_renderer.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *GameSession, dt: f32, total_time: f32, input: *Input, mapper: *const InputMapper, atlas: *TextureAtlas, window: anytype, paused: bool, skip_world: bool) !void {
        self.atmosphere.update(dt);
        self.clouds.update(dt);

        // Update Camera from Player
        self.camera = self.player.camera;

        const screen_w: f32 = @floatFromInt(input.window_width);
        const screen_h: f32 = @floatFromInt(input.window_height);

        if (!paused) {
            if (mapper.isActionPressed(input, .toggle_fps)) self.debug_show_fps = !self.debug_show_fps;
            if (mapper.isActionPressed(input, .toggle_block_info)) self.debug_show_block_info = !self.debug_show_block_info;
            if (mapper.isActionPressed(input, .toggle_shadows)) self.debug_shadows = !self.debug_shadows;
            if (self.debug_shadows and mapper.isActionPressed(input, .cycle_cascade)) self.debug_cascade_idx = (self.debug_cascade_idx + 1) % 3;
            if (mapper.isActionPressed(input, .toggle_time_scale)) {
                self.atmosphere.time.time_scale = if (self.atmosphere.time.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
            }
            if (mapper.isActionPressed(input, .toggle_creative)) {
                self.creative_mode = !self.creative_mode;
                self.player.setCreativeMode(self.creative_mode);
            }

            if (mapper.isActionPressed(input, .inventory)) {
                self.inventory_ui_state.toggle();
                input.setMouseCapture(window, !self.inventory_ui_state.visible);
            }

            if (!self.inventory_ui_state.visible) {
                if (mapper.isActionPressed(input, .slot_1)) self.inventory.selectSlot(0);
                if (mapper.isActionPressed(input, .slot_2)) self.inventory.selectSlot(1);
                if (mapper.isActionPressed(input, .slot_3)) self.inventory.selectSlot(2);
                if (mapper.isActionPressed(input, .slot_4)) self.inventory.selectSlot(3);
                if (mapper.isActionPressed(input, .slot_5)) self.inventory.selectSlot(4);
                if (mapper.isActionPressed(input, .slot_6)) self.inventory.selectSlot(5);
                if (mapper.isActionPressed(input, .slot_7)) self.inventory.selectSlot(6);
                if (mapper.isActionPressed(input, .slot_8)) self.inventory.selectSlot(7);
                if (mapper.isActionPressed(input, .slot_9)) self.inventory.selectSlot(8);
                if (input.scroll_y != 0) {
                    self.inventory.scrollSelection(@intFromFloat(input.scroll_y));
                }
            }

            if (self.map_controller.show_map) {
                self.map_controller.update(input, mapper, &self.camera, dt, window, screen_w, screen_h, self.world_map.width);
            } else if (!skip_world) {
                if (!self.inventory_ui_state.visible) {
                    self.player.update(input, mapper, self.world, dt, total_time);

                    // Handle interaction
                    if (mapper.isActionPressed(input, .interact_primary)) {
                        self.player.breakTargetBlock(self.world);
                        self.hand_renderer.swing();
                    }
                    if (mapper.isActionPressed(input, .interact_secondary)) {
                        if (self.inventory.getSelectedBlock()) |block_type| {
                            self.player.placeBlock(self.world, block_type);
                            self.hand_renderer.swing();
                        }
                    }
                }

                self.hand_renderer.update(dt);
                try self.hand_renderer.updateMesh(self.inventory, atlas);
            } else if (!self.world.paused) {
                self.world.pauseGeneration();
            }

            if (!skip_world) {
                try self.world.update(self.player.camera.position, dt);

                // ECS Updates
                ECSPhysicsSystem.update(&self.ecs_registry, self.world, dt);
            }
        }
    }

    pub fn renderEntities(self: *GameSession, camera_pos: Vec3) void {
        self.ecs_render_system.render(&self.ecs_registry, camera_pos);
    }

    pub fn drawHUD(self: *GameSession, ui: *UISystem, atlas: *const TextureAtlas, active_pack: ?[]const u8, fps: f32, screen_w: f32, screen_h: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) !void {
        if (self.map_controller.show_map) {
            try self.map_controller.draw(ui, screen_w, screen_h, &self.world_map, self.world.generator, self.camera.position, self.allocator);
            return;
        }

        if (self.debug_show_fps) {
            ui.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
            Font.drawNumber(ui, @intFromFloat(fps), 15, 15, Color.white);
        }

        const stats = self.world.getStats();
        const rs = self.world.getRenderStats();
        const pc = worldToChunk(@intFromFloat(self.camera.position.x), @intFromFloat(self.camera.position.z));
        const hy: f32 = 50.0;
        const fault_count = self.rhi.getFaultCount();
        const hud_h: f32 = if (fault_count > 0) 210 else 190;
        ui.drawRect(.{ .x = 10, .y = hy, .width = 220, .height = hud_h }, Color.rgba(0, 0, 0, 0.6));
        Font.drawText(ui, "POS:", 15, hy + 5, 1.5, Color.white);
        Font.drawNumber(ui, pc.chunk_x, 120, hy + 5, Color.white);
        Font.drawNumber(ui, pc.chunk_z, 170, hy + 5, Color.white);
        Font.drawText(ui, "CHUNKS:", 15, hy + 25, 1.5, Color.white);
        Font.drawNumber(ui, @intCast(stats.chunks_loaded), 140, hy + 25, Color.white);
        Font.drawText(ui, "VISIBLE:", 15, hy + 45, 1.5, Color.white);
        Font.drawNumber(ui, @intCast(rs.chunks_rendered), 140, hy + 45, Color.white);
        Font.drawText(ui, "QUEUED GEN:", 15, hy + 65, 1.5, Color.white);
        Font.drawNumber(ui, @intCast(stats.gen_queue), 140, hy + 65, Color.white);
        Font.drawText(ui, "QUEUED MESH:", 15, hy + 85, 1.5, Color.white);
        Font.drawNumber(ui, @intCast(stats.mesh_queue), 140, hy + 85, Color.white);
        Font.drawText(ui, "PENDING UP:", 15, hy + 105, 1.5, Color.white);
        Font.drawNumber(ui, @intCast(stats.upload_queue), 140, hy + 105, Color.white);
        const h = self.atmosphere.getHours();
        const hr = @as(i32, @intFromFloat(h));
        const mn = @as(i32, @intFromFloat((h - @as(f32, @floatFromInt(hr))) * 60.0));
        Font.drawText(ui, "TIME:", 15, hy + 125, 1.5, Color.white);
        Font.drawNumber(ui, hr, 100, hy + 125, Color.white);
        Font.drawText(ui, ":", 125, hy + 125, 1.5, Color.white);
        Font.drawNumber(ui, mn, 140, hy + 125, Color.white);
        Font.drawText(ui, "SUN:", 15, hy + 145, 1.5, Color.white);
        Font.drawNumber(ui, @intFromFloat(self.atmosphere.sun_intensity * 100.0), 100, hy + 145, Color.white);

        const px_i: i32 = @intFromFloat(self.camera.position.x);
        const pz_i: i32 = @intFromFloat(self.camera.position.z);
        const region = self.world.generator.getRegionInfo(px_i, pz_i);
        const c3 = region_pkg.getRoleColor(region.role);
        Font.drawText(ui, "ROLE:", 15, hy + 165, 1.5, Color.rgba(c3[0], c3[1], c3[2], 1.0));
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}", .{@tagName(region.role)}) catch "???";
        Font.drawText(ui, label, 100, hy + 165, 1.5, Color.white);

        if (fault_count > 0) {
            var buf_f: [32]u8 = undefined;
            const fault_text = std.fmt.bufPrint(&buf_f, "GPU FAULTS: {d}", .{fault_count}) catch "GPU FAULTS: ???";
            Font.drawText(ui, fault_text, 15, hy + 185, 1.5, Color.red);
        }

        if (self.debug_show_block_info) {
            if (self.player.target_block) |target| {
                const block_type = self.world.getBlock(target.x, target.y, target.z);
                const tiles = atlas.getTilesForBlock(@intFromEnum(block_type));
                const ux = screen_w - 350;
                var uy: f32 = 10;
                ui.drawRect(.{ .x = ux - 10, .y = uy, .width = 350, .height = 80 }, Color.rgba(0, 0, 0, 0.7));
                var buf2: [128]u8 = undefined;
                const pos_text = std.fmt.bufPrint(&buf2, "BLOCK: {s} ({}, {}, {})", .{ @tagName(block_type), target.x, target.y, target.z }) catch "BLOCK: ???";
                Font.drawText(ui, pos_text, ux, uy + 5, 1.5, Color.white);
                uy += 25;
                const tiles_text = std.fmt.bufPrint(&buf2, "TILES: T:{} B:{} S:{}", .{ tiles.top, tiles.bottom, tiles.side }) catch "TILES: ???";
                Font.drawText(ui, tiles_text, ux, uy + 5, 1.5, Color.white);
                uy += 25;
                const pack_name = if (active_pack) |ap| ap else "Default";
                const pack_text = std.fmt.bufPrint(&buf2, "PACK: {s}", .{pack_name}) catch "PACK: ???";
                Font.drawText(ui, pack_text, ux, uy + 5, 1.5, Color.white);
            }
        }

        if (!self.inventory_ui_state.visible) {
            const cx = screen_w / 2.0;
            const cy = screen_h / 2.0;
            ui.drawRect(.{ .x = cx - 10, .y = cy - 1, .width = 20, .height = 2 }, Color.white);
            ui.drawRect(.{ .x = cx - 1, .y = cy - 10, .width = 2, .height = 20 }, Color.white);
        }

        if (!self.inventory_ui_state.visible) hotbar.drawDefault(ui, &self.inventory, screen_w, screen_h);

        if (self.inventory_ui_state.visible) {
            const time_action = self.inventory_ui_state.draw(ui, &self.inventory, mouse_x, mouse_y, mouse_clicked, screen_w, screen_h);
            if (time_action) |time_idx| {
                const times = [_]f32{ 0.0, 0.25, 0.5, 0.75 };
                if (time_idx < 4) self.atmosphere.setTimeOfDay(times[time_idx]);
            }
        }

        if (self.creative_mode) {
            Font.drawText(ui, "CREATIVE", screen_w - 100, 10, 1.5, Color.rgba(100, 200, 255, 200));
            if (self.player.fly_mode) Font.drawText(ui, "FLYING", screen_w - 80, 25, 1.5, Color.rgba(150, 255, 150, 200));
        }
    }
};
