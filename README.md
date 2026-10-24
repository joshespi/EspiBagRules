# EspiBagRules

A custom Clean Up for World of Warcraft (retail 12.x). It replaces the Clean Up button in your bags with a sorter that keeps equipment-set gear together at the top, puts gear you can still trade in the middle, and pins conjured items, junk and your other bound gear to the last slots.

## Layout

Your general bags are sorted into this order, in the order the slots are shown on screen:

1. **Set gear**: gear that belongs to an equipment set. One block per set, sets ordered by the spec they're assigned to (unassigned sets last, by name), pieces in paperdoll order.
2. **Toy gear**: gear you keep for its Use effect rather than to wear: the guild teleport cloaks (Shroud of Cooperation, Wrap of Unity, Cloak of Coordination).
3. **Other**: everything else, by item type, quality, item level and name.
4. **BoE**: gear you can still trade or send to an alt: not bound yet, Warbound, or Warbound until equipped.
5. *(empty slots)*
6. **Conjured**: Healthstones, mage food and other conjured items.
7. **Junk**: poor quality items.
8. **Bound**: bound gear that isn't in a set, in the very last slots.

Conjured, Junk and Bound form the bottom block, pinned to the last slots. `/bagrules pin` turns the pinning off, which packs them right after BoE with no gap.

Partial stacks of the same item are merged. The reagent bag and profession bags are sorted within themselves, and bags set to "Ignore this bag" are left alone. Shift-click on Clean Up runs Blizzard's sort instead.

## Install

Install from CurseForge, or copy the `EspiBagRules` folder into `_retail_/Interface/AddOns/`.

## Commands

`/bagrules` or `/brules`

| Command             | Effect                                                  |
| ------------------- | ------------------------------------------------------- |
| `/bagrules sort`    | Sort now (open your bags first so their layout is used) |
| `/bagrules preview` | Show how many items go in each section, moves nothing   |
| `/bagrules on`      | Clean Up button uses EspiBagRules                           |
| `/bagrules off`     | Clean Up button uses Blizzard's sort                    |
| `/bagrules pin`     | Toggle the bottom block pinned to the last slots        |
| `/bagrules log`     | Show the last 15 log lines                              |
| `/bagrules debug`   | Toggle per-pass detail in chat and the log              |

Each sort reports its result in chat ("sorted: …", "already sorted" or "sort stopped: …"). The last 200 lines are also kept in `WTF/Account/<account>/SavedVariables/EspiBagRules.lua`, which WoW writes on `/reload` or logout.
