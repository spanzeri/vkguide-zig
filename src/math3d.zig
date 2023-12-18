const std = @import("std");

// FIXME: This is a temporary hack to deal with fabs being renamed abs in 0.12.0.
// Once 0.12 is officially released, we need to remove this
pub fn abs(f: anytype) callconv(.Inline) @TypeOf(f) {
    const type_info = @typeInfo(@TypeOf(f));
    if (type_info != .Float and type_info != .Int) {
        @compileError("Expected integer or floating point type");
    }

    return if (f < 0) -f else f;
}

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub const ZERO = make(0.0, 0.0);

    pub fn make(x: f32, y: f32) callconv(.Inline) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn to_vec3(self: Vec2, z: f32) callconv(.Inline) Vec3 {
        return .{ .x = self.x, .y = self.y, .z = z };
    }
};


pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    const Self = @This();

    pub const ZERO = make(0.0, 0.0, 0.0);

    pub fn make(x: f32, y: f32, z: f32) callconv(.Inline) Self {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn to_point4(self: Self) callconv(.Inline) Vec4 {
        return Vec4.make(self.x, self.y, self.z, 1.0);
    }

    pub fn to_vector4(self: Self) callconv(.Inline) Vec4 {
        return Vec4.make(self.x, self.y, self.z, 0.0);
    }

    pub fn to_vec4(self: Self, w: f32) callconv(.Inline) Vec4 {
        return Vec4.make(self.x, self.y, self.z, w);
    }

    pub fn squared_norm(self: Self) callconv(.Inline) f32 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }

    pub fn norm(self: Self) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn add(self: Self, other: Self) callconv(.Inline) Self {
        return make(self.x + other.x, self.y + other.y, self.z + other.z);
    }

    pub fn sub(self: Self, other: Self) callconv(.Inline) Self {
        return make(self.x - other.x, self.y - other.y, self.z - other.z);
    }

    pub fn mul(self: Self, other: f32) callconv(.Inline) Self {
        return make(self.x * other, self.y * other, self.z * other);
    }

    pub fn div(self: Self, other: f32) callconv(.Inline) Self {
        return make(self.x / other, self.y / other, self.z / other);
    }

    pub fn normalized(self: Self) callconv(.Inline) Self {
        const len = self.norm();
        return self.div(len);
    }

    pub fn dot(a: Self, b: Self) callconv(.Inline) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
};

pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub const ZERO = make(0.0, 0.0, 0.0, 0.0);

    // Those are not real thing, however, they match my preference for 3d coordinates:
    // - x is right;
    // - y is forward;
    // - z is up.
    // The coordinate system is right-handed.
    // This allows to use x,y coordinates as a 2d vector on the floor plane (so to speak).
    pub const UP = make(0.0, 0.0, 1.0, 0.0);
    pub const FORWARD = make(0.0, 1.0, 0.0, 0.0);
    pub const RIGHT = make(1.0, 0.0, 0.0, 0.0);

    const Self = @This();

    pub fn make(x: f32, y: f32, z: f32, w: f32) callconv(.Inline) Self {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn add(self: Self, other: Self) Self {
        // The result is going to be a point if either of the operands is a point.
        return make(
            self.x + other.x,
            self.y + other.y,
            self.z + other.z,
            if (self.w > 0 or other.w > 0) 1.0 else 0.0,
        );
    }

    pub fn nomalized(self: Self) Self {
        return self.to_vec3().normalized().to_vec4(self.w);
    }

    pub fn to_vec3(self: Self) Vec3 {
        return Vec3.make(self.x, self.y, self.z);
    }

    pub fn dot(a: Self, b: Self) callconv(.Inline) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
};

