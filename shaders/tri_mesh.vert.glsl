#version 460

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec3 color;
layout(location = 3) in vec2 uv;

layout(location = 0) out vec3 out_color;
layout(location = 1) out vec2 out_uv;

layout(set = 0, binding = 0) uniform UniformBufferObject {
	mat4 view;
	mat4 proj;
	mat4 view_proj;
} camera_data;

struct ObjectData {
	mat4 model;
};

layout(std140, set = 1, binding = 0) readonly buffer ObjectBuffer {
	ObjectData objects[];
} object_buffer;

layout (push_constant) uniform PushConstants {
	vec4 data;
	mat4 render_matrix;
} push_constants;

void main() {
	mat4 transform = camera_data.view_proj * object_buffer.objects[gl_BaseInstance].model;
	gl_Position = transform * vec4(position, 1.0f);
	out_uv = uv;
	out_color = color;
}

