#version 410 core
in vec2 vUV;
uniform sampler2D uMap;
out vec4 FragColor;
void main() {
    FragColor = vec4(texture(uMap, vUV).rgb, 0.88);
}
