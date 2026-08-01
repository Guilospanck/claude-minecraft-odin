#version 410 core
in float vShade;
uniform vec3 uColor;
uniform float uAmbient;
out vec4 FragColor;
void main() {
    FragColor = vec4(uColor * vShade * uAmbient, 1.0);
}
