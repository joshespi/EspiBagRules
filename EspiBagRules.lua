local ADDON = ...

local STEP_INTERVAL = 0.05 -- seconds between move-engine steps
local LOCK_TIMEOUT = 3     -- seconds to wait for item locks to clear
local MAX_PASSES = 60
local ROW_TOL = 2          -- px; button tops are floats
local LOG_MAX = 200        -- lines kept in EspiBagRulesDB.log
local LOG_SHOW = 15        -- lines /bagrules log prints

local defaults = {
    enabled = true,  -- Clean Up button uses EspiBagRules
    pinBound = true, -- bottom block (conjured, junk, bound gear) pinned to the last slots
    debug = false,   -- per-pass detail in chat and the log
}

local db

local function Print(msg)
    print("|cff66ccffEspiBagRules:|r " .. msg)
end

-- run history in EspiBagRulesDB.log; WoW writes it to disk on /reload or logout
local function Log(msg)
    local log = db.log
    log[#log + 1] = date("%m-%d %H:%M:%S ") .. msg
    while #log > LOG_MAX do table.remove(log, 1) end
end

local function Say(msg)
    Log(msg)
    Print(msg)
end

local function Debug(msg)
    if db.debug then Say(msg) end
end

local frame = CreateFrame("Frame")

-- Classification ------------------------------------------------------------

-- in layout order; pinned sections form the bottom block in the last slots
local SECTIONS = {
    { name = "SetGear" }, { name = "ToyGear" }, { name = "Heirloom" }, { name = "Other" }, { name = "BoE" },
    { name = "Conjured", pinned = true }, { name = "Junk", pinned = true }, { name = "Bound", pinned = true },
}
local SETGEAR, TOYGEAR, HEIRLOOM, OTHER, BOE, CONJURED, JUNK, BOUND = 1, 2, 3, 4, 5, 6, 7, 8 -- indices into SECTIONS

-- gear kept for its Use effect, not to wear: sorts like a toy
local TOYGEAR_IDS = {
    [63352] = true, [63353] = true, -- Shroud of Cooperation (Alliance, Horde)
    [63206] = true, [63207] = true, -- Wrap of Unity (Alliance, Horde)
    [65360] = true, [65274] = true, -- Cloak of Coordination (Alliance, Horde)
}

local SLOT_ORDER = {
    INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_CLOAK = 4,
    INVTYPE_CHEST = 5, INVTYPE_ROBE = 5, INVTYPE_BODY = 6, INVTYPE_TABARD = 7,
    INVTYPE_WRIST = 8, INVTYPE_HAND = 9, INVTYPE_WAIST = 10, INVTYPE_LEGS = 11,
    INVTYPE_FEET = 12, INVTYPE_FINGER = 13, INVTYPE_TRINKET = 14,
    INVTYPE_WEAPON = 15, INVTYPE_2HWEAPON = 15, INVTYPE_WEAPONMAINHAND = 15,
    INVTYPE_RANGED = 15, INVTYPE_RANGEDRIGHT = 15,
    INVTYPE_WEAPONOFFHAND = 16, INVTYPE_SHIELD = 16, INVTYPE_HOLDABLE = 16,
}

-- Warbound by the item's bind type. Not ToBnetAccountUntilEquipped: once worn that's soulbound,
-- so it's checked on the bag slot instead.
local WARBOUND = { [Enum.ItemBind.ToWoWAccount] = true, [Enum.ItemBind.ToBnetAccount] = true }

-- gear you can still trade or send to an alt sorts as BoE: unbound, Warbound, or Warbound
-- until equipped (loc is the item's bag slot)
local function IsTradeable(info, loc)
    return not info.isBound or WARBOUND[select(14, C_Item.GetItemInfo(info.itemID))]
        or (C_Item.IsBoundToAccountUntilEquip and C_Item.IsBoundToAccountUntilEquip(loc))
end

-- no API for this: the tooltip's "Conjured Item" line is the only signal
local conjured = {} -- itemID -> bool
local function IsConjured(bag, slot, itemID)
    if conjured[itemID] == nil then
        local data = C_TooltipInfo.GetBagItem(bag, slot)
        if not (data and data.lines and #data.lines > 0) then return false end -- not loaded; retry next pass
        conjured[itemID] = false
        for _, line in ipairs(data.lines) do
            if line.leftText == ITEM_CONJURED then
                conjured[itemID] = true
                break
            end
        end
    end
    return conjured[itemID]
end

local function IsGear(classID, equipLoc)
    return (classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor)
        and equipLoc ~= nil and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
end

-- sets in block order (an item's set rank is its index): assigned spec first, then unassigned by name
local function BuildSets()
    local sets = {}
    for _, id in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
        local name = C_EquipmentSet.GetEquipmentSetInfo(id)
        if name then
            sets[#sets + 1] = {
                name = name, lname = name:lower(), needle = ", " .. name .. ", ",
                spec = C_EquipmentSet.GetEquipmentSetAssignedSpec(id),
            }
        end
    end
    table.sort(sets, function(a, b)
        local sa, sb = a.spec or 1000, b.spec or 1000
        if sa ~= sb then return sa < sb end
        if a.lname ~= b.lname then return a.lname < b.lname end
        return a.name < b.name
    end)
    return sets
end

-- lowest rank of any known set named in setList (plain find: names may hold commas);
-- #sets + 1 for a set we don't know by name
local function SetRank(setList, sets)
    local hay = ", " .. setList .. ", "
    for rank, s in ipairs(sets) do
        if hay:find(s.needle, 1, true) then return rank end
    end
    return #sets + 1
end

local loc = ItemLocation:CreateEmpty() -- reused: Classify never keeps it

-- general == false: a reagent or profession bag, where everything is Other or Junk
local function Classify(bag, slot, info, sets, general)
    local itemID = info.itemID
    local count = info.stackCount or 1
    local link = info.hyperlink or tostring(itemID)
    local quality = info.quality or 0
    local _, _, _, equipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    loc:SetBagAndSlot(bag, slot)
    local gear = IsGear(classID, equipLoc)

    local rec = {
        itemID = itemID, link = link, count = count, key = link .. ":" .. count,
        quality = quality, locked = info.isLocked,
        name = (info.itemName or ""):lower(),
        classID = classID or 0, subClassID = subClassID or 0,
        ilvl = C_Item.GetCurrentItemLevel(loc) or 0,
        slotOrder = gear and SLOT_ORDER[equipLoc] or 99,
        setRank = 0,
    }

    if quality == Enum.ItemQuality.Poor then
        rec.section = JUNK
    elseif not general then
        rec.section = OTHER
    elseif TOYGEAR_IDS[itemID] then
        rec.section = TOYGEAR
    elseif IsConjured(bag, slot, itemID) then
        rec.section = CONJURED
    elseif not gear then
        rec.section = OTHER
    else
        local inSet, setList = C_Container.GetContainerItemEquipmentSetInfo(bag, slot)
        if inSet then
            rec.section = SETGEAR
            rec.setRank = SetRank(setList or "", sets)
        elseif quality == Enum.ItemQuality.Heirloom then
            rec.section = HEIRLOOM
        elseif IsTradeable(info, loc) then
            rec.section = BOE
        else
            rec.section = BOUND
        end
    end
    return rec
end

local function Compare(a, b)
    if a.section ~= b.section then return a.section < b.section end
    if a.setRank ~= b.setRank then return a.setRank < b.setRank end
    if a.slotOrder ~= b.slotOrder then return a.slotOrder < b.slotOrder end
    if a.classID ~= b.classID then return a.classID < b.classID end
    if a.subClassID ~= b.subClassID then return a.subClassID < b.subClassID end
    if a.quality ~= b.quality then return a.quality > b.quality end
    if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
    if a.name ~= b.name then return a.name < b.name end
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    if a.count ~= b.count then return a.count > b.count end
    return a.link < b.link -- equal link and count means equal key: interchangeable
end

-- one record per occupied position; empty positions stay nil (the table has holes)
local function Scan(region, sets)
    local recs = {}
    for i = 1, region.n do
        local s = region.slots[i]
        local info = C_Container.GetContainerItemInfo(s.bag, s.slot)
        if info and info.itemID then
            recs[i] = Classify(s.bag, s.slot, info, sets, region.general)
        end
    end
    return recs
end

-- Regions -------------------------------------------------------------------

local function Ignored(bag)
    if bag == Enum.BagIndex.Backpack then return C_Container.GetBackpackAutosortDisabled() end
    return C_Container.GetBagSlotFlag(bag, Enum.BagSlotFlags.DisableAutoSort)
end

local function UsingCombinedBags()
    return ContainerFrameSettingsManager and ContainerFrameSettingsManager:IsUsingCombinedBags()
end

-- combined bags on but hidden: their on-screen order can't be read
local function CombinedBagsClosed()
    return UsingCombinedBags() and not ContainerFrameCombinedBags:IsShown()
end

-- Reading order of the combined backpack, from the real buttons.
-- Slots the buttons don't cover keep their fallback order at the end.
local function DisplayOrder(slots)
    if not UsingCombinedBags() then
        return slots, "fallback: combined bags off"
    end
    if CombinedBagsClosed() then -- only Preview gets here: Sort refuses first
        return slots, "fallback: bags closed"
    end
    local cf = ContainerFrameCombinedBags

    local byId = {}
    for _, s in ipairs(slots) do byId[s.bag * 1000 + s.slot] = s end

    local btns, seen = {}, {}
    for _, btn in cf:EnumerateValidItems() do
        local bag, slot = btn:GetBagID(), btn:GetID()
        local top, left = btn:GetTop(), btn:GetLeft()
        local s = bag and slot and byId[bag * 1000 + slot]
        if s and top and left and not seen[s] then
            seen[s] = true
            btns[#btns + 1] = { s = s, top = top, left = left }
        end
    end
    table.sort(btns, function(a, b) return a.top > b.top end)

    local out, i = {}, 1
    while i <= #btns do
        local row, rowTop = {}, btns[i].top
        while i <= #btns and rowTop - btns[i].top <= ROW_TOL do
            row[#row + 1] = btns[i]
            i = i + 1
        end
        table.sort(row, function(a, b) return a.left < b.left end)
        for _, e in ipairs(row) do out[#out + 1] = e.s end
    end
    for _, s in ipairs(slots) do
        if not seen[s] then out[#out + 1] = s end
    end
    local missing = #slots - #btns
    return out, missing > 0 and ("screen, %d slots appended"):format(missing) or "screen"
end

local function AllSlots(bag)
    local slots = {}
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
        slots[slot] = { bag = bag, slot = slot }
    end
    return slots
end

local function NewRegion(slots, general, label)
    return { slots = slots, n = #slots, general = general, label = label }
end

-- the general bags share one region (first, in display order); reagent and profession bags sort alone
local function BuildRegions()
    local regions, general = {}, {}
    for bag = Enum.BagIndex.Backpack, Enum.BagIndex.ReagentBag do
        local slots = AllSlots(bag)
        if #slots > 0 and not Ignored(bag) then
            local _, family = C_Container.GetContainerNumFreeSlots(bag)
            if bag ~= Enum.BagIndex.ReagentBag and (family or 0) == 0 then
                for _, s in ipairs(slots) do general[#general + 1] = s end
            else
                regions[#regions + 1] = NewRegion(slots, false, ("bag %d: %d slots"):format(bag, #slots))
            end
        end
    end
    if #general > 0 then
        local slots, order = DisplayOrder(general)
        local region = NewRegion(slots, true, ("general %d slots (%s)"):format(#slots, order))
        region.fallback = order:match("^fallback: (.*)")
        table.insert(regions, 1, region)
    end
    return regions
end

-- Desired layout ------------------------------------------------------------

-- des[i] is the record that belongs at position i; nil means empty
local function BuildDesired(region, recs)
    local list = {}
    for i = 1, region.n do
        if recs[i] then list[#list + 1] = recs[i] end
    end
    table.sort(list, Compare)

    local pin = db.pinBound and region.general
    local head, tail = {}, {}
    for _, r in ipairs(list) do
        local t = pin and SECTIONS[r.section].pinned and tail or head
        t[#t + 1] = r
    end
    local des, base = {}, region.n - #tail
    for k, r in ipairs(head) do des[k] = r end
    for k, r in ipairs(tail) do des[base + k] = r end
    return des
end

-- Move engine ---------------------------------------------------------------

local run -- state of the sort in progress; nil when idle

local function Stop(reason)
    if not run then return end
    run.ticker:Cancel()
    if reason then
        Say(("sort stopped: %s (pass %d, %d moves)"):format(reason, run.passes, run.moves))
    end
    run = nil
end

local function Done(stuck)
    local locked = stuck > 0 and ("; %d locked items not moved"):format(stuck) or ""
    if run.moves + run.merges == 0 then
        Say("already sorted" .. locked)
    else
        Say(("sorted: %d moves, %d merges, %d passes, %.1fs%s"):format(
            run.moves, run.merges, run.passes, GetTime() - run.start, locked))
    end
    Stop()
end

-- Swap two slots, move into an empty one, or merge (amount splits off just what
-- fits). Anything still in hand after the drop is put back in slot a.
local function Move(a, b, amount)
    if GetCursorInfo() then -- the user grabbed something
        ClearCursor()
        return nil, "something is on your cursor"
    end
    if amount then
        C_Container.SplitContainerItem(a.bag, a.slot, amount)
    else
        C_Container.PickupContainerItem(a.bag, a.slot)
    end
    if not GetCursorInfo() then return nil, "couldn't pick up an item" end
    C_Container.PickupContainerItem(b.bag, b.slot)
    if GetCursorInfo() then
        C_Container.PickupContainerItem(a.bag, a.slot)
        if GetCursorInfo() then
            ClearCursor()
            return nil, "an item got stuck on your cursor"
        end
    end
    run.pending[#run.pending + 1] = a
    run.pending[#run.pending + 1] = b
    return true
end

-- only wait on slots we moved: an item locked by trade or mail mustn't stall the sort
local function PendingLocked()
    for _, s in ipairs(run.pending) do
        local info = C_Container.GetContainerItemInfo(s.bag, s.slot)
        if info and info.isLocked then return true end
    end
    return false
end

-- earliest stack to merge into and a later one to pick up, skipping pairs already tried
local function PickPair(region, g)
    for a = 1, #g - 1 do
        for b = #g, a + 1, -1 do
            local dst, src = region.slots[g[a]], region.slots[g[b]]
            local id = src.bag .. ":" .. src.slot .. ">" .. dst.bag .. ":" .. dst.slot
            if not run.tried[id] then
                run.tried[id] = true
                return g[b], g[a]
            end
        end
    end
end

-- one merge per item per pass; returns the merges issued.
-- Grouped by link, not itemID: the same item with different links may not stack.
local function MergeRegion(region, recs)
    local groups, order = {}, {}
    for i = 1, region.n do
        local r = recs[i]
        if r and not r.locked then
            local max = C_Item.GetItemMaxStackSizeByID(r.itemID)
            if max and r.count < max then
                local g = groups[r.link]
                if not g then
                    g = { max = max }
                    groups[r.link] = g
                    order[#order + 1] = g
                end
                g[#g + 1] = i
            end
        end
    end

    local moves = 0
    for _, g in ipairs(order) do
        local si, di = PickPair(region, g)
        if si then
            local room = g.max - recs[di].count
            local amount = recs[si].count > room and room or nil
            local ok, err = Move(region.slots[si], region.slots[di], amount)
            if not ok then return moves, err end
            moves = moves + 1
        end
    end
    return moves
end

-- an unused, unlocked slot holding key that isn't already where it belongs
local function FindSource(region, recs, des, used, key)
    for j = 1, region.n do
        local src, target = recs[j], des[j]
        if not used[j] and src and not src.locked and src.key == key
            and not (target and target.key == key) then
            return j
        end
    end
end

-- swaps each wrong position into place, touching a slot at most once.
-- Returns the moves issued, an error, and the locked items that are out of place.
local function OrderRegion(region, recs)
    local des = BuildDesired(region, recs)
    local used, moves, stuck = {}, 0, 0
    for i = 1, region.n do
        local want, have = des[i], recs[i]
        if have and have.locked and not (want and want.key == have.key) then
            stuck = stuck + 1
        end
        if want and not used[i] and not (have and have.key == want.key) then
            local j = not (have and have.locked) and FindSource(region, recs, des, used, want.key)
            if j then
                local ok, err = Move(region.slots[j], region.slots[i])
                if not ok then return moves, err end
                moves = moves + 1
                used[i], used[j] = true, true
            end
        end
    end
    return moves, nil, stuck
end

local function Step()
    if PendingLocked() then
        local now = GetTime()
        run.lockSince = run.lockSince or now
        if now - run.lockSince > LOCK_TIMEOUT then
            return Stop("timed out waiting for items to unlock")
        end
        return
    end
    run.lockSince = nil
    run.pending = {}

    if run.passes >= MAX_PASSES then
        return Stop("gave up after " .. MAX_PASSES .. " passes")
    end
    run.passes = run.passes + 1

    local snaps, merged = {}, 0
    for i, region in ipairs(run.regions) do
        snaps[i] = Scan(region, run.sets)
        local n, err = MergeRegion(region, snaps[i])
        if err then return Stop(err) end
        merged = merged + n
    end
    if merged > 0 then -- let the merges land, then re-snapshot
        run.merges = run.merges + merged
        Debug(("pass %d: %d merges"):format(run.passes, merged))
        return
    end

    local moved, stuck = 0, 0
    for i, region in ipairs(run.regions) do
        local n, err, s = OrderRegion(region, snaps[i])
        if err then return Stop(err) end
        moved, stuck = moved + n, stuck + s
    end
    -- no moves issued: anything still out of place is a locked item
    if moved == 0 then return Done(stuck) end
    run.moves = run.moves + moved
    Debug(("pass %d: %d moves"):format(run.passes, moved))
end

local function Tick()
    local ok, err = pcall(Step)
    if not ok then
        ClearCursor() -- the error may have hit between the two pickups
        Stop("Lua error: " .. tostring(err))
        geterrorhandler()(err)
    end
end

local function Sort()
    if run then
        Say("already sorting")
        return
    end
    if InCombatLockdown() then
        Say("can't sort in combat")
        return
    end
    if GetCursorInfo() then
        Say("drop the item on your cursor first")
        return
    end
    -- the fallback order would fight the next sort made with the bags open
    if CombinedBagsClosed() then
        Say("open your bags first")
        return
    end
    local regions = BuildRegions()
    if #regions == 0 then
        Say("no bags to sort")
        return
    end

    local labels = {}
    for _, region in ipairs(regions) do labels[#labels + 1] = region.label end
    Log("sort: " .. table.concat(labels, ", "))
    if regions[1].fallback then
        Print("sorting by slot order, not screen order (" .. regions[1].fallback .. ")")
    end
    Print("sorting... /bagrules stop to cancel")

    run = {
        regions = regions, sets = BuildSets(), passes = 0, moves = 0, merges = 0,
        tried = {}, pending = {}, start = GetTime(),
    }
    run.ticker = C_Timer.NewTicker(STEP_INTERVAL, Tick)
end

-- Preview -------------------------------------------------------------------

local function Preview()
    local region = BuildRegions()[1] -- the general region always comes first
    if not (region and region.general) then
        Print("no general bags to sort")
        return
    end

    local sets = BuildSets()
    local recs = Scan(region, sets)
    local counts, perSet, total = {}, {}, 0
    for i = 1, region.n do
        local r = recs[i]
        if r then
            total = total + 1
            counts[r.section] = (counts[r.section] or 0) + 1
            if r.section == SETGEAR then perSet[r.setRank] = (perSet[r.setRank] or 0) + 1 end
        end
    end

    Print(("%d items in %d general slots"):format(total, region.n))
    for sec, section in ipairs(SECTIONS) do
        Print(("%s: %d"):format(section.name, counts[sec] or 0))
        if sec == SETGEAR then
            for rank, s in ipairs(sets) do
                local spec = s.spec and (" (spec " .. s.spec .. ")") or ""
                Print(("  %s%s: %d"):format(s.name, spec, perSet[rank] or 0))
            end
            if perSet[#sets + 1] then
                Print(("  (unmatched set): %d"):format(perSet[#sets + 1]))
            end
        end
    end
end

-- Button hook ---------------------------------------------------------------

local function HookButton()
    local btn = BagItemAutoSortButton
    if not btn then
        Print("Clean Up button not found, use /bagrules sort")
        return
    end
    local blizzardClick = btn:GetScript("OnClick")
    btn:SetScript("OnClick", function(self, ...)
        if IsShiftKeyDown() or not db.enabled then return blizzardClick(self, ...) end
        PlaySound(SOUNDKIT.UI_BAG_SORTING_01)
        Sort()
    end)
    btn:HookScript("OnEnter", function()
        if not db.enabled then return end -- a plain click already is Blizzard's sort
        GameTooltip:AddLine("EspiBagRules: Shift-click for Blizzard sort", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
end

-- Events --------------------------------------------------------------------

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        EspiBagRulesDB = EspiBagRulesDB or {}
        db = EspiBagRulesDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        db.log = db.log or {}
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        HookButton()
    elseif event == "PLAYER_REGEN_DISABLED" then
        Stop("combat started")
    end
end)

-- Slash commands ------------------------------------------------------------

local HELP = {
    "/bagrules sort - sort your bags now",
    "/bagrules stop - cancel a sort in progress",
    "/bagrules preview - list what each section would hold, moves nothing",
    "/bagrules on - Clean Up button uses EspiBagRules",
    "/bagrules off - Clean Up button uses Blizzard's sort",
    "/bagrules pin - toggle conjured, junk and bound gear pinned to the last slots",
    ("/bagrules log - show the last %d log lines"):format(LOG_SHOW),
    "/bagrules debug - toggle per-pass detail in chat and the log",
    "Shift-click Clean Up for Blizzard's sort",
}

SLASH_ESPIBAGRULES1 = "/bagrules"
SLASH_ESPIBAGRULES2 = "/brules"
SlashCmdList.ESPIBAGRULES = function(msg)
    local cmd = strtrim(msg or ""):lower():match("^(%S*)")
    if cmd == "sort" then
        Sort()
    elseif cmd == "stop" then
        if run then Stop("cancelled") else Print("not sorting") end
    elseif cmd == "preview" then
        Preview()
    elseif cmd == "on" or cmd == "off" then
        db.enabled = cmd == "on"
        Print("Clean Up button override " .. cmd)
    elseif cmd == "pin" then
        db.pinBound = not db.pinBound
        Print(db.pinBound and "bottom block pinned to the last slots" or "bottom block packed after BoE")
    elseif cmd == "debug" then
        db.debug = not db.debug
        Print("debug " .. (db.debug and "on" or "off"))
    elseif cmd == "log" then
        local log = db.log
        if #log == 0 then Print("log is empty") end
        for i = math.max(1, #log - LOG_SHOW + 1), #log do Print(log[i]) end
    else
        if cmd ~= "" and cmd ~= "help" then Print(("unknown command '%s'"):format(cmd)) end
        local ver = C_AddOns.GetAddOnMetadata(ADDON, "Version") or "?"
        Print(("%s - override %s, pin %s, debug %s"):format(
            ver:find("^@") and "dev" or "v" .. (ver:gsub("^v", "")),
            db.enabled and "on" or "off", db.pinBound and "on" or "off", db.debug and "on" or "off"))
        for _, line in ipairs(HELP) do Print(line) end
    end
end
