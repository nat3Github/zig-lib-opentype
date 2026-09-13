const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Font-discovery backends: each is an explicit, documented opt-in/out
    // build option (`zig build -h` lists them) rather than an implicit
    // "compiled whenever the target OS matches" gate. Defaults mirror the
    // native platform so a plain `zig build` keeps working, but any
    // consumer that only wants parsing/shaping/rasterization can pass
    // e.g. `-Dcore-text=false` to keep CoreFoundation/CoreText off their
    // link line on macOS.
    const enable_font_fallback = b.option(
        bool,
        "font-fallback",
        "Enable font fallback: the OS font-discovery backends below and the on-demand Noto web fallback (discovery.web_fallback). Off compiles none of them in, overriding the per-backend options",
    ) orelse true;

    // Declared unconditionally: a short-circuited b.option() would reject a
    // forwarded -Dfontconfig=... as an invalid option.
    const option_fontconfig = b.option(
        bool,
        "fontconfig",
        "Enable the Fontconfig font-discovery backend (Linux desktop; dlopen'd at runtime, adds no build-time library dependency)",
    ) orelse (target.result.os.tag == .linux and target.result.abi != .android);

    const option_core_text = b.option(
        bool,
        "core-text",
        "Enable the CoreText font-discovery backend (macOS/iOS; links CoreText + CoreFoundation)",
    ) orelse target.result.os.tag.isDarwin();

    const option_directwrite = b.option(
        bool,
        "directwrite",
        "Enable the DirectWrite font-discovery backend (Windows; links dwrite + ole32)",
    ) orelse (target.result.os.tag == .windows);

    const option_android = b.option(
        bool,
        "android",
        "Enable the Android font-discovery backend (parses /system/etc/fonts.xml, no system library)",
    ) orelse (target.result.abi == .android);

    const enable_fontconfig = enable_font_fallback and option_fontconfig;
    const enable_core_text = enable_font_fallback and option_core_text;
    const enable_directwrite = enable_font_fallback and option_directwrite;
    const enable_android = enable_font_fallback and option_android;

    const enable_manifest = b.option(
        bool,
        "manifest",
        "Enable the manifest font-discovery backend (matches a caller-supplied, already-fetched family->URL manifest; no system library, no fetch of its own, works on any target)",
    ) orelse true;

    // WOFF2 decoding needs a ported Brotli decoder plus its static
    // transform/dictionary tables, which are a meaningful binary-size cost
    // (the dictionary alone is on the order of 100 KiB before compression).
    // Off by default so consumers who never see woff2 fonts don't pay for
    // it; parseFont() falls back to error.Woff2NotSupported when disabled.
    const enable_woff2 = b.option(
        bool,
        "woff2",
        "Enable WOFF2 font decoding (ports a Brotli decoder + FreeType's woff2 transform tables; adds dictionary/prefix table size to the binary)",
    ) orelse false;

    const discovery_options = b.addOptions();
    discovery_options.addOption(bool, "font_fallback", enable_font_fallback);
    discovery_options.addOption(bool, "fontconfig", enable_fontconfig);
    discovery_options.addOption(bool, "core_text", enable_core_text);
    discovery_options.addOption(bool, "directwrite", enable_directwrite);
    discovery_options.addOption(bool, "android", enable_android);
    discovery_options.addOption(bool, "manifest", enable_manifest);
    discovery_options.addOption(bool, "woff2", enable_woff2);

    const mod = b.addModule("opentype", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", discovery_options);

    // CoreText's link-time dependency only applies when its backend is
    // enabled — see the option comment above.
    if (enable_core_text) {
        mod.linkFramework("CoreFoundation", .{});
        mod.linkFramework("CoreText", .{});
        mod.link_libc = true;
    }

    // Same rationale as CoreText: dwrite.lib/ole32.lib only get linked when
    // the DirectWrite backend is actually enabled.
    if (enable_directwrite) {
        mod.linkSystemLibrary("dwrite", .{});
        mod.linkSystemLibrary("ole32", .{});
        mod.link_libc = true;
    }

    // Fontconfig dlopens libfontconfig at runtime (src/discovery/fontconfig.zig)
    // and Android just parses a file on disk — neither has a build-time link
    // dependency, so `enable_fontconfig`/`enable_android` only gate whether
    // discovery.zig compiles their source in at all. The manifest backend
    // (src/discovery/manifest.zig) is the same, minus even the OS-specific
    // data source: it only matches a manifest the caller already fetched, so
    // it works identically on every target and defaults to on everywhere.

    // White-box unit tests (of private state) live alongside the
    // implementation in src/**. Black-box tests of the public API live in
    // tests/, kept out of src/ and out of this module's build.zig.zon
    // `.paths` so downstream consumers who `zig fetch` this module don't
    // pay for test source they'll never run. Integration, fixture-driven,
    // and differential tests live in the private parent repo's test/
    // directory and run against this module as a dependency.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    const enable_external_tests = b.option(
        bool,
        "tests",
        "Build tests/ (public-API black-box tests, absent from published module paths)",
    ) orelse true;

    if (enable_external_tests) {
        // Listed explicitly rather than discovered by directory iteration:
        // one new black-box test file is a one-line addition here anyway,
        // and it keeps this build script off std.fs's directory-walking API.
        const external_test_files = [_][]const u8{
            "tests/root_test.zig",
            "tests/cff_fixed_test.zig",
        };
        for (external_test_files) |path| {
            // tests/ is deliberately absent from build.zig.zon's `.paths`,
            // so a fetched (as opposed to locally-checked-out) copy of this
            // module won't have it — skip rather than error so `zig build
            // test` still works for a downstream consumer who fetched a
            // release instead of cloning the source tree.
            b.build_root.handle.access(b.graph.io, path, .{}) catch continue;
            const external_test = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(path),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            external_test.root_module.addImport("opentype", mod);
            test_step.dependOn(&b.addRunArtifact(external_test).step);
        }
    }
}
