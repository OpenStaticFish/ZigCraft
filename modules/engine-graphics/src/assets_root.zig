pub const material_system = @import("material_system.zig");

test {
    _ = @import("assets_test_root.zig");
}
pub const resource_pack = @import("resource_pack.zig");
pub const texture_atlas = @import("texture_atlas.zig");

pub const MaterialSystem = material_system.MaterialSystem;
pub const BLOCK_TEXTURES = resource_pack.BLOCK_TEXTURES;
pub const LoadedTexture = resource_pack.LoadedTexture;
pub const LoadedTextureFloat = resource_pack.LoadedTextureFloat;
pub const PBRMapType = resource_pack.PBRMapType;
pub const PBRTextureSet = resource_pack.PBRTextureSet;
pub const PackInfo = resource_pack.PackInfo;
pub const ResourcePackManager = resource_pack.ResourcePackManager;
pub const TextureMapping = resource_pack.TextureMapping;
pub const ATLAS_SIZE = texture_atlas.ATLAS_SIZE;
pub const BlockTextureDefinition = texture_atlas.BlockTextureDefinition;
pub const DEFAULT_TILE_SIZE = texture_atlas.DEFAULT_TILE_SIZE;
pub const SUPPORTED_TILE_SIZES = texture_atlas.SUPPORTED_TILE_SIZES;
pub const TILE_SIZE = texture_atlas.TILE_SIZE;
pub const TILES_PER_ROW = texture_atlas.TILES_PER_ROW;
pub const TextureAtlas = texture_atlas.TextureAtlas;
