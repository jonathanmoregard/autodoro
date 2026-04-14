# Autodoro

## Setup

After cloning, activate the tracked git hooks:

```sh
git config core.hooksPath .githooks
```

This enables the `post-push` hook which automatically reloads the autodoro systemd service after every push.
