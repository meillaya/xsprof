#version 330 core
layout(location=0) in vec4 a_rect;
layout(location=1) in vec4 a_clip;
layout(location=2) in vec4 a_uv;
layout(location=3) in uint a_color;
layout(location=4) in uint a_border;
layout(location=5) in float a_radius;
layout(location=6) in float a_border_width;
layout(location=7) in uint a_mode;

uniform vec2 u_viewport;

out vec2 v_world;
out vec2 v_local;
out vec2 v_size;
out vec4 v_clip;
out vec2 v_uv;
out vec4 v_color;
out vec4 v_border;
out float v_radius;
out float v_bw;
flat out uint v_mode;

vec4 unpackColor(uint c) {
    return vec4(float((c >> 24) & 255u), float((c >> 16) & 255u),
                float((c >> 8) & 255u), float(c & 255u)) / 255.0;
}

void main() {
    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    vec2 pos = a_rect.xy + corner * a_rect.zw;
    vec2 ndc = vec2(pos.x / u_viewport.x * 2.0 - 1.0,
                    1.0 - pos.y / u_viewport.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_world = pos;
    v_local = corner * a_rect.zw;
    v_size = a_rect.zw;
    v_clip = a_clip;
    v_uv = a_uv.xy + corner * (a_uv.zw - a_uv.xy);
    v_color = unpackColor(a_color);
    v_border = unpackColor(a_border);
    v_radius = a_radius;
    v_bw = a_border_width;
    v_mode = a_mode;
}
