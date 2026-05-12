const cli = @import("../cli/root.zig");

pub fn handleTopLevelHelp() !void {
    try cli.help.printHelp();
}
