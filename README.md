# ReadyToWork

Quality-of-life helpers for **World of Warcraft: Forever** (`v1.57.2`).

Formerly **BalHelper** and **Minimap Fan** — your settings for both carry over automatically, and `/bh`, `/balhelper`, `/minifan`, and `/mmfan` still work alongside `/rtw` and `/readytowork`.

---

## Getting around

- **One minimap button (the Orc Peon icon):**
  - **Left-click:** fan out collected minimap buttons from other addons (or open Settings if the fan is off).
  - **Right-click:** open the quick menu.
  - **Shift-click:** open the full Settings window.
  - **Mouse wheel:** page through the fan.
  - **Drag:** move around the minimap (round or square).
- **Settings window (`/rtw settings` or `/rtw settings <page>`):**
  - Left rail with **Search**, **Home** (live status cards with toggles), and every page grouped by category with live on/off status dots.
  - Each page shows **Status** (live stat chips and quick actions), **Behavior**, **Appearance & position** (including **Move**), and **Lists**, plus a **···** menu (**Restore defaults...**, **Undo this page's last change**, **Undo this page's changes since opening**).
  - Footer with **Undo** (takes back the newest change made anywhere: window, quick menu, `/rtw` command, or frame drag), **Revert visit**, and **Reload UI**.
- **Unlock mode (`/rtw unlock`, General > Unlock frames, or key binding):**
  - Outlines ReadyToWork's movable frames (**Destroy button**, **Bar profile swap button**, **Flight timer**), even while hidden.
  - Drag to move, mouse wheel to resize, right-click to reset. **Done**, Escape, or `/rtw unlock` ends it.
  - Alt-drag (**Destroy button**, **Bar profile swap button**) or plain drag (**Flight timer**) also works at any time.
- **Key bindings & AddOns entry:**
  - Listed under **Options > AddOns > ReadyToWork**.
  - Bindings under **Options > Keybindings > ReadyToWork**: Settings window, Quick menu, Unlock frames, Skip talk, Accept quests, Turn in quests.
- **Introduction (`/rtw intro` or General > Introduction):**
  - Shown automatically on fresh installs and once after each version update (preserving all saved settings) until **Don't show automatically on future updates** is ticked.
- **Undo & Defaults:**
  - `/rtw undo` takes back the newest settings edit (up to 50 edits per session).
  - `/rtw reset <name>` restores one helper's settings to defaults while keeping your custom lists, bar profiles, and frame positions.

---

## Helpers

### Sell & repair (`/rtw vendor`)
- **Auto-repair:** repairs your gear when a repair-capable vendor opens (**Repair at vendors**), optionally using guild funds first when allowed (**Use guild funds first**). Hold **Shift** while opening a vendor to skip both repair and selling once.
- **Auto-sell:** sells paid gray items and any white items you add via **Drop to auto-vendor** on the merchant bar or the **Sell & repair** page.
- **Sell preview & Buy back:** hover **Sell items** under the merchant frame for an itemized preview; click **Buy back sale** to buy back only what ReadyToWork sold during that visit.
- **Commands:** `/rtw vendor [on|off|now|log|total|buyback]`, `/rtw vendor repair [on|off|now|guild on|guild off]`, `/rtw vendor chat [on|off]`.

### Auto-open (`/rtw open`)
- Automatically opens clams and other bag containers (`Clams only`, `White and gray containers`, or `Any container`) when safe (out of combat, not casting, no interaction/loot window open) while keeping at least **Keep free bag slots** open (excluding reagent bags).
- Pauses cleanly if bags fill up and docks an **Open all** bar on your open bags so you can resume with one click.
- Locked lockboxes and items on your **Never open** list are skipped.
- **Commands:** `/rtw open [on|off|now|openall|clams|common|all|free <n>|chat on|off|skip <item>|unskip <item>|list]`.

### Quick destroy (`/rtw destroy`)
- Shows a movable button offering your cheapest junk (gray items, optional **Conjured mage food** / **Conjured mage water** smallest stack first, and any bag items dropped onto it).
- Click to fan out choices (or destroy the cheapest immediately if **On click** is set to **Destroy the cheapest at once**). Right-click a fan tile to protect that item; right-click the main button for Quick destroy settings. Uncommon+ manually included items ask for a second click within 4 seconds.
- **Commands:** `/rtw destroy [on|off|full [slots]|always|reset|click fan|destroy|show <n>|food [on|off]|water [on|off]|keep [clear]]`.

