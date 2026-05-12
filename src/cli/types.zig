pub const ApiMode = enum {
    default,
    force_api,
    skip_api,
};

pub const ListOptions = struct {
    live: bool = false,
    api_mode: ApiMode = .default,
    active_only: bool = false,
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
pub const ExportFormat = enum { standard, cpa };
pub const ExportOptions = struct {
    dest_path: ?[]u8,
    format: ExportFormat,
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
pub const CleanTarget = enum { accounts, background };
pub const CleanOptions = struct {
    target: CleanTarget = .accounts,
};
pub const LiveOptions = struct {
    interval_seconds: u16,
};
pub const ConfigOptions = union(enum) { live: LiveOptions };
pub const HelpTopic = enum {
    top_level,
    list,
    login,
    import_auth,
    export_auth,
    switch_account,
    remove_account,
    clean,
    config,
};

pub const Command = union(enum) {
    list: ListOptions,
    login: LoginOptions,
    import_auth: ImportOptions,
    export_auth: ExportOptions,
    switch_account: SwitchOptions,
    remove_account: RemoveOptions,
    clean: CleanOptions,
    config: ConfigOptions,
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
