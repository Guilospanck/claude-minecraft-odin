#version 410 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUV;
layout(location = 2) in float aShade;
layout(location = 3) in float aBlock;

uniform mat4 uMVP;
uniform vec3 uCamPos;

out vec2 vUV;
out float vShade;
out float vBlock;
out float vDist;

void main() {
    vUV = aUV;
    vShade = aShade;
    vBlock = aBlock;
    vDist = length(aPos - uCamPos);
    gl_Position = uMVP * vec4(aPos, 1.0);
}
