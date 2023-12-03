#version 450

layout(location = 0) in vec3 in_color;

layout(location = 0) out vec4 frag_color;

void main() {
	frag_color = vec4(in_color, 1.0f);
}