### Bar profiles (`/rtw bars`)
- Saves and loads full action bar layouts (slots `1–180`, macros matched by name and body, items when carried, spells upgraded to your highest known rank when **Spell ranks** is active). Profiles are stored per character with spec awareness.
- **Auto-update current spec profile:** writes your bar edits into the loaded profile automatically, including after reloads/spec-settle and new-spell auto-placements. If an automatic update would overwrite buttons hidden on the current spec or match another saved profile, it pauses and notes why on the **Bar profiles** Status card so you can confirm with **Update**.
- Optional **Swap button** fans out profiles, **Update**, and **Save as new profile**. **Report in chat** defaults to off.
- **Commands:** `/rtw bars [save Name|load Name|update|rename Old = New|delete Name|undo|list|button on|off|reset|chat on|off|on|off]`.

### Spell ranks (`/rtw spells`, `/bms`, `/mrb`)
- Keeps action bars (including shaman totem bar slots) on the highest rank of each spell you know, and places newly learned spells into empty visible bar slots (**Place new spells**).
- Suppresses Blizzard's `AutoPushSpellToActionBar` during spec switches (`/rtw spells gamepush on` to re-enable).
- **Commands:** `/rtw spells [scan|on|off|place [on|off]|casts [on|off]|gamepush [on|off]|status]`.

### Quest markers (`/rtw questkills`)
- Marks living, attackable quest mobs on nameplates (and distant hovered creatures above your cursor) with customizable icons for kill and loot objectives.
- In groups, defaults to marking only mobs confirmed for your own quests; enable **Party guesses** if you also want unattributed group quest mobs marked.
- **Commands:** `/rtw questkills [on|off|preview|check|log|party on|off]`.

### Talk & quests (`/rtw talk`)
- Three independent switches — **Skip talk**, **Auto-accept quests**, and **Auto-turn in quests** — controlled via a 3-button strip on dialog/quest frames, the quick menu, key bindings, or `/rtw talk`.
- Leaves reward choices, gold-cost turn-ins, PvP-flag quests, and item/area-started popups to you. Hold **Shift** when starting a conversation to pause all three for that NPC.
- **Commands:** `/rtw talk [on|off|skip|accept|turnin [on|off]|grey on|off|chat on|off|buttons top|bottom|hidden]`.

### Gather tooltips (`/rtw gather`)
- Adds required skill vs. your current skill (with gear/racial bonuses) to tooltips of herbs, ore veins, locked chests, fishing pools, and skinnable/gatherable corpses, colored by recipe difficulty (`red` / `orange` / `yellow` / `green` / `gray`).
- Individual toggles for **Herbs**, **Ore**, **Corpses**, **Locked chests**, and **Fishing pools**.
- **Commands:** `/rtw gather [on|off|herbs|ore|corpses|chests|fishing on|off]`.

### Flight timer (`/rtw flight`)
- Displays a countdown bar while on a flight path, using your own timed flights first, then ForeverDungeonJournal / InFlight Classic Era estimates (`FlightTimes.lua`), then continent-pace distance estimates, adjusting for the Frequent Flier perk.
- Includes an **ETA button** to post your remaining time to party or instance chat, and adds known/estimated flight times to flight-map tooltips.
- **Commands:** `/rtw flight [on|off|test|reset|forget|party [on|off]]`.

### Minimap buttons (`/rtw fan`, `/minifan`, `/rtw minimap`)
- Collects third-party minimap buttons into a customizable **Fan**, **Grid**, or **Line** flyout with per-page sizing, drag-and-drop button ordering in Settings (with live button artwork preview), and per-button ignore checkboxes.
- **Commands:** `/rtw fan [on|off|reset|scan|list|status|autoclose|ignore <name>|include <name>]`, `/rtw minimap [on|off]`.

---

## Combat behavior

Everything ReadyToWork can safely do in combat keeps working during fights:
- **Works normally in combat:** Gather tooltips on corpses (using cached skill ranks/bonuses and tooltip corpse levels when Blizzard hides live unit/skill APIs; on Forever `1.60.1`, Blizzard secret-locks hovered 3D world-object names during combat until combat ends), Quest markers, Settings window, Quick menu, Unlock mode (for ReadyToWork's own frames), Minimap button dragging/toggling, Quick destroy, Flight timer, Sell & repair, Talk & quests, and saving/auto-updating Bar profiles.
- **Deferred by WoW combat lockdown until combat ends:** Loading bar profiles, upgrading/placing spells on action bars, auto-opening bag containers, and reparenting third-party addon minimap buttons into/out of the fan.
