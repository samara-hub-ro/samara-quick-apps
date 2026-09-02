# Quick Apps

A discreet launcher in the Omarchy bar: the applications you actually use,
grouped into your own categories, one hover away — no click, no window, no
searching through a full application list.

![Panel preview](preview.png)

## What it does

One small icon in the bar. Rest the pointer on it and a translucent panel drops
down with your applications as icon tiles, under headings you name yourself
("Internet", "Work", "Games" — whatever you keep going back to). Click a tile to
launch, move the pointer away and the panel is gone.

The same panel opens from a keybinding, and that open is keyboard-driven: arrow
keys move between tiles, typing filters them, Enter launches, Escape closes.

The grid is edited in place — **Edit** turns on add, remove, rename and reorder
right in the panel, so you never have to hand-write a config file to change what
is in it (though you can; it is plain JSON).

## Requirements

| | |
|---|---|
| **Omarchy** | 4.x (the Quickshell `omarchy-shell`) |
| **Applications** | Anything with a `.desktop` entry — the panel reads the same application index as the Omarchy menu |

No daemon, no extra packages, nothing to enable.

## Install

```bash
omarchy plugin add https://github.com/samara-hub-ro/samara-quick-apps.git --enable --yes
```

Plugins run as unsandboxed code inside `omarchy-shell`. Drop `--enable --yes` to
review the source before enabling it:

```bash
omarchy plugin add https://github.com/samara-hub-ro/samara-quick-apps.git
# review ~/.config/omarchy/plugins/samara-hub-ro.quick-apps/
omarchy plugin enable samara-hub-ro.quick-apps --section center
```

It lands in the bar's centre section. Move it with:

```bash
omarchy bar move samara-hub-ro.quick-apps --section right
```

Updating and removal are the usual commands:

```bash
omarchy plugin update samara-hub-ro.quick-apps
omarchy plugin remove samara-hub-ro.quick-apps
```

> **Bar widgets need a full shell restart to re-instantiate.**
> `omarchy-shell shell rescanPlugins` reloads plugin *code*, but live bar
> widgets keep their existing instances. After installing or hacking on this
> plugin, run `omarchy restart shell` if the bar looks unchanged.

## Using it

**Bar icon**

| Action | Result |
|---|---|
| Hover | Open the panel (after `hoverOpenDelay`) |
| Left click | Open / close it |
| Right click | Open it straight into edit mode |

Moving the pointer off both the icon and the panel closes it again after
`hoverCloseDelay`, which is there so crossing the gap between the two does not
snap it shut. A panel you are editing never closes on its own.

**Panel**

- **Click a tile** to launch it. The panel closes as it launches.
- **Edit** turns the grid into an editor: rename a category in place, `＋` add an
  application to it, `‹ ›` move it up or down, `✕` delete it, and on each tile
  `✕` removes it while `‹ ›` reorder it. **＋ Category** adds a new group.
- Adding an application opens a searchable list of everything installed; the
  ones already in that category are marked and inert, so you can add several in
  a row without losing your place. **Esc** goes back.

**Keyboard**, once the panel is open from the keybinding (a hover or click open leaves the keyboard where it was; pressing **Edit** claims it too):

| Key | Result |
|---|---|
| `←` `→` `↑` `↓` | Move between tiles |
| `Enter` | Launch the selected application |
| Any letter | Filter the grid; `Backspace` deletes, `Esc` clears |
| `Tab` | Move to the neighbouring bar panel |
| `Esc` | Close |

A pointer-opened panel deliberately does **not** take the keyboard, so passing
the pointer over the bar never swallows a keystroke from whatever you were
typing in.

## A keybinding

