# Save Scores

SourceMod plugin for Counter-Strike: Source: when a player leaves and comes back during the same map,
his kills, deaths and (optionally) cash are restored. Restarting the game with `mp_restartgame` clears
the saved scores.

Port of [Save Scores](https://forums.alliedmods.net/showthread.php?t=74975) 1.3.4 by exvel to
SourceMod 1.12+ and CS:S x64 (no gamedata). See [CHANGELOG.md](CHANGELOG.md) for the changes.

## Installation

Extract the release archive matching your SourceMod version (`-sm1.12` or `-sm1.13`) into `cstrike/`:

- `addons/sourcemod/plugins/SaveScores.smx`
- `addons/sourcemod/translations/savescores.phrases.txt`

The config `cfg/sourcemod/plugin.savescores.cfg` is created on first load.

Optional: the `clientprefs` extension, for the "Reset Score" item of the `!settings` menu.

## Cvars

| Cvar | Default | Description |
| - | - | - |
| `sm_save_scores` | `1` | Enable save scores |
| `sm_save_scores_tracking_time` | `20` | Minutes a saved score is kept, `0` = until the end of the map |
| `sm_save_scores_forever` | `0` | Keep saved scores across map changes and game restarts until `sm_save_scores_reset` (lost on server restart or plugin reload) |
| `sm_save_scores_allow_reset` | `1` | Allow players to reset their score (`resetscore` console command, `!settings` menu item) |
| `sm_save_scores_css_cash` | `1` | Also restore the cash of reconnecting players |
| `sm_save_scores_css_spec_cash` | `1` | Save the cash of players moving to spectators and give it back when they join a team again |

## Commands

| Command | Access | Description |
| - | - | - |
| `resetscore` | everyone | Reset your kills and deaths (if `sm_save_scores_allow_reset` is `1`) |
| `sm_save_scores_reset` | generic admin | Clear every saved score and reset everyone's score and cash |

## With other plugins

- [ResetScore](https://github.com/srcdslab/sm-plugin-ResetScore) (`!rs`): compatible. A score reset with
  `!rs` is never undone on reconnect. If ResetScore is installed, set `sm_save_scores_allow_reset 0` to
  keep a single reset command.
- Servers that hand out a fixed amount of money every round (for example
  [RoundMoney](https://github.com/srcdslab/sm-plugin-RoundMoney)): set `sm_save_scores_css_cash 0` and
  `sm_save_scores_css_spec_cash 0`, restoring cash is useless there.

## License

GPL-3.0, see [LICENSE](LICENSE). Original plugin by exvel.
