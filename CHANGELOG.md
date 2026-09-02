# Changelog

All notable changes to this plugin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version in `manifest.json` is the source of truth and matches the git tag
for each release.

## [Unreleased]

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

[Unreleased]: https://github.com/samara-hub-ro/samara-quick-apps/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/samara-hub-ro/samara-quick-apps/releases/tag/v1.0.0
