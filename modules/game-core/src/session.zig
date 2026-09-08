//! Game session - handles active gameplay state.

const std = @import("std");
const Vec3 = @import("engine-math").Vec3;
const World = @import("world-runtime").World;
const IWorldSimulation = @import("world-runtime").IWorldSimulation;
const WorldMap = @import("world-worldgen").WorldMap;
const MapController = @import("map_controller.zig").MapController;
const Player = @import("player.zig").Player;
const Inventory = @import("inventory.zig").Inventory;
const inventory_ui = @import("ui/inventory_ui.zig");
const BlockOutline = @import("block_outline.zig").BlockOutline;
const HandRenderer = @import("hand_renderer.zig").HandRenderer;
const Camera = @import("engine-camera").Camera;
const RHI = @import("engine-rhi").RHI;
const RenderContext = @import("engine-rhi").RenderContext;
const Texture = @import("engine-rhi").Texture;
const TextureAtlas = @import("engine-graphics").TextureAtlas;
const Input = @import("engine-input").Input;
const IRawInputProvider = @import("engine-input").IRawInputProvider;
const log = @import("engine-core").log;
const runtime_env = @import("engine-core").runtime_env;
const input_mapper_pkg = @import("input_mapper.zig");
const InputMapper = input_mapper_pkg.InputMapper;
const IInputMapper = input_mapper_pkg.IInputMapper;
const GameAction = input_mapper_pkg.GameAction;

const CSM = @import("engine-graphics").csm;
const UISystem = @import("engine-ui").UISystem;
const session_hud = @import("ui/session_hud.zig");

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub const BuildConfig = struct {
    auto_world: []const u8 = "",
    chunk_debug_enable: []const u8 = "",
    chunk_debug_mode: bool = false,
    screenshot_path: []const u8 = "",
    shadow_test_scene: bool = false,
    shadow_test_variant: []const u8 = "cave-entrance",
    startup_diagnostic_seconds: u32 = 0,
};

const ECSManager = @import("engine-ecs").manager;
const ECSRegistry = ECSManager.Registry;
const ECSComponents = @import("engine-ecs").components;
const ECSPhysicsSystem = @import("engine-ecs").PhysicsSystem;
const ECSRenderSystem = @import("engine-ecs").RenderSystem;

const Atmosphere = @import("engine-atmosphere").Atmosphere;

const SpawnColumn = struct {
    x: i32,
    z: i32,
    info: @import("world-worldgen").ColumnInfo,
};

pub fn cameraFarPlaneForRenderDistance(render_distance_chunks: i32) f32 {
    const blocks: i64 = @max(render_distance_chunks, 1) * 16;
    return @floatFromInt(@max(blocks + 256, 10_000));
}

