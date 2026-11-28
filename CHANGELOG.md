# ReadyToWork Changelog

## 1.59.0 (2026-11-28): Fast loot, Mailbox, per-character settings & quiet changelog

- **New module — Fast loot (`FastLoot.lua`):**
  - Collects all unlocked loot slots in one frame on `LOOT_READY` / `LOOT_OPENED` without the ~0.4s loot window delay or flash, while standing aside for **Auto-open** container loot sessions.
  - Safely suppresses the brief `LootFrame` visual flash with `SetAlpha(0)` (never calling `Hide()` or `CloseLoot()` while server loot is in flight) and immediately restores the window for `LOOT_BIND_CONFIRM`, locked/Master Loot slots, full-bag errors (`ERR_INV_FULL`), modifier-key holds (`Shift`), or a `0.30s` safety reveal check.
  - Supports **Hide loot window while fast-looting** and **Auto-loot even when WoW Auto Loot is off** toggles plus an inline **Enable WoW Auto Loot** quick action (`/rtw loot [on|off|hide|always]`).
- **New module — Mailbox (`Mailbox.lua`):**
  - Adds a compact Inbox bottom bar with **Gold only** and **Collect all** plus a high-contrast emerald dropdown beside `To:` on **Send Mail** for **Alts & recent recipients**.
  - Collects gold even when your bags have `0` free slots, honors a configurable **Keep free bag slots** reserve (`0–10`) for item attachments, and skips CoD, GM mail, and failed/`Unique` items cleanly with one chat summary.
  - Strictly zero-loss: never calls `DeleteInboxItem`, `ReturnInboxItem`, `GetInboxText`, or `SendMail`.
- **WoW Forever full character names & Per-character settings (`Core/Core.lua`, `Core/Migrate.lua`, `Core/Features.lua`):**
  - Split **Sell & repair**, **Auto-open**, **Quick destroy**, **Spell ranks**, and **Talk & quests** per character while keeping **Fast loot**, **Mailbox**, **Bar profiles** (per-char/per-spec storage), **Quest markers**, **Gather tooltips**, **Flight timer**, **Minimap buttons**, and frame positions account-wide; existing characters automatically inherit their lists while brand-new level-1 alts start clean.
  - Added **Copy from character** under **General → Character settings**, each per-character page's `···` menu, and `/rtw copy [character] [helper]`.
  - Resolved WoW Forever two-word character names (`UnitFullName("player")` / `UnitNameFromGUID` / `GetPlayerInfoByGUID`, e.g. `"Hexual Angst"`) and live `PLAYER_LEVEL_UP` level updates across character lists, Mail recipients, and `/rtw copy`.
- **Quick destroy & Changelog UI polish (`QuickDestroy.lua`, `UI/Intro.lua`, `UI/Window.lua`):**
  - Fixed **Quick destroy** showing while plenty of bag slots are free even when manually included items are in your bags.
  - Full **Introduction** now auto-shows only for brand-new installs (`"Show update notifications in chat"` opt-in, off by default), compact **New module** popup shows only when `newModule = true`, and a quiet **What's new** button lives at the bottom of the Settings sidebar (`/rtw updates`), with its unread dot completely hidden once read and **General** workspace buttons grouped above **Character settings**.

## 1.58.0 (2026-11-27): Batch Sell items, quest count badges & Hyjal/Riverglades flight times

