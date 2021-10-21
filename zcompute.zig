//! Simple and easy to use GPU compute library for Zig

const std = @import("std");
const vk = @import("vk.zig");
const vk_allocator = @import("vk_allocator.zig");
const log = std.log.scoped(.zcompute);

pub const Context = struct {
    vk_alloc: vk.AllocationCallbacks,

    vkb: BaseDispatch,
    vki: InstanceDispatch,
    vkd: DeviceDispatch,

    instance: vk.Instance,
    phys_device: vk.PhysicalDevice,
    device: vk.Device,

    /// BEWARE: Using a GPA with nonzero stack_trace_frames may cause random segmentation faults
    pub fn init(allocator: *std.mem.Allocator) !Context {
        var self: Context = undefined;
        self.vk_alloc = vk_allocator.wrap(allocator);

        try loader.ref();
        errdefer loader.deref();
        self.vkb = try BaseDispatch.load(loader.getProcAddress);
        try self.initInstance(allocator);

        return self;
    }

    pub fn deinit(self: Context) void {
        self.vki.destroyInstance(self.instance, &self.vk_alloc);
        loader.deref();
    }

    fn initInstance(self: *Context, allocator: *std.mem.Allocator) !void {
        const app_name = std.meta.globalOption("zcompute_app_name", [*:0]const u8);
        const app_version = std.meta.globalOption("zcompute_app_version", u32) orelse 0;
        const layers = try self.instanceLayers(allocator);
        defer allocator.free(layers);
        const exts: [][*:0]const u8 = &.{};

        self.instance = try self.vkb.createInstance(.{
            .flags = .{},
            .p_application_info = &.{
                .p_application_name = app_name,
                .application_version = app_version,
                .p_engine_name = "zcompute",
                .engine_version = 00_01_00,
                .api_version = vk.makeApiVersion(0, 1, 1, 0),
            },
            .enabled_layer_count = @intCast(u32, layers.len),
            .pp_enabled_layer_names = layers.ptr,
            .enabled_extension_count = @intCast(u32, exts.len),
            .pp_enabled_extension_names = exts.ptr,
        }, &self.vk_alloc);
        self.vki = try InstanceDispatch.load(self.instance, self.vkb.dispatch.vkGetInstanceProcAddr);
        errdefer self.vki.destroyInstance(self.instance, &self.vk_alloc);
    }

    fn instanceLayers(self: Context, allocator: *std.mem.Allocator) ![][*:0]const u8 {
        if (std.builtin.mode != .Debug) {
            return &.{};
        }

        var wanted_layers = [_][:0]const u8{
            "VK_LAYER_KHRONOS_validation",
        };

        var n_supported_layers: u32 = undefined;
        _ = try self.vkb.enumerateInstanceLayerProperties(&n_supported_layers, null);
        const supported_layers = try allocator.alloc(vk.LayerProperties, n_supported_layers);
        defer allocator.free(supported_layers);
        _ = try self.vkb.enumerateInstanceLayerProperties(&n_supported_layers, supported_layers.ptr);

        var n_layers: usize = 0;
        var layers: [wanted_layers.len][*:0]const u8 = undefined;
        for (wanted_layers) |wanted| {
            for (supported_layers) |supported| {
                if (std.mem.eql(u8, wanted, std.mem.sliceTo(&supported.layer_name, 0))) {
                    layers[n_layers] = wanted.ptr;
                    n_layers += 1;
                    break;
                }
            } else {
                log.warn("Skipping validation layer {s}", .{wanted});
            }
        }

        return allocator.dupe([*:0]const u8, layers[0..n_layers]);
    }
};

const BaseDispatch = vk.BaseWrapper(.{
    .CreateInstance,
    .EnumerateInstanceLayerProperties,
    .GetInstanceProcAddr,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .CreateDevice,
    .DestroyInstance,
    .EnumerateDeviceExtensionProperties,
    .EnumeratePhysicalDevices,
    .GetDeviceProcAddr,
    .GetPhysicalDeviceProperties,
    .GetPhysicalDeviceQueueFamilyProperties,
});

const DeviceDispatch = vk.DeviceWrapper(.{
    .DestroyDevice,
    .GetDeviceQueue,
});

// Simple loader for base Vulkan functions
threadlocal var loader = Loader{};
const Loader = struct {
    ref_count: usize = 0,
    lib: ?std.DynLib = null,
    getProcAddress: vk.PfnGetInstanceProcAddr = undefined,

    fn ref(self: *Loader) !void {
        if (self.lib != null) {
            self.ref_count += 1;
            return;
        }

        const lib_name = switch (std.builtin.os.tag) {
            .windows => "vulkan-1.dll",
            else => "libvulkan.so.1",
            .macos => @compileError("Unsupported platform: " ++ @tagName(std.builtin.os)),
        };
        if (!std.builtin.link_libc) {
            @compileError("zcompute requires libc to be linked");
        }

        self.lib = std.DynLib.open(lib_name) catch |err| {
            log.err("Could not load vulkan library '{s}': {s}", .{ lib_name, @errorName(err) });
            return err;
        };
        errdefer self.lib.?.close();

        self.getProcAddress = self.lib.?.lookup(
            vk.PfnGetInstanceProcAddr,
            "vkGetInstanceProcAddr",
        ) orelse {
            log.err("Vulkan loader does not export vkGetInstanceProcAddr", .{});
            return error.MissingSymbol;
        };
    }

    fn deref(self: *Loader) void {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
            return;
        }

        self.lib.?.close();
        self.lib = null;
        self.getProcAddress = undefined;
    }
};
