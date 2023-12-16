# VkGuide tutorial implemented in the zig programming language.

Vulkan book: [VulkanGuide](https://vkguide.dev/)
Zig language: [Zig](https://ziglang.org/)

![Screnshot](screenshot.png)

Most of the code is implemented from scratch in Zig. However, I kept some of
the original dependencies.

C/C++ dependencies:
 - Media layer: [SDL3](https://www.libsdl.org/)
 - Image loading: [stb_image.h](https://github.com/nothings/stb)
 - Vulkan Memory Allocator: [AMD VMA](https://gpuopen.com/vulkan-memory-allocator/)

In the future I might add [Dear ImGui](https://github.com/ocornut/imgui) if I decide
to continue with the extra chapters.

### Note:
I am not an experienced Zig programmer, and this code is not intended to be optimal or *idiomatic*.

Instead, this project served as an experiment and a valuable learning experience. Consequently, there are numerous aspects that could be enhanced, and I would approach certain parts differently if I were to rewrite it now.

## Build

This code has been compiled and run using Zig 0.11.0 and 0.12.0 (master branch at the
time of writing).

The code has been tested on Windows and Linux.

To run on MacOS it would need:
- MoltenVK;
- SDL3 compiled for Mac;

As I don't currently own a apple machine, I can't test it myself.

The sole system dependency is the Vulkan headers:
- This code has been compiled and executed using Zig versions 0.11.0 and 0.12.0 (master branch at the time of writing).

The code has undergone testing on both Windows and Linux. Unfortunately, I lack a MacOS system for testing, so some adjustments in the `build.zig` script might be necessary for it to run on MacOS.

The only system dependency is the Vulkan headers:
- On Linux, utilize your package manager to search for `vulkan-devel` package.
- On Windows, you can obtain the Vulkan SDK from [lunarg.com](https://www.lunarg.com/vulkan-sdk/).

___WARNING___: There's a known issue where shaders might not always recompile on change. As a precaution, until the issue is resolved, it's advisable to delete the `zig-cache` directory whenever shader code is modified!


## About the code:

### Boostrap

The basic functionalities of [vk-bootstrap](https://github.com/charles-lunarg/vk-bootstrap)
have been re-implemented from scratch in `vulkan_init.zig`.

Note that this is by no mean a complete and/or production-ready for vk-boostrap.

### GLM

The original tutorial code depends on [glm](https://github.com/g-truc/glm) for
matrices and vectors.

Instead, I rewrote just the linear algebra code I needed in `math3d.zig`.

### Obj loader

As for the previous 2 libraries, I decided to avoid depending on [tinyobjloader](https://github.com/tinyobjloader/tinyobjloader).

Enough of the library functionalities have been implemented from scratch in
`obj_loader.zig`.

As an additional bonus, the mesh loading code can perform basic triangulation
of n-gons, so it should be able to load any obj file without the original tutorial
limitation of triangular only meshes.

### C and C++ libraries

The other dependencies are included with the code and should work automatically.

- SDL3: I have compiled and pushed in the repository both the windows and linux library.
As SDL3 is experimental, most linux package managers don't provide it yet;
- VMA, stb_image: those are header only libraries. The headers can be found in the `thirdparty` directory. A .c or .cpp file for the implementation is provided in `src`
and compiled in the exe.

---

## Post-mortem and personal opinions:

This section provides an opinionated perspective on the project and the Zig language. Feel free to disagree or disregard this section entirely if it doesn't align with your views.

The motivation behind implementing the code from the book was to assess the viability of Zig as a language for game development. Specifically, the goal was to determine whether Zig could be a suitable choice for writing a game engine, comparing it against other languages such as C++, C, Rust, etc.

Throughout this experiment, several aspects were appreciated, but there were also a few pain points worth noting.

### Pros:
- build.zig:

One of the standout features of Zig, in my opinion, is its support for crafting a custom build system directly in the same language as the rest of the codebase. This capability is truly fantastic.

Build system range, in my opinion, from almost OK (cargo) to a complete dumpster
fire (everything that deals with C++).

While a cargo.toml file has a much gentler learning curve, Zig's build system
allows to do everything that C++ projects have to do either through dozen of scripts,
in some weird DSL (cmake) or through a completely custom build tool (Unreal Build Tool).

- The language design:

Zig distinguishes itself by being a very minimilast language.

Even counting the standard library and all the metaprogramming/compile time introspection 
features, the language only takes few days to learn and, in a few week, I felt
completely at home.

`build.zig` feels a bit more foregin, but while I was writing this code an official
[documentation page](https://ziglang.org/learn/build-system/) was released on the Zig website

However, compared to a similarly small language like C, Zig packs a lot more
punches. So many - in fact - that some of those features are not yet available
in the behemot of a language that C++ is (comptime and introspection are light years ahead
of the C++ counterpart).

The cost of being such a lean syntax is, sometimes, at the expense of some of
the syntactic sugar. Zig tends to be more verbose.

- C and C++ interoperability:

I knew, having used zig a little before, that directly including and using C
headers was possible.

I was also aware that zig could be used as a C/C++ build system.

I did not, however, know that you could simply add C and C++ files to an exe and
seamlessy build them alongside your zig code.

Other languages allow interfacing with C through bindings, but in zig you can just
drop your files in and add a line in build.zig.

This is major point in Zig's favour, especially as a game dev language, where so
many C and C++ libraries already exist.

- Language server:

While the quality of ZLS might not yet be on par with rust-analyzer or clangd,
it has signficantly improved since the last time I experimented with them.

There were few issues (see below), but at least for the first few days it has
worked seemlessy.

*Note:* The code was developed in neovim, using the zig.vim plugin and zls as LSP.

### Cons

- @import:

Imports in Zig are different than modules in other languages.

An imported file is a struct and lazily evaluated.

This has both positive and negatives effect on the way code is organised.

It allows for top level declarations inside a single file (you'll notice libary files
generally are snake_cased, while struct implementation files are UpperCased).

I don´t know the rationale that lead toward this design and I am sure there were
very good reasons, however it comes with a few drawbacks.

First, because of the string aliasing rules, @import names will conflict with
local variable names.

Say you have a file `mesh.zig` and import it as `const mesh = @import("mesh.zig");`.

If you then name a variable in your code `const mesh = mesh.load_from_file();` you'll
end up with a name conflict.

There might be ways to organize files and name imports that alleviate the issue,
but I haven't found one yet and it led to some awkward code.

If anyone has a good suggestion or naming scheme I would love to know.

- Syntactic sugar

There are few things that I would have liked the language to provide.

This are obviously my own personal preference and I am aware about Zig policy on
new language features.

1) Omit duplicated names while initializing a struct

```zig
const name = "Bob";
const age: u32 = 30;
const job = "Builder";
const Person = struct {
	name: []const u8,
	age: u32,
	occupation: []const u8,
};

// Current initialization syntax
const p1 = Person{ .name = name, .age = age, .occupation = job };

// Rust-like omission of member name if it matches the variable name
const p2 = Person{ name, age, .occupation = job };
```

In understand this change probably has some implication on the syntax and the
parsing of the language, but it's just nice to have.

2) Local functions:

I know this has been discussed in the community and the proposal was not approved.

I am also aware of the workaround using structs.

While I do understand the decision of not supporting closures, I think local functions
would be nice to have.

```zig
fn outer_func(nums: []i32) i32 {
	// This works
	const Doubler = struct {
		fn double(a: i32) i32 {
			return a * 2;
		}
	};
	const r1 = do_something_on_nums(nums, Doubler.double);

	// There is not way to do:
	const r2 = do_something_on_nums(nums, fn(a: i32) i32 { return a * 2; });
	// or
	const double = fn(a: i32) i32 { return a * 2; };
	const r3 = do_something_on_nums(nums, double);
}
```
The decision against this syntax was made to promote iterative code over functional
one.

I mostly agree with iterative code being more readable, but I believe functional
code is a tool and like every other tool has its place (sometimes).

3) Operator overloading and global name scope:

This is going to be the more controversial point.

99.9% of the time, operator overloading and dumping names in a global scope are
not good ideas.

The one (and only) expection is writing a 3d math library.

The absence of operators, combined with the @import discussed above and the lack
of function overloading makes math API awkward to write and use.

``` zig
// You either need to manually bring all the names out
const math_3d = @import("math3d.zig");
const Vec3 = math_3d.Vec3;
const vec3_add = math_3d.Vec3;
...
const a = Vec3{ .x = 0, .y = 0, .z = 1 };
const b = Vec3{ .x = 1, .y = 2, .z = 3 };
const c = vec3_add(a, b);

// Or make the functions members
const math_3d = @import("math3d.zig");
const Vec3 = math_3d.Vec3;
...
const a = Vec3{ .x = 0, .y = 0, .z = 1 };
const b = Vec3{ .x = 1, .y = 2, .z = 3 };
const c = Vec3.add(a, b);
const d = a.add(b);
const e = math_3d.Vec3.add(a, b);
```

None of those solutions are ideal.

The one I am more likely to use in the future is to make all the functions
members and expose the types as:
```zig
const math_3d = @import("math3d.zig");
const Vec3 = math_3d.Vec3;
const Vec3 = math_3d.Vec4;
const Mat4 = math_3d.Mat4;
```

But I find it cumbersome and it needs to be repeated in every file that needs
3d math.

**NOTE:** I am aware Zig provides a @Vector intrinsic.

Vector intrinsics are a great abstraction over simd code.

However, I prefer to choose when and when not to vectorize and focus on algorthms
rather than the shotgun approach of making every vector a simd data.

Finally, @Vector do not allow scalar operations (say multiplication with a f32),
which means you'll end up with a mixed API and awkward wrappers around them.

This is also my main concern about writing an engine potentially for someone to
use. While I might not mind as much C-style APIs, a lot of people won't be happy
to write gameplay code where they cannot add two positions with a plus operator.

4) Tooling:

This goes in both sections.

While ZLS has gotten a lot better, I still run into issues as my files got larger.

Eventually, I had to start using nvim text operations because the LSP would take
sometime minutes to respond to a code rename or a search by symbol.

This can probably be mitigated by better organising the code.

As I mentioned early on, I am not a zig expert and I am figuring out best practices
as I go.

Also, neither the language nor the LSP ar 1.0 yet, so I am sure it will get even
better over time.

5) Error reporting:

This has already improved a bit with Zig 0.12.

Zig has, in my opinion, succeded in making macros obsolete. All the library is
written in userland code and this is incredibly powerful.

However, that also means that everything that look like a function, is a function.

In particular, std.debug.assert will throw (reach `unreachable` code) and
break in the debugger inside the library code.

While it sounds minor, it would be such a better user experience if there was a
way for assert to break at the calling side rather than on some library code.

I remember Jai having some way to specify how far up the callstack to break,
something along that line would be awesome.

The same could be applied to @compileError and @panic.

If I forget a `{s}` inside my format string, I would love for the compiler to
point me at the actual print line rather than the fmt library code.

6) Interfaces:

This has been discussing extensively in the Zig community.

I would like to make the distinction here between runtime and compile time
interfaces.

The latter is used for runtime polymorphism and I am OK with Zig current approach
for things like std.mem.Allocator or iterators.

The former, can be used to specify at compile time the requirements for a type (e.g 
Rust interfaces or C++ concepts).

Zig current approach for generic arguments is to use anytype, which does not
provide any information to either the compiler or the person reading the code.

A combination of `@TypeOf` and `@typeInfo` and `comptime` code can be used to
limit and test the type of arguments that can be passed to a function.

This has the advantage of keeping the language smaller, but it is not without
drawbacks.

First, the type in a function signature still does not provide any information
to the person reading it.

The code to check the type is also quite noisy most of the times and can either:
 * Be written inline: which adds a lot of noise to the person reading the code;
 * Be moved to another function: which cause `@compileErrors` to fire potentially
 quite far from the place where someone is trying to use your function and be
 therefore difficult to read;

I guess if there was a way to specify an offset in the stack for a `@compileError`
to fire as discussed in the previous point, this issue could be solved with
userland code (or library code).

```zig
// Made up, pseudo-lib code
const MyInterface = std.meta.Interface(.{
	.Fn { "getName¨, []const u8, &.{} },
	.Fn { "addToAge", void, &.{ i32 } },
});

fn myFunc(a: anytype) void {
	comptime std.debug.assert(std.meta.isA(MyInterface, @TypeOf(a)));
}
```

This code, I believe, could be written in zig (or maybe it already exists somewhere
in the library and I haven´t found it yet), and it is fairly readable.

The error message would still start (and in 0.11.0 end) at the library code for
assert, as described in the previous point. But if this were to change, I think
it would make for a very good compromise. No changes to the compiler or syntax,
but more readable and informative code and errors.

## Conclusions

I know the con list seems to be a lot longer, but that is only because it is
easier to find negatives than it easy to find merits.

However, I do believe Zig is my favourite programming language available at the
moment and I do plan to keep using it for personal projects.

I love C, but is more barebone than a modern language needs to be.

Rust is an improvement over C++, but the language is still very complex and 
compilation time is awful.

C++ manage to be more complex than all of the above (maybe combined), have the
worst tooling and also awful compilation time.

It is the best tool we have had for gamedev and I have been using it for nearly
two decades (the second one profesionally), but I would be glad if we could move
on from it at this point, and Zig is a very strong contender.

Finally, Jai. I do not have beta access and it is not publicly available now,
but I am looking forward to give that a go too.