- **Sell & repair (`AutoVendor.lua`):** Fixed manual **Sell items (#)** stopping after a single stack; clicking once now sells all eligible gray and opted-in white items across async merchant ticks (unless Blizzard blocks bulk sales).
- **Quest markers (`QuestKills.lua`, `Core/Features.lua`, `UI/Window.lua`):** Added high-contrast remaining kill/loot count pill badges on nameplate markers, cursor hover markers, and Settings previews (`Show remaining count`).
- **Flight timer (`FlightTimes.lua`, `FlightTimer.lua`):** Added Mount Hyjal (`Summit of Eternity`, `Tainted Foothills`) and Riverglades (`Farholde Keep`, `Rog'mar`) route estimates and clearer untimed-route wording.

## 1.57.3 (2026-11-26): Intro checkbox & close button fix

- **Introduction window (`UI/Intro.lua`, `UI/Widgets.lua`):**
  - Fixed `W.Checkbox` click synchronization so clicking **Don't show automatically on future updates** reliably displays its checkmark/accent state and saves `skipUpdates`.
  - Added a top-right **Close (`X`)** button, clean footer/release-note text wrapping, and `OnHide` persistence for `seenVersion`.

## 1.57.2 (2026-11-26): Clean fan button tooltips

- **Bar profiles & Quick destroy buttons:**
  - Opening the fan immediately dismisses the main button's tooltip and suppresses it while the fan stays open (and right-clicking hides it before opening Settings; closing the fan hides any open tile tooltip).
  - Main-button and fan-tile tooltips now anchor toward the interior of the screen and away from the fan axis (`ANCHOR_LEFT` / `ANCHOR_RIGHT` on vertical fans; `ANCHOR_TOP` / `ANCHOR_BOTTOM` on horizontal fans) so the buttons can sit anywhere on screen cleanly.

## 1.57.1 (2026-11-25): Custom Orc Peon icon, UI hierarchy, chat toggles & keybindings

- **Custom branding & icons:**
  - Added a custom Orc Peon icon (`Media/icon_rtw.png`) with a circular mask on the minimap button and updated **Minimap buttons** to use a distinct spyglass icon.
- **Settings UI hierarchy & polish:**
  - Stacked child switches directly beneath their parent toggle with an indented L-shaped connector (`Include gray quests`, `Use guild funds first`, `Lock minimap button`) and dimmed/disabled dependent sliders and choices when their parent turns them off.
  - Fixed multi-line `note()` text wrapping, widened the header subheading margin, added 4 symmetric **Sell & repair** status chips (`Sold today`, `Sold lifetime`, `Repairs today`, `Repairs lifetime`), renamed pages for clarity (`Sell & repair`, `Auto-open`, `Gather tooltips`, `Minimap buttons`) with old-name aliases preserved, reordered the **World** section (`Quest markers`, `Talk & quests`, `Gather tooltips`, `Flight timer`), and standardized on American English (`Behavior`, `gray`, `dialog`).
- **Chat reporting controls:**
  - Added a **Report in chat** toggle (off by default; `/rtw bars chat on|off`) to **Bar profiles**, plus sealed remaining unguarded automatic chat prints across **Spell ranks**, **Sell & repair**, and **Quick destroy**.
  - Added a quiet once-per-version chat notice on first load after an update.
- **Keybindings & Gather tooltips:**
  - Moved ReadyToWork's keybindings into their own **Options > Keybindings > ReadyToWork** category.
  - Cleaned up **Gather tooltips** and documented Forever `1.60.1.71139` combat secret-string behavior on hovered 3D world-object names (skill ranks, zone fishing data, and corpse tooltips continue working in combat).

## 1.57.0 (2026-11-25): Quiet bar auto-update, version-aware intro & release packaging

- **Bar profiles auto-update:**
  - Stopped login / `/reload` auto-update chat warning spam: background post-settle checks now run quietly (any hold reason still displays on the **Bar profiles** Status card in Settings).
  - Deleted or renamed macros on the same spec's saved profile no longer stall auto-update as unknown cross-spec buttons.
- **Version-aware Introduction:**
  - Automatically opens once after every version, minor, or patch update while preserving all saved settings, showing your previous version and a **What's new** note.
  - Replaced **Don't show this again** with **Don't show automatically on future updates**.
- **Community release prep:**
  - Added `.pkgmeta`, `.gitignore`, `.github/workflows/release.yml` (`BigWigsMods/packager`), and CurseForge/Wago ID placeholders in `ReadyToWork.toc`.

## 1.56.0 (2026-11-25): Combat resilience, Bar auto-update fix & polish

- **Combat support:**
  - **Gathering skill:** caches your learned skill ranks/bonuses and current zone/subzone so herb, ore, chest, fishing pool, and skinnable corpse tooltips continue working during combat even when Blizzard hides live skill/unit APIs (with tooltip-line fallback for corpse levels).
  - **Unlock mode & Minimap button:** unlock mode now opens and stays usable during combat for ReadyToWork's own unprotected frames, and ReadyToWork's minimap button can be shown, hidden, or dragged in combat.
- **Bar profiles auto-update:**
  - Automatically syncs pending safe changes after login/`/reload` settle and immediately when **Auto-update current spec profile** is switched on.
  - No longer drops bar edits made during casting or the post-reload settle window, and tracks new spells auto-placed by **Spell ranks**.
  - Deduplicates repeated automatic-pause chat warnings and displays the hold reason directly on the **Bar profiles** Status card when manual review is needed.
- **UI & glitch fixes:**
  - Fixed the Quick destroy main button tooltip when set to immediate destroy mode (`Right-click: settings.`).
  - Cancelled any prior `/rtw flight test` preview timer before starting a new preview, landing on a real flight, or turning the timer off.
  - Settings window rail dot and header switch now reflect `fanStandsDown` accurately when the legacy standalone `MinimapFan` addon is loaded.
  - Toggling items in **Never open** (`Open.SetSkip`) now updates the docked Containers bag bar count immediately.
  - `/rtw vendor log` now prints recent vendor log lines in chat.
- **Performance & cleanup:**
  - **Launcher** now detaches its `OnUpdate` completely when the fan menu and unread badge are hidden, using `LibDataBroker-1.1` callbacks for badge updates.
  - **Settings window** coalesces rapid `BAG_UPDATE_DELAYED` redraws.
  - **Quest markers** clears its log-throttle cache on zone/reload transitions.
  - Removed duplicate `PartyChat` helper in `FlightTimer.lua` (reusing `Helper.GroupChannel`), unused `SECURE` table in `Frames.lua`, and stale `MaxSpells.lua` text/comments.
  - Refreshed `README.md` and `CHANGELOG.md`.

## 1.55.0: Rare detection removed

- Removed the Rares helper and added SavedVariables schema migration `4 -> 5` to clean up `rares` settings, placement, and hints.

## 1.54.0: UI refinements & Containers bag bar

- Containers pauses cleanly on full-bag stalls and docks an **Open all** bar onto open bag frames.
- Status cards render stat chips and header actions; Flight timer shows `HH:MM:SS` for lifetime flight time; General uses a single card.
- Dragging sliders deduplicates integer steps and suppresses chat spam until release.
- Removed inline History cards from the Settings window.

## 1.53.1 (2026-11-22): Talk buttons readable

- Anchored Skip talk / Accept / Turn in tooltips beside the button strip so they never cover the buttons.
- Active Talk switches render as filled green buttons with white text and live-update open tooltips on click.

## 1.53.0 (2026-11-22): Talk & quests

- Added **Talk & quests** with independent **Skip talk**, **Accept**, and **Turn in** switches, a dockable 3-button strip, quick menu entries, `/rtw talk`, and key bindings.

## 1.52.0 (2026-11-22): Gathering skill on tooltips

- Added **Gathering skill** tooltips for herbs, ore veins, locked chests, fishing pools, and skinnable/gatherable corpses (`GatherData.lua`).

## 1.51.0 (2026-11-22): Vendors overhaul

- Added **Auto-repair** (including optional guild funds), **Sell items** itemized preview tooltip, **Buy back sale** for ReadyToWork's own sales, and SavedVariables schema `3 -> 4` (remembered white items stored by plain name).

## 1.50.0 (2026-11-22): Settings window & single minimap button

- Combined ReadyToWork's settings bag and Minimap Fan into one minimap button (schema `2 -> 3`).
- Built the Settings window, Quick menu, Unlock mode, Introduction, and AddOns panel from the unified registry in `Core\Features.lua`.

## 1.40.0 (2026-11-22): Core registry & unified Undo

- Added `Core\Features.lua`, `Core\Store.lua` (50-edit undo history across window, menu, commands, and frame drags), `Core\Migrate.lua` (schema `1 -> 2`), `/rtw reset <name>`, and tooltips on all quick menu entries.

## 1.30.0 (2026-11-22): Reliability & performance pass

- Bar profile rank/macro/undo fixes, spec-switch spell rank passes, objective-diff quest marker rebuilds, fewer Quick destroy rescans, bag-confirmed vendor sales, and settled Minimap Fan rendering.
