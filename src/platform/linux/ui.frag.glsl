#version 330 core
in vec2 v_world;
in vec2 v_local;
in vec2 v_size;
in vec4 v_clip;
in vec2 v_uv;
in vec4 v_color;
in vec4 v_border;
in float v_radius;
in float v_bw;
flat in uint v_mode;

uniform sampler2D u_atlas;
out vec4 outColor;

void main() {
    if (v_world.x < v_clip.x || v_world.y < v_clip.y ||
        v_world.x > v_clip.z || v_world.y > v_clip.w) discard;
    if (v_mode == 1u) {
        float a = texture(u_atlas, v_uv).r * v_color.a;
        if (a < 0.002) discard;
        outColor = vec4(v_color.rgb, a);
        return;
    }
    vec2 half_size = v_size * 0.5;
    vec2 q = abs(v_local - half_size) - (half_size - vec2(v_radius));
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - v_radius;
    float cover = clamp(0.5 - dist, 0.0, 1.0);
    if (cover <= 0.0) discard;
    if (v_bw > 0.0) {
        float inner = clamp(0.5 - (dist + v_bw), 0.0, 1.0);
        float ring = cover - inner;
        vec3 rgb = mix(v_color.rgb, v_border.rgb, clamp(ring / max(cover, 0.0001), 0.0, 1.0));
        float a = max(v_color.a * inner, v_border.a * ring);
        if (a <= 0.0) discard;
        outColor = vec4(rgb, a);
    } else {
        outColor = vec4(v_color.rgb, v_color.a * cover);
    }
}
