#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec3 color;

layout(location = 0) out vec3 out_color;

layout (push_constant) uniform PushConstants {
	vec4 data;
	mat4 render_matrix;
} push_constants;

void main() {
	gl_Position = push_constants.render_matrix * vec4(position, 1.0f);
	out_color = color;
}

