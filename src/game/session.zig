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
const TerrainGenerator = @import("../world/worldgen/generator.zig").TerrainGenerator;

const ECSManager = @import("../engine/ecs/manager.zig");
const ECSRegistry = ECSManager.Registry;
const ECSComponents = @import("../engine/ecs/components.zig");
const ECSPhysicsSystem = @import("../engine/ecs/systems/physics.zig").PhysicsSystem;
const ECSRenderSystem = @import("../engine/ecs/systems/render.zig").RenderSystem;

pub const AtmosphereState = struct {
    world_ticks: u64 = 0,
    tick_accumulator: f32 = 0.0,
    time_scale: f32 = 1.0,
    time_of_day: f32 = 0.25,
    sun_intensity: f32 = 1.0,
    moon_intensity: f32 = 0.0,
    sun_dir: Vec3 = Vec3.init(0, 1, 0),
    moon_dir: Vec3 = Vec3.init(0, -1, 0),
    sky_color: Vec3 = Vec3.init(0.5, 0.7, 1.0),
    horizon_color: Vec3 = Vec3.init(0.8, 0.85, 0.95),
    sun_color: Vec3 = Vec3.init(1.0, 1.0, 1.0),
    fog_color: Vec3 = Vec3.init(0.6, 0.75, 0.95),
    ambient_intensity: f32 = 0.3,
    fog_density: f32 = 0.0015,
    fog_enabled: bool = true,
    orbit_tilt: f32 = 0.35,

    fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
        const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    fn lerpVec3(a: Vec3, b: Vec3, t: f32) Vec3 {
        return Vec3.init(
            std.math.lerp(a.x, b.x, t),
            std.math.lerp(a.y, b.y, t),
            std.math.lerp(a.z, b.z, t),
        );
    }

    pub fn update(self: *AtmosphereState, delta_time: f32) void {
        self.tick_accumulator += delta_time * 20.0 * self.time_scale;
        if (self.tick_accumulator >= 1.0) {
            const ticks_delta: u64 = @intFromFloat(self.tick_accumulator);
            self.world_ticks +%= ticks_delta;
            self.tick_accumulator -= @floatFromInt(ticks_delta);
        }

        const day_ticks = self.world_ticks % 24000;
        self.time_of_day = @as(f32, @floatFromInt(day_ticks)) / 24000.0;

        self.updateCelestialBodies();
        self.updateIntensities();
        self.updateColors();
    }

    fn updateCelestialBodies(self: *AtmosphereState) void {
        const sun_angle = self.time_of_day * std.math.tau;
        const cos_angle = @cos(sun_angle);
        const sin_angle = @sin(sun_angle);
        const cos_tilt = @cos(self.orbit_tilt);
        const sin_tilt = @sin(self.orbit_tilt);

        self.sun_dir = Vec3.init(
            sin_angle,
            -cos_angle * cos_tilt,
            -cos_angle * sin_tilt,
        ).normalize();
        self.moon_dir = self.sun_dir.scale(-1);
    }

    fn updateIntensities(self: *AtmosphereState) void {
        const t = self.time_of_day;
        const DAWN_START: f32 = 0.20;
        const DAWN_END: f32 = 0.30;
        const DUSK_START: f32 = 0.70;
        const DUSK_END: f32 = 0.80;

        if (t < DAWN_START) {
            self.sun_intensity = 0;
        } else if (t < DAWN_END) {
            self.sun_intensity = smoothstep(DAWN_START, DAWN_END, t);
        } else if (t < DUSK_START) {
            self.sun_intensity = 1.0;
        } else if (t < DUSK_END) {
            self.sun_intensity = 1.0 - smoothstep(DUSK_START, DUSK_END, t);
        } else {
            self.sun_intensity = 0;
        }

        self.moon_intensity = (1.0 - self.sun_intensity) * 0.15;
        const day_ambient: f32 = 0.45;
        const night_ambient: f32 = 0.15;
        self.ambient_intensity = std.math.lerp(night_ambient, day_ambient, self.sun_intensity);
    }

    fn updateColors(self: *AtmosphereState) void {
        const t = self.time_of_day;
        const DAWN_START: f32 = 0.20;
        const DAWN_END: f32 = 0.30;
        const DUSK_START: f32 = 0.70;
        const DUSK_END: f32 = 0.80;

        const day_sky = Vec3.init(0.4, 0.65, 1.0).toLinear();
        const day_horizon = Vec3.init(0.7, 0.8, 0.95).toLinear();
        const night_sky = Vec3.init(0.02, 0.02, 0.08).toLinear();
        const night_horizon = Vec3.init(0.05, 0.05, 0.12).toLinear();
        const dawn_sky = Vec3.init(0.25, 0.3, 0.5).toLinear();
        const dawn_horizon = Vec3.init(0.95, 0.55, 0.2).toLinear();
        const dusk_sky = Vec3.init(0.25, 0.3, 0.5).toLinear();
        const dusk_horizon = Vec3.init(0.95, 0.55, 0.2).toLinear();

        const day_sun = Vec3.init(1.0, 0.95, 0.9).toLinear();
        const dawn_sun = Vec3.init(1.0, 0.85, 0.6).toLinear();
        const dusk_sun = Vec3.init(1.0, 0.85, 0.6).toLinear();
        const night_sun = Vec3.init(0.04, 0.04, 0.1).toLinear();

        if (t < DAWN_START) {
            self.sky_color = night_sky;
            self.horizon_color = night_horizon;
            self.sun_color = night_sun;
        } else if (t < DAWN_END) {
            const blend = smoothstep(DAWN_START, DAWN_END, t);
            self.sky_color = lerpVec3(night_sky, dawn_sky, blend);
            self.horizon_color = lerpVec3(night_horizon, dawn_horizon, blend);
            self.sun_color = lerpVec3(night_sun, dawn_sun, blend);
        } else if (t < 0.35) {
            const blend = smoothstep(DAWN_END, 0.35, t);
            self.sky_color = lerpVec3(dawn_sky, day_sky, blend);
            self.horizon_color = lerpVec3(dawn_horizon, day_horizon, blend);
            self.sun_color = lerpVec3(dawn_sun, day_sun, blend);
        } else if (t < DUSK_START) {
            self.sky_color = day_sky;
            self.horizon_color = day_horizon;
            self.sun_color = day_sun;
        } else if (t < 0.75) {
            const blend = smoothstep(DUSK_START, 0.75, t);
            self.sky_color = lerpVec3(day_sky, dusk_sky, blend);
            self.horizon_color = lerpVec3(day_horizon, dusk_horizon, blend);
            self.sun_color = lerpVec3(day_sun, dusk_sun, blend);
        } else if (t < DUSK_END) {
            const blend = smoothstep(0.75, DUSK_END, t);
            self.sky_color = lerpVec3(dusk_sky, night_sky, blend);
            self.horizon_color = lerpVec3(dusk_horizon, night_horizon, blend);
            self.sun_color = lerpVec3(dusk_sun, night_sun, blend);
        } else {
            self.sky_color = night_sky;
            self.horizon_color = night_horizon;
            self.sun_color = night_sun;
        }

        self.fog_color = self.horizon_color;
        self.fog_density = std.math.lerp(0.0015, 0.0008, self.sun_intensity);
    }

    pub fn setTimeOfDay(self: *AtmosphereState, time: f32) void {
        self.world_ticks = @intFromFloat(time * 24000.0);
        self.time_of_day = time;
        self.tick_accumulator = 0;
        self.updateCelestialBodies();
        self.updateIntensities();
        self.updateColors();
    }

    pub fn getHours(self: *const AtmosphereState) f32 {
        return self.time_of_day * 24.0;
    }

    pub fn getSkyLightFactor(self: *const AtmosphereState) f32 {
        return @max(self.sun_intensity, self.moon_intensity);
    }
};

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

    atmosphere: AtmosphereState,
    clouds: CloudState,

    creative_mode: bool,

    debug_show_fps: bool = false,
    debug_show_block_info: bool = false,
    debug_shadows: bool = false,
    debug_cascade_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, rhi: *RHI, seed: u64, render_distance: i32, lod_enabled: bool) !*GameSession {
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
                .lod0_radius = @min(effective_render_distance, 8),
                .lod1_radius = 12,
                .lod2_radius = 24,
                .lod3_radius = 40,
            }
        else
            LODConfig{
                .lod0_radius = @min(effective_render_distance, 16),
                .lod1_radius = 40,
                .lod2_radius = 80,
                .lod3_radius = 160,
            };

        const world = if (effective_lod_enabled)
            try World.initWithLOD(allocator, effective_render_distance, seed, rhi.*, lod_config)
        else
            try World.init(allocator, effective_render_distance, seed, rhi.*);

        const world_map = WorldMap.init(rhi.*, 256, 256);

        // ecs_registry and ecs_render_system are initialized directly in the struct

        const player = Player.init(Vec3.init(8, 100, 8), true); // Default creative for now

        var atmosphere = AtmosphereState{};
        atmosphere.setTimeOfDay(0.25);

        session.* = .{
            .allocator = allocator,
            .world = world,
            .world_map = world_map,
            .map_controller = .{},
            .player = player,
            .inventory = Inventory.init(),
            .inventory_ui_state = .{},
            .block_outline = BlockOutline.init(rhi.*),
            .hand_renderer = HandRenderer.init(rhi.*),
            .camera = player.camera,
            .ecs_registry = ECSRegistry.init(allocator),
            .ecs_render_system = ECSRenderSystem.init(rhi),
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
                self.atmosphere.time_scale = if (self.atmosphere.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
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
                self.hand_renderer.updateMesh(self.inventory, atlas);
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

    pub fn drawHUD(self: *GameSession, ui: *UISystem, active_pack: ?[]const u8, fps: f32, screen_w: f32, screen_h: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) !void {
        if (self.map_controller.show_map) {
            try self.map_controller.draw(ui, screen_w, screen_h, &self.world_map, &self.world.generator, self.camera.position);
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
                const tiles = TextureAtlas.getTilesForBlock(@intFromEnum(block_type));
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
