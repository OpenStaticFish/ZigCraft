//! Generic Sparse Set storage for ECS components.

const std = @import("std");
const EntityId = @import("entity.zig").EntityId;

pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Dense array of components
        components: std.ArrayListUnmanaged(T),
        /// Dense array of entity IDs matching the components
        entities: std.ArrayListUnmanaged(EntityId),
        /// Sparse map from EntityId to index in dense arrays
        map: std.AutoHashMap(EntityId, usize),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .components = .{},
                .entities = .{},
                .map = std.AutoHashMap(EntityId, usize).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.components.deinit(self.allocator);
            self.entities.deinit(self.allocator);
            self.map.deinit();
        }

        pub fn has(self: Self, entity: EntityId) bool {
            return self.map.contains(entity);
        }

        pub fn get(self: Self, entity: EntityId) ?T {
            if (self.map.get(entity)) |index| {
                return self.components.items[index];
            }
            return null;
        }

        pub fn getPtr(self: Self, entity: EntityId) ?*T {
            if (self.map.get(entity)) |index| {
                return &self.components.items[index];
            }
            return null;
        }

        pub fn set(self: *Self, entity: EntityId, component: T) !void {
            if (self.map.get(entity)) |index| {
                // Update existing
                self.components.items[index] = component;
            } else {
                // Add new
                const index = self.components.items.len;
                try self.components.append(self.allocator, component);
                try self.entities.append(self.allocator, entity);
                try self.map.put(entity, index);
            }
        }

        pub fn remove(self: *Self, entity: EntityId) bool {
            if (self.map.get(entity)) |index| {
                // Swap with last element to keep dense
                const last_index = self.components.items.len - 1;
                const last_entity = self.entities.items[last_index];

                // Move last element to current slot
                self.components.items[index] = self.components.items[last_index];
                self.entities.items[index] = last_entity;

                // Update map for the moved entity
                if (self.map.getPtr(last_entity)) |last_index_ptr| {
                    last_index_ptr.* = index;
                }

                // Pop back
                _ = self.components.pop(self.allocator);
                _ = self.entities.pop(self.allocator);
                _ = self.map.remove(entity);
                return true;
            }
            return false;
        }

        pub fn clear(self: *Self) void {
            self.components.clearRetainingCapacity();
            self.entities.clearRetainingCapacity();
            self.map.clearRetainingCapacity();
        }
    };
}
