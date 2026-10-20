# agy.el

Run Google's [Antigravity CLI](https://antigravity.google/docs/cli/reference) (`agy`) inside Emacs.

agy.el starts `agy` in a terminal buffer and lets you drive it from any other buffer: send regions, files and compiler errors with their line numbers, answer its prompts, cycle its agent modes, attach clipboard images, and resume old conversations. When a turn ends, Emacs can tell you, even if the session is buried in another window.

The design follows Stephen Molitor's [claude-code.el](https://github.com/stevemolitor/claude-code.el), so if you use that package the commands and keys will feel familiar.

## Requirements

- Emacs 29.1 or later
- The `agy` CLI on your `PATH` (tested with agy 1.4.3)
- A terminal backend: [ghostel](https://github.com/dakra/ghostel) or [eat](https://codeberg.org/akib/emacs-eat)
- [transient](https://github.com/magit/transient) and [inheritenv](https://github.com/purcell/inheritenv)
- `sqlite3` on your `PATH`, for `agy-resume` only

## Installation

Clone the repository and point `use-package` at it:

```elisp
(use-package agy
  :load-path "~/src/agy.el"
  :commands (agy agy-transient agy-resume)
  :bind-keymap ("C-c g" . agy-command-map)
  :config
  (setq agy-terminal-backend 'ghostel))   ; or 'eat, the default
```

Or with `package-vc-install` (Emacs 29+):

```elisp
(package-vc-install "https://github.com/ifinkelstein/agy.el")
```

## Usage

`M-x agy` starts a session in the current project's root (or the file's directory, or `default-directory`). The buffer is named `*agy:~/path/to/project/*`. A second session in the same directory asks for an instance name and becomes `*agy:~/path/to/project/:name*`.

Commands that send something work from any buffer. They go to the session for the current directory; if there are several, you choose one, and if there is none, you can pick a session from another directory and agy.el remembers that choice.

`M-x agy-transient` opens a menu of everything below. Its top row sets start options (`--model`, `--mode`, `--effort`, `--sandbox`, `--dangerously-skip-permissions`) for sessions started from that menu.

### Starting and stopping

| Key | Command | What it does |
|-----|---------|--------------|
| `a` | `agy` | Start a session (`C-u` prompts for the directory) |
| `d` | `agy-start-in-directory` | Start in a directory you choose |
| `C` | `agy-continue` | Start with `--continue` (most recent conversation) |
| `R` | `agy-resume` | Pick a past conversation from this directory and resume it (`C-u`: from any directory) |
| `i` | `agy-new-instance` | Start another named session here |
| `S` | `agy-sandbox` | Start with `--sandbox` |
| `k` | `agy-kill` | Kill this directory's session |
| `K` | `agy-kill-all` | Kill every session |

Keys are those of `agy-command-map`.

### Sending

| Key | Command | What it sends |
|-----|---------|---------------|
| `s` | `agy-send-command` | A prompt you type in the minibuffer |
| `x` | `agy-send-command-with-context` | A prompt plus `@file (lines N-M)` for point or the region |
| `r` | `agy-send-region` | The region, or the whole buffer (`C-u` adds instructions first) |
| `o` | `agy-send-buffer-file` | `@file` for this buffer's file (`C-u` adds instructions) |
| `e` | `agy-fix-error-at-point` | The flycheck or flymake error at point, with its location |
| `v` | `agy-paste-image` | The clipboard image, through agy's own Ctrl+V |
| `/` | `agy-slash-commands` | A menu of slash commands (`/compact`, `/rewind`, `/fork`, `/btw`, `/goal`, `/model`, `/mcp`, ...) |

### Managing

| Key | Command | What it does |
|-----|---------|--------------|
| `t` | `agy-toggle` | Show or hide the session window |
| `b` | `agy-switch-to-buffer` | Go to this directory's session (`C-u`: any session) |
| `B` | `agy-select-buffer` | Go to any session |
| `z` | `agy-toggle-read-only-mode` | Freeze the terminal so normal Emacs commands can search and copy |
| `M` | `agy-cycle-mode` | Shift+Tab: default, accept-edits, auto, plan |
| `y` | `agy-send-return` | RET, to confirm a prompt |
| `n` | `agy-send-escape` | ESC, to decline a prompt or interrupt a turn |
| `m` | `agy-transient` | The menu |

### Inside a session buffer

`agy-session-mode` is on in every session buffer:

- `S-RET` and `M-RET` insert a line break without submitting.
- `C-g` sends ESC (interrupt, close a panel), or quits normally while the terminal is read-only.

Everything else goes to agy as usual.

## Notifications

agy.el notifies you when a session is waiting, unless you are already looking at it. It hears about this in two ways.

1. The Stop hook (recommended). Run `M-x agy-install-hooks` once. It adds an entry named `agy-el` to `~/.gemini/config/hooks.json`, keeping any hooks already there. The entry runs `bin/agy-emacs-hook`, which forwards agy's Stop event to Emacs through `emacsclient`. It needs a running Emacs server (`M-x server-start`), and does nothing in agy sessions started outside Emacs.
2. The terminal bell. If you turn on Notifications in agy's `/config`, agy rings the bell at the end of a turn and agy.el treats the bell as a notification.

Set `agy-notification-function` to use your own notifier. The default prints a message and flashes the mode line.

`agy-event-functions` receives every forwarded hook as a plist `(:event "Stop" :buffer BUFFER :data PAYLOAD)`, where `PAYLOAD` is agy's hook JSON as a plist (`:terminationReason`, `:conversationId`, `:transcriptPath`, ...). To forward other events, add entries to `hooks.json` that run `agy-emacs-hook EVENT`; the script answers `{}`, which lets agy carry on unchanged.

## Customization

| Option | Default | Meaning |
|--------|---------|---------|
| `agy-program` | `"agy"` | The CLI executable |
| `agy-program-switches` | `nil` | Switches for every session, e.g. `("--model=gemini-4-argon-high")` |
| `agy-terminal-backend` | `eat` | `eat` or `ghostel` |
| `agy-display-window-fn` | below selected | How a new or toggled session window is shown |
| `agy-toggle-auto-select` | `nil` | Select the session window when it is shown |
| `agy-no-delete-other-windows` | `nil` | Protect session windows from `delete-other-windows` |
| `agy-confirm-kill` | `t` | Ask before killing sessions |
| `agy-large-buffer-threshold` | `100000` | Ask before sending a buffer bigger than this |
| `agy-enable-notifications` | `t` | Notify when a turn ends |
| `agy-notification-function` | message + mode-line flash | Called with a title and a message |
| `agy-start-hook` | `nil` | Run in each new session buffer |
| `agy-process-environment-functions` | `nil` | Return extra `VAR=VALUE` strings for a session |
| `agy-data-directory` | `~/.gemini/antigravity-cli/` | Where agy keeps its conversation index |
| `agy-hooks-file` | `~/.gemini/config/hooks.json` | File `agy-install-hooks` edits |

Every session gets `AGY_BUFFER_NAME` in its environment, naming its Emacs buffer.

## Notes

- Text is sent as a bracketed paste, then RET. If it ends in an `@path` mention, agy.el adds a space first, because agy's file-completion menu would otherwise take the RET.
- File references are written `@/abs/path (lines 10-20)`; agy reads the file itself.
- `agy-resume` reads `conversation_summaries.db` read-only with `sqlite3`, lists top-level conversations newest first, and starts `agy --conversation=ID` in that conversation's workspace.
- vterm is not supported yet. The backend layer is a set of `cl-defgeneric` methods (`agy--term-make`, `agy--term-send`, `agy--term-paste`, ...), so adding a backend means adding methods.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
