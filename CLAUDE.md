# Autodoro

## Setup

After cloning, activate the tracked git hooks:

```sh
git config core.hooksPath .githooks
```

This enables the `post-push` hook which automatically reloads the autodoro systemd service after every push.

## Deploying changes

To deploy code changes to the running service, commit and push — the
`post-push` hook reloads `autodoro.service` automatically. Do not run
`systemctl --user restart autodoro` manually; pushing is the canonical
path and avoids drift between the working tree and the running script.
