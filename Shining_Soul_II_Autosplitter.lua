-- Shining Soul II (Japan) normal mode autosplitter for LiveSplit
-- Target: BizHawk + mGBA core
-- Requires LiveSplit 1.7+
-- Based on: https://github.com/trysdyn/bizhawk-speedrun-lua
-- Lua docs: https://tasvideos.org/BizHawk/LuaFunctions
-- "Hard Reset" does NOT fully reset the script, need to use "Reboot Core" (Ctrl+R)

-- splits on the 11 main boss kills
-- most bosses share the same address for their HP
-- Deatharte and Vaitali (Head) use another address
-- track "next expected boss" index, current area and floor
-- split when boss HP is seen at full in associated area on the the right floor, then drops to 0

-- -------------------------------------------------------------
-- ROM COMPATIBILITY CHECK
-- -------------------------------------------------------------
local EXPECTED_ROM_HASH = "19856388CAF5140F7527728BD09E20BCB8924EEB" -- Shining Soul II (Japan)
local actual_hash = gameinfo.getromhash()
if actual_hash ~= EXPECTED_ROM_HASH then
    console.log("SS2: WARNING - ROM hash mismatch!")
    console.log("SS2: expected " .. EXPECTED_ROM_HASH .. ", got " .. actual_hash)
end

-- -------------------------------------------------------------
-- DEBUG
-- -------------------------------------------------------------
-- show debug logs (should be false (disabled) for normal use)
local DEBUG = false

-- -------------------------------------------------------------
-- MEMORY ADDRESSES (GBA address space)
--   EWRAM: 0x02000000 - 0x0203FFFF
--   IWRAM: 0x03000000 - 0x03007FFF
-- -------------------------------------------------------------
local ADDR_BOSS_HP      = 0x02006CE4 -- EWRAM
local ADDR_ALT_BOSS_HP  = 0x02007138 -- EWRAM
local ADDR_AREA_ID      = 0x0300329C -- IWRAM
local ADDR_AREA_FLOOR   = 0x030032A0 -- IWRAM
local ADDR_PLAYER_HP    = 0x03003E4C -- IWRAM
local ADDR_MENU_OPEN    = 0x03006524 -- IWRAM

-- -------------------------------------------------------------
-- BOSS TABLE (split order)
-- -------------------------------------------------------------
-- name and area_name is just for clarity
-- area_floor refers to the ingame value for the respective boss fight floor
-- 0 is the first floor, 9 is the tenth floor etc.
-- some areas have floors that have two versions and each still has a unique id for the area
-- this is why some boss fight floors are higher than expected
local bosses = {
    { name = "Colonel Gobovich",        area_name = "Goblin Fort",          area_ID = 1,  area_floor = 7,   hp = 540  }, -- index  0
    { name = "Grove Giant",             area_name = "Giant's Graveyard",    area_ID = 2,  area_floor = 9,   hp = 1050 }, -- index  1
    { name = "Wizari",                  area_name = "Wizari's Palace",      area_ID = 3,  area_floor = 14,  hp = 1200 }, -- index  2
    { name = "(Water spirit) Clione",   area_name = "Fairy Spring",         area_ID = 4,  area_floor = 12,  hp = 2040 }, -- index  3
    { name = "Kraken (Giant squid)",    area_name = "Robert's Pirate Ship", area_ID = 5,  area_floor = 13,  hp = 2550 }, -- index  4
    { name = "Oswald",                  area_name = "Driazhek Desert",      area_ID = 6,  area_floor = 16,  hp = 2700 }, -- index  5
    { name = "Vaitali (Head)",          area_name = "Koldazhek Cave",       area_ID = 7,  area_floor = 12,  hp = 900  }, -- index  6 -> uses ADDR_ALT_BOSS_HP
    { name = "Dark Angel",              area_name = "Demons' Tower",        area_ID = 8,  area_floor = 18,  hp = 2100 }, -- index  7
    { name = "Holy Guardian of Fire",   area_name = "Hottazhek Volcano",    area_ID = 9,  area_floor = 16,  hp = 6000 }, -- index  8
    { name = "Deatharte of Darkness",   area_name = "Chaos Castle",         area_ID = 10, area_floor = 20,  hp = 4800 }, -- index  9 -> uses ADDR_ALT_BOSS_HP
    { name = "Chaos",                   area_name = "Chaos' Domain",        area_ID = 13, area_floor = 0,   hp = 5100 }, -- index 10
}

-- -------------------------------------------------------------
-- STATE
-- -------------------------------------------------------------
local pipe_handle       = nil
local is_run_active     = false
local is_boss_active    = false
local slain_bosses      = 0 -- used to know the next expected boss