pub const GameSession = struct {
    pub const Persistence = union(enum) {
        transient,
        diagnostic,
        /// Borrowed only during init; SaveManager owns its own path copy.
        directory: []const u8,
    };
    allocator: std.mem.Allocator,
    world: *World,
    world_map: WorldMap,
    world_map_texture: Texture,
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

    creative_mode: bool,

    debug_show_fps: bool = false,
    debug_show_block_info: bool = false,
    debug_shadows: bool = false,
    debug_cascade_idx: usize = 0,
    build_config: BuildConfig = .{},

    pub fn init(allocator: std.mem.Allocator, rhi: *RHI, atlas: *const TextureAtlas, seed: u64, render_distance: i32, generator_index: usize, build_config: BuildConfig, persistence: Persistence) !*GameSession {
        const session = try allocator.create(GameSession);
        errdefer allocator.destroy(session);

        const safe_mode = runtime_env.safeModeEnabled();
        const strict_safe_mode = runtime_env.strictSafeModeEnabled();
        const effective_render_distance: i32 = render_distance;

        if (strict_safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: keeping render distance {} with reduced GPU pressure", .{effective_render_distance});
        } else if (safe_mode) {
            log.log.warn("Wayland stability profile active: keeping configured render distance {}", .{effective_render_distance});
        }
        if (build_config.chunk_debug_mode) {
            log.log.warn("CHUNK DEBUG MODE enabled: restore='{s}'", .{build_config.chunk_debug_enable});
        }

        session.* = undefined;

        const world = try World.init(.{
            .allocator = allocator,
            .render_distance = effective_render_distance,
            .seed = seed,
            .rhi = rhi.*,
            .atlas = atlas,
            .generator_index = generator_index,
            .save_dir_path = switch (persistence) {
                .transient => null,
                .diagnostic => getenv("ZIGCRAFT_SAVE_DIR"),
                .directory => |path| path,
            },
        });
        errdefer world.deinit();

        // Keep source texels near 1:1 with the fullscreen map on common
        // displays. At the default zoom this also samples one world block per
        // texel, so individual builds and canopy shapes remain visible.
        var world_map = try WorldMap.init(allocator, 1024, 1024);
        errdefer world_map.deinit();

        var world_map_texture = try Texture.initEmpty(rhi.resourceManager(), world_map.width, world_map.height, .rgba, .{
            .min_filter = .linear,
            .mag_filter = .linear,
            .generate_mipmaps = false,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        });
        errdefer world_map_texture.deinit();

        var block_outline = try BlockOutline.init(rhi.resourceManager());
        errdefer block_outline.deinit();

        var hand_renderer = try HandRenderer.init(rhi.resourceManager());
        errdefer hand_renderer.deinit();

        var ecs_render_system = try ECSRenderSystem.init(rhi.resourceManager());
        errdefer ecs_render_system.deinit();

        const world_sim = world.interface().simulation();
        const seed_spawn = findSpawnColumn(world_sim, build_config, 8, 8);
        const spawn = findActualSpawnColumn(world_sim, seed_spawn.x, seed_spawn.z) orelse seed_spawn;
        const spawn_y: f32 = @floatFromInt(spawn.info.height + 16);
        var player = Player.init(Vec3.init(@floatFromInt(spawn.x), spawn_y, @floatFromInt(spawn.z)), true);
        player.camera.far = cameraFarPlaneForRenderDistance(effective_render_distance);
        // Aim toward the terrain so the first frame shows the ground.
        player.camera.setYawPitch(player.camera.yaw, -std.math.degreesToRadians(35.0));

        var atmosphere = Atmosphere.init();
        atmosphere.setTimeOfDay(0.5);
        if (build_config.shadow_test_scene) {
            const scene = lightingBaselineScene(build_config.shadow_test_variant);
            atmosphere.setTimeOfDay(scene.time_of_day);
            atmosphere.time.time_scale = 0.0;
            player.position = scene.position;
            player.camera.position = player.getEyePosition();
            player.camera.setYawPitch(scene.yaw, scene.pitch);
        }

        session.* = .{
            .allocator = allocator,
            .world = world,
            .world_map = world_map,
            .world_map_texture = world_map_texture,
            .map_controller = .{},
            .player = player,
            .inventory = Inventory.init(),
            .inventory_ui_state = .{},
            .block_outline = block_outline,
            .hand_renderer = hand_renderer,
            .camera = player.camera,
            .ecs_registry = ECSRegistry.init(allocator),
            .ecs_render_system = ecs_render_system,
            .rhi = rhi,
            .atmosphere = atmosphere,
            .creative_mode = true,
            .build_config = build_config,
        };

        // Force map update initially
        session.map_controller.map_needs_update = true;

        return session;
    }

    pub fn deinit(self: *GameSession) void {
        self.ecs_render_system.deinit();
        self.ecs_registry.deinit();
        // The map worker reads the generator, so it must join before World.
        self.world_map.deinit();
        self.world.interface().deinit();
        self.world_map_texture.deinit();
        self.block_outline.deinit();
        self.hand_renderer.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *GameSession, dt: f32, total_time: f32, input: IRawInputProvider, mapper: IInputMapper, atlas: *TextureAtlas, window: anytype, paused: bool, skip_world: bool, benchmark_mode: bool) !void {
        self.atmosphere.update(dt);

        // Update Camera from Player
        self.camera = self.player.camera;

        const screen_w: f32 = @floatFromInt(input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(input.getWindowHeight());

        if (!paused) {
            if (benchmark_mode) {
                self.hand_renderer.update(dt);
                try self.hand_renderer.updateMesh(self.inventory, atlas);
            } else {
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
                    input.setMouseCapture(@ptrCast(@alignCast(window)), !self.inventory_ui_state.visible);
                }

                if (!self.inventory_ui_state.visible and !self.map_controller.show_map) {
                    if (mapper.isActionPressed(input, .slot_1)) self.inventory.selectSlot(0);
                    if (mapper.isActionPressed(input, .slot_2)) self.inventory.selectSlot(1);
                    if (mapper.isActionPressed(input, .slot_3)) self.inventory.selectSlot(2);
                    if (mapper.isActionPressed(input, .slot_4)) self.inventory.selectSlot(3);
                    if (mapper.isActionPressed(input, .slot_5)) self.inventory.selectSlot(4);
                    if (mapper.isActionPressed(input, .slot_6)) self.inventory.selectSlot(5);
                    if (mapper.isActionPressed(input, .slot_7)) self.inventory.selectSlot(6);
                    if (mapper.isActionPressed(input, .slot_8)) self.inventory.selectSlot(7);
                    if (mapper.isActionPressed(input, .slot_9)) self.inventory.selectSlot(8);
                    const scroll_y = input.getScrollDelta().y;
                    if (scroll_y != 0) {
                        self.inventory.scrollSelection(@intFromFloat(scroll_y));
                    }
                }

                self.map_controller.update(input, mapper, &self.camera, dt, window, screen_w, screen_h);

                if (self.map_controller.show_map) {
                    // map open – skip player/world update
                } else if (!skip_world) {
                    const world_sim = self.world.interface().simulation();
                    if (!self.inventory_ui_state.visible) {
                        self.player.update(input, mapper, world_sim, dt, total_time);

                        // Handle interaction
                        if (mapper.isActionPressed(input, .interact_primary)) {
                            self.player.breakTargetBlock(world_sim);
                            self.hand_renderer.swing();
                        }
                        if (mapper.isActionPressed(input, .interact_secondary)) {
                            if (self.inventory.getSelectedBlock()) |block_type| {
                                self.player.placeBlock(world_sim, block_type);
                                self.hand_renderer.swing();
                            }
                        }
                    }

                    self.hand_renderer.update(dt);
                    try self.hand_renderer.updateMesh(self.inventory, atlas);
                } else {
                    const world_sim = self.world.interface().simulation();
                    if (!world_sim.isPaused()) world_sim.pauseGeneration();
                }
            }

            if (!skip_world) {
                const world_sim = self.world.interface().simulation();
                try world_sim.update(self.player.camera.position, dt);

                // ECS Updates
                ECSPhysicsSystem.update(&self.ecs_registry, world_sim.collisionWorld(), dt);
            }
        }
    }

    pub fn renderEntities(self: *GameSession, ctx: RenderContext, camera_pos: Vec3) void {
        self.ecs_render_system.render(ctx, &self.ecs_registry, camera_pos);
    }

    pub fn renderEntityShadowCasters(self: *GameSession, ctx: RenderContext, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3) void {
        self.ecs_render_system.renderShadowCasters(ctx, &self.ecs_registry, camera_pos, caster_min, caster_max);
    }

    pub fn drawHUD(self: *GameSession, ui: *UISystem, atlas: *const TextureAtlas, active_pack: ?[]const u8, fps: f32, screen_w: f32, screen_h: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) !void {
        try session_hud.draw(self, ui, atlas, active_pack, fps, screen_w, screen_h, mouse_x, mouse_y, mouse_clicked);
    }
};

