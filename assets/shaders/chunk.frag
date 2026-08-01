#version 410 core
in vec2 vUV;
in float vLight;
in float vDist;

uniform sampler2D uTex;
uniform float uAlpha;
uniform vec3 uFogColor;
uniform float uFogStart;
uniform float uFogEnd;

out vec4 FragColor;

void main() {
    vec4 tex = texture(uTex, vUV);
    if (tex.a < 0.5) discard; // cutout support (unused while all blocks opaque)
    vec3 c = tex.rgb * vLight;
    float fog = clamp((vDist - uFogStart) / (uFogEnd - uFogStart), 0.0, 1.0);
    c = mix(c, uFogColor, fog);
    FragColor = vec4(c, uAlpha);
}
