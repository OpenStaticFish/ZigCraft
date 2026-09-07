const std = @import("std");
const Vec3 = @import("zig-math").Vec3;
const Player = @import("game-core").player.Player;

test "Player initialization preserves spawn state and camera eye height" {
    const player = Player.init(Vec3.init(10, 100, 20), true);
    try std.testing.expectEqual(@as(f32, 10), player.position.x);
    try std.testing.expectEqual(@as(f32, 100), player.position.y);
    try std.testing.expectEqual(@as(f32, 20), player.position.z);
    try std.testing.expectEqual(@as(f32, 0), player.velocity.y);
    try std.testing.expect(player.fly_mode);
    try std.testing.expect(player.can_fly);
    try std.testing.expect(!player.noclip);
    try std.testing.expect(!player.is_grounded);
    try std.testing.expectEqual(@as(f32, 100 + Player.EYE_HEIGHT), player.camera.position.y);
    try std.testing.expect(player.target_block == null);
}

test "Player survival mode and creative mode manage flight" {
    var player = Player.init(Vec3.zero, false);
    try std.testing.expect(!player.fly_mode);
    try std.testing.expect(!player.can_fly);
    player.setCreativeMode(true);
    try std.testing.expect(player.fly_mode);
    try std.testing.expect(player.can_fly);
    player.toggleNoclip();
    try std.testing.expect(player.noclip);
    player.setCreativeMode(false);
    try std.testing.expect(!player.fly_mode);
    try std.testing.expect(!player.can_fly);
    try std.testing.expect(!player.noclip);
}

test "Player collision box and eye position follow player coordinates" {
    const player = Player.init(Vec3.init(100, 50, -30), true);
    const box = player.getAABB();
    try std.testing.expectApproxEqAbs(@as(f32, 100 - Player.WIDTH / 2.0), box.min.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50 + Player.HEIGHT), box.max.y, 0.0001);
    try std.testing.expectEqual(@as(f32, -30), player.getEyePosition().z);
}

test "Player constants remain usable gameplay values" {
    try std.testing.expect(Player.WIDTH > 0 and Player.WIDTH < 1);
    try std.testing.expect(Player.EYE_HEIGHT > 0 and Player.EYE_HEIGHT < Player.HEIGHT);
    try std.testing.expect(Player.WALK_SPEED > 0 and Player.FLY_SPEED > 0);
    try std.testing.expect(Player.GRAVITY > 0 and Player.JUMP_VELOCITY > 0);
}
