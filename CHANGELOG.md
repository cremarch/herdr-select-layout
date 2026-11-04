# Changelog

## 0.1.0

- Layouts `even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical` and `tiled`
  (tmux `prefix M-1` to `M-5`), plus `next` (`prefix Space`) and `spread` (`prefix E`).
- `config.toml`: main pane size and choice, tiled orientation.
- Panes keep their processes and scrollback; a failed rearrangement moves parked panes back;
  runs on the same tab are serialized; errors show as a herdr notification.