pub const Mat4 = struct {
    i: Vec4,
    j: Vec4,
    k: Vec4,
    t: Vec4,

    const Self = @This();

    pub const IDENTITY: Mat4 = make(
        Vec4.make(1.0, 0.0, 0.0, 0.0),
        Vec4.make(0.0, 1.0, 0.0, 0.0),
        Vec4.make(0.0, 0.0, 1.0, 0.0),
        Vec4.make(0.0, 0.0, 0.0, 1.0),
    );

    pub fn make(i: Vec4, j: Vec4, k: Vec4, t: Vec4) callconv(.Inline) Self {
        return .{ .i = i, .j = j, .k = k, .t = t };
    }

    /// Returns the transpose of the input matrix
    pub fn transposed(self: Self) Self {
        return make(
            Vec4.make(self.i.x, self.j.x, self.k.x, self.t.x),
            Vec4.make(self.i.y, self.j.y, self.k.y, self.t.y),
            Vec4.make(self.i.z, self.j.z, self.k.z, self.t.z),
            Vec4.make(self.i.w, self.j.w, self.k.w, self.t.w),
        );
    }

    pub fn mul(ma: Self, mb: Self) Self {
        return make(
            Vec4.make(
                ma.i.x * mb.i.x + ma.j.x * mb.i.y + ma.k.x * mb.i.z + ma.t.x * mb.i.w,
                ma.i.y * mb.i.x + ma.j.y * mb.i.y + ma.k.y * mb.i.z + ma.t.y * mb.i.w,
                ma.i.z * mb.i.x + ma.j.z * mb.i.y + ma.k.z * mb.i.z + ma.t.z * mb.i.w,
                ma.i.w * mb.i.x + ma.j.w * mb.i.y + ma.k.w * mb.i.z + ma.t.w * mb.i.w
            ),
            Vec4.make(
                ma.i.x * mb.j.x + ma.j.x * mb.j.y + ma.k.x * mb.j.z + ma.t.x * mb.j.w,
                ma.i.y * mb.j.x + ma.j.y * mb.j.y + ma.k.y * mb.j.z + ma.t.y * mb.j.w,
                ma.i.z * mb.j.x + ma.j.z * mb.j.y + ma.k.z * mb.j.z + ma.t.z * mb.j.w,
                ma.i.w * mb.j.x + ma.j.w * mb.j.y + ma.k.w * mb.j.z + ma.t.w * mb.j.w
            ),
            Vec4.make(
                ma.i.x * mb.k.x + ma.j.x * mb.k.y + ma.k.x * mb.k.z + ma.t.x * mb.k.w,
                ma.i.y * mb.k.x + ma.j.y * mb.k.y + ma.k.y * mb.k.z + ma.t.y * mb.k.w,
                ma.i.z * mb.k.x + ma.j.z * mb.k.y + ma.k.z * mb.k.z + ma.t.z * mb.k.w,
                ma.i.w * mb.k.x + ma.j.w * mb.k.y + ma.k.w * mb.k.z + ma.t.w * mb.k.w
            ),
            Vec4.make(
                ma.i.x * mb.t.x + ma.j.x * mb.t.y + ma.k.x * mb.t.z + ma.t.x * mb.t.w,
                ma.i.y * mb.t.x + ma.j.y * mb.t.y + ma.k.y * mb.t.z + ma.t.y * mb.t.w,
                ma.i.z * mb.t.x + ma.j.z * mb.t.y + ma.k.z * mb.t.z + ma.t.z * mb.t.w,
                ma.i.w * mb.t.x + ma.j.w * mb.t.y + ma.k.w * mb.t.z + ma.t.w * mb.t.w
            ),
        );
    }

    /// Create a translation matrix
    pub fn translation(v: Vec3) Mat4 {
        return make(
            Vec4.make(1.0, 0.0, 0.0, 0.0),
            Vec4.make(0.0, 1.0, 0.0, 0.0),
            Vec4.make(0.0, 0.0, 1.0, 0.0),
            v.to_point4(),
        );
    }

    /// Returns a new matrix obtained by translating the input one.
    pub fn translate(self: Self, v: Vec3) Self {
        return make(
            self.i,
            self.j,
            self.k,
            self.t.add(v.to_vector4()),
        );
    }

    /// Create a perspective projection matrix
    /// The result matrix is for a right-handed, zero to one, clipping space.
    pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        std.debug.assert(abs(aspect) > 0.0001);
        const f = 1.0 / @tan(fovy_rad / 2.0);

        return make(
            Vec4.make(f / aspect, 0.0, 0.0, 0.0),
            Vec4.make(0.0, f, 0.0, 0.0),
            Vec4.make(0.0, 0.0, far / (near - far), -1.0),
            Vec4.make(0.0, 0.0, -(far * near) / (far - near), 0.0),
        );
    }

    /// Create a rotation matrix around an arbitrary axis.
    // TODO: Add a faster version that assume the axis is normalized.
    pub fn rotation(axis: Vec3, angle_rad: f32) Mat4 {
        const c = @cos(angle_rad);
        const s = @sin(angle_rad);
        const t = 1.0 - c;

        const sqr_norm = axis.squared_norm();
        if (sqr_norm == 0.0) {
            return Mat4.IDENTITY;
        } else if (abs(sqr_norm - 1.0) > 0.0001) {
            const norm = @sqrt(sqr_norm);
            return rotation(axis.div(norm), angle_rad);
        }

        const x = axis.x;
        const y = axis.y;
        const z = axis.z;

        return make(
            Vec4.make(x * x * t + c, y * x * t + z * s, z * x * t - y * s, 0.0),
            Vec4.make(x * y * t - z * s, y * y * t + c, z * y * t + x * s, 0.0),
            Vec4.make(x * z * t + y * s, y * z * t - x * s, z * z * t + c, 0.0),
            Vec4.make(0.0, 0.0, 0.0, 1.0)
        );
    }

    ///Rotates a matrix around an arbitrary axis.
    // OPTIMIZE: We can work out the math to create the matrix directly.
    pub fn rotate(m: Mat4, axis: Vec3, angle_rad: f32) Mat4 {
        return mul(rotation(axis, angle_rad), m);
    }

    pub fn scale(v: Vec3) Mat4 {
        return make(
            Vec4.make(v.x, 0.0, 0.0, 0.0),
            Vec4.make(0.0, v.y, 0.0, 0.0),
            Vec4.make(0.0, 0.0, v.z, 0.0),
            Vec4.make(0.0, 0.0, 0.0, 1.0),
        );
    }
};
