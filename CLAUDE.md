# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`hooji.expose` is an Omarchy shell plugin (QML/Quickshell) that gives Hyprland a
Mission Control–style window overview: four fingers up lays every window of the
current workspace out in a grid, four fingers down restores it. Three files:
`manifest.json`, `Expose.qml` (the overlay), `SwipeSource.qml` (the gesture source).

It lives at `~/.config/omarchy/plugins/hooji.expose/` — the path the Omarchy
shell scans for third-party plugins. It is not a standalone app and there is no
build step; the shell loads the QML directly.

## Commands

```bash
# Reload after editing (saving under ~/.config/omarchy/plugins/ auto-reloads,
# but this forces it):
omarchy-shell shell rescanPlugins

# Open / close / toggle the overlay without the touchpad:
omarchy-shell shell summon hooji.expose '{}'
omarchy-shell shell hide hooji.expose
omarchy-shell shell toggle hooji.expose '{}'

# Confirm it is discovered and enabled:
omarchy-shell shell listPlugins

# The plugin's own IPC target — status is JSON, and the fastest way to see
# what the overlay thinks is on screen without screenshotting it:
omarchy-shell expose status
omarchy-shell expose open        # close, toggle, select <i>, activate, focus <i>
omarchy-shell expose gestures off
omarchy-shell expose set threshold 260

# Full shell restart (needed only when a reload wedges):
omarchy-restart-shell
```

**`keepLoaded: true` means a file save does not remount the object.** The shell
logs `Local plugin changed, reloading` and rescans, but the already-mounted item
keeps running the old code — edits appear to do nothing, including edits meant to
debug why nothing is happening. Run `omarchy restart shell` after every change.

There is no test suite. Verification is manual: reload, swipe, and read
`console.warn` output from the shell process (`journalctl --user -f` or the
terminal that launched `quickshell -p $OMARCHY_PATH/shell`). QML errors from a
failed plugin load surface as `panel plugin hooji.expose failed to load: …`.

The gesture reader needs the user to be in the `input` group (`groups` should
list `input`) so it can read `/dev/input/event*`, and `libinput-tools` installed.
Both failures now raise `SwipeSource.problem` and surface as one desktop
notification instead of a lone WARN in the journal.

Keyboard paths can be exercised headlessly with `wtype -k Right` and friends
while the overlay holds the keyboard.

## Architecture

### Plugin contract with the shell

The shell (`/usr/share/omarchy/shell/shell.qml`, docs in
`/usr/share/omarchy/shell/README.md`) loads `entryPoints.overlay` into a
`Loader` and injects, when the root object declares them: `shell`, `manifest`,
`omarchyPath`. `Expose.qml` declares all three.

Overlay plugins must expose `open(payloadJson)`, `close()`, and a readable
`opened` property — `shell.toggle` reads `opened` to decide which way to go.
`keepLoaded: true` in the manifest keeps the object mounted between summons,
which this plugin *requires*: the libinput reader in `SwipeSource` must be
running before any gesture happens, and a summon-on-demand plugin would only
start listening after it was already open.

Styling comes from `qs.Commons` (`Color.background`, `Color.accent`,
`Color.foreground`, `Style.fontFamily`), which tracks the active Omarchy theme.
Do not hardcode colors or fonts.

### Gesture pipeline (`SwipeSource.qml`)

Hyprland's gesture API only fires once, at the *end* of a swipe, which cannot
drive a follow-the-fingers animation. So this opens the touchpad a second time
in parallel:

1. A `Process` runs `libinput list-devices | awk …` to find the touchpad's
   `/dev/input/eventN` node (not stable across boots — never hardcode it).
2. `startReader()` then spawns `stdbuf -oL libinput debug-events --device <node>`
   and parses `GESTURE_SWIPE_BEGIN/UPDATE/END` lines with the three regexes at
   the top of the file. libinput does not `EVIOCGRAB` in debug-events mode, so
   Hyprland still receives the same events — this is a listener, not an
   interceptor.
3. It emits `began()`, `moved(dx, dy, axis)`, `ended(dx, dy, vx, vy, cancelled)`.
   Deltas are the *unaccelerated* pair (fields 5/6 of the update regex);
   accelerated deltas are tuned for a cursor and make the overview lurch.
   `vx/vy` come from a ~80ms tail of samples, which is what distinguishes a
   flick from a slow drag.

Only 4-finger gestures are consumed; 3-finger stays with Hyprland. If the reader
process dies, `onExited` schedules a restart via the 2s `restart` Timer.

