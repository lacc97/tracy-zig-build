const std = @import("std");

pub fn build(b: *std.Build) void {
    const target: std.Build.ResolvedTarget = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    if (target.result.cpu.arch.endian() != .little) @panic("tracy is only supported on little-endian architectures");

    const strip_binary = b.option(bool, "strip", "Strip output binaries") orelse false;
    const build_shared = b.option(bool, "tracy_shared_libs", "Build tracy as a shared library") orelse false;

    const tracy_options = enableOptions(b);

    const capstone_dep = b.dependency("capstone", .{ .target = target, .optimize = optimize });
    const capstone_lib = capstone_dep.artifact("capstone");

    const tracy_lib = tracy_lib_blk: {
        const lib = std.Build.Step.Compile.create(b, .{
            .name = "tracy",
            .kind = .lib,
            .linkage = if (build_shared) .dynamic else .static,
            .root_module = .{
                .target = target,
                .optimize = optimize,
            },
        });
        if (lib.isDynamicLibrary()) lib.root_module.addCMacro("TRACY_EXPORTS", "");
        inline for (options_spec) |spec| if (@field(tracy_options, spec[0])) {
            const define = comptime &asciiUpperStringComptime("tracy_" ++ spec[0]);
            lib.root_module.addCMacro(define, "");
        };
        lib.root_module.addCSourceFiles(.{
            .root = b.path("upstream"),
            .files = &.{"public/TracyClient.cpp"},
            .flags = &.{"-std=c++11"},
        });
        lib.root_module.link_libc = true;
        lib.root_module.link_libcpp = true;
        lib.root_module.strip = true;
        installTracyHeaders(b, lib);
        b.installArtifact(lib);
        break :tracy_lib_blk lib;
    };
    _ = tracy_lib; // autofix

    const zstd_lib = zstd_lib_blk: {
        const lib = b.addStaticLibrary(.{
            .name = "zstd",
            .target = target,
            .optimize = optimize,
        });
        lib.root_module.addCMacro("ZSTD_DISABLE_ASM", "");
        lib.root_module.addCSourceFiles(.{
            .root = b.path("upstream"),
            .files = &zstd_sources,
            .flags = &base_c_flags,
        });
        lib.root_module.link_libc = true;

        break :zstd_lib_blk lib;
    };

    const server_lib = server_lib_blk: {
        const lib = b.addStaticLibrary(.{
            .name = "tracy-server",
            .target = target,
            .optimize = optimize,
        });
        lib.root_module.addCMacro("NO_PARALLEL_SORT", ""); // TODO: needs tbb dependency
        // lib.root_module.addCMacro("TRACY_NO_STATISTICS", ""); // TODO: make this an option
        lib.root_module.addCSourceFiles(.{
            .root = b.path("upstream"),
            .files = &.{
                "public/common/tracy_lz4.cpp",
                "public/common/tracy_lz4hc.cpp",
                "public/common/TracySocket.cpp",
                "public/common/TracyStackFrames.cpp",
                "public/common/TracySystem.cpp",

                "server/TracyMemory.cpp",
                "server/TracyMmap.cpp",
                "server/TracyPrint.cpp",
                "server/TracySysUtil.cpp",
                "server/TracyTaskDispatch.cpp",
                "server/TracyTextureCompression.cpp",
                "server/TracyThreadCompress.cpp",
                "server/TracyWorker.cpp",
            },
            .flags = &base_cxx_flags,
        });
        lib.root_module.link_libc = true;
        lib.root_module.link_libcpp = true;
        lib.root_module.linkLibrary(capstone_lib);
        lib.root_module.addIncludePath(getInstallRelativePath(b, capstone_lib, "capstone"));
        lib.root_module.linkLibrary(zstd_lib);

        break :server_lib_blk lib;
    };

    const capture_exe = capture_exe_blk: {
        const exe = b.addExecutable(.{
            .name = "tracy-capture",
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addCMacro("NO_PARALLEL_SORT", ""); // TODO: needs tbb dependency
        exe.root_module.addCSourceFiles(.{
            .root = b.path("upstream"),
            .files = &.{"capture/src/capture.cpp"},
            .flags = &base_cxx_flags,
        });
        exe.root_module.linkLibrary(server_lib);
        if (strip_binary) exe.root_module.strip = true;
        b.installArtifact(exe);
        break :capture_exe_blk exe;
    };
    _ = capture_exe; // autofix
}

const Options = blk: {
    var struct_fields: [options_spec.len]std.builtin.Type.StructField = undefined;
    for (options_spec, &struct_fields) |spec, *f|
        f.* = .{
            .name = spec[0],
            .type = bool,
            .default_value = &spec[1],
            .is_comptime = false,
            .alignment = 0,
        };
    break :blk @Type(.{ .Struct = std.builtin.Type.Struct{
        .layout = .auto,
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};
const options_spec = .{
    .{ "enable", true, "Enable profiling" },
    .{ "on_demand", false, "On-demand profiling" },
    .{ "callstack", false, "Enfore callstack collection for tracy regions" },
    .{ "no_callstack", false, "Disable all callstack related functionality" },
    .{ "no_callstack_inlines", false, "Disables the inline functions in callstacks" },
    .{ "only_localhost", false, "Only listen on the localhost interface" },
    .{ "no_broadcast", false, "Disable client discovery by broadcast to local network" },
    .{ "only_ipv4", true, "Tracy will only accept connections on IPv4 addresses (disable IPv6)" },
    .{ "no_code_transfer", false, "Disable collection of source code" },
    .{ "no_context_switch", false, "Disable capture of context switches" },
    .{ "no_exit", false, "Client executable does not exit until all profile data is sent to server" },
    .{ "no_sampling", false, "Disable call stack sampling" },
    .{ "no_verify", false, "Disable zone validation for C API" },
    .{ "no_vsync_capture", false, "Disable capture of hardware Vsync events" },
    .{ "no_frame_image", true, "Disable the frame image support and its thread" },
    .{ "no_system_tracing", false, "Disable systrace sampling" },
    .{ "timer_fallback", false, "Use lower resolution timers" },
    .{ "delayed_init", false, "Enable delayed initialization of the library (init on first call)" },
    .{ "manual_lifetime", false, "Enable the manual lifetime management of the profile" },
    .{ "fibers", false, "Enable fibers support" },
    .{ "no_crash_handler", true, "Disable crash handling" },
};
fn enableOptions(b: *std.Build) Options {
    var options: Options = .{};
    inline for (options_spec) |spec| {
        if (b.option(bool, "tracy_" ++ spec[0], spec[2])) |enabled| {
            @field(options, spec[0]) = enabled;
        }
    }
    return options;
}

// Postprocesses the tracy headers so they work in a nicer single directory structure.
fn installTracyHeaders(b: *std.Build, lib: *std.Build.Step.Compile) void {
    const headers_wf = b.addWriteFiles();

    inline for (public_header_files) |h| {
        // TODO: cross platform (don't use sed, define separate step to process the header files in zig)
        const sed_cmd = b.addSystemCommand(&.{"sed"});
        sed_cmd.addArgs(&.{ "-e", "s|#include \"../client|#include \"./client|" });
        sed_cmd.addArgs(&.{ "-e", "s|#include \"../common|#include \"./common|" });
        sed_cmd.addFileArg(b.path("upstream/public/tracy/" ++ h));
        _ = headers_wf.addCopyFile(sed_cmd.captureStdOut(), h);
    }

    lib.installHeadersDirectory(
        b.path("upstream/public/client"),
        "tracy/client",
        .{ .include_extensions = &.{ ".h", ".hpp" } },
    );
    lib.installHeadersDirectory(
        b.path("upstream/public/common"),
        "tracy/common",
        .{ .include_extensions = &.{ ".h", ".hpp" } },
    );
    lib.installHeadersDirectory(
        headers_wf.getDirectory(),
        "tracy",
        .{},
    );
}

const base_c_flags = [_][]const u8{
    "-std=c99",
};
const base_cxx_flags = [_][]const u8{
    "-std=c++20",
};

const public_header_files = [_][]const u8{
    "TracyC.h",
    "TracyD3D11.hpp",
    "TracyD3D12.hpp",
    "Tracy.hpp",
    "TracyLua.hpp",
    "TracyOpenCL.hpp",
    "TracyOpenGL.hpp",
    "TracyVulkan.hpp",
};

const common_sources = [_][]const u8{
    "public/common/tracy_lz4.cpp",
    "public/common/tracy_lz4hc.cpp",
    "public/common/TracySocket.cpp",
    "public/common/TracyStackFrames.cpp",
    "public/common/TracySystem.cpp",
};

const capture_sources = common_sources ++ [_][]const u8{
    "capture/src/capture.cpp",

    "server/TracyMemory.cpp",
    "server/TracyMmap.cpp",
    "server/TracyPrint.cpp",
    "server/TracyTaskDispatch.cpp",
    "server/TracyTextureCompression.cpp",
    "server/TracyThreadCompress.cpp",
    "server/TracyWorker.cpp",
};

const profiler_cxx_sources = common_sources ++ [_][]const u8{
    "profiler/src/ConnectionHistory.cpp",
    "profiler/src/Filters.cpp",
    "profiler/src/Fonts.cpp",
    "profiler/src/HttpRequest.cpp",
    "profiler/src/ImGuiContext.cpp",
    "profiler/src/imgui/imgui_impl_opengl3.cpp",
    "profiler/src/IsElevated.cpp",
    "profiler/src/main.cpp",
    "profiler/src/ResolvService.cpp",
    "profiler/src/RunQueue.cpp",
    "profiler/src/WindowPosition.cpp",
    "profiler/src/winmain.cpp",
    "profiler/src/winmainArchDiscovery.cpp",

    "server/TracyBadVersion.cpp",
    "server/TracyColor.cpp",
    "server/TracyEventDebug.cpp",
    "server/TracyFileselector.cpp",
    "server/TracyFilesystem.cpp",
    "server/TracyImGui.cpp",
    "server/TracyMemory.cpp",
    "server/TracyMicroArchitecture.cpp",
    "server/TracyMmap.cpp",
    "server/TracyMouse.cpp",
    "server/TracyPrint.cpp",
    "server/TracyProtoHistory.cpp",
    "server/TracySourceContents.cpp",
    "server/TracySourceTokenizer.cpp",
    "server/TracySourceView.cpp",
    "server/TracyStorage.cpp",
    "server/TracyTaskDispatch.cpp",
    "server/TracyTexture.cpp",
    "server/TracyTextureCompression.cpp",
    "server/TracyThreadCompress.cpp",
    "server/TracyTimelineController.cpp",
    "server/TracyTimelineItem.cpp",
    "server/TracyTimelineItemCpuData.cpp",
    "server/TracyTimelineItemGpu.cpp",
    "server/TracyTimelineItemPlot.cpp",
    "server/TracyTimelineItemThread.cpp",
    "server/TracyUserData.cpp",
    "server/TracyUtility.cpp",
    "server/TracyView_Annotations.cpp",
    "server/TracyView_Callstack.cpp",
    "server/TracyView_Compare.cpp",
    "server/TracyView_ConnectionState.cpp",
    "server/TracyView_ContextSwitch.cpp",
    "server/TracyView_CpuData.cpp",
    "server/TracyView_FindZone.cpp",
    "server/TracyView_FrameOverview.cpp",
    "server/TracyView_FrameTimeline.cpp",
    "server/TracyView_FrameTree.cpp",
    "server/TracyView_GpuTimeline.cpp",
    "server/TracyView_Locks.cpp",
    "server/TracyView_Memory.cpp",
    "server/TracyView_Messages.cpp",
    "server/TracyView_Navigation.cpp",
    "server/TracyView_NotificationArea.cpp",
    "server/TracyView_Options.cpp",
    "server/TracyView_Playback.cpp",
    "server/TracyView_Plots.cpp",
    "server/TracyView_Ranges.cpp",
    "server/TracyView_Samples.cpp",
    "server/TracyView_Statistics.cpp",
    "server/TracyView_Timeline.cpp",
    "server/TracyView_TraceInfo.cpp",
    "server/TracyView_Utility.cpp",
    "server/TracyView_ZoneInfo.cpp",
    "server/TracyView_ZoneTimeline.cpp",
    "server/TracyView.cpp",
    "server/TracyWeb.cpp",
    "server/TracyWorker.cpp",

    "imgui/imgui.cpp",
    "imgui/imgui_demo.cpp",
    "imgui/imgui_draw.cpp",
    "imgui/imgui_tables.cpp",
    "imgui/imgui_widgets.cpp",
    "imgui/misc/freetype/imgui_freetype.cpp",

    "nfd/nfd_portal.cpp",
};
const profiler_c_sources = [_][]const u8{
    "profiler/src/ini.c",
};

const profiler_wayland_cxx_sources = [_][]const u8{
    "profiler/src/BackendWayland.cpp",
};
const profiler_wayland_c_sources = [_][]const u8{
    "profiler/src/wayland/xdg-shell.c",
    "profiler/src/wayland/xdg-activation.c",
    "profiler/src/wayland/xdg-decoration.c",
};

const zstd_sources = [_][]const u8{
    "zstd/common/debug.c",
    "zstd/common/entropy_common.c",
    "zstd/common/error_private.c",
    "zstd/common/fse_decompress.c",
    "zstd/common/pool.c",
    "zstd/common/threading.c",
    "zstd/common/xxhash.c",
    "zstd/common/zstd_common.c",
    "zstd/compress/fse_compress.c",
    "zstd/compress/hist.c",
    "zstd/compress/huf_compress.c",
    "zstd/compress/zstdmt_compress.c",
    "zstd/compress/zstd_compress.c",
    "zstd/compress/zstd_compress_literals.c",
    "zstd/compress/zstd_compress_sequences.c",
    "zstd/compress/zstd_compress_superblock.c",
    "zstd/compress/zstd_double_fast.c",
    "zstd/compress/zstd_fast.c",
    "zstd/compress/zstd_lazy.c",
    "zstd/compress/zstd_ldm.c",
    "zstd/compress/zstd_opt.c",
    "zstd/decompress/huf_decompress.c",
    "zstd/decompress/zstd_ddict.c",
    "zstd/decompress/zstd_decompress.c",
    "zstd/decompress/zstd_decompress_block.c",
    "zstd/dictBuilder/cover.c",
    "zstd/dictBuilder/divsufsort.c",
    "zstd/dictBuilder/fastcover.c",
    "zstd/dictBuilder/zdict.c",
};

fn getInstallRelativePath(b: *std.Build, other: *std.Build.Step.Compile, to: []const u8) std.Build.LazyPath {
    const installed_tree = other.installed_headers_include_tree orelse @panic("was not linked");
    return installed_tree.getDirectory().path(b, to);
}

fn asciiUpperStringComptime(comptime s: []const u8) [s.len]u8 {
    comptime var buf: [s.len]u8 = undefined;
    _ = std.ascii.upperString(&buf, s);
    return buf;
}
