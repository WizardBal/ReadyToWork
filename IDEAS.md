# ReadyToWork — Future Helper Ideas

Ideas to revisit for upcoming versions before/after publishing. Every helper should stay independently toggleable, combat-safe where Blizzard allows, and wired into `Core\Features.lua` + `Core\Store.lua` (Undo).

## Tier 1 — High-impact everyday QoL (replaces Leatrix Plus / micro-addons)

1. **Fast Loot** *(Bags & Vendors)*
   - Instantly drain all loot slots on `LOOT_READY` when auto-loot is active.
   - Respect Shift-override, BoP confirmation prompts, and full-bag stalls cleanly (reusing patterns from `AutoOpen.lua`).

2. **Auto Dismount & Stand** *(World)*
   - Automatically dismount or stand up when an action fails with *"You are mounted"* / *"You must be standing"*, or when interacting with a Flight Master (with safe flying/combat checks).

3. **Smart Confirmations & Automation** *(World / Interface — separate opt-in toggles)*
   - Auto-fill `"DELETE"` on the item-destroy confirmation popup.
   - Auto-accept party invites from friends or guild members (optional whisper keyword).
   - Auto-accept resurrections and summons (optional out-of-combat guard).
   - Auto-release in battlegrounds (off in world/dungeons by default).

4. **Camera & Error-Spam Tweaks** *(Interface / General — CVar & frame toggles backed by Undo)*
   - Extended max camera zoom (`cameraDistanceMaxZoomFactor`).
   - Mute red error speech (*"Not enough mana"*, *"I can't cast that yet"*).
   - Filter common `UIErrorsFrame` red spam (*"Ability is not ready yet"*, *"Out of range"*), while keeping important warnings visible.

## Tier 2 — Strong differentiators

5. **Mailbox Helper** *(Bags & Vendors)*
   - One-click **Open all** on the Inbox frame that collects gold and items, pauses cleanly if bags fill up, skips CoD mail, and prints a short summary; optional recent-recipients dropdown on Send Mail.

6. **Item Tooltip Prices & IDs** *(World, alongside Gathering skill)*
   - Optional toggles to display vendor sell price (unit + stack) on item tooltips away from a merchant, plus opt-in Item ID / Spell ID lines.

7. **Low Durability / Low Consumable Alert** *(Bags & Vendors)*
   - Subtle warning when equipped gear durability drops below a chosen threshold (pairs with **Vendors** auto-repair).

## Scope guardrail — what to skip

Keep ReadyToWork as a **zero-conflict companion toolbox**. Avoid overlapping heavy specialized addons players already rely on:
- Full bag replacements (*Baganator*)
- Quest map guides (*Questie*)
- AH scanners (*Auctionator* / *TSM*)
- Rotation helpers (*ForeCast*)
- Unit-frame overhauls (*EllesmereUI*)