Nothing is bound by default — pick a free key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + A", "Quick Apps", "omarchy-shell samara-hub-ro.quick-apps toggle")
```

`toggle`, `open`, `close`, `show` and `hide` are all accepted:

```bash
omarchy-shell samara-hub-ro.quick-apps toggle
```

On a multi-monitor setup the widget exists once per bar, and IPC reaches the
first one that registered — the same way Omarchy's own panels behave.

## Settings

Configured per bar entry in `~/.config/omarchy/shell.json`, or through Omarchy's
plugin settings UI, which builds a form from the manifest schema.

| Key | Type | Default | What it does |
|---|---|---|---|
| `openOnHover` | boolean | `true` | Open the panel when the pointer rests on the icon |
| `hoverOpenDelay` | integer (ms) | `140` | How long the pointer has to stay before it opens |
| `hoverCloseDelay` | integer (ms) | `280` | Grace period after the pointer leaves both icon and panel |
| `backgroundOpacity` | integer (%) | `82` | Opacity of the panel background |
| `iconSize` | integer (px) | `34` | Size of each application icon |
| `columns` | integer | `5` | Tiles per row — this is what sets the panel's width |
| `maxHeight` | integer (px) | `480` | Height at which the grid starts scrolling instead of growing |
| `showLabels` | boolean | `true` | Print application names under the icons |
| `seedOnFirstRun` | boolean | `true` | Fill the categories from installed applications the first time |
| `icon` | string | `󰀻` | Glyph shown in the bar |
| `configPath` | path | *(empty)* | Where the categories are stored; empty means `~/.config/omarchy/quick-apps.json` |

```jsonc
{
  "id": "samara-hub-ro.quick-apps",
  "columns": 6,
  "iconSize": 40,
  "backgroundOpacity": 65,
  "showLabels": false
}
```

## The categories file

Your applications are **not** kept in `shell.json` — they are content rather
than configuration, and the panel rewrites them every time you add or remove a
tile. They live in `~/.config/omarchy/quick-apps.json`:

```json
{
  "version": 1,
  "categories": [
    { "id": "internet", "name": "Internet", "apps": ["brave-browser", "chromium"] },
    { "id": "work",     "name": "Work",     "apps": ["obsidian", "slack"] }
  ]
}
```

`apps` holds desktop-entry ids — the `.desktop` filename without its extension.
The file is watched, so editing it by hand updates the panel immediately, and
anything malformed in it is ignored rather than thrown away. An application
whose `.desktop` file has since disappeared keeps its tile, greyed out, so you
can see what to remove instead of wondering where it went.

The first time the panel opens with nothing in it, it builds a starting set from
the applications you have installed, bucketed by their own XDG categories
(Internet, Development, Media, Office, System). It is a starting point, not a
policy — rename it, regroup it, delete what you do not want. Turn
`seedOnFirstRun` off to start from an empty panel instead.

## Transparency

`backgroundOpacity` sets the panel's alpha over whatever is behind it; the
colour itself comes from your theme's `popups.background`, so the panel follows
a theme switch like every other Omarchy surface.

For a frosted panel rather than a plain translucent one, blur its layer in
Hyprland — the surface is namespaced `samara-quick-apps`:

```lua
hl.config({ decoration = { blur = { enabled = true } } })
hl.layer_rule({ match = { namespace = "samara-quick-apps" }, blur = true })
```

Omarchy ships with compositor blur off, so the first line is the price of the
second — it turns blur on for the whole desktop.

## How it works

**Hover without breaking hover.** A popup that opens on hover has an awkward
problem: Omarchy's keyboard-capable panel base claims the entire screen as its
input region, so the moment it opens, the bar stops seeing the pointer — the
icon "un-hovers" and the panel would close itself. This plugin ships its own
panel surface, adapted from `Ui/KeyboardPanel.qml`, whose input region is
narrowed to the card. The bar keeps its own hover, and the widget decides
"open" from the union of the icon's hover and the card's, with a delay on each
edge.

**Except when the keyboard is involved.** Hyprland hands keyboard focus back to
whatever is under the pointer the moment a layer surface steps down from its
focus grab, so a panel that wants to keep the keyboard has to be under the
pointer wherever the pointer is. When the panel is opened from the keybinding
(or a click), it takes the whole screen as its input region — which is also what
gives outside clicks something to land on for dismissal. Hover-opened, it stays
narrow and takes no keyboard focus at all.

**Launching** goes through the shell's own application library when the running
bar exposes it, so it gets the same icon resolution and the same launch feedback
as the Omarchy menu, and falls back to the desktop entry's own launch path
otherwise.

## Troubleshooting

**The icon is not in the bar.** Confirm it is enabled and placed:
`omarchy plugin list | grep quick-apps`. Then `omarchy restart shell` —
`rescanPlugins` alone will not re-instantiate a bar widget.

**The panel does not open on hover.** Check `openOnHover` is on and that
`hoverOpenDelay` is not set higher than you expect. A click on the icon always
opens it regardless.

**The keybinding opens nothing.** Test the call directly:
`omarchy-shell samara-hub-ro.quick-apps toggle`. If that works, the binding is
the problem — `omarchy menu keybindings --print` shows what is registered.

**Typing does not filter.** Type-to-filter only works on a panel that owns the
keyboard, which means one opened from the keybinding — a hover or click open
deliberately leaves the keyboard alone.

**An icon is missing or generic.** The application's `.desktop` entry names an
icon your theme does not carry. The panel falls back to a generic one rather
than leaving a hole.

## Versioning

Semantic versioning. The version in `manifest.json` is the source of truth and
matches the git tag (`v1.0.0`) and the GitHub release for each version.
`omarchy plugin update` tracks the default branch, so it picks up whatever is on
`main`; the tags and [CHANGELOG.md](CHANGELOG.md) are there to pin or review a
specific version.

```bash
omarchy plugin list | grep quick-apps        # the version you are running
```

## License

MIT. See [LICENSE](LICENSE). The panel surface is adapted from Omarchy's own
`shell/Ui/KeyboardPanel.qml`, also MIT.
