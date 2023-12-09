#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec3 color;

layout(location = 0) out vec3 out_color;

layout(set = 0, binding = 0) uniform UniformBufferObject {
	mat4 view;
	mat4 proj;
	mat4 view_proj;
} camera_data;

layout (push_constant) uniform PushConstants {
	vec4 data;
	mat4 render_matrix;
} push_constants;

void main() {
	mat4 transform = camera_data.view_proj * push_constants.render_matrix;
	gl_Position = transform * vec4(position, 1.0f);
	out_color = color;
}

