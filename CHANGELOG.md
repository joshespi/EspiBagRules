# EspiBagRules

## 1.3.0

- Supports the WoW Forever client (interface 16001) alongside retail.
- Reagent and profession bags: items move into a bag only if its type accepts them, so herb, mining and skinning bags fill correctly. Each item is tried once per sort, which fixes a sort that repeated until it gave up after 60 passes.
- `/bagrules probe` lists which game APIs the client is missing.
- Loads without errors on clients that lack `Enum.ItemBind` or `ItemLocation`.
- `/bagrules debug` now logs each move.

## 1.2.1

- Properly sort reagents into reagent conatiner when there is space

## 1.2.0

- `/bagrules stop` cancels a sort in progress; a sort now announces itself when it starts.
- A sort that falls back to slot order (combined bags off) says so in chat.
- Heirloom items get their own section between toy gear and other items.
- Unknown `/bagrules` commands are called out, and the help header shows the current override, pin and debug state.

## 1.1.0

- The guild teleport cloaks (Shroud of Cooperation, Wrap of Unity, Cloak of Coordination) sort right after set gear, as toy gear, instead of with the bound gear in the last slots.

## 1.0.0

- First release.
- Replaces the Clean Up button with a sorter that keeps equipment-set gear together, BoE and Warbound gear in the middle, and conjured items, junk and other bound gear pinned to the last slots.
- Merges partial stacks and sorts the reagent and profession bags within themselves.
- Shift-click Clean Up for Blizzard's sort; `/bagrules preview` shows the plan without moving anything.
- Every sort reports its result in chat and in a saved log (`/bagrules log`, `/bagrules debug`).
