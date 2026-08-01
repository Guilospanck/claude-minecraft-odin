#version 410 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in float aShade;
uniform mat4 uMVP;
out float vShade;
void main() {
    vShade = aShade;
    gl_Position = uMVP * vec4(aPos, 1.0);
}
