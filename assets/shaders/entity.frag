#version 410 core
in float vShade;
uniform vec3 uColor;
uniform float uAmbient;
uniform float uFlash; // 0 = normal, 1 = full red "just got hit" blink
out vec4 FragColor;
void main() {
    vec3 c = uColor * vShade * uAmbient;
    c = mix(c, vec3(1.0, 0.18, 0.14), uFlash); // MC-style red damage tint
    FragColor = vec4(c, 1.0);
}
