# agy.el

> [!WARNING]
> This package is vibe-coded. Expect rough edges and read the code before trusting it with anything important.

Run Google's [Antigravity CLI](https://antigravity.google/docs/cli/reference) (`agy`) inside Emacs.

`agy.el` starts `agy` in a terminal buffer ([eat](https://codeberg.org/akib/emacs-eat) or [ghostel](https://github.com/dakra/ghostel)) and lets you drive it from the buffer you are editing: send a region, a file with line numbers, or the compiler error at point; answer `agy` prompts with `y`/`n` without switching windows; cycle agent modes; and resume old conversations. When a turn finishes in the background, Emacs can notify you.

The command layout and workflow are modeled on Stephen Molitor's [claude-code.el](https://github.com/stevemolitor/claude-code.el).

## Requirements

- Emacs 29.1+
- `agy` on `PATH` (tested with 1.4.3)
- [eat](https://codeberg.org/akib/emacs-eat) (default) or [ghostel](https://github.com/dakra/ghostel)
- [transient](https://github.com/magit/transient) and [inheritenv](https://github.com/purcell/inheritenv)
- `sqlite3` on `PATH` (only used by `M-x agy-resume`)

## Installation

With `use-package` from a local checkout:

```elisp
(use-package agy
  :load-path "~/projects/elisp/agy"
  :commands (agy agy-transient agy-resume)
  :bind-keymap ("C-c g" . agy-command-map)
  :config
  (setq agy-terminal-backend 'ghostel)) ; or 'eat (default)
```

Or with `package-vc-install`:

```elisp
(package-vc-install "https://github.com/ifinkelstein/agy.el")
```

## Usage

Run `M-x agy` (or `C-c g a` if you bound `agy-command-map` to `C-c g`) from any file in a project. It opens a terminal buffer named `*agy:~/path/to/project/*` at the project root. Starting a second session in the same directory prompts for an instance name (`*agy:~/path/to/project/:name*`).

Send and control commands work from any buffer. If there is one session for the current project, they use it; if there are several, you pick one; if there is none in the current project, you can pick a session running elsewhere and `agy.el` remembers that choice until the buffer is killed.

`M-x agy-transient` (`C-c g m`) opens a menu with all commands below, plus startup flags (`--model`, `--mode`, `--effort`, `--sandbox`, `--dangerously-skip-permissions`).

### Starting and stopping

| Key | Command | What it does |
|-----|---------|--------------|
| `a` | `agy` | Start a session (`C-u` prompts for directory) |
| `d` | `agy-start-in-directory` | Prompt for a directory and start there |
| `C` | `agy-continue` | Start with `--continue` (most recent conversation) |
| `R` | `agy-resume` | Pick and resume an old conversation from this directory (`C-u`: any directory) |
| `i` | `agy-new-instance` | Start another named session in this directory |
| `S` | `agy-sandbox` | Start with `--sandbox` |
| `k` | `agy-kill` | Kill this directory's session |
| `K` | `agy-kill-all` | Kill all sessions |

### Sending

| Key | Command | What it sends |
|-----|---------|---------------|
| `s` | `agy-send-command` | A prompt read from the minibuffer (`C-u` switches to the `agy` window) |
| `x` | `agy-send-command-with-context` | A prompt plus `@file (line N)` or `@file (lines N-M)` for point or the region |
| `r` | `agy-send-region` | The region, or the whole buffer (`C-u` asks for instructions; `C-u C-u` also switches window) |
| `o` | `agy-send-buffer-file` | `@file` for the current buffer (`C-u` asks for instructions; `C-u C-u` also switches window) |
| `f` | `agy-send-file` | `@file` for a file you choose |
| `e` | `agy-fix-error-at-point` | The Flycheck or Flymake diagnostic at point, with its file and line |
| `v` | `agy-paste-image` | The clipboard image (sends `Ctrl+V` to `agy`) |
| `/` | `agy-slash-commands` | Transient menu of slash commands (`/compact`, `/rewind`, `/fork`, `/btw`, `/goal`, `/model`, `/mcp`, ...) |

### Session and prompt control

| Key | Command | What it does |
|-----|---------|--------------|
| `t` | `agy-toggle` | Show or hide the session window |
| `b` | `agy-switch-to-buffer` | Switch to this directory's session (`C-u`: any session) |
| `B` | `agy-select-buffer` | Pick from all running sessions |
| `z` | `agy-toggle-read-only-mode` | Toggle read-only mode so normal Emacs movement, search, and copy work |
| `M` | `agy-cycle-mode` | Send `Shift+Tab` (`default` → `accept-edits` → `auto` → `plan`) |
| `y` | `agy-send-return` | Send `RET` to accept a prompt |
| `n` | `agy-send-escape` | Send `ESC` to reject a prompt or interrupt a turn |
| `m` | `agy-transient` | Open the transient menu |

### Inside an `agy` buffer

`agy-session-mode` is enabled in every session buffer:

- `S-RET` and `M-RET` insert a newline without submitting.
- `C-g` sends `ESC` to `agy`, or runs `keyboard-quit` when the terminal is read-only.

## Notifications

When a turn finishes and the session buffer isn't focused, `agy.el` flashes the mode line and prints a message (customizable via `agy-notification-function`). It can detect turn completion in two ways:

1. `M-x agy-install-hooks` (recommended). This writes an `"agy-el"` `Stop` entry to `~/.gemini/config/hooks.json`, keeping any other hooks already in the file. When `agy` finishes a turn, `bin/agy-emacs-hook` calls `emacsclient` to notify Emacs. Requires a running Emacs server (`M-x server-start`). Sessions started outside Emacs are ignored.
2. Terminal bell. If notifications are turned on in `agy`'s `/config`, `agy` rings the bell at the end of a turn and `agy.el` catches it.

Hook events also run `agy-event-functions` with a plist `(:event "Stop" :buffer BUFFER :data PAYLOAD)`. If you want other `agy` events (`SessionStart`, `PreInvocation`, `PostInvocation`, `PostToolUse`) forwarded to `agy-event-functions`, point them at `bin/agy-emacs-hook EVENT` in `hooks.json`.

## Customization

| Variable | Default | Description |
|----------|---------|-------------|
| `agy-program` | `"agy"` | CLI executable |
| `agy-program-switches` | `nil` | Extra switches passed on every start, e.g. `'("--model=gemini-4-argon-high")` |
| `agy-terminal-backend` | `'eat` | `'eat` or `'ghostel` |
| `agy-display-window-fn` | `#'agy-display-buffer-below` | Function that displays a session window |
| `agy-toggle-auto-select` | `nil` | Select the session window when displayed |
| `agy-no-delete-other-windows` | `nil` | Keep session windows when `delete-other-windows` (`C-x 1`) runs |
| `agy-confirm-kill` | `t` | Ask before killing a session |
| `agy-large-buffer-threshold` | `100000` | Ask before sending a whole buffer larger than this many chars |
| `agy-enable-notifications` | `t` | Notify when a turn ends |
| `agy-notification-function` | `#'agy-default-notification` | Called with `(title message)` |
| `agy-start-hook` | `nil` | Hook run in each new session buffer |
| `agy-process-environment-functions` | `nil` | Functions `(fn name dir)` returning extra `"VAR=VALUE"` strings |
| `agy-data-directory` | `"~/.gemini/antigravity-cli/"` | Directory containing `conversation_summaries.db` |
| `agy-hooks-file` | `"~/.gemini/config/hooks.json"` | File edited by `M-x agy-install-hooks` |
| `agy-sqlite-program` | `"sqlite3"` | SQLite binary used by `M-x agy-resume` |

## Notes

- Prompts are sent as a bracketed paste followed by `RET`. If a prompt ends with an `@path` mention, a space is appended before pasting so `agy`'s file-completion menu doesn't swallow the `RET`.
- `agy-resume` queries `conversation_summaries.db` read-only with `sqlite3` and starts `agy --conversation=ID` in that conversation's workspace.
- Terminal backends are implemented as `cl-defgeneric` methods (`agy--term-make`, `agy--term-send`, `agy--term-paste`, `agy--term-configure`, `agy--term-read-only-p`, `agy--term-set-read-only`, `agy--term-kill`).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
