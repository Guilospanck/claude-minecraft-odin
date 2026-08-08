#version 410 core
uniform vec4 uColor;
in float vShade;
out vec4 FragColor;
void main() {
    FragColor = vec4(uColor.rgb * vShade, uColor.a);
}