Two subtleties that are easy to reintroduce: `reader.running` is set by hand in
`startReader()` rather than bound to `device` (a binding can flip `running`
before `command` picks up the new path, handing libinput an empty `--device`);
and the first `GESTURE_SWIPE_UPDATE` of a gesture has no sequence number, hence
the optional group in `updateRe`.

### Overlay (`Expose.qml`)

Everything on screen is a function of one number, `progress` (0 = desktop,
1 = full overview). While `dragging` it tracks the fingers exactly; the
`Behavior` animation is disabled during the drag and only smooths what happens
after release.

**Nothing is ever moved.** Real windows keep their geometry; what animates is a
`ScreencopyView` live capture of each toplevel drawn on a `WlrLayer.Overlay`
layer-shell window above a scrim. This is deliberate — the layout is
`scrolling`, and a real "arrange into a grid then restore" would destroy the
column state with no way to ask Hyprland to put it back.

- `snapshot()` captures the toplevels of the active workspace on
  `targetMonitor`, converting `lastIpcObject.at`/`.size` into monitor-local
  logical pixels (the overlay's coordinate space), sorted top-left to
  bottom-right.
- `slot()` picks the grid. It tries *every* column count and keeps the one whose
  worst-case scale over the whole window set is largest — `sqrt(count)` columns
  is wrong on a wide screen (3 windows land in a 2×2 with a hole at half the
  size a 3×1 would give). Every window must score the same candidate grid, so
  the scoring loop reads `root.windows`, not just the one window.
- Each thumbnail interpolates from the window's real geometry to its slot by
  `progress`, so at `p = 0` the thumbnail sits exactly on top of the real
  window and the transition reads as the desktop folding up.
- Keyboard focus (`WlrKeyboardFocus.Exclusive`) is only taken at
  `progress > 0.99 && !dragging`, so a swipe that goes nowhere does not eat
  keystrokes.

The plugin owns all four swipe directions, not just vertical: Hyprland's native
workspace swipe cannot be toggled at runtime, so horizontal-while-closed
dispatches `workspace e+1`/`e-1` itself (see `naturalWorkspaceSwipe`), and
horizontal-while-open walks the grid selection instead.

Selecting a window closes the overlay first and dispatches focus 240ms later:
the panel holds an exclusive keyboard grab while open, and focusing before the
grab drops lets Hyprland hand focus back to whatever was focused before it,
silently undoing the pick. An empty workspace refuses to open at all rather than
showing a bare scrim.

**Dispatch grammar depends on how Hyprland is configured.** Omarchy 4 uses Lua,
where the classic `focuswindow address:0x…` string is rejected by the Lua
evaluator (`')' expected near 'address'`) and does nothing — silently, because
the IPC error never reaches the caller. Everything goes through
`root.dispatch(luaForm, classicForm)`, which picks the form off
`Hyprland.usingLua`; the Lua forms are `hl.dsp.focus({ window = "address:0x…" })`
and `hl.dsp.focus({ workspace = "e+1" })`. The error text from `hl.focus` lists
the accepted keys, which is the fastest way to find the right shape for a
dispatcher.

A layer-shell surface can hold the keyboard while nothing inside it has active
focus, and then every key press is dropped. `keys.forceActiveFocus()` on
`progress > 0.99` is what makes the key handlers fire at all.

### Settings, IPC, and the pause switch

The shell has **no settings channel for overlays** — `schema`/`defaults` in a
manifest are read for bar widgets only, and the panel Loader injects nothing of
the sort. Settings are therefore read straight off the plugin's own entry in
`shell.json` (`root.settings`, with `setting(key, fallback)` accessors) and
written back through `shell.updateEntryInline()`, the same writer the shell uses.
`config.example.json` documents the keys. The entry itself is what marks the
plugin enabled: drop a key, never the entry.

`IpcHandler { target: "expose" }` exposes `status` (JSON), `open`/`close`/
`toggle`, `select`, `activate`, `focus`, `gestures`, `set`. Quickshell IPC
arguments are all required strings, hence `activate()` beside `focus(index)`,
and `set` parses its value as JSON so numbers and booleans stay typed.

Pausing rides omarchy's own toggle mechanism: `expose-gestures-paused` is a flag
file under `~/.local/state/omarchy/toggles/` that `omarchy toggle` touches or
removes. A `FileView` watches the *directory* (so creation is caught, not just
removal) and a `test -f` Process reads it. Pausing sets `SwipeSource.enabled =
false`, which stops the libinput process rather than merely ignoring it.

## Conventions

Comments here explain *why* a non-obvious choice was made (and often what the
obvious alternative breaks), not what the line does. Match that density and
tone; the existing comments are the main documentation of the tricky parts.
`manifest.json`'s `description` is in Vietnamese — keep user-facing manifest
strings consistent with that if you change them.
