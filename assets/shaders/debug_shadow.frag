#version 330 core
out vec4 FragColor;
in vec2 vTexCoord;
uniform sampler2D uDepthMap;
void main() {
    float depth = texture(uDepthMap, vTexCoord).r;
    FragColor = vec4(vec3(depth), 1.0);
}
