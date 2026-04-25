pub const ForegroundUsageRefreshTarget = enum {
    list,
    switch_account,
    remove_account,
};

pub const LiveTtyTarget = enum {
    list,
    switch_account,
    remove_account,
};

pub fn liveTtyPreflightError(target: LiveTtyTarget, stdin_is_tty: bool, stdout_is_tty: bool) ?anyerror {
    if (stdin_is_tty and stdout_is_tty) return null;
    return switch (target) {
        .list => error.ListLiveRequiresTty,
        .switch_account => error.SwitchSelectionRequiresTty,
        .remove_account => error.RemoveSelectionRequiresTty,
    };
}

pub fn shouldRefreshForegroundUsage(target: ForegroundUsageRefreshTarget) bool {
    return target == .list or target == .switch_account or target == .remove_account;
}
