#include <metal_stdlib>
using namespace metal;

// Keep this layout in sync with CurlUniforms in CurlRenderer.swift (96 bytes).
struct Uniforms {
    float4 paperTint;
    float4 viewTransform;   // ndc = book * xy + zw
    float2 quadSize;        // points
    float2 quadOffset;      // position of the quad's origin in leaf-local space (points)
    float2 axisPoint;       // curl axis point C (leaf-local)
    float2 axisNormal;      // unit normal n pointing toward the free edge
    float radius;           // cylinder radius (points)
    float flipX;            // +1 or -1 (mirrors the whole book)
    float mode;             // 0 = flat quad, 1 = curling leaf
    float backMode;         // 0 = back texture, 1 = ghost of the front, 2 = blank paper
    float shadow;           // strength of the shadow cast by the curl onto this quad
    float zBase;            // depth bias in points
    float tint;             // brightness multiplier
    float spineSide;        // 0 none, 1 spine at u=0, 2 spine at u=1
};

struct VertexIn {
    float2 uv;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float3 normal;
    float2 local;
    float angle;
};

vertex VertexOut page_vertex(uint vid [[vertex_id]],
                             const device VertexIn *verts [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    VertexOut o;
    float2 uv = verts[vid].uv;
    float2 p = uv * u.quadSize + u.quadOffset;   // leaf-local, before deformation
    float2 local = p;
    float z = 0.0;
    float3 nrm = float3(0.0, 0.0, 1.0);
    float angle = 0.0;
    if (u.mode > 0.5) {
        float d = dot(p - u.axisPoint, u.axisNormal);
        float r = max(u.radius, 0.05);
        if (d > 0.0) {
            if (d < M_PI_F * r) {
                angle = d / r;
                p = p - u.axisNormal * d + u.axisNormal * (r * sin(angle));
                z = r * (1.0 - cos(angle));
                nrm = float3(-u.axisNormal * sin(angle), cos(angle));
            } else {
                angle = M_PI_F;
                p = p - u.axisNormal * d - u.axisNormal * (d - M_PI_F * r);
                z = 2.0 * r;
                nrm = float3(0.0, 0.0, -1.0);
            }
        }
    }
    float2 book = float2(p.x * u.flipX, p.y);
    float2 ndc = book * u.viewTransform.xy + u.viewTransform.zw;
    float depth = 0.5 - (z + u.zBase) * 0.002;
    o.position = float4(ndc, depth, 1.0);
    o.uv = uv;
    o.normal = nrm;
    o.local = local;
    o.angle = angle;
    return o;
}

fragment float4 page_fragment(VertexOut in [[stage_in]],
                              bool frontFacing [[front_facing]],
                              texture2d<float> frontTex [[texture(0)]],
                              texture2d<float> backTex [[texture(1)]],
                              constant Uniforms &u [[buffer(1)]]) {
    constexpr sampler smp(mag_filter::linear, min_filter::linear, mip_filter::linear, address::clamp_to_edge);
    // Mirroring the book flips the winding, so undo that when deciding which side we see.
    bool isFront = (frontFacing == (u.flipX > 0.0));
    float uFront = (u.flipX < 0.0) ? (1.0 - in.uv.x) : in.uv.x;
    float2 tf = float2(uFront, in.uv.y);
    float3 n = normalize(in.normal);
    float4 color;
    bool showingBack = (u.mode > 0.5) && !isFront;
    if (showingBack) {
        n = -n;
        if (u.backMode < 0.5) {
            color = backTex.sample(smp, float2(1.0 - uFront, in.uv.y));
        } else if (u.backMode < 1.5) {
            float4 f = frontTex.sample(smp, tf);
            color = mix(u.paperTint, f, 0.10);
        } else {
            color = u.paperTint;
        }
    } else {
        color = frontTex.sample(smp, tf);
    }

    // Lighting: a flat page is exactly 1.0, tilted paper darkens or brightens around it.
    float3 L = normalize(float3(-0.38, -0.42, 0.82));
    float diff = dot(n, L);
    float light = 1.0 + 0.62 * (diff - L.z);
    float3 H = normalize(L + float3(0.0, 0.0, 1.0));
    float sheen = (in.angle > 0.01) ? pow(max(dot(n, H), 0.0), 48.0) * 0.09 : 0.0;

    // Spine gutter.
    float shade = 1.0;
    if (u.spineSide > 0.5) {
        float sd = (u.spineSide > 1.5) ? (1.0 - in.uv.x) : in.uv.x;
        shade *= 1.0 - 0.13 * (1.0 - smoothstep(0.0, 0.11, sd));
    }
    // Paper edge.
    float ex = min(in.uv.x, 1.0 - in.uv.x) * u.quadSize.x;
    float ey = min(in.uv.y, 1.0 - in.uv.y) * u.quadSize.y;
    float edge = min(ex, ey);
    shade *= 1.0 - 0.18 * (1.0 - smoothstep(0.0, 0.9, edge));

    // Shadow cast by the lifted paper onto the surface below.
    if (u.shadow > 0.0) {
        float d = dot(in.local - u.axisPoint, u.axisNormal);
        float ahead = d - u.radius;
        float w = u.radius * 1.8 + 16.0;
        float s = (d > 0.0) ? (1.0 - smoothstep(0.0, w, ahead)) : 0.0;
        shade *= 1.0 - u.shadow * s;
    }
    float3 rgb = color.rgb * light * shade * u.tint + sheen;
    return float4(rgb, 1.0);
}
