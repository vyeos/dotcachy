# dotcachy

A monochrome Hyprland desktop for CachyOS: flat, square and graphite grey, built on [Noctalia](https://github.com/noctalia-dev/noctalia-shell) with one custom plugin that replaces the bar, panels and launcher.

![The desktop with the launcher open](docs/screenshots/desktop.png)

![The bar](docs/screenshots/bar.png)

## Launcher

`Super + Space` searches the whole desktop and learns what you pick.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/launcher-defaults.png" alt="Searching for the default terminal, with its keybind on the right"></td>
    <td width="50%"><img src="docs/screenshots/launcher-actions.png" alt="The Ctrl+K action menu"></td>
  </tr>
  <tr>
    <td align="center">Default apps, with keybinds on the right</td>
    <td align="center"><code>Ctrl + K</code>: everything a result can do</td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/launcher-maths.png" alt="A maths answer in the results"></td>
    <td><img src="docs/screenshots/launcher-emoji.png" alt="Emoji search"></td>
  </tr>
  <tr>
    <td align="center">Maths and unit conversion</td>
    <td align="center">Emoji with <code>:fire</code></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/launcher-clipboard.png" alt="Clipboard history search"></td>
    <td><img src="docs/screenshots/launcher-quicklink.png" alt="A YouTube quicklink search"></td>
  </tr>
  <tr>
    <td align="center">Clipboard history with <code>cb</code></td>
    <td align="center">Quicklinks like <code>yt lofi beats</code></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/launcher-webapp.png" alt="The Create Web App form"></td>
    <td></td>
  </tr>
  <tr>
    <td align="center">Turn any site into an app, icon included</td>
    <td></td>
  </tr>
</table>

- **Searches** apps, web apps, open windows, files in your home folder, toggles, Wi-Fi and Bluetooth devices, power actions, panels and keyboard shortcuts.
- **Learns** from what you pick. It shows pinned items, suggestions and recents before you type, and tolerates typos.
- **Runs in place:** maths, unit conversion, emoji (`:`), clipboard (`cb`), wallpapers (`wp`), quicklinks, and DuckDuckGo when nothing matches.
- **Every result has actions** on `Ctrl + K`: pin, alias, set or change its keybind, open its file location (`Ctrl + Enter`) and more.
- **Default apps:** change your terminal, browser, file manager or editor from the launcher.

## Panels

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/panel-cc.png" alt="Control center"></td>
    <td width="50%"><img src="docs/screenshots/panel-calendar.png" alt="Calendar"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/panel-calc.png" alt="Calculator"></td>
    <td><img src="docs/screenshots/panel-clip.png" alt="Clipboard history"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/panel-shortcuts.png" alt="Keyboard shortcuts"></td>
    <td><img src="docs/screenshots/panel-power.png" alt="Battery and power profile"><br><br><img src="docs/screenshots/panel-session.png" alt="Session actions"></td>
  </tr>
</table>

Also included: Wi-Fi, Bluetooth, audio, GPU mode, emoji picker, window switcher, wallpaper picker and a notification drawer.

## The rest of the rice

- **Theme:** one graphite palette across the shell, Hyprland borders, GTK 3 and 4, Qt, KDE apps and kitty.
- **Fonts:** Graphite Sans and Graphite Mono, static cuts of Recursive, set as the system defaults.
- **Hyprland:** Lua config with square corners, 1 px borders, no blur or shadows, and quick animations.
- **Lock and login:** a matching lock screen and greeter.
- **Screenshots:** `graphite-shot` saves, copies and notifies. Clicking the notification opens the shot in Swash for annotating.

## Main shortcuts

| Keys | Action |
| --- | --- |
| `Super + Space` | Launcher |
| `Super + X` | Control center |
| `Super + Ctrl + /` | All keyboard shortcuts |
| `Super + V` | Clipboard history |
| `Super + .` | Emoji |
| `Super + C` | Calculator |
| `Super + Tab` | Window switcher |
| `Super + Esc` | Session menu |
| `Super + Enter` | Terminal |
| `Super + Shift + Enter` | Browser |

## Install

This repo is my `~/.config`, tracked with an allowlist, so back up your own first. Some paths use my username, and a few things suit my laptop (the GPU panel needs `supergfxctl`). Expect to adjust them.

You'll need Hyprland 0.57+ (Lua config), Noctalia 5.4+, Go, `fd`, `wl-clipboard`, ImageMagick, NetworkManager, BlueZ, PipeWire, UPower, kitty and Thunar. Web apps use Brave Origin.

```sh
git clone https://github.com/vyeos/dotcachy ~/.config   # into an empty ~/.config
ln -s ../../../.config/noctalia/fonts ~/.local/share/fonts/Graphite
ln -s ../../.config/noctalia/bin/graphite-shot ~/.local/bin/graphite-shot
sudo sh ~/.config/noctalia/greeter/install.sh           # optional: the login screen
```

The plugin in `noctalia/plugins-local/graphite` compiles its Go helpers the first time it starts.

## How it's built

Panels and bar widgets are Luau, which is what Noctalia plugins run. Everything else is Go, using only the standard library, in `noctalia/plugins-local/graphite/src`.
