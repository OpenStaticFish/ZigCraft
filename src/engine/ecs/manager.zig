//! ECS Registry/Manager.

const std = @import("std");
const EntityId = @import("entity.zig").EntityId;
const ComponentStorage = @import("storage.zig").ComponentStorage;
const components = @import("components.zig");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    next_entity_id: EntityId = 1,

    // Component Storages
    transforms: ComponentStorage(components.Transform),
    physics: ComponentStorage(components.Physics),
    meshes: ComponentStorage(components.Mesh),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .transforms = ComponentStorage(components.Transform).init(allocator),
            .physics = ComponentStorage(components.Physics).init(allocator),
            .meshes = ComponentStorage(components.Mesh).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.transforms.deinit();
        self.physics.deinit();
        self.meshes.deinit();
    }

    pub fn create(self: *Registry) EntityId {
        const id = self.next_entity_id;
        // Check for overflow (extremely unlikely but good practice)
        if (self.next_entity_id == std.math.maxInt(EntityId)) {
            @panic("Entity ID overflow");
        }
        self.next_entity_id += 1;
        return id;
    }

    pub fn destroy(self: *Registry, entity: EntityId) void {
        _ = self.transforms.remove(entity);
        _ = self.physics.remove(entity);
        _ = self.meshes.remove(entity);
    }

    pub fn clear(self: *Registry) void {
        self.transforms.clear();
        self.physics.clear();
        self.meshes.clear();
        self.next_entity_id = 1;
    }
};