-- previous-tick values, used to detect transitions (old -> current)
-- init as 0, because the respective addresses are initially zeroed anyway
local prev_menu_open    = 0
local prev_boss_hp      = 0
local prev_alt_boss_hp  = 0
local prev_area_ID      = 0
local prev_area_floor   = 0

-- -------------------------------------------------------------
-- LIVESPLIT PIPE HELPERS
-- -------------------------------------------------------------
local function init_livesplit()
    local handle = io.open("//./pipe/LiveSplit", "a")
    if not handle then
        error("\nFailed to open LiveSplit named pipe!\n" ..
              "Please make sure LiveSplit is running and is at least " ..
              "version 1.7, then load this script again.")
    end
    return handle
end

local function send_command(cmd)
    if not pipe_handle then
        return
    end
    local ok, err = pipe_handle:write(cmd .. "\r\n")
    if not ok then
        console.log("SS2: failed to write to LiveSplit pipe: " .. tostring(err))
        return
    end
    pipe_handle:flush()
end

local function ls_start()
    send_command("starttimer")
end

local function ls_split()
    send_command("split")
end

local function ls_reset()
    send_command("reset")
end

-- ---------------------------------------------------------
-- START
-- ---------------------------------------------------------
-- INFO: menu_open is probably not a great name
--       it toggles (0->1) on game start after character creation and when opening the inventory
-- least robust detection, just intended for starting the rom, 
-- choosing, naming, color scheming a character and then start
local function check_start()
    local menu_open = memory.read_u16_le(ADDR_MENU_OPEN)
    if prev_menu_open == 0 and menu_open ~= 0 then
        is_run_active = true
        ls_start()
    end
    -- save old value
    prev_menu_open = menu_open
end

-- -------------------------------------------------------------
-- SPLIT
-- -------------------------------------------------------------
local function check_split()
    -- read mem
    local player_hp    = memory.read_u16_le(ADDR_PLAYER_HP)
    local boss_hp      = memory.read_u16_le(ADDR_BOSS_HP)
    local alt_boss_hp  = memory.read_u16_le(ADDR_ALT_BOSS_HP)
    local area_ID      = memory.read_u16_le(ADDR_AREA_ID)
    local area_floor   = memory.read_u16_le(ADDR_AREA_FLOOR)

    -- debug logs
    if not DEBUG then
        -- do nothing
    elseif area_ID ~= prev_area_ID then
        console.log("SS2: Entered Area with ID " .. area_ID)
        console.log("SS2: Entered Floor " .. area_floor)
    elseif area_floor ~= prev_area_floor then
        console.log("SS2: Entered Floor " .. area_floor)
    end

    -- check for boss kill
    if is_run_active and slain_bosses < #bosses then
        local next_boss = bosses[slain_bosses + 1] -- Lua tables are 1-indexed
        local hp, prev_hp
        if slain_bosses == 6 or slain_bosses == 9 then -- Vaitali and Deatharte
            hp = alt_boss_hp
            prev_hp = prev_alt_boss_hp
        else
            hp = boss_hp
            prev_hp = prev_boss_hp
        end

        -- INFO: 3 min split that I used in Glitchless
        --       main purpose was to not forget doing the sidequest before Ship
        -- Klantol has area_ID = 0
        -- Ipa's Palace Shop has area_ID = 21, with floors 0,1,2,3,4
        -- splits on exit of the last floor

        -- if prev_area_ID == 21 and prev_area_floor == 4 and area_ID == 0 then -- IPA SPLIT CODE
        --     ls_split()                                                       -- IPA SPLIT CODE
        -- end                                                                  -- IPA SPLIT CODE

        -- reset boss fight flag in case of death
        if player_hp <= 0 then
            is_boss_active = false
        -- "boss is active" once HP is seen at exact value in expected floor of expected area, while player alive
        elseif not is_boss_active and area_ID == next_boss.area_ID and area_floor == next_boss.area_floor and hp == next_boss.hp then
            is_boss_active = true
        end

        -- SPLIT/KILL: In Boss fight, if Boss HP just dropped from >0 to 0
        if is_boss_active and prev_hp > 0 and hp == 0 then
            slain_bosses = slain_bosses + 1
            is_boss_active = false
            ls_split()
        end
    end

    -- save old values
    prev_boss_hp = boss_hp
    prev_alt_boss_hp = alt_boss_hp
    prev_area_ID = area_ID
    prev_area_floor = area_floor
end

-- -------------------------------------------------------------
-- ENTRY POINT
-- -------------------------------------------------------------
pipe_handle = init_livesplit()
ls_reset()
console.log("SS2: autosplitter loaded")

while true do
    if not is_run_active then
        check_start()
    end
    check_split()
    emu.frameadvance()
end
