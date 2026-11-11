# Terminal appearance

Nirux terminals follow the appearance settings of your Ghostty configuration. You don't need Ghostty installed: only its config file is read.

## Which files are read

The same files as Ghostty, in the same order:

1. `$XDG_CONFIG_HOME/ghostty/config` and `config.ghostty` (`~/.config` when `XDG_CONFIG_HOME` is unset);
2. `config` and `config.ghostty` in `~/Library/Application Support/com.mitchellh.ghostty/`;
3. any `config-file` includes.

The configuration is read each time a terminal opens. A change applies to terminals you open afterwards; open ones keep their settings.

## Which keys are honored

Only appearance keys:

| Group | Keys |
| --- | --- |
| Fonts | `font-family*`, `font-style*`, `font-feature`, `font-variation*`, `font-codepoint-map`, `font-synthetic-style`, `font-size`, `font-thicken*`, `font-shaping-break`, the `adjust-*` cell metrics |
| Colors | `theme`, `background`, `foreground`, `palette`, `palette-generate`, `palette-harmonious`, `bold-color`, `minimum-contrast`, `faint-opacity`, `alpha-blending`, `window-colorspace`, the `selection-*` and `search-*` colors, and the deprecated `bold-is-bright`, `cursor-invert-fg-bg`, `selection-invert-fg-bg` |
| Cursor | `cursor-color`, `cursor-text`, `cursor-opacity`, `cursor-style`, `cursor-style-blink` |

Everything else is ignored, including keybinds, window and macOS options, padding, opacity, and shell or command settings: Nirux handles input, layout and shells itself.

What you don't set keeps Nirux's defaults: 14 pt, a blinking block cursor and the Afterglow palette. If you set your own `background` or `foreground`, Afterglow's cursor and selection colors are dropped too, so they stay visible against your colors.

## Themes

`theme` accepts a theme name, an absolute path, or a `light:…,dark:…` pair. Nirux always uses the dark variant, because its window is always dark.

Names are looked up in `$XDG_CONFIG_HOME/ghostty/themes` (`~/.config/ghostty/themes` by default), then in the themes bundled with Ghostty.app when it is installed. A theme that can't be found is ignored.

As in Ghostty, a theme overrides the defaults and your explicit settings override the theme. Nirux's default colors are left out as soon as the theme contributes any setting.

## When something looks wrong

Invalid lines, in your config or in its theme, are skipped one by one instead of invalidating the whole file. Look for `[GhosttyConfig]` messages in Console.app.

To make Nirux ignore your Ghostty configuration:

```bash
defaults write com.xikimay.nirux IgnoreGhosttyConfig -bool true
```

`defaults delete com.xikimay.nirux IgnoreGhosttyConfig` undoes it.
