#version 410 core
in vec2 vUV;
uniform sampler2D uTex;
out vec4 FragColor;
void main() {
    vec4 c = texture(uTex, vUV);
    if (c.a < 0.02) discard;
    FragColor = c;
}
