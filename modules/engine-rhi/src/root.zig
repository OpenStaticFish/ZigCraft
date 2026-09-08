//! Render Hardware Interface for ZigCraft.
//!
//! This project currently ships a Vulkan-only renderer. The RHI keeps call sites
//! decoupled from the concrete Vulkan context where practical, but native handle
//! facets are explicitly Vulkan integration seams for systems that must talk to
//! Vulkan-shaped third-party APIs (compute, ImGui, LPV). They are not a portable
//! multi-backend contract.

const builtin = @import("builtin");

test {
    _ = @import("test_root.zig");
}

pub const rhi = @import("rhi.zig");
pub const interfaces = @import("interfaces.zig");
pub const wrappers = @import("wrappers.zig");
pub const rhi_types = @import("rhi_types.zig");
pub const culling = @import("culling.zig");
pub const render_device = @import("render_device.zig");
pub const render_settings = @import("render_settings.zig");
pub const texture = @import("texture.zig");
pub const world_contracts = @import("world_contracts.zig");
pub const rhi_contract_tests = if (builtin.is_test) @import("rhi_contract_tests.zig") else struct {};

pub const RhiError = rhi_types.RhiError;
pub const BufferHandle = rhi_types.BufferHandle;
pub const InvalidBufferHandle = rhi_types.InvalidBufferHandle;
pub const ShaderHandle = rhi_types.ShaderHandle;
pub const InvalidShaderHandle = rhi_types.InvalidShaderHandle;
pub const TextureHandle = rhi_types.TextureHandle;
pub const InvalidTextureHandle = rhi_types.InvalidTextureHandle;
pub const MAX_FRAMES_IN_FLIGHT = rhi_types.MAX_FRAMES_IN_FLIGHT;
pub const MAX_SWAPCHAIN_IMAGES = rhi_types.MAX_SWAPCHAIN_IMAGES;
pub const SHADOW_CASCADE_COUNT = rhi_types.SHADOW_CASCADE_COUNT;
pub const BufferUsage = rhi_types.BufferUsage;
pub const TextureFormat = rhi_types.TextureFormat;
pub const FilterMode = rhi_types.FilterMode;
pub const WrapMode = rhi_types.WrapMode;
pub const TextureConfig = rhi_types.TextureConfig;
pub const TextureAtlasHandles = rhi_types.TextureAtlasHandles;
pub const Vertex = rhi_types.Vertex;
pub const DrawMode = rhi_types.DrawMode;
pub const ShaderStageFlags = rhi_types.ShaderStageFlags;
pub const DrawIndirectCommand = rhi_types.DrawIndirectCommand;
pub const InstanceData = rhi_types.InstanceData;
pub const SkyParams = rhi_types.SkyParams;
pub const SkyPushConstants = rhi_types.SkyPushConstants;
pub const FrameRenderParams = rhi_types.FrameRenderParams;
pub const GlobalUniforms = rhi_types.GlobalUniforms;
pub const ShadowConfig = rhi_types.ShadowConfig;
pub const ShadowParams = rhi_types.ShadowParams;
pub const Color = rhi_types.Color;
pub const Rect = rhi_types.Rect;
pub const UVRect = rhi_types.UVRect;
pub const UiVertex = rhi_types.UiVertex;
pub const UiScissor = rhi_types.UiScissor;
pub const GpuTimingResults = rhi_types.GpuTimingResults;
pub const BLOOM_MIP_COUNT = rhi.BLOOM_MIP_COUNT;
pub const RenderResolution = rhi.RenderResolution;
pub const IResourceFactory = rhi.IResourceFactory;
pub const ResourceManager = rhi.ResourceManager;
pub const RenderContext = rhi.RenderContext;
pub const IShadowContext = rhi.IShadowContext;
pub const ShadowSystemWrapper = rhi.ShadowSystemWrapper;
pub const IWaterContext = rhi.IWaterContext;
pub const WaterSystemWrapper = rhi.WaterSystemWrapper;
pub const IUIContext = rhi.IUIContext;
pub const UIRenderer = rhi.UIRenderer;
pub const IGraphicsCommandEncoder = rhi.IGraphicsCommandEncoder;
pub const IRenderStateContext = rhi.IRenderStateContext;
pub const ISSAOContext = rhi.ISSAOContext;
pub const IDebugOverlayContext = rhi.IDebugOverlayContext;
pub const IRenderContext = rhi.IRenderContext;
pub const IPassOrchestrationContext = rhi.IPassOrchestrationContext;
pub const IPostProcessContext = rhi.IPostProcessContext;
pub const IRenderEffectsContext = rhi.IRenderEffectsContext;
pub const VulkanNativeHandles = rhi.VulkanNativeHandles;
pub const IDeviceQuery = rhi.IDeviceQuery;
pub const IDeviceTiming = rhi.IDeviceTiming;
pub const IRenderQualityOptions = rhi.IRenderQualityOptions;
pub const IDeviceRecovery = rhi.IDeviceRecovery;
pub const ICullingSystemFactory = rhi.ICullingSystemFactory;
pub const IScreenshotContext = rhi.IScreenshotContext;
pub const RHI = rhi.RHI;
pub const IWorldRenderView = world_contracts.IWorldRenderView;
pub const IShadowScene = world_contracts.IShadowScene;
pub const ILPVWorld = world_contracts.ILPVWorld;
pub const GpuLight = world_contracts.GpuLight;
pub const Texture = texture.Texture;
pub const Config = texture.Config;
pub const RenderSettingsAdapter = render_settings.RenderSettingsAdapter;
pub const ChunkCullData = culling.ChunkCullData;
pub const DispatchConfig = culling.DispatchConfig;
pub const ICullingSystem = culling.ICullingSystem;
pub const RenderDevice = render_device.RenderDevice;
pub const Stats = render_device.Stats;
pub const encodeColor = rhi_types.encodeColor;
pub const encodeNormal = rhi_types.encodeNormal;
pub const encodeMeta = rhi_types.encodeMeta;
pub const encodeBlocklight = rhi_types.encodeBlocklight;
