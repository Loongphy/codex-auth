# TODO

- [ ] Pending tests: run an end-to-end auto-switch scenario where account A is switched to account B and confirm the daemon does not reassign A's last unchanged rollout `(path, mtime)` to B before a new rollout is written.
- [ ] Pending tests: verify that a newer rollout update on the same file path with a changed `mtime` is attributed to the current active account after an automatic switch.
- [ ] Pending tests: verify the persisted `auto_switch.last_rollout` signature survives restart and still blocks reassignment of the last unchanged rollout after the daemon restarts.
