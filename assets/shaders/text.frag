#version 410 core
in vec2 vUV;
uniform sampler2D uFont;
uniform vec4 uColor;
out vec4 FragColor;
void main() {
    float a = texture(uFont, vUV).r;
    FragColor = vec4(uColor.rgb, uColor.a * a);
}
