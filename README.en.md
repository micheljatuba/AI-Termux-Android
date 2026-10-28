<div align="center">

# AI Termux Android

### Turn your Android phone into an AI coding workstation.

**Five real AI coding agents, one menu, no PC.**
GitHub Copilot &middot; Claude Code &middot; Codex &middot; Antigravity &middot; OpenCode &middot; Hermes (optional)

[![Shell Checks](https://github.com/micheljatuba/AI-Termux-Android/actions/workflows/checks.yml/badge.svg)](https://github.com/micheljatuba/AI-Termux-Android/actions/workflows/checks.yml)
![Android 11+](https://img.shields.io/badge/Android-11%2B-3DDC84?logo=android&logoColor=white)
![No root](https://img.shields.io/badge/root-not_needed-198754)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Security policy](https://img.shields.io/badge/security-policy-8250df)](SECURITY.md)

<img src="docs/images/menu-android.png" width="720" alt="AI Termux Android menu with the agents, the Linux terminal, EmbeddingGemma, versions and updates, diagnostics, the optional Hermes Agent and the web panel">

<sub>Type <code>ia</code>. Pick a number. Start coding.</sub>

</div>

<table>
  <tr>
    <td width="50%"><img src="docs/images/claude-entry.png" alt="Claude Code on Android before login"><br><sub><b>Claude Code</b></sub></td>
    <td width="50%"><img src="docs/images/copilot-entry.png" alt="GitHub Copilot CLI on Android before login"><br><sub><b>GitHub Copilot CLI</b></sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/codex-entry.png" alt="Codex on Android with its sign-in options"><br><sub><b>Codex</b></sub></td>
    <td width="50%"><img src="docs/images/agents-versions.png" alt="Copilot, Claude, Codex, Antigravity and OpenCode versions on Android"><br><sub><b>All five installed</b></sub></td>
  </tr>
</table>

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

## Browser panel

`ia web` starts a local multi-agent panel in the phone's browser. The panel, the
optional menu terminal and the optional EmbeddingGemma server listen only on
`127.0.0.1` **and require a private token**, because other apps on the same
Android device can also reach `127.0.0.1`. Treat the links as passwords.

## Decision front with TypeSafe Jev (optional, experimental)

`ia typesafe configurar` turns on a decision step before every orchestration:
TypeSafe Jev rates the risk (dangerous tasks are **blocked**, risky ones need
confirmation), checks that the task is clear, and suggests the agent (Hermes
included) and the mode. Only the task text and up to 300 file **names** leave
the device, never file contents; tasks containing known secrets are never sent.
If Jev is unreachable, nothing runs without your explicit confirmation.

## Compatibility and security

Tested on Android without root. PRoot is **not** a security sandbox: agents can
access files available to Termux, so keep backups. Codex's own sandbox may fail
under PRoot, and the installer does not disable it. See
[SECURITY.md](SECURITY.md) for the security policy, how to report a vulnerability
privately and the known limitations of the installation.

## License

[MIT](LICENSE). Termux, the agent CLIs and the AI services remain subject to their
providers' licenses and terms.

<div align="center">

**Like it? Leave a ⭐ to find it later and help more people discover it.**

</div>