const LightingBaselineScene = struct {
    position: Vec3,
    yaw: f32,
    pitch: f32,
    time_of_day: f32,
};

fn lightingBaselineScene(name: []const u8) LightingBaselineScene {
    const forward_z = std.math.pi / 2.0;
    const slight_down = -std.math.degreesToRadians(8.0);

    if (std.ascii.eqlIgnoreCase(name, "low-sun")) return .{ .position = Vec3.init(0.0, 68.0, 18.0), .yaw = forward_z, .pitch = slight_down, .time_of_day = 0.30 };
    if (std.ascii.eqlIgnoreCase(name, "sealed-cave")) return .{ .position = Vec3.init(-25.0, 65.0, -4.0), .yaw = forward_z, .pitch = 0.0, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "rgb-emitter")) return .{ .position = Vec3.init(-46.0, 65.0, -5.0), .yaw = forward_z, .pitch = 0.0, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "foliage-cutout")) return .{ .position = Vec3.init(12.0, 67.0, 10.0), .yaw = forward_z, .pitch = slight_down, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "water")) return .{ .position = Vec3.init(25.0, 68.0, -12.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(18.0), .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "cross-chunk-corridor")) return .{ .position = Vec3.init(10.0, 65.0, 32.0), .yaw = 0.0, .pitch = 0.0, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "bend")) return .{ .position = Vec3.init(5.5, 65.0, -14.0), .yaw = forward_z, .pitch = slight_down, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "noon")) return .{ .position = Vec3.init(0.0, 68.0, 18.0), .yaw = forward_z, .pitch = slight_down, .time_of_day = 0.5 };
    return .{ .position = Vec3.init(0.0, 65.0, -16.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(5.0), .time_of_day = 0.5 };
}

