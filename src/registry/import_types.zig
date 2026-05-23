const std = @import("std");

pub const ImportRenderKind = enum {
    single_file,
    scanned,
};

pub const ImportOutcome = enum {
    imported,
    updated,
    skipped,
};

pub const ImportEvent = struct {
    label: []u8,
    outcome: ImportOutcome,
    reason: ?[]u8 = null,
    item_index: ?usize = null,
    detail: ?[]u8 = null,

    pub fn deinit(self: *ImportEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.reason) |reason| allocator.free(reason);
        if (self.detail) |detail| allocator.free(detail);
    }
};

pub const ImportReport = struct {
    render_kind: ImportRenderKind,
    source_label: ?[]u8 = null,
    failure: ?anyerror = null,
    imported: usize = 0,
    updated: usize = 0,
    skipped: usize = 0,
    total_files: usize = 0,
    events: std.ArrayList(ImportEvent),

    pub fn init(render_kind: ImportRenderKind) ImportReport {
        return .{
            .render_kind = render_kind,
            .events = std.ArrayList(ImportEvent).empty,
        };
    }

    pub fn deinit(self: *ImportReport, allocator: std.mem.Allocator) void {
        if (self.source_label) |source_label| allocator.free(source_label);
        for (self.events.items) |*event| event.deinit(allocator);
        self.events.deinit(allocator);
    }

    pub fn addEvent(
        self: *ImportReport,
        allocator: std.mem.Allocator,
        label: []const u8,
        outcome: ImportOutcome,
        reason: ?[]const u8,
    ) !void {
        try self.addEventDetail(allocator, label, outcome, reason, null, null);
    }

    pub fn addItemEvent(
        self: *ImportReport,
        allocator: std.mem.Allocator,
        label: []const u8,
        item_index: usize,
        outcome: ImportOutcome,
        reason: ?[]const u8,
        detail: ?[]const u8,
    ) !void {
        try self.addEventDetail(allocator, label, outcome, reason, item_index, detail);
    }

    pub fn addScannedFile(self: *ImportReport) void {
        self.total_files += 1;
    }

    fn addEventDetail(
        self: *ImportReport,
        allocator: std.mem.Allocator,
        label: []const u8,
        outcome: ImportOutcome,
        reason: ?[]const u8,
        item_index: ?usize,
        detail: ?[]const u8,
    ) !void {
        const owned_label = try allocator.dupe(u8, label);
        errdefer allocator.free(owned_label);
        const owned_reason = if (reason) |reason_text| try allocator.dupe(u8, reason_text) else null;
        errdefer if (owned_reason) |owned| allocator.free(owned);
        const owned_detail = if (detail) |detail_text| try allocator.dupe(u8, detail_text) else null;
        errdefer if (owned_detail) |owned| allocator.free(owned);

        try self.events.append(allocator, .{
            .label = owned_label,
            .outcome = outcome,
            .reason = owned_reason,
            .item_index = item_index,
            .detail = owned_detail,
        });
        if (item_index == null or item_index.? == 1) self.total_files += 1;
        switch (outcome) {
            .imported => self.imported += 1,
            .updated => self.updated += 1,
            .skipped => self.skipped += 1,
        }
    }

    pub fn appliedCount(self: *const ImportReport) usize {
        return self.imported + self.updated;
    }
};
