#version 450

void main() {
	const vec3 postions[3] = vec3[3](
		vec3( 1.0f,  1.0f, 0.0f),
		vec3(-1.0f,	 1.0f, 0.0f),
		vec3( 0.0f, -1.0f, 0.0f)
	);

	gl_Position = vec4(postions[gl_VertexIndex], 1.0f);
}
