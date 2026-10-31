#include <metal_stdlib>
using namespace metal;

struct Instance {
    float4 rect;
    float4 clip;
    float4 uv;
    uint color;
    uint border_color;
    float radius;
    float border_width;
    uint mode;
    uint pad;
};

struct VOut {
    float4 pos [[position]];
    float2 world;
    float2 local;
    float2 size;
    float4 clip;
    float2 uv;
    float4 color;
    float4 border;
    float radius;
    float bw;
    uint mode [[flat]];
};

static float4 unpack(uint c) {
    return float4(float((c >> 24) & 255u), float((c >> 16) & 255u),
                  float((c >> 8) & 255u), float(c & 255u)) / 255.0;
}

vertex VOut vs(uint vid [[vertex_id]], uint iid [[instance_id]],
               constant Instance *instances [[buffer(0)]],
               constant float2 &viewport [[buffer(1)]]) {
    Instance in = instances[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 pos = in.rect.xy + corner * in.rect.zw;
    VOut o;
    o.pos = float4(pos / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.world = pos;
    o.local = corner * in.rect.zw;
    o.size = in.rect.zw;
    o.clip = in.clip;
    o.uv = mix(in.uv.xy, in.uv.zw, corner);
    o.color = unpack(in.color);
    o.border = unpack(in.border_color);
    o.radius = in.radius;
    o.bw = in.border_width;
    o.mode = in.mode;
    return o;
}

fragment float4 fs(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    if (in.world.x < in.clip.x || in.world.y < in.clip.y ||
        in.world.x > in.clip.z || in.world.y > in.clip.w) discard_fragment();
    if (in.mode == 1u) {
        constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
        float a = atlas.sample(s, in.uv).r * in.color.a;
        if (a < 0.002) discard_fragment();
        return float4(in.color.rgb, a);
    }
    float2 half_size = in.size * 0.5;
    float2 q = abs(in.local - half_size) - (half_size - float2(in.radius));
    float dist = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - in.radius;
    float cover = clamp(0.5 - dist, 0.0, 1.0);
    if (cover <= 0.0) discard_fragment();
    if (in.bw > 0.0) {
        float inner = clamp(0.5 - (dist + in.bw), 0.0, 1.0);
        float ring = cover - inner;
        float3 rgb = mix(in.color.rgb, in.border.rgb,
                         clamp(ring / max(cover, 0.0001), 0.0, 1.0));
        float a = max(in.color.a * inner, in.border.a * ring);
        if (a <= 0.0) discard_fragment();
        return float4(rgb, a);
    }
    return float4(in.color.rgb, in.color.a * cover);
}
