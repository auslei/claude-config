# Claude Code global config

Version-controlled copy of my global `~/.claude` config: `CLAUDE.md`, `settings.json`,
and the authored `skills/`, `commands/`, and `agents/`. Everything else in `~/.claude`
(session history, plugins, caches, credentials) is machine-local and git-ignored.

## What's tracked

| Path | What it is |
|------|------------|
| `CLAUDE.md` | Global instructions applied to every project |
| `settings.json` | Permissions, hooks, status line, enabled plugins, marketplaces, prefs |
| `commands/` | Custom slash commands |
| `agents/` | Custom sub-agent definitions |
| `statusline.sh` | Status line: optional machine-role badge + claude-hud (auto-located) |

`skills/` is intentionally **not** tracked — it only holds auto-synced built-in skills
(they regenerate on their own) and local symlinks. To version an authored skill later,
add `!skills/<name>/**` to `.gitignore`.

Paths in `settings.json` use `$HOME` (not a hardcoded username) and call `node` via
`PATH`, so the file is portable across machines.

## Replicate onto a new machine

`~/.claude` already exists on any machine that has run Claude Code, so **don't `git clone`**
(it refuses a non-empty dir). Init in place and pull — git only touches tracked files, so
your local sessions, plugins, and credentials are never at risk:

```bash
cd ~/.claude
git init
git remote add origin <REPO_URL>
git fetch origin
git reset --hard origin/main   # overwrites ONLY tracked files; ignored junk untouched
```

To later pull updates on that machine: `git pull`. To keep a machine-specific tweak to a
tracked file without pushing it, commit it on a local branch or just don't `reset --hard`.

## External dependencies (not in this repo)

These are referenced by `settings.json` but live outside `~/.claude` — set them up per machine
or the hooks/status line will error (harmlessly):

- **`$HOME/.config/iterm2/cc-status`** — iTerm2 status hook. Install it or remove those hook
  entries if you don't use iTerm2.
- **`node` on `PATH`** — required for the claude-hud status line.
- **Plugins** — `plugins/` is git-ignored (hundreds of MB). Claude Code re-installs them on
  startup from `enabledPlugins` + `extraKnownMarketplaces` in `settings.json`. No manual step.

## Machine role (e.g. PROD)

To mark a machine, create `~/.claude/machine-role.md` (git-ignored, machine-local). Line 1 is
`Role: <LABEL>` (shown as a red badge in the status line); the whole file is injected into every
session's context by a `SessionStart` hook. Machines without the file show no badge and get no context.

## Push changes

Edit files in place (this *is* `~/.claude`), then:

```bash
git add -A && git commit -m "..." && git push
```

Before the **first** commit, run `git status` and confirm only the tracked files above appear —
never `.credentials.json` or session data.
