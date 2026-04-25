pub const switch_picker = @import("picker_switch.zig");
pub const remove_picker = @import("picker_remove.zig");
pub const nav = @import("picker_nav.zig");
pub const auto = @import("picker_auto.zig");

pub const selectAccount = switch_picker.selectAccount;
pub const selectAccountWithUsageOverrides = switch_picker.selectAccountWithUsageOverrides;
pub const selectAccountFromIndices = switch_picker.selectAccountFromIndices;
pub const selectAccountFromIndicesWithUsageOverrides = switch_picker.selectAccountFromIndicesWithUsageOverrides;
pub const selectWithNumbers = switch_picker.selectWithNumbers;
pub const selectWithNumbersFromIndices = switch_picker.selectWithNumbersFromIndices;
pub const shouldUseNumberedSwitchSelector = switch_picker.shouldUseNumberedSwitchSelector;

pub const selectAccountsToRemove = remove_picker.selectAccountsToRemove;
pub const selectAccountsToRemoveWithUsageOverrides = remove_picker.selectAccountsToRemoveWithUsageOverrides;
pub const shouldUseNumberedRemoveSelector = remove_picker.shouldUseNumberedRemoveSelector;

pub const isQuitInput = nav.isQuitInput;
pub const isQuitKey = nav.isQuitKey;
pub const activeSelectableIndex = nav.activeSelectableIndex;
pub const accountIdForSelectable = nav.accountIdForSelectable;
pub const accountRowCount = nav.accountRowCount;
pub const displayedIndexForSelectable = nav.displayedIndexForSelectable;
pub const selectableIndexForDisplayedAccount = nav.selectableIndexForDisplayedAccount;
pub const accountIdForDisplayedAccount = nav.accountIdForDisplayedAccount;
pub const dupSelectedAccountKeyForDisplayedAccount = nav.dupSelectedAccountKeyForDisplayedAccount;
pub const parsedDisplayedIndex = nav.parsedDisplayedIndex;
pub const selectedDisplayIndexForRender = nav.selectedDisplayIndexForRender;
pub const dupSelectedAccountKey = nav.dupSelectedAccountKey;
pub const dupeOptionalAccountKey = nav.dupeOptionalAccountKey;
pub const accountIndexForSelectable = nav.accountIndexForSelectable;
pub const selectableIndexForAccountKey = nav.selectableIndexForAccountKey;
pub const replaceSelectedAccountKeyForSelectable = nav.replaceSelectedAccountKeyForSelectable;
pub const replaceOptionalOwnedString = nav.replaceOptionalOwnedString;
pub const accountKeyForSelectableAlloc = nav.accountKeyForSelectableAlloc;
pub const firstSelectableAccountKeyAlloc = nav.firstSelectableAccountKeyAlloc;
pub const removeOwnedAccountKey = nav.removeOwnedAccountKey;
pub const containsOwnedAccountKey = nav.containsOwnedAccountKey;
pub const toggleOwnedAccountKey = nav.toggleOwnedAccountKey;
pub const clearOwnedAccountKeys = nav.clearOwnedAccountKeys;

pub const maybeAutoSwitchTargetKeyAlloc = auto.maybeAutoSwitchTargetKeyAlloc;