fn chunkDebugRestoreEnabled(build_config: BuildConfig, name: []const u8) bool {
    if (!build_config.chunk_debug_mode) return false;

    var it = std.mem.tokenizeScalar(u8, build_config.chunk_debug_enable, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}

fn findSpawnColumn(world: IWorldSimulation, build_config: BuildConfig, default_x: i32, default_z: i32) SpawnColumn {
    const sea_level = 64;
    const default_info = world.getColumnInfo(default_x, default_z);
    const needs_dry_spawn = build_config.chunk_debug_mode and (chunkDebugRestoreEnabled(build_config, "water") or chunkDebugRestoreEnabled(build_config, "watergen") or chunkDebugRestoreEnabled(build_config, "waterrender"));
    if ((!needs_dry_spawn or (!default_info.is_ocean and default_info.height >= sea_level)) and isSpawnPatchStable(world, default_x, default_z, default_info, sea_level)) {
        return .{ .x = default_x, .z = default_z, .info = default_info };
    }

    var radius: i32 = 1;
    while (radius <= 64) : (radius += 1) {
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (@max(@abs(dx), @abs(dz)) != radius) continue;

                const x = default_x + dx;
                const z = default_z + dz;
                const info = world.getColumnInfo(x, z);
                if (!info.is_ocean and info.height >= sea_level and isSpawnPatchStable(world, x, z, info, sea_level)) {
                    log.log.info("Chunk debug water spawn moved from ({},{}) to ({},{})", .{ default_x, default_z, x, z });
                    return .{ .x = x, .z = z, .info = info };
                }
            }
        }
    }

    return .{ .x = default_x, .z = default_z, .info = default_info };
}

fn findActualSpawnColumn(world: IWorldSimulation, default_x: i32, default_z: i32) ?SpawnColumn {
    var radius: i32 = 0;
    while (radius <= 64) : (radius += 1) {
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (@max(@abs(dx), @abs(dz)) != radius) continue;

                const x = default_x + dx;
                const z = default_z + dz;
                const surface_y = findActualSurfaceY(world, x, z) orelse continue;
                const info = world.getColumnInfo(x, z);
                if (isActualSpawnAreaStable(world, x, z, surface_y)) {
                    if (x != default_x or z != default_z) {
                        log.log.info("Actual spawn moved from ({},{}) to ({},{})", .{ default_x, default_z, x, z });
                    }
                    return .{ .x = x, .z = z, .info = info };
                }
            }
        }
    }
    return null;
}

fn isActualSpawnAreaStable(world: IWorldSimulation, spawn_x: i32, spawn_z: i32, center_y: i32) bool {
    const patch_radius = 4;
    const step = 2;
    const max_height_delta = 4;

    var dz: i32 = -patch_radius;
    while (dz <= patch_radius) : (dz += step) {
        var dx: i32 = -patch_radius;
        while (dx <= patch_radius) : (dx += step) {
            const surface_y = findActualSurfaceY(world, spawn_x + dx, spawn_z + dz) orelse return false;
            if (@abs(surface_y - center_y) > max_height_delta) return false;
        }
    }
    return true;
}

fn findActualSurfaceY(world: IWorldSimulation, x: i32, z: i32) ?i32 {
    var y: i32 = 255;
    while (y >= 0) : (y -= 1) {
        const block = world.getBlock(x, y, z);
        switch (block) {
            .air,
            .water,
            .lava,
            .leaves,
            .mangrove_leaves,
            .jungle_leaves,
            .acacia_leaves,
            .birch_leaves,
            .spruce_leaves,
            .tall_grass,
            .flower_red,
            .flower_yellow,
            .dead_bush,
            .vine,
            .torch,
            .cactus,
            .bamboo,
            .acacia_sapling,
            .wood,
            .mangrove_log,
            .jungle_log,
            .acacia_log,
            .birch_log,
            .spruce_log,
            .mangrove_roots,
            .melon,
            => continue,
            else => return y,
        }
    }
    return null;
}

fn isSpawnPatchStable(world: IWorldSimulation, spawn_x: i32, spawn_z: i32, center_info: @import("world-worldgen").ColumnInfo, sea_level: i32) bool {
    if (!checkSpawnArea(world, spawn_x, spawn_z, center_info, sea_level, 1, 1, 2)) return false;
    if (!checkSpawnArea(world, spawn_x, spawn_z, center_info, sea_level, 8, 4, 8)) return false;
    return true;
}

fn checkSpawnArea(world: IWorldSimulation, spawn_x: i32, spawn_z: i32, center_info: @import("world-worldgen").ColumnInfo, sea_level: i32, radius: i32, step: i32, max_height_delta: i32) bool {
    var dz: i32 = -radius;
    while (dz <= radius) : (dz += step) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += step) {
            const info = world.getColumnInfo(spawn_x + dx, spawn_z + dz);
            if (info.is_ocean or info.height < sea_level) return false;
            if (@abs(info.height - center_info.height) > max_height_delta) return false;

            const surface_block = world.getBlock(spawn_x + dx, info.height, spawn_z + dz);
            if (surface_block == .air or surface_block == .water) return false;
        }
    }
    return true;
}
