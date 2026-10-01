<div align="center">

# AI Termux Android

**Code with AI agents straight from your Android phone or tablet.**

GitHub Copilot &middot; Claude Code &middot; Codex &middot; Antigravity &middot; OpenCode

[![Shell Checks](https://github.com/micheljatuba/AI-Termux-Android/actions/workflows/checks.yml/badge.svg)](https://github.com/micheljatuba/AI-Termux-Android/actions/workflows/checks.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

Five coding agents, one menu, no root and no PC. The installer sets up a dedicated
Linux (Debian + Node.js 24 through PRoot) inside Termux with the official CLIs,
Git and the GitHub CLI. Your projects stay in the Termux home folder; each agent
keeps its own login.

> The full guide is in Portuguese: [README.md](README.md). This page covers the
> essentials. Cloud models still need internet and an account with each provider;
> subscriptions and usage limits are not included.

## Install

Requires the official **Termux** (not a look-alike app), Android 11+, a 64-bit
build (ARM64 or x86_64), 6 GiB free and 4 GB RAM (8 GB recommended).

```sh
pkg update && pkg install -y git
git clone https://github.com/micheljatuba/AI-Termux-Android.git ~/AI-Termux-Android
cd ~/AI-Termux-Android
bash install.sh --check   # read-only pre-check
bash install.sh
```

Review the scripts before running them. Then open the menu with `ia`, or call an
agent directly: `claude`, `copilot`, `codex`, `agy`, `opencode`. Every command
runs in your current folder.

## Continue on another device (experimental)

Start on your phone, continue on your tablet, even with a different agent. The
handoff moves **the work, not the conversation**: your changed files plus a
continuity note, through a dedicated branch of your **private** GitHub repository.

```sh
ia handoff --dry-run     # preview what would be sent
ia handoff --note "Next: test the login"
ia continuar             # on the other device, inside the same clone
```

Security first, covered by automated tests:

- sends only after GitHub confirms the repository is **private**;
- never touches your branch, index or files; never force-pushes; writes only to a
  new `ia/handoff/*` branch;
- excludes `.env*`, keys, agent credential folders and `node_modules`;
- scans changed files, unpublished local commits and the note for known token and
  key formats, and aborts without printing the value;
- refuses to resume a handoff made by another git identity and never overwrites
  pending changes.

Limits: the secret scan is a safety net, **not a guarantee**; commit author e-mails
can be forged by collaborators with write access, so review `git diff` before
running anything; it has not been validated on Android/PRoot yet. Details in
[SECURITY.md](SECURITY.md).

## Compatibility and security

Tested on Android without root. PRoot is **not** a security sandbox: agents can
access files available to Termux, so keep backups. Codex's own sandbox may fail
under PRoot, and the installer does not disable it. See
[SECURITY.md](SECURITY.md) for the security policy, how to report a vulnerability
privately and the known limitations of the installation.

## License

[MIT](LICENSE). Termux, the agent CLIs and the AI services remain subject to their
providers' licenses and terms.
