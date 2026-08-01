#version 410 core
in float vShade;
uniform vec3 uColor;
out vec4 FragColor;
void main() {
    FragColor = vec4(uColor * vShade, 1.0);
}
