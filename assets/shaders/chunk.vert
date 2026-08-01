#version 410 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUV;
layout(location = 2) in float aLight;

uniform mat4 uMVP;
uniform vec3 uCamPos;

out vec2 vUV;
out float vLight;
out float vDist;

void main() {
    vUV = aUV;
    vLight = aLight;
    vDist = length(aPos - uCamPos);
    gl_Position = uMVP * vec4(aPos, 1.0);
}
