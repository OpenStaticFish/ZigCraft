// Local-space clipping is independent of height and camera translation. Inset
// max edges are half-open; outer region edges are expanded by the CPU so their
// vertical faces/skirts remain owned by the region.
layout(location = 18) in vec2 vLODLocalXZ;
layout(location = 19) flat in vec4 vLODOwnershipBounds;
layout(location = 20) flat in vec2 vLODLocalNormalXZ;

void discardOutsideLODOwnership() {
    if (vLODOwnershipBounds.z <= vLODOwnershipBounds.x) return;
    // Surface positions are in model-local space, so use their local normals
    // rather than world/view normals. Only edge-facing normals move the probe;
    // horizontal surfaces retain the regular half-open partition.
    const float edge_epsilon = 0.001;
    vec2 probe = vLODLocalXZ;
    if (abs(vLODLocalXZ.x - vLODOwnershipBounds.x) <= edge_epsilon ||
        abs(vLODLocalXZ.x - vLODOwnershipBounds.z) <= edge_epsilon) {
        probe.x -= sign(vLODLocalNormalXZ.x) * edge_epsilon;
    }
    if (abs(vLODLocalXZ.y - vLODOwnershipBounds.y) <= edge_epsilon ||
        abs(vLODLocalXZ.y - vLODOwnershipBounds.w) <= edge_epsilon) {
        probe.y -= sign(vLODLocalNormalXZ.y) * edge_epsilon;
    }
    if (any(lessThan(probe, vLODOwnershipBounds.xy)) ||
        any(greaterThanEqual(probe, vLODOwnershipBounds.zw))) discard;
}
