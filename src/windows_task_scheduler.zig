const std = @import("std");
const builtin = @import("builtin");

pub const RuntimeState = enum { running, stopped, unknown };

pub const TaskSpec = struct {
    task_name: []const u8,
    executable_path: []const u8,
    arguments: []const u8,
    restart_count: i32,
    restart_interval: []const u8,
    execution_time_limit: []const u8,
};

const impl = if (builtin.os.tag == .windows) struct {
    const c = @cImport({
        @cDefine("_FORTIFY_SOURCE", "0");
        @cInclude("windows.h");
        @cInclude("taskschd.h");
        @cInclude("combaseapi.h");
        @cInclude("oleauto.h");
    });

    fn guid(d1: u32, d2: u16, d3: u16, d4: [8]u8) c.GUID {
        return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
    }

    const clsid_task_scheduler =
        guid(0x0f87369f, 0xa4e5, 0x4cfc, .{ 0xbd, 0x3e, 0x73, 0xe6, 0x15, 0x45, 0x72, 0xdd });
    const iid_itask_service =
        guid(0x2faba4c7, 0x4da9, 0x4013, .{ 0x96, 0x97, 0x20, 0xcc, 0x3f, 0xd4, 0x0f, 0x85 });
    const iid_iexec_action =
        guid(0x4c3d624d, 0xfd6b, 0x49a3, .{ 0xb9, 0xb7, 0x09, 0xcb, 0x3c, 0xd3, 0xf0, 0x47 });

    fn hresultBits(hr: c.HRESULT) u32 {
        return @bitCast(@as(i32, @intCast(hr)));
    }

    fn mapHResult(hr: c.HRESULT) anyerror {
        return switch (hresultBits(hr)) {
            0x80070002, 0x80070003 => error.TaskNotFound,
            0x80070005 => error.AccessDenied,
            else => error.TaskSchedulerCallFailed,
        };
    }

    fn checkHResult(hr: c.HRESULT) !void {
        if (hr >= 0) return;
        return mapHResult(hr);
    }

    fn releaseCom(ptr: anytype) void {
        const value = switch (@typeInfo(@TypeOf(ptr))) {
            .optional => ptr orelse return,
            else => ptr,
        };
        _ = value.lpVtbl.*.Release.?(value);
    }

    fn queryInterface(source: anytype, iid: *const c.GUID, out: anytype) !void {
        try checkHResult(source.lpVtbl.*.QueryInterface.?(source, iid, @ptrCast(out)));
    }

    const OwnedBstr = struct {
        value: c.BSTR = null,

        fn init(allocator: std.mem.Allocator, utf8: []const u8) !OwnedBstr {
            const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, utf8);
            defer allocator.free(utf16);
            return .{ .value = c.SysAllocStringLen(utf16.ptr, @intCast(utf16.len)) orelse return error.OutOfMemory };
        }

        fn deinit(self: *OwnedBstr) void {
            if (self.value != null) c.SysFreeString(self.value);
            self.value = null;
        }
    };

    fn bstrToUtf8Alloc(allocator: std.mem.Allocator, value: c.BSTR) ![]u8 {
        const len: usize = c.SysStringLen(value);
        const utf16 = @as([*]const u16, @ptrCast(value))[0..len];
        return try std.unicode.utf16LeToUtf8Alloc(allocator, utf16);
    }

    fn initEmptyVariant() c.VARIANT {
        var value = std.mem.zeroes(c.VARIANT);
        c.VariantInit(&value);
        return value;
    }

    fn clearVariant(value: *c.VARIANT) void {
        _ = c.VariantClear(value);
    }

    const Session = struct {
        com_initialized: bool = false,
        service: ?*c.ITaskService = null,
        root: ?*c.ITaskFolder = null,

        fn init(allocator: std.mem.Allocator) !Session {
            var self = Session{};
            const init_hr = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
            if (init_hr == c.RPC_E_CHANGED_MODE) {
                self.com_initialized = false;
            } else {
                try checkHResult(init_hr);
                self.com_initialized = true;
            }
            errdefer if (self.com_initialized) c.CoUninitialize();

            var service: ?*c.ITaskService = null;
            try checkHResult(c.CoCreateInstance(
                &clsid_task_scheduler,
                null,
                c.CLSCTX_INPROC_SERVER,
                &iid_itask_service,
                @ptrCast(&service),
            ));
            self.service = service;
            errdefer releaseCom(self.service);

            var empty_server = initEmptyVariant();
            defer clearVariant(&empty_server);
            var empty_user = initEmptyVariant();
            defer clearVariant(&empty_user);
            var empty_domain = initEmptyVariant();
            defer clearVariant(&empty_domain);
            var empty_password = initEmptyVariant();
            defer clearVariant(&empty_password);
            try checkHResult(service.?.lpVtbl.*.Connect.?(service.?, empty_server, empty_user, empty_domain, empty_password));

            var root_path = try OwnedBstr.init(allocator, "\\");
            defer root_path.deinit();
            var root: ?*c.ITaskFolder = null;
            try checkHResult(service.?.lpVtbl.*.GetFolder.?(service.?, root_path.value, @ptrCast(&root)));
            self.root = root;
            return self;
        }

        fn deinit(self: *Session) void {
            releaseCom(self.root);
            releaseCom(self.service);
            if (self.com_initialized) c.CoUninitialize();
        }

        fn getTask(self: *Session, allocator: std.mem.Allocator, task_name: []const u8) !?*c.IRegisteredTask {
            var name = try OwnedBstr.init(allocator, task_name);
            defer name.deinit();

            var task: ?*c.IRegisteredTask = null;
            const hr = self.root.?.lpVtbl.*.GetTask.?(self.root.?, name.value, @ptrCast(&task));
            if (hr < 0) {
                const err = mapHResult(hr);
                if (err == error.TaskNotFound) return null;
                return err;
            }
            return task;
        }
    };

    pub fn queryTaskRuntimeState(allocator: std.mem.Allocator, task_name: []const u8) RuntimeState {
        var session = Session.init(allocator) catch return .unknown;
        defer session.deinit();

        const task = session.getTask(allocator, task_name) catch return .unknown;
        if (task == null) return .stopped;
        defer releaseCom(task);

        var state: c.TASK_STATE = c.TASK_STATE_UNKNOWN;
        const hr = task.?.lpVtbl.*.get_State.?(task.?, &state);
        if (hr < 0) return .unknown;

        return switch (@as(c_int, @intCast(state))) {
            c.TASK_STATE_RUNNING => .running,
            c.TASK_STATE_UNKNOWN => .unknown,
            else => .stopped,
        };
    }

    pub fn installTask(allocator: std.mem.Allocator, spec: TaskSpec) !void {
        var session = try Session.init(allocator);
        defer session.deinit();

        if (try session.getTask(allocator, spec.task_name)) |existing| {
            defer releaseCom(existing);
            _ = existing.lpVtbl.*.Stop.?(existing, 0);
        }

        var definition: ?*c.ITaskDefinition = null;
        try checkHResult(session.service.?.lpVtbl.*.NewTask.?(session.service.?, 0, @ptrCast(&definition)));
        defer releaseCom(definition);

        var principal: ?*c.IPrincipal = null;
        try checkHResult(definition.?.lpVtbl.*.get_Principal.?(definition.?, @ptrCast(&principal)));
        defer releaseCom(principal);
        try checkHResult(principal.?.lpVtbl.*.put_LogonType.?(principal.?, c.TASK_LOGON_INTERACTIVE_TOKEN));
        try checkHResult(principal.?.lpVtbl.*.put_RunLevel.?(principal.?, c.TASK_RUNLEVEL_LUA));

        var settings: ?*c.ITaskSettings = null;
        try checkHResult(definition.?.lpVtbl.*.get_Settings.?(definition.?, @ptrCast(&settings)));
        defer releaseCom(settings);
        try checkHResult(settings.?.lpVtbl.*.put_Enabled.?(settings.?, c.VARIANT_TRUE));
        try checkHResult(settings.?.lpVtbl.*.put_AllowDemandStart.?(settings.?, c.VARIANT_TRUE));

        var restart_interval = try OwnedBstr.init(allocator, spec.restart_interval);
        defer restart_interval.deinit();
        try checkHResult(settings.?.lpVtbl.*.put_RestartInterval.?(settings.?, restart_interval.value));
        try checkHResult(settings.?.lpVtbl.*.put_RestartCount.?(settings.?, @intCast(spec.restart_count)));

        var execution_limit = try OwnedBstr.init(allocator, spec.execution_time_limit);
        defer execution_limit.deinit();
        try checkHResult(settings.?.lpVtbl.*.put_ExecutionTimeLimit.?(settings.?, execution_limit.value));

        var triggers: ?*c.ITriggerCollection = null;
        try checkHResult(definition.?.lpVtbl.*.get_Triggers.?(definition.?, @ptrCast(&triggers)));
        defer releaseCom(triggers);

        var trigger: ?*c.ITrigger = null;
        try checkHResult(triggers.?.lpVtbl.*.Create.?(triggers.?, c.TASK_TRIGGER_LOGON, @ptrCast(&trigger)));
        defer releaseCom(trigger);
        try checkHResult(trigger.?.lpVtbl.*.put_Enabled.?(trigger.?, c.VARIANT_TRUE));

        var actions: ?*c.IActionCollection = null;
        try checkHResult(definition.?.lpVtbl.*.get_Actions.?(definition.?, @ptrCast(&actions)));
        defer releaseCom(actions);

        var action: ?*c.IAction = null;
        try checkHResult(actions.?.lpVtbl.*.Create.?(actions.?, c.TASK_ACTION_EXEC, @ptrCast(&action)));
        defer releaseCom(action);

        var exec_action: ?*c.IExecAction = null;
        try queryInterface(action.?, &iid_iexec_action, &exec_action);
        defer releaseCom(exec_action);

        var executable_path = try OwnedBstr.init(allocator, spec.executable_path);
        defer executable_path.deinit();
        try checkHResult(exec_action.?.lpVtbl.*.put_Path.?(exec_action.?, executable_path.value));

        var arguments = try OwnedBstr.init(allocator, spec.arguments);
        defer arguments.deinit();
        try checkHResult(exec_action.?.lpVtbl.*.put_Arguments.?(exec_action.?, arguments.value));

        var task_name = try OwnedBstr.init(allocator, spec.task_name);
        defer task_name.deinit();

        var empty_user = initEmptyVariant();
        defer clearVariant(&empty_user);
        var empty_password = initEmptyVariant();
        defer clearVariant(&empty_password);
        var empty_sddl = initEmptyVariant();
        defer clearVariant(&empty_sddl);

        var registered: ?*c.IRegisteredTask = null;
        try checkHResult(session.root.?.lpVtbl.*.RegisterTaskDefinition.?(session.root.?, task_name.value, definition.?, c.TASK_CREATE_OR_UPDATE, empty_user, empty_password, c.TASK_LOGON_INTERACTIVE_TOKEN, empty_sddl, @ptrCast(&registered)));
        defer releaseCom(registered);

        var run_params = initEmptyVariant();
        defer clearVariant(&run_params);
        var running_task: ?*c.IRunningTask = null;
        const run_hr = registered.?.lpVtbl.*.Run.?(registered.?, run_params, @ptrCast(&running_task));
        if (running_task) |value| {
            _ = value.lpVtbl.*.Release.?(value);
        }
        try checkHResult(run_hr);
    }

    pub fn uninstallTask(allocator: std.mem.Allocator, task_name: []const u8) !void {
        var session = try Session.init(allocator);
        defer session.deinit();

        if (try session.getTask(allocator, task_name)) |task| {
            defer releaseCom(task);
            _ = task.lpVtbl.*.Stop.?(task, 0);
        } else {
            return;
        }

        var name = try OwnedBstr.init(allocator, task_name);
        defer name.deinit();
        try checkHResult(session.root.?.lpVtbl.*.DeleteTask.?(session.root.?, name.value, 0));
    }

    pub fn readTaskXmlAlloc(allocator: std.mem.Allocator, task_name: []const u8) !?[]u8 {
        var session = try Session.init(allocator);
        defer session.deinit();

        const task = try session.getTask(allocator, task_name);
        if (task == null) return null;
        defer releaseCom(task);

        var xml: c.BSTR = null;
        try checkHResult(task.?.lpVtbl.*.get_Xml.?(task.?, &xml));
        defer if (xml != null) c.SysFreeString(xml);
        return try bstrToUtf8Alloc(allocator, xml);
    }
} else struct {
    pub fn queryTaskRuntimeState(_: std.mem.Allocator, _: []const u8) RuntimeState {
        return .unknown;
    }

    pub fn installTask(_: std.mem.Allocator, _: TaskSpec) !void {
        return error.UnsupportedPlatform;
    }

    pub fn uninstallTask(_: std.mem.Allocator, _: []const u8) !void {
        return error.UnsupportedPlatform;
    }

    pub fn readTaskXmlAlloc(_: std.mem.Allocator, _: []const u8) !?[]u8 {
        return error.UnsupportedPlatform;
    }
};

pub const queryTaskRuntimeState = impl.queryTaskRuntimeState;
pub const installTask = impl.installTask;
pub const uninstallTask = impl.uninstallTask;
pub const readTaskXmlAlloc = impl.readTaskXmlAlloc;
