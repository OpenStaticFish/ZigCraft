#!/usr/bin/env python3
"""Shader contracts and exact FXAA sampled-image regression on CPU Vulkan.

Run inside the graphics devenv with the Lavapipe ICD explicitly selected, a
timeout, and the shared build lock. No window or surface is created. The FXAA
adapter supplies pixel-centre UVs and explicit base LOD (the input has one mip);
it executes the actual shader math, not a CPU reimplementation. It does not
replace raster/MSAA scene comparisons or test interpolator precision.
"""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
GRAPHICS = ROOT / 'modules/engine-graphics/src'


class ShaderOptimizationTests(unittest.TestCase):
    def test_sky_reverse_z_and_shared_main_pass_contract(self):
        sky = (ROOT / 'assets/shaders/vulkan/sky.vert').read_text()
        self.assertRegex(sky, r'gl_Position\s*=\s*vec4\(render_pos,\s*0\.0,\s*1\.0\)')
        pipeline = (GRAPHICS / 'vulkan/pipeline_manager.zig').read_text()
        self.assertIn('depth_stencil.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;', pipeline)
        self.assertIn('sky_depth_stencil.depthWriteEnable = c.VK_FALSE;', pipeline)
        self.assertIn('sky_depth_stencil = depth_stencil.*;', pipeline)
        graph = (GRAPHICS / 'render_graph.zig').read_text()
        self.assertRegex(graph, r'if \(!main_pass_started\.\*\) \{\s*ctx\.render_ctx\.beginMainPass\(\);')
        for name in ('OpaquePass', 'SkyPass', 'CloudPass'):
            body = graph.split('pub const ' + name + ' = struct {', 1)[1].split('pub fn pass', 1)[0]
            self.assertIn('.needs_main_pass = true,', body)
        render_system = (GRAPHICS / 'render_system.zig').read_text()
        self.assertIn('defer ctx.render_ctx.setTerrainPipelineBound(false);', render_system)
        order = re.findall(r'addPass\((?:self\.)?(\w+)_pass(?:\.pass\(\))?\)', render_system)
        start = order.index('cloud')
        self.assertEqual(order[start:start+4], ['cloud', 'opaque', 'late_sky', 'water'])

    def test_fxaa_one_to_one_base_level_contract(self):
        system = (GRAPHICS / 'vulkan/fxaa_system.zig').read_text()
        self.assertIn('image_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };', system)
        self.assertIn('image_info.mipLevels = 1;', system)
        passes = (GRAPHICS / 'vulkan/rhi_pass_orchestration.zig').read_text()
        fxaa = passes.split('pub fn beginFXAAPassInternal', 1)[1].split('pub fn beginUISwapchainPassInternal', 1)[0]
        self.assertIn('const extent = ctx.swapchain.getExtent();', fxaa)
        self.assertIn('.width = @floatFromInt(extent.width),', fxaa)
        self.assertIn('.height = @floatFromInt(extent.height),', fxaa)
        self.assertIn('.texel_size = .{ 1.0 / @as(f32, @floatFromInt(extent.width)), 1.0 / @as(f32, @floatFromInt(extent.height)) },', fxaa)

    def test_fxaa_exact_sampled_image_readback(self):
        with tempfile.TemporaryDirectory(prefix='zigcraft-fxaa-') as directory:
            directory = Path(directory)
            shaders = []
            for name, path in [('reference', ROOT / 'scripts/fixtures/fxaa_reference.frag'),
                               ('runtime', ROOT / 'assets/shaders/vulkan/fxaa.frag')]:
                source = path.read_text()
                source = source.replace('layout(location = 0) in vec2 inUV;', 'vec2 inUV;')
                source = source.replace('layout(location = 0) out vec4 outColor;', 'vec4 outColor;')
                source = source.replace('void main()', 'void evaluateFXAA()')
                source = source.replace('texture(uColorBuffer,', 'sampleBase(')
                source = source.replace('void evaluateFXAA()', 'vec4 sampleBase(vec2 uv) { return textureLod(uColorBuffer, uv, 0.0); }\nvoid evaluateFXAA()')
                source += '''
layout(local_size_x=8, local_size_y=8) in;
layout(set=0, binding=1, std430) buffer Output { vec4 pixels[]; } result;
void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 extent = textureSize(uColorBuffer, 0);
    if (any(greaterThanEqual(p, extent))) return;
    inUV = (vec2(p) + 0.5) / vec2(extent);
    evaluateFXAA();
    result.pixels[p.y * extent.x + p.x] = outColor;
}
'''
                output = directory / (name + '.spv')
                subprocess.run(['glslangValidator', '-V', '--stdin', '-S', 'comp', '-o', str(output)],
                               input=source, text=True, check=True, timeout=30)
                shaders.append(str(output))
            executable = directory / 'readback'
            subprocess.run(['cc', '-O2', str(ROOT / 'scripts/fxaa_readback_test.c'), '-o', str(executable), '-lvulkan', '-lm'],
                           check=True, timeout=60)
            for w, h in [(1, 1), (7, 5), (1280, 720), (1920, 1080), (1919, 1079)]:
                for color_space in ('unorm', 'srgb'):
                    with self.subTest(width=w, height=h, color_space=color_space):
                        subprocess.run([str(executable), *shaders, str(w), str(h), color_space], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
