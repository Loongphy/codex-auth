pub const ApiMode = enum {
    default,
    force_api,
    skip_api,
};

pub const ListOptions = struct {
    live: bool = false,
    api_mode: ApiMode = .default,
};
pub const LoginOptions = struct {
    device_auth: bool = false,
};
pub const ImportSource = enum { standard, cpa };
pub const ImportOptions = struct {
    auth_path: ?[]u8,
    alias: ?[]u8,
    purge: bool,
    source: ImportSource,
};
pub const SwitchOptions = struct {
    query: ?[]u8,
    live: bool = false,
    api_mode: ApiMode = .default,
};
pub const RemoveOptions = struct {
    selectors: [][]const u8,
    all: bool,
    live: bool = false,
    api_mode: ApiMode = .default,
};
pub const CleanOptions = struct {};
pub const AutoAction = enum { enable, disable };
pub const AutoThresholdOptions = struct {
    threshold_5h_percent: ?u8,
    threshold_weekly_percent: ?u8,
};
pub const AutoOptions = union(enum) {
    action: AutoAction,
    configure: AutoThresholdOptions,
};
pub const ApiAction = enum { enable, disable };
pub const LiveOptions = struct {
    interval_seconds: u16,
};
pub const ConfigOptions = union(enum) {
    auto_switch: AutoOptions,
    api: ApiAction,
    live: LiveOptions,
};
pub const DaemonMode = enum { watch, once };
pub const DaemonOptions = struct { mode: DaemonMode };
pub const HelpTopic = enum {
    top_level,
    list,
    status,
    login,
    import_auth,
    switch_account,
    remove_account,
    clean,
    config,
    daemon,
};

pub const Command = union(enum) {
    list: ListOptions,
    login: LoginOptions,
    import_auth: ImportOptions,
    switch_account: SwitchOptions,
    remove_account: RemoveOptions,
    clean: CleanOptions,
    config: ConfigOptions,
    status: void,
    daemon: DaemonOptions,
    version: void,
    help: HelpTopic,
};

pub const UsageError = struct {
    topic: HelpTopic,
    message: []u8,
};

pub const ParseResult = union(enum) {
    command: Command,
    usage_error: UsageError,
};
