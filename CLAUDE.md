# Autodoro

## Deploying changes

The dellan host installs a global `pre-push` git hook (declared in
`nixos-config: home/autodoro.nix`) that restarts `autodoro.service`
on any `git push` from this repo. Workdir edits and local commits
do not trigger a restart — only `git push` does. The hook is
no-op for pushes from any other repo (guarded by `git rev-parse
--show-toplevel`).

So the canonical deploy path is: commit, push. Don't `systemctl
--user restart autodoro` manually; pushing is the only path and
avoids drift between the working tree and the running script.

The runtime wrapper (PATH for `pactl` / `xprintidle` /
`cinnamon-screensaver-command`, `GI_TYPELIB_PATH` for gi-python,
`GDK_PIXBUF_MODULE_FILE` for the webp loader) is also defined in
`nixos-config: home/autodoro.nix`. Changes to those need a
nixos-config PR + rebuild, not a push here.

## Historical note

This repo used to ship `.githooks/post-push` plus a one-line
`git config core.hooksPath .githooks` setup instruction. That
never actually worked: `post-push` is not a real git hook (git
only defines `pre-push` client-side), and the host's global
`core.hooksPath` shadows per-repo `.githooks/` anyway. Both have
been removed; the declarative pre-push hook is the working
replacement.
