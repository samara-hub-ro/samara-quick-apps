# Changelog

All notable changes to this plugin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version in `manifest.json` is the source of truth and matches the git tag
for each release.

## [Unreleased]

## [1.1.0] — 2026-09-03

### Added

- **Most used, on top.** Above the categories, a ranking of the applications
  you actually reach for, each with its launch count, and beside it a chart of
  the same numbers. Click a row to launch it like any tile. Hidden while you
  are editing or filtering, so it never gets in the way of either.
- **A launch counter on every tile**, as a small badge in the colour of its
  category. It counts opens **from the launcher, since that application was
  added to its category** — not since the machine was installed, and not opens
  from anywhere else. Take an application out of a category and its history
  goes with it; put it back and it starts from zero again.
- **The usage chart**: one glowing arc per application on its own orbit, its
  length the share of that application's count against the busiest one, inside
  a HUD frame carrying the total. Deliberately not a bar chart or a pie — the
  exact numbers are already in the rows beside it, so the chart's job is the
  shape of the habit at a glance.
- **Colour per category.** Each one washes its own background — 70%
  transparent by default, enough to group the tiles under it and far too faint
  to fight the icons — and lends its colour to its heading, its tile
  highlights, its launch badges and its arc in the chart. Categories that have
  never been given a colour follow a built-in palette by position, so this
  needs no configuration to look deliberate. In edit mode, the swatch beside a
  category's name unfolds the palette; `A` puts it back on automatic.
- **Drag a category into place.** In edit mode every category grows a handle on
  its left: press it and drag, an insertion line shows where it will land, and
  the move is committed when you let go. The `↑ ↓` buttons remain for
  one-step nudges.
- **New settings**: `showMostUsed`, `mostUsedCount`, `showUsageChart`,
  `showLaunchCounts`, `countIcon` and `categoryTint`.
- **Two more IPC verbs**: `edit` opens the panel straight into edit mode (for a
  second keybinding), and `resetCounts` puts every counter back to zero without
  disturbing the categories.

### Changed

- The category reorder buttons are now `↑ ↓` rather than `‹ ›`; they always
  moved a category up and down the list, and now they say so.

### Notes on behaviour

- **Counts live in their own file**, `~/.config/omarchy/quick-apps-usage.json`,
  beside the categories rather than inside them: they change on every launch,
  and rewriting the file you hand-edit once per launch is a good way to lose a
  hand edit. It is reconciled against the categories whenever they change —
  new applications get an entry, removed ones lose theirs — and, unlike the
  categories, a copy that does not parse is rebuilt from zero rather than left
  to rot, because counts are derived data and not something you wrote.
- **Upgrading from 1.0.0 starts every counter at zero**, dated to the first run
  of this version. There was nothing to carry over.

## [1.0.0] — 2026-09-02

First public release.

### Added

- **Bar widget** for the Omarchy 4 Quickshell bar: a single icon that drops a
  panel of application tiles grouped under categories you name yourself.
- **Hover to open**, with a delay on each edge so the panel does not appear
  while the pointer is merely passing by, and does not vanish while the pointer
  crosses the gap from the icon to the card. Click opens and closes it too;
  right click opens it straight into edit mode.
- **Keyboard open** over IPC (`omarchy-shell samara-hub-ro.quick-apps toggle`),
  for binding to a key. That open takes keyboard focus and enables arrow-key
  navigation, `Enter` to launch, type-to-filter with `Backspace`/`Esc`, `Tab` to
  the neighbouring panel, and `Esc` to close.
- **In-place editing**: add and remove applications from a searchable list of
  everything installed, rename categories, reorder both categories and tiles,
  and add or delete categories — all from the panel, with no file to hand-write.
- **First-run seed** that fills the categories from the applications actually
  installed, bucketed by their own XDG categories, so a fresh install opens onto
  something usable instead of an empty card.
- **Settings schema** in the manifest (`openOnHover`, `hoverOpenDelay`,
  `hoverCloseDelay`, `backgroundOpacity`, `iconSize`, `columns`, `maxHeight`,
  `showLabels`, `seedOnFirstRun`, `icon`, `configPath`), so Omarchy's plugin
  settings UI builds the form automatically.
- **Themed, translucent panel** — the background colour follows the theme's
  `popups` surface and its alpha is yours to set, with a Hyprland `layer_rule`
  documented for blurring the `samara-quick-apps` namespace.

### Notes on behaviour

- **The panel owns its input region.** Omarchy's keyboard-capable panel base
  claims the whole screen, which kills the bar's own hover the instant a popup
  opens — fatal for a hover launcher. This plugin's surface narrows that region
  to the card when opened by hover, and widens it to the screen when opened from
  the keyboard, because Hyprland returns keyboard focus to whatever is under the
  pointer once a layer surface leaves its focus grab.
- **A hover-opened panel never takes the keyboard**, so passing the pointer over
  the bar cannot swallow a keystroke from the window being typed in.
- **Applications live in their own file**, `~/.config/omarchy/quick-apps.json`,
  not in `shell.json`: the panel rewrites them as tiles are added and removed.
  The file is watched, so hand edits appear immediately; malformed content is
  ignored rather than overwritten, and a tile whose `.desktop` entry has gone
  stays visible and greyed out instead of silently disappearing.
- **Launching prefers the shell's own application library** when the running bar
  exposes it, for the same icon resolution and launch feedback as the Omarchy
  menu, and falls back to the desktop entry itself otherwise.

[Unreleased]: https://github.com/samara-hub-ro/samara-quick-apps/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/samara-hub-ro/samara-quick-apps/releases/tag/v1.1.0
[1.0.0]: https://github.com/samara-hub-ro/samara-quick-apps/releases/tag/v1.0.0
