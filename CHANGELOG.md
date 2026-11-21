## Release Notes

## [1.3.4-srcdslab]

Port of Save Scores 1.3.4 by exvel
([AlliedModders thread](https://forums.alliedmods.net/showthread.php?t=74975)) to SourceMod 1.12+
and Counter-Strike: Source x64. The upstream release is imported as is in the first commit of this
repository.

### Changed

- Rewritten in the new SourcePawn syntax (`#pragma newdecls required`, methodmaps), in a single
  `SaveScores.sp` file. The plugin file is now `SaveScores.smx` (was `savescores.smx`); cvar names,
  the config file (`cfg/sourcemod/plugin.savescores.cfg`) and the translation file are unchanged.
- Saved scores are kept in memory (`StringMap`) instead of a SQLite database: no synchronous
  `VACUUM`/`DELETE`/`INSERT` on the game thread at map start, map end or admin reset, and no
  `savescores.sq3` file. In forever mode, saved scores now last until the server restarts or the
  plugin is reloaded.
- Cash is read and written through the `m_iAccount` netprop (`GetEntProp`/`SetEntProp`) instead of a
  raw send prop offset: no gamedata, works on x86 and x64.
- Steam IDs come from `GetClientAuthId(AuthId_Steam2)` (replaces the removed `GetClientAuthString`).
- Chat colors use MultiColors instead of the old `colors.inc`.
- `mp_restartgame` is detected by comparing the game time on `round_start` instead of a timer.
- Restoring a score happens one frame after the team join (it used to wait for the SQL query).

### Fixed

- A player who reset his score (with `resetscore`, the settings menu or another plugin such as
  ResetScore) and left with 0 kills, 0 deaths and the start money kept his older saved entry, so the
  reset was undone on reconnect in forever mode. An empty score now removes the saved entry.
- `player_team` events fired by a disconnect no longer trigger a restore.
- Players already in game when the plugin is loaded late are no longer treated as just connected.

### Added

- Translations: fr, es, pt, chi, tr, it, ua, zho, cze for every phrase, plus the server and admin
  replies (`Players only`, `Save Scores disabled`, `All scores reset`) that were hard-coded in English.

### Removed

- Support for games other than Counter-Strike: Source (Team Fortress 2 needed the 32-bit only
  CalcPlayerScore extension; Half-Life 2: Deathmatch, Day of Defeat: Source and generic games).
- Plugin Autoupdater support (its update server, savescores.googlecode.com, is gone).
- Automatic unloading of the TF2 `scoremod.smx` plugin.
