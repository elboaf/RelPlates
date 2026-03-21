-- RelPlates.lua
-- Nameplate addon for WoW 1.12.1 (Turtle WoW)
-- Requires: SuperWoW | Benefits from: Nampower, UnitXP SP3
-- Author: Vati
-- ============================================================

RelPlatesDB = RelPlatesDB or {}

-- ── Print helper ──────────────────────────────────────────────────────────────

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RelPlates]|r " .. tostring(msg))
end

-- ── Detect optional DLL mods ──────────────────────────────────────────────────

local hasNamepower = (GetUnitField ~= nil)

-- ── SavedVariables globals ────────────────────────────────────────────────────

local S           = {}   -- Settings
local tankList    = {}   -- lowercased player names of designated off-tanks
local playerRole  = "DPS"
local minimapAngle = 220
local overlap      = true   -- true = plates overlap freely, false = engine stacks them

-- ── Defaults ──────────────────────────────────────────────────────────────────

local DEFAULTS = {
    hpHeight      = 10,
    hpWidth       = 115,
    hpTextShow    = true,
    hpTextFmt     = 1,
    hpTextPos     = "CENTER",
    mpShow        = false,
    mpHeight      = 4,
    mpTextShow    = true,
    mpTextFmt     = 1,
    mpTextPos     = "CENTER",
    cbHeight      = 8,
    cbWidth       = 115,
    cbIndependent = false,
    cbIconShow    = true,
    cbColor       = {1, 0.8, 0, 1},
    font          = "Fonts\\ARIALN.TTF",
    hpFontSize    = 8,
    nameFontSize  = 10,
    lvlFontSize   = 10,
    nameColor     = {1, 1, 1, 1},
    hpTextColor   = {1, 1, 1, 1},
    mpTextColor   = {1, 1, 1, 1},
    lvlColor      = {1, 1, 0.6, 1},
    targetColor   = {0.4, 0.8, 0.9, 1},
    raidIconSide  = "LEFT",
    colorRed      = {0.85, 0.20, 0.20, 1},
    colorOrange   = {1.00, 0.55, 0.00, 1},
    colorBlue     = {0.41, 0.35, 0.76, 1},
    colorOtherTank= {0.95, 0.50, 0.50, 1},
    colorTapped   = {0.50, 0.50, 0.50, 1},
    colorFriendly = {0.27, 0.63, 0.27, 1},
    colorNeutral  = {0.90, 0.70, 0.00, 1},
    colorMana     = {0.07, 0.58, 1.00, 1},
}

for k, v in pairs(DEFAULTS) do
    if type(v) == "table" then
        local t = {}
        for i, v2 in pairs(v) do t[i] = v2 end
        S[k] = t
    else
        S[k] = v
    end
end

-- ── Threat colors ─────────────────────────────────────────────────────────────

local CLASS_COLORS = {
    WARRIOR={0.78,0.61,0.43,1}, PALADIN={0.96,0.55,0.73,1},
    HUNTER ={0.67,0.83,0.45,1}, ROGUE  ={1.00,0.96,0.41,1},
    PRIEST ={1.00,1.00,1.00,1}, SHAMAN ={0.00,0.44,0.87,1},
    MAGE   ={0.41,0.80,0.94,1}, WARLOCK={0.58,0.51,0.79,1},
    DRUID  ={1.00,0.49,0.04,1},
}

-- ── GUID → threat key ─────────────────────────────────────────────────────────

local HEX = {
    ["0"]=0,["1"]=1,["2"]=2,["3"]=3,["4"]=4,
    ["5"]=5,["6"]=6,["7"]=7,["8"]=8,["9"]=9,
    ["A"]=10,["a"]=10,["B"]=11,["b"]=11,
    ["C"]=12,["c"]=12,["D"]=13,["d"]=13,
    ["E"]=14,["e"]=14,["F"]=15,["f"]=15,
}

local function guidToKey(guid)
    if not guid or guid == "" then return nil end
    local clean = string.gsub(guid, "^0x", "")
    local len = string.len(clean)
    if len < 4 then return nil end
    local last4 = string.sub(clean, len - 3, len)
    local n = 0
    for i = 1, 4 do
        local v = HEX[string.sub(last4, i, i)]
        if not v then return nil end
        n = n * 16 + v
    end
    return tostring(n)
end

-- ── Threat engine ─────────────────────────────────────────────────────────────
--
-- RelPlates has a fully standalone threat engine. TWThreat does NOT need to be
-- installed. We speak the same wire protocol and maintain our own threat tables.
--
-- HOW IT WORKS
-- ─────────────
-- Every 0.2s while in combat with a group and targeting an elite or worldboss,
-- we send:  SendAddonMessage("TWT_UDTSv4_TM", "limit=10", "RAID"/"PARTY")
--
-- The server responds with two possible packet types (via CHAT_MSG_ADDON):
--
--   TWTv4=name:tank:threat:perc:melee;...
--     Single-target data for the current target. One entry per player.
--     tank=1 means that player is top threat holder.
--     perc = that player's % of the top threat holder (0-100).
--     We extract our own perc and isTank status, plus the highest non-tank perc.
--
--   TMTv1=creature:guid:name:perc;...
--     Multi-mob tank-mode data. One entry per mob the server has threat data for.
--     guid = last 4 hex digits of SuperWoW GUID converted to decimal string.
--     name = second-highest threat holder on that creature.
--     perc = second-highest holder's % of top on that creature (0-100).
--     Only sent when the requesting player has top threat on at least one mob.
--     This is the key AoE limitation — DPS never receive TMTv1= data.
--
-- The server often sends a combined packet: TWTv4=...#TMTv1=...
--
-- GUID KEY CONVERSION
-- ───────────────────
-- SuperWoW GUIDs look like "0xF130002C3600BE12".
-- TMTv1= uses the last 4 hex digits converted to decimal as the mob identifier.
-- e.g. "0xF130002C3600BE12" → last4 = "BE12" → 48658
-- This is how we correlate nameplate GUIDs to threat table entries.
--
-- DATA TABLES
-- ───────────
-- GP_st[key] = single-target data (from TWTv4=), keyed by GUID key
--   { perc, isTank, warningPerc, time }
--   warningPerc: if isTank → highest non-tank's %; if DPS → our own %
--   TTL: 3s, but extended while the mob's plate is still visible (stun support)
--
-- GP_tm[key] = tank-mode data (from TMTv1=), keyed by GUID key
--   { creature, name, perc, time }
--   perc = second-highest threat holder's % of top on that mob
--   TTL: same as GP_st — extended while plate is visible
--   Priority: GP_tm is checked first, falls through to GP_st if absent/expired
--
-- Both tables are wiped on PLAYER_REGEN_ENABLED (combat end).
--
-- COLOR SYSTEM
-- ─────────────
-- Role-aware, split into two independent gradients:
--
--   TANK mode (playerRole == "TANK"):
--     Has aggro    → red → orange  (gradient starts at 50% challenger threat)
--     Lost aggro   → static blue
--     Lost-aggro plates pop to frame level 22 (above target at 20) so they
--     are always clickable for fast retaunt targeting.
--
--   DPS/Healer mode:
--     No aggro     → blue → red    (gradient starts at 50% of tank's threat)
--     Has aggro    → static red
--
--   Both roles:
--     Friendly     → green
--     Neutral idle → yellow
--     Enemy player → class color
--     Tapped       → grey
--     Off-tank mob → light red (mob targeting a player in tankList)
--
-- STUN / CC COLOR CACHING
-- ────────────────────────
-- When a mob has no target and isn't attacking (stunned, feared, CC'd),
-- inCombat and isAttacking both drop to false. Without caching this would
-- cause the plate to snap to the binary fallback color (blue/neutral).
-- Instead, we cache the last computed threat color on the plate frame and
-- serve it whenever the mob appears stunned, refreshing the cache timestamp
-- each frame so long stuns don't expire it. The cache is cleared when the
-- plate is hidden (mob dies/despawns).
--

local PLAYER_NAME = UnitName("player")
local GP_st = {}   -- single-target data keyed by GUID key
local GP_tm = {}   -- tank-mode data keyed by GUID key
local GP_TTL = 3

local function wipe(t) for k in pairs(t) do t[k] = nil end end

local function explode(s, sep)
    local r, from = {}, 1
    local a, b = string.find(s, sep, from, true)
    while a do
        table.insert(r, string.sub(s, from, a-1))
        from = b + 1
        a, b = string.find(s, sep, from, true)
    end
    table.insert(r, string.sub(s, from))
    return r
end

local function parseThreatPacket(msg)
    local start = string.find(msg, "TWTv4=", 1, true)
    if not start then return end
    if not UnitExists("target") or UnitIsPlayer("target") then return end
    local _, tGuid = UnitExists("target")
    if not tGuid then return end
    local key = guidToKey(tGuid)
    if not key then return end

    local body = string.sub(msg, start + 6)
    local hash = string.find(body, "#", 1, true)
    if hash then body = string.sub(body, 1, hash-1) end

    local myPerc, myTank, topOther = 0, false, 0
    for _, entry in ipairs(explode(body, ";")) do
        local f = explode(entry, ":")
        if f[1] and f[2] and f[4] then
            local isTnk = f[2] == "1"
            local perc  = tonumber(f[4]) or 0
            if f[1] == PLAYER_NAME then
                myPerc = perc; myTank = isTnk
            elseif not isTnk and perc > topOther then
                topOther = perc
            end
        end
    end

    GP_st[key] = {
        perc        = myPerc,
        isTank      = myTank,
        warningPerc = myTank and topOther or myPerc,
        time        = GetTime(),
    }
end

local function parseTankModePacket(msg)
    local start = string.find(msg, "TMTv1=", 1, true)
    if not start then return end
    local body = string.sub(msg, start + 6)
    wipe(GP_tm)
    for _, entry in ipairs(explode(body, ";")) do
        local f = explode(entry, ":")
        if f[1] and f[2] and f[3] and f[4] then
            GP_tm[f[2]] = { creature=f[1], name=f[3], perc=tonumber(f[4]) or 0, time=GetTime() }
        end
    end
end

local function onPacket(msg)
    if string.find(msg, "TWTv4=", 1, true) then
        parseThreatPacket(msg)
        if string.find(msg, "#", 1, true) and string.find(msg, "TMTv1=", 1, true) then
            parseTankModePacket(string.sub(msg, string.find(msg, "#", 1, true) + 1))
        end
    elseif string.find(msg, "TMTv1=", 1, true) then
        parseTankModePacket(msg)
    end
end

local registry = {}
local castDB   = {}
local plateSeq = 0

local pollFrame = CreateFrame("Frame")
pollFrame:Hide()
pollFrame:SetScript("OnShow",   function() this.t = GetTime() end)
pollFrame:SetScript("OnUpdate", function()
    local now = GetTime()
    if not this.t then this.t = now end
    if now - this.t < 0.2 then return end
    this.t = now
    local ch = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
    if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then return end
    SendAddonMessage("TWT_UDTSv4_TM", "limit=10", ch)

    -- Build set of keys that have a visible plate right now
    local activeKeys = {}
    for frame, plate in pairs(registry) do
        if frame:IsShown() then
            local g = frame:GetName(1)
            local k = g and guidToKey(g)
            if k then activeKeys[k] = true end
        end
    end

    -- ST entries expire normally at GP_TTL — don't extend them while visible.
    -- Stale isTank=true data after an aggro swap is worse than no data.
    -- TM entries are extended while visible for stun/CC support (the server
    -- stops sending TM data when you lose top threat, so we keep it alive).
    for k, v in pairs(GP_st) do
        if now - v.time > GP_TTL then GP_st[k] = nil end
    end
    for k, v in pairs(GP_tm) do
        if now - v.time > GP_TTL and not activeKeys[k] then GP_tm[k] = nil end
    end
end)

local function combatEnd()
    wipe(GP_st); wipe(GP_tm); pollFrame:Hide()
end

-- ── Color helpers ─────────────────────────────────────────────────────────────

local function setColor(bar, col)
    bar:SetStatusBarColor(col[1], col[2], col[3], col[4] or 1)
end

-- ── Unit class lookup ─────────────────────────────────────────────────────────

local function getUnitClass(guid)
    if not guid then return nil end
    if hasNamepower and GetUnitData then
        local d = GetUnitData(guid)
        if d and d.classId then
            local map = {[1]="WARRIOR",[2]="PALADIN",[3]="HUNTER",[4]="ROGUE",
                         [5]="PRIEST",[7]="SHAMAN",[8]="MAGE",[9]="WARLOCK",[11]="DRUID"}
            return map[d.classId]
        end
    end
    if UnitClass then local _, cl = UnitClass(guid); return cl end
    return nil
end

-- ── Nameplate registry & building ────────────────────────────────────────────

local function isNameplateFrame(f)
    if not f then return false end
    local t = f:GetObjectType()
    if t ~= "Frame" and t ~= "Button" then return false end
    for _, r in ipairs({f:GetRegions()}) do
        if r and r.GetObjectType and r:GetObjectType() == "Texture" and r.GetTexture then
            if r:GetTexture() == "Interface\\Tooltips\\Nameplate-Border" then return true end
        end
    end
    return false
end

local applyDimensions  -- forward declare

local function buildPlate(frame)
    plateSeq = plateSeq + 1
    local p = CreateFrame("Button", "RelPlate"..plateSeq, WorldFrame)
    p:EnableMouse(false)
    p:SetFrameStrata("BACKGROUND")
    p:SetFrameLevel(5)
    p:RegisterForClicks("LeftButtonUp","RightButtonUp")
    p:SetScript("OnClick", function()
        local guid = frame:GetName(1)
        if guid and guid ~= "" then
            TargetUnit(guid)
        end
    end)

    p.original = {}

    for i, r in ipairs({frame:GetRegions()}) do
        if r and r.GetObjectType then
            if i == 2 then p.original.glow     = r end
            if i == 6 then p.original.raidicon = r end
            if r:GetObjectType() == "FontString" then
                local txt = r:GetText()
                if txt then
                    if tonumber(txt) then p.original.level = r
                    else                  p.original.name  = r end
                end
            end
        end
    end
    p.original.hp = frame.healthbar or frame:GetChildren()

    -- Health bar
    p.hp = CreateFrame("StatusBar", nil, p)
    p.hp:SetFrameStrata("BACKGROUND"); p.hp:SetFrameLevel(6)
    p.hp:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    p.hp:SetPoint("CENTER", p, "CENTER", 0, 0)
    p.hp.bg = p.hp:CreateTexture(nil, "BACKGROUND")
    p.hp.bg:SetTexture(0,0,0,0.8); p.hp.bg:SetAllPoints()
    p.hp.border = p.hp:CreateTexture(nil, "OVERLAY")
    p.hp.border:SetTexture(0,0,0,1); p.hp.border:SetAllPoints(); p.hp.border:SetDrawLayer("BORDER")

    -- Mana bar
    p.mp = CreateFrame("StatusBar", nil, p)
    p.mp:SetFrameStrata("BACKGROUND"); p.mp:SetFrameLevel(6)
    p.mp:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    p.mp:SetStatusBarColor(S.colorMana[1], S.colorMana[2], S.colorMana[3], 1)
    p.mp:SetPoint("TOP", p.hp, "BOTTOM", 0, 0); p.mp:Hide()
    p.mp.bg = p.mp:CreateTexture(nil, "BACKGROUND")
    p.mp.bg:SetTexture(0,0,0,0.8); p.mp.bg:SetAllPoints()
    p.mp.border = p.mp:CreateTexture(nil, "OVERLAY")
    p.mp.border:SetTexture(0,0,0,1); p.mp.border:SetAllPoints(); p.mp.border:SetDrawLayer("BORDER")
    p.mp.text = p.mp:CreateFontString(nil, "OVERLAY")

    -- Cast bar
    p.cb = CreateFrame("StatusBar", nil, p)
    p.cb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8"); p.cb:Hide()
    p.cb.bg = p.cb:CreateTexture(nil, "BACKGROUND")
    p.cb.bg:SetTexture(0,0,0,1); p.cb.bg:SetAllPoints()
    p.cb.border = p.cb:CreateTexture(nil, "OVERLAY")
    p.cb.border:SetTexture(0,0,0,1); p.cb.border:SetAllPoints(); p.cb.border:SetDrawLayer("BORDER")
    p.cb.text = p.cb:CreateFontString(nil, "OVERLAY")
    p.cb.text:SetPoint("LEFT",p.cb,"LEFT",2,0); p.cb.text:SetJustifyH("LEFT"); p.cb.text:SetTextColor(1,1,1,1)
    p.cb.timer = p.cb:CreateFontString(nil, "OVERLAY")
    p.cb.timer:SetPoint("RIGHT",p.cb,"RIGHT",-2,0); p.cb.timer:SetJustifyH("RIGHT"); p.cb.timer:SetTextColor(1,1,1,1)
    p.cb.icon = p.cb:CreateTexture(nil, "OVERLAY"); p.cb.icon:SetTexCoord(0.08,0.92,0.08,0.92)
    p.cb.icon.border = p.cb:CreateTexture(nil, "BACKGROUND"); p.cb.icon.border:SetTexture(0,0,0,1)

    -- Target brackets (parented to hp bar for natural clipping)
    local function mkTex()
        local t = p.hp:CreateTexture(nil, "OVERLAY")
        t:SetTexture(1,1,1,0.6); t:Hide(); return t
    end
    p.br = { lv=mkTex(), lt=mkTex(), lb=mkTex(), rv=mkTex(), rt=mkTex(), rb=mkTex() }
    p.br.lv:SetWidth(1); p.br.rv:SetWidth(1)
    p.br.lt:SetHeight(1); p.br.lt:SetWidth(6)
    p.br.lb:SetHeight(1); p.br.lb:SetWidth(6)
    p.br.rt:SetHeight(1); p.br.rt:SetWidth(6)
    p.br.rb:SetHeight(1); p.br.rb:SetWidth(6)

    -- Text elements
    p.name = p:CreateFontString(nil, "OVERLAY")
    p.name:SetPoint("BOTTOM", p.hp, "TOP", 0, 6); p.name:SetJustifyH("CENTER")
    p.level = p:CreateFontString(nil, "OVERLAY")
    p.level:SetPoint("BOTTOMRIGHT", p.hp, "TOPRIGHT", 0, 2); p.level:SetJustifyH("RIGHT")
    p.hptext = p.hp:CreateFontString(nil, "OVERLAY")
    p.hptext:SetPoint("CENTER", p.hp, "CENTER", 0, 0); p.hptext:SetJustifyH("CENTER")

    -- Reparent raid icon
    if p.original.raidicon then
        p.original.raidicon:SetParent(p.hp)
        p.original.raidicon:SetWidth(24); p.original.raidicon:SetHeight(24)
        p.original.raidicon:SetDrawLayer("OVERLAY")
    end

    frame.plate = p
    registry[frame] = p
    applyDimensions(p)
    return p
end

-- ── applyDimensions ───────────────────────────────────────────────────────────

applyDimensions = function(p)
    p.hp:SetWidth(S.hpWidth); p.hp:SetHeight(S.hpHeight)
    p.mp:SetWidth(S.hpWidth); p.mp:SetHeight(S.mpHeight)
    p.cb:SetWidth(S.cbIndependent and S.cbWidth or S.hpWidth); p.cb:SetHeight(S.cbHeight)
    p.cb:SetStatusBarColor(S.cbColor[1], S.cbColor[2], S.cbColor[3], S.cbColor[4] or 1)

    if p.original.raidicon then
        p.original.raidicon:ClearAllPoints()
        if S.raidIconSide == "RIGHT" then
            p.original.raidicon:SetPoint("LEFT",  p.hp, "RIGHT",  5, 0)
        else
            p.original.raidicon:SetPoint("RIGHT", p.hp, "LEFT",  -5, 0)
        end
    end

    local font = S.font
    p.name:SetFont(font, S.nameFontSize, "OUTLINE")
    p.level:SetFont(font, S.lvlFontSize, "OUTLINE")
    p.hptext:SetFont(font, S.hpFontSize, "OUTLINE")
    p.mp.text:SetFont(font, 7, "OUTLINE")
    p.cb.text:SetFont(font, 8, "OUTLINE")
    p.cb.timer:SetFont(font, 8, "OUTLINE")

    p.name:SetTextColor(S.nameColor[1], S.nameColor[2], S.nameColor[3], 1)
    p.level:SetTextColor(S.lvlColor[1], S.lvlColor[2], S.lvlColor[3], 1)
    p.hptext:SetTextColor(S.hpTextColor[1], S.hpTextColor[2], S.hpTextColor[3], 1)
    p.mp.text:SetTextColor(S.mpTextColor[1], S.mpTextColor[2], S.mpTextColor[3], 1)

    -- HP text position
    p.hptext:ClearAllPoints()
    if S.hpTextPos == "LEFT" then
        p.hptext:SetPoint("LEFT", p.hp, "LEFT", 2, 0); p.hptext:SetJustifyH("LEFT")
    elseif S.hpTextPos == "RIGHT" then
        p.hptext:SetPoint("RIGHT", p.hp, "RIGHT", -2, 0); p.hptext:SetJustifyH("RIGHT")
    else
        p.hptext:SetPoint("CENTER", p.hp, "CENTER", 0, 0); p.hptext:SetJustifyH("CENTER")
    end

    -- MP text position
    p.mp.text:ClearAllPoints()
    if S.mpTextPos == "LEFT" then
        p.mp.text:SetPoint("LEFT", p.mp, "LEFT", 2, 0); p.mp.text:SetJustifyH("LEFT")
    elseif S.mpTextPos == "RIGHT" then
        p.mp.text:SetPoint("RIGHT", p.mp, "RIGHT", -2, 0); p.mp.text:SetJustifyH("RIGHT")
    else
        p.mp.text:SetPoint("CENTER", p.mp, "CENTER", 0, 0); p.mp.text:SetJustifyH("CENTER")
    end
end

-- ── Text formatters ───────────────────────────────────────────────────────────

local function fmtHP(hp, hpmax)
    if not S.hpTextShow then return "" end
    local pct = (hp / hpmax) * 100
    local fmt = S.hpTextFmt
    if fmt == 1 then return string.format("%.0f%%", pct)
    elseif fmt == 2 then
        return hp > 1000 and string.format("%.1fK", hp/1000) or string.format("%d", hp)
    elseif fmt == 3 then
        local cur = hp > 1000 and string.format("%.1fK", hp/1000) or string.format("%d", hp)
        return string.format("%s (%.0f%%)", cur, pct)
    elseif fmt == 4 then
        if hpmax > 1000 then return string.format("%.1fK-%.1fK", hp/1000, hpmax/1000)
        else return string.format("%d-%d", hp, hpmax) end
    elseif fmt == 5 then
        if hpmax > 1000 then return string.format("%.1fK-%.1fK (%.0f%%)", hp/1000, hpmax/1000, pct)
        else return string.format("%d-%d (%.0f%%)", hp, hpmax, pct) end
    end
    return ""
end

local function fmtMP(mp, mpmax)
    if not S.mpTextShow then return "" end
    local pct = (mp / mpmax) * 100
    local fmt = S.mpTextFmt
    if fmt == 1 then return string.format("%.0f%%", pct)
    elseif fmt == 2 then
        return mp > 1000 and string.format("%.1fK", mp/1000) or string.format("%d", mp)
    elseif fmt == 3 then
        local cur = mp > 1000 and string.format("%.1fK", mp/1000) or string.format("%d", mp)
        return string.format("%s (%.0f%%)", cur, pct)
    end
    return ""
end

-- ── updatePlate ───────────────────────────────────────────────────────────────

local function blend(a, b, t)
    if t <= 0 then return a end
    if t >= 1 then return b end
    return { a[1]+(b[1]-a[1])*t, a[2]+(b[2]-a[2])*t, a[3]+(b[3]-a[3])*t, 1 }
end

local GRADIENT_FLOOR = 50

local function threatColor(isTopThreat, threatPct)
    if playerRole == "TANK" then
        if isTopThreat then
            local t = (threatPct - GRADIENT_FLOOR) / (100 - GRADIENT_FLOOR)
            return blend(S.colorRed, S.colorOrange, t)
        else
            return S.colorBlue
        end
    else
        if isTopThreat then
            return S.colorRed
        else
            local t = (threatPct - GRADIENT_FLOOR) / (100 - GRADIENT_FLOOR)
            return blend(S.colorBlue, S.colorRed, t)
        end
    end
end

local function updatePlate(frame)
    local p = frame.plate
    if not p then return end
    local orig = p.original
    if not orig.hp then return end

    -- Faction from bar color — must be read BEFORE suppressing the original bar,
    -- because SetStatusBarTexture("") resets the color to white in WoW 1.12.
    local r, g, b = orig.hp:GetStatusBarColor()
    local isFriendly = g > 0.8 and r < 0.5
    local isHostile  = r > 0.8 and g < 0.5
    local isNeutral  = not isFriendly and not isHostile

    -- Suppress original textures once (stable, don't change after first pass).
    -- FontStrings must be suppressed every frame — the game resets their alpha
    -- on unit updates, causing original name/level text to bleed through.
    if not p.suppressed then
        orig.hp:SetStatusBarTexture(""); orig.hp:SetAlpha(0)
        for _, reg in ipairs({frame:GetRegions()}) do
            if reg and reg.GetObjectType then
                local ot = reg:GetObjectType()
                if ot == "Texture" and reg ~= orig.raidicon then reg:SetAlpha(0) end
            end
        end
        for _, ch in ipairs({frame:GetChildren()}) do
            if ch and ch ~= p and ch ~= orig.hp then
                if ch.SetAlpha then ch:SetAlpha(0) end
                if ch.Hide then ch:Hide() end
            end
        end
        p.suppressed = true
    end
    -- Always hide original FontStrings (name, level) every frame
    for _, reg in ipairs({frame:GetRegions()}) do
        if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" then
            reg:SetAlpha(0)
        end
    end

    -- Health
    local hp = orig.hp:GetValue() or 0
    local hpmin, hpmax = orig.hp:GetMinMaxValues()
    if not hpmax or hpmax == 0 then hpmax = 1 end
    p.hp:SetMinMaxValues(hpmin, hpmax); p.hp:SetValue(hp)
    p.hptext:SetText(fmtHP(hp, hpmax))

    -- Level
    if orig.level and orig.level.GetText then p.level:SetText(orig.level:GetText() or "") end

    -- Name
    if orig.name and orig.name.GetText then p.name:SetText(orig.name:GetText() or "") end

    -- GUID via SuperWoW
    local guid = frame:GetName(1)

    -- SuperWoW unit queries (all accept GUID)
    local isAttacking   = false
    local isTargetTank  = false
    local isTapped      = false
    local inCombat      = false
    local isEnemyPlayer = false
    local unitClass     = nil

    if guid and guid ~= "" then
        local mobTarget = guid .. "target"
        isAttacking   = UnitIsUnit(mobTarget, "player")
        isTapped      = UnitIsTapped(guid) and not UnitIsTappedByPlayer(guid)
        inCombat      = UnitExists(mobTarget)
        isEnemyPlayer = UnitIsPlayer(guid)
        if isEnemyPlayer then unitClass = getUnitClass(guid) end
        if not isAttacking and inCombat then
            local tn = UnitName(mobTarget)
            if tn then isTargetTank = (tankList[string.lower(tn)] == true) end
        end
    end

    -- Mana bar
    local mpShown = false
    if S.mpShow and guid and guid ~= "" then
        local mp, mpmax = 0, 0
        if hasNamepower and GetUnitField then
            mp    = GetUnitField(guid, "power1") or 0
            mpmax = GetUnitField(guid, "maxPower1") or 0
        else
            mp    = UnitMana(guid) or 0
            mpmax = UnitManaMax(guid) or 0
        end
        local pt = UnitPowerType and UnitPowerType(guid) or 0
        if mpmax > 0 and pt == 0 then
            p.mp:SetMinMaxValues(0, mpmax); p.mp:SetValue(mp)
            p.mp.text:SetText(fmtMP(mp, mpmax)); p.mp:Show(); mpShown = true
        else p.mp:Hide() end
    else p.mp:Hide() end

    -- Track whether this mob has been in combat this plate lifetime.
    -- Set when we observe a target or being attacked. Cleared on plate hide.
    if inCombat or isAttacking then
        p.wasInCombat = true
    end

    local now = GetTime()

    -- ── Threat data hierarchy ──────────────────────────────────────────────────
    -- ST data (TWTv4=)  : ultimate truth. isTank is authoritative. Expires at 3s.
    -- TM data (TMTv1=)  : truthful when present, but lossy — server only sends it
    --                     when we have top threat, and drops mobs silently on swap.
    --                     TTL extended while plate is visible for stun support.
    -- isAttacking       : decent indicator we have aggro, but not always true
    --                     (mob may be casting on a secondary target).
    -- inCombat          : mob has a target, but not necessarily us.
    -- not inCombat      : mob has no target — does NOT mean out of combat.
    -- ─────────────────────────────────────────────────────────────────────────

    local threatPct   = 0
    local hasThreat   = false
    local isTopThreat = false

    if p.wasInCombat and guid and guid ~= "" then
        local key = guidToKey(guid)
        if key then
            local st = GP_st[key]
            local tm = GP_tm[key]
            if st then
                -- ST is ultimate truth
                threatPct   = st.warningPerc
                hasThreat   = true
                isTopThreat = st.isTank
            elseif tm then
                -- TM is truthful when present: we have top threat
                threatPct   = tm.perc
                hasThreat   = true
                isTopThreat = true
            end
        end
    end

    -- Color decision
    local col
    if isFriendly then
        col = S.colorFriendly

    elseif isEnemyPlayer and unitClass and CLASS_COLORS[unitClass] then
        col = CLASS_COLORS[unitClass]

    elseif isTapped then
        col = S.colorTapped

    elseif isTargetTank then
        -- Mob is targeting a listed off-tank — highest priority combat signal,
        -- overrides threat data (which may be stale or from a different target state)
        col = S.colorOtherTank

    elseif hasThreat then
        -- Packet data available — trust it, regardless of mob target state
        if isTopThreat then
            col = threatColor(true, threatPct)
        else
            col = threatColor(false, threatPct)
        end

    elseif isAttacking then
        -- No packet data, but mob is on us — decent indicator
        col = S.colorRed

    elseif inCombat then
        -- Mob has a target, not us, no packet data
        col = S.colorBlue

    elseif p.wasInCombat then
        -- Mob has no target but was in combat — stunned/CC'd/brief gap.
        -- not inCombat does NOT mean out of combat.
        if p.colorCache and (now - p.colorCache.time < GP_TTL) then
            col = p.colorCache.col
        else
            col = S.colorBlue
        end

    else
        -- Genuinely idle
        col = isNeutral and S.colorNeutral or S.colorBlue
    end

    -- Cache while mob has an active target so stun fallback stays fresh
    if inCombat or isAttacking then
        p.colorCache = { col = col, time = now }
    end

    setColor(p.hp, col)

    -- Target indicator (GUID-based, exact)
    local isTarget = false
    if guid and guid ~= "" and UnitExists("target") then
        local _, tguid = UnitExists("target")
        isTarget = (tguid == guid) and (frame:GetAlpha() == 1)
    end

    local br   = p.br
    local topA = p.hp
    local botA = mpShown and p.mp or p.hp

    if isTarget then
        br.lv:ClearAllPoints()
        br.lv:SetPoint("TOPRIGHT",    topA, "TOPLEFT",    -1,  2)
        br.lv:SetPoint("BOTTOMRIGHT", botA, "BOTTOMLEFT", -1, -2)
        br.lv:Show()
        br.lt:ClearAllPoints(); br.lt:SetPoint("TOPLEFT",    br.lv, "TOPRIGHT",    0, 0); br.lt:Show()
        br.lb:ClearAllPoints(); br.lb:SetPoint("BOTTOMLEFT", br.lv, "BOTTOMRIGHT", 0, 0); br.lb:Show()
        br.rv:ClearAllPoints()
        br.rv:SetPoint("TOPLEFT",    topA, "TOPRIGHT",    1,  2)
        br.rv:SetPoint("BOTTOMLEFT", botA, "BOTTOMRIGHT", 1, -2)
        br.rv:Show()
        br.rt:ClearAllPoints(); br.rt:SetPoint("TOPRIGHT",    br.rv, "TOPLEFT",    0, 0); br.rt:Show()
        br.rb:ClearAllPoints(); br.rb:SetPoint("BOTTOMRIGHT", br.rv, "BOTTOMLEFT", 0, 0); br.rb:Show()
        p.hp.border:SetVertexColor(S.targetColor[1], S.targetColor[2], S.targetColor[3], 1)
        p:SetFrameLevel(20); p.hp:SetFrameLevel(21)
    else
        br.lv:Hide(); br.lt:Hide(); br.lb:Hide()
        br.rv:Hide(); br.rt:Hide(); br.rb:Hide()
        p.hp.border:SetVertexColor(0,0,0,1)
        local lostAggro = (playerRole == "TANK") and inCombat and not isTopThreat
        local highPriority = isAttacking or lostAggro
        -- Lost aggro plates go above the target plate (22/23 > 20/21)
        -- so they're always clickable even when overlapping the current target
        local level = lostAggro and 22 or (highPriority and 16 or 5)
        p:SetFrameLevel(level)
        p.hp:SetFrameLevel(level + 1)
    end

    -- Cast bar
    local cast = nil
    if guid and UnitCastingInfo then
        local spell,_,_,texture,startMs,endMs = UnitCastingInfo(guid)
        if spell then cast = {spell=spell,icon=texture,start=startMs/1000,dur=endMs-startMs} end
    end
    if not cast and guid and UnitChannelInfo then
        local spell,_,_,texture,startMs,endMs = UnitChannelInfo(guid)
        if spell then cast = {spell=spell,icon=texture,start=startMs/1000,dur=endMs-startMs} end
    end
    if not cast and guid and castDB[guid] then
        local cd = castDB[guid]
        if cd.start + cd.dur/1000 > now then cast = cd
        else castDB[guid] = nil end
    end

    if cast then
        local dur  = cast.dur
        local left = cast.start + dur/1000 - now
        p.cb:SetMinMaxValues(0, dur)
        p.cb:SetValue(math.max(0, (now - cast.start)*1000))
        p.cb.text:SetText(cast.spell or "")
        p.cb.timer:SetText(left > 0 and string.format("%.1fs", left) or "")
        p.cb:ClearAllPoints()
        p.cb:SetPoint("TOP", mpShown and p.mp or p.hp, "BOTTOM", 0, -2)

        if cast.icon and S.cbIconShow then
            local iconH = S.hpHeight + S.cbHeight + (mpShown and S.mpHeight or 0)
            p.cb.icon:SetWidth(iconH); p.cb.icon:SetHeight(iconH)
            p.cb.icon:SetTexture(cast.icon); p.cb.icon:ClearAllPoints()
            if S.raidIconSide == "RIGHT" then
                p.cb.icon:SetPoint("BOTTOMRIGHT", p.cb, "BOTTOMLEFT", -4, 0)
            else
                p.cb.icon:SetPoint("BOTTOMLEFT",  p.cb, "BOTTOMRIGHT",  4, 0)
            end
            p.cb.icon:Show()
            p.cb.icon.border:SetAllPoints(p.cb.icon); p.cb.icon.border:Show()
        else
            p.cb.icon:Hide(); p.cb.icon.border:Hide()
        end
        p.cb:Show()
    else
        p.cb:Hide()
    end
end

-- ── Main frame / events ───────────────────────────────────────────────────────

local mainFrame = CreateFrame("Frame", "RelPlatesFrame", UIParent)
mainFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
mainFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
mainFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
mainFrame:RegisterEvent("UNIT_CASTEVENT")
mainFrame:RegisterEvent("CHAT_MSG_ADDON")

mainFrame:SetScript("OnUpdate", function()
    for _, f in ipairs({WorldFrame:GetChildren()}) do
        if isNameplateFrame(f) and not registry[f] then buildPlate(f) end
    end
    for frame, plate in pairs(registry) do
        if frame:IsShown() then
            if not plate:IsShown() then
                plate:Show()
            end
            updatePlate(frame)
            if overlap then
                -- Overlap mode: shrink vanilla frame to 1x1 so the engine ignores
                -- it for stacking. Plates sit freely at the unit's natural screen position.
                if frame:GetWidth() > 1 then
                    frame:SetWidth(1); frame:SetHeight(1)
                end
                frame:EnableMouse(false)
                if not plate.layoutSetup or plate.layoutW ~= S.hpWidth or plate.layoutH ~= S.hpHeight then
                    plate:ClearAllPoints()
                    plate:SetPoint("CENTER", frame, "CENTER", 0, 0)
                    plate:SetWidth(S.hpWidth + 10)
                    plate:SetHeight(S.hpHeight + 30)
                    plate:EnableMouse(true)
                    plate.layoutSetup = true
                    plate.layoutW = S.hpWidth
                    plate.layoutH = S.hpHeight
                    applyDimensions(plate)
                end
            else
                -- Stacking mode: match vanilla frame size to our overlay so the engine
                -- spaces plates correctly based on our actual bar dimensions.
                local targetW = math.floor((S.hpWidth + 10) * UIParent:GetScale())
                local targetH = math.floor((S.hpHeight + 30) * UIParent:GetScale())
                if math.floor(frame:GetWidth()) ~= targetW then
                    frame:SetWidth(targetW); frame:SetHeight(targetH)
                end
                frame:EnableMouse(false)
                if not plate.layoutSetup or plate.layoutW ~= S.hpWidth or plate.layoutH ~= S.hpHeight then
                    plate:ClearAllPoints()
                    plate:SetPoint("CENTER", frame, "CENTER", 0, 0)
                    plate:SetWidth(S.hpWidth + 10)
                    plate:SetHeight(S.hpHeight + 30)
                    plate:EnableMouse(true)
                    plate.layoutSetup = true
                    plate.layoutW = S.hpWidth
                    plate.layoutH = S.hpHeight
                    applyDimensions(plate)
                end
            end
        else
            if plate:IsShown() then plate:Hide() end
            plate.colorCache  = nil
            plate.suppressed  = nil
            plate.layoutSetup = nil
            plate.wasInCombat = nil
        end
    end
end)

mainFrame:SetScript("OnEvent", function()
    if event == "PLAYER_REGEN_DISABLED" then
        pollFrame:Show()
    elseif event == "PLAYER_REGEN_ENABLED" then
        combatEnd()
    elseif event == "PLAYER_ENTERING_WORLD" then
        combatEnd(); wipe(castDB)
        Print("Loaded. /rp for options.")
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- nothing needed at runtime

    elseif event == "UNIT_CASTEVENT" then
        local cg, etype, sid, dur = arg1, arg3, arg4, arg5
        if not cg then return end
        if etype == "START" or etype == "CHANNEL" then
            local spell, _, icon
            if SpellInfo and sid then spell,_,icon = SpellInfo(sid) end
            castDB[cg] = { spell=spell or "Casting", icon=icon, start=GetTime(), dur=dur or 0 }
        elseif etype == "CAST" or etype == "FAIL" then
            castDB[cg] = nil
        end
    elseif event == "CHAT_MSG_ADDON" then
        if arg2 then onPacket(arg2) end
    end
end)

-- ── Settings save/load ────────────────────────────────────────────────────────

local function invalidatePlateLayout()
    for _, plate in pairs(registry) do
        plate.layoutSetup = nil
        plate.suppressed  = nil
        plate.wasInCombat = nil
        plate.colorCache  = nil
    end
end

local function SaveSettings()
    invalidatePlateLayout()
    RelPlatesDB = RelPlatesDB or {}
    RelPlatesDB.playerRole   = playerRole
    RelPlatesDB.overlap      = overlap
    RelPlatesDB.minimapAngle = minimapAngle
    RelPlatesDB.Settings     = S
    RelPlatesDB.tankList     = tankList
end

local function LoadSettings()
    if RelPlatesDB.playerRole    then playerRole   = RelPlatesDB.playerRole    end
    if RelPlatesDB.overlap ~= nil then overlap     = RelPlatesDB.overlap       end
    if RelPlatesDB.minimapAngle  then minimapAngle = RelPlatesDB.minimapAngle  end
    if RelPlatesDB.tankList      then tankList      = RelPlatesDB.tankList      end
    if RelPlatesDB.Settings then
        for k, v in pairs(RelPlatesDB.Settings) do
            -- For table values (colors etc), copy in-place to preserve references
            if type(v) == "table" and type(S[k]) == "table" then
                for i2, v2 in pairs(v) do S[k][i2] = v2 end
            else
                S[k] = v
            end
        end
    end
end

local function resetSettings()
    for k, v in pairs(DEFAULTS) do
        if type(v) == "table" then
            -- deep copy so DEFAULTS tables aren't shared with S
            local t = {}
            for i2, v2 in pairs(v) do t[i2] = v2 end
            S[k] = t
        else
            S[k] = v
        end
    end
    SaveSettings()
    Print("Settings reset to defaults.")
end

local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("VARIABLES_LOADED")
loadFrame:SetScript("OnEvent", function() LoadSettings() end)

-- ── Minimap button ────────────────────────────────────────────────────────────

local mmBtn = CreateFrame("Button", "RelPlatesMinimapButton", Minimap)
mmBtn:SetWidth(32); mmBtn:SetHeight(32); mmBtn:SetFrameStrata("LOW")
mmBtn:SetPoint("TOPLEFT", Minimap, "TOPLEFT",
    math.cos(math.rad(minimapAngle))*80-16,
    math.sin(math.rad(minimapAngle))*80+16)

local mmIcon = mmBtn:CreateTexture(nil, "BACKGROUND")
mmIcon:SetTexture("Interface\\Icons\\INV_Misc_Head_Dragon_01")
mmIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
mmIcon:SetWidth(20); mmIcon:SetHeight(20)
mmIcon:SetPoint("CENTER", mmBtn, "CENTER", 0, 0)

local mmBorder = mmBtn:CreateTexture(nil, "OVERLAY")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmBorder:SetWidth(52); mmBorder:SetHeight(52)
mmBorder:SetPoint("CENTER", mmBtn, "CENTER", 10, -10)
mmBtn:SetMovable(true)
mmBtn:RegisterForClicks("LeftButtonUp","RightButtonUp")
mmBtn:RegisterForDrag("LeftButton")
mmBtn:SetScript("OnDragStart", function() this:StartMoving() end)
mmBtn:SetScript("OnDragStop",  function()
    this:StopMovingOrSizing()
    local mx,my = Minimap:GetCenter()
    local bx,by = this:GetCenter()
    minimapAngle = math.deg(math.atan2(by-my, bx-mx))
    SaveSettings()
end)
mmBtn:SetScript("OnClick", function()
    if arg1 == "RightButton" or IsControlKeyDown() then
        if RelPlatesOptionsFrame:IsShown() then RelPlatesOptionsFrame:Hide()
        else RelPlatesOptionsFrame:Show() end
    end
end)
mmBtn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this,"ANCHOR_LEFT")
    GameTooltip:AddLine("RelPlates")
    GameTooltip:AddLine("Left-Drag to move",1,1,1)
    GameTooltip:AddLine("Right-Click for settings",0.7,0.7,0.7)
    GameTooltip:Show()
end)
mmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- ── Slash commands ────────────────────────────────────────────────────────────

SLASH_RELPLATES1 = "/relplates"
SLASH_RELPLATES2 = "/rp"

SlashCmdList["RELPLATES"] = function(raw)
    local msg = string.lower(string.gsub(raw or "", "^%s*(.-)%s*$", "%1"))

    if msg == "tank" then
        playerRole = "TANK"; SaveSettings(); Print("Role: TANK")
    elseif msg == "dps" then
        playerRole = "DPS"; SaveSettings(); Print("Role: DPS/Healer")
    elseif msg == "toggle" then
        playerRole = playerRole == "TANK" and "DPS" or "TANK"; SaveSettings(); Print("Role: "..playerRole)
    elseif msg == "config" or msg == "options" then
        if RelPlatesOptionsFrame:IsShown() then RelPlatesOptionsFrame:Hide()
        else RelPlatesOptionsFrame:Show() end
    elseif msg == "tanks" then
        if RelPlatesTankListFrame:IsShown() then RelPlatesTankListFrame:Hide()
        else RelPlatesTankListFrame:Show(); RelPlates_RefreshTankList() end

    elseif msg == "ot" or msg == "othertank"
        or string.find(msg,"^ot ") or string.find(msg,"^othertank ") then
        local cmd = string.gsub(string.gsub(msg,"^othertank%s*",""),"^ot%s*","")
        if cmd == "" then
            if UnitExists("target") and UnitIsPlayer("target") and UnitIsFriend("player","target") then
                local n = string.lower(UnitName("target"))
                if tankList[n] then tankList[n]=nil; Print("Removed "..n)
                else tankList[n]=true; Print("Added "..n) end
                SaveSettings()
            else Print("Target a friendly player") end
        elseif cmd == "list" then
            local any=false
            for n in pairs(tankList) do Print("  "..n); any=true end
            if not any then Print("Tank list empty") end
        elseif cmd == "clear" then
            tankList={}; SaveSettings(); Print("Tank list cleared")
        elseif string.find(cmd,"^add ") then
            local n=string.lower(string.sub(cmd,5))
            if n~="" then tankList[n]=true; SaveSettings(); Print("Added "..n) end
        elseif string.find(cmd,"^remove ") then
            local n=string.lower(string.sub(cmd,8))
            if n~="" then tankList[n]=nil; SaveSettings(); Print("Removed "..n) end
        end

    else
        Print("/rp tank|dps|toggle|config|tanks|ot  (role: "..playerRole..")")
    end
end

-- ── Settings window ───────────────────────────────────────────────────────────

local optFrame = CreateFrame("Frame","RelPlatesOptionsFrame",UIParent)
optFrame:SetFrameStrata("DIALOG"); optFrame:SetFrameLevel(100)
optFrame:SetWidth(480); optFrame:SetHeight(520)
optFrame:SetPoint("CENTER",UIParent,"CENTER")
optFrame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
    tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
optFrame:SetMovable(true); optFrame:EnableMouse(true)
optFrame:RegisterForDrag("LeftButton")
optFrame:SetScript("OnDragStart",function() this:StartMoving() end)
optFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
optFrame:Hide()

local optTitle = optFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
optTitle:SetPoint("TOP",optFrame,"TOP",0,-18); optTitle:SetText("RelPlates Settings")
local optClose = CreateFrame("Button",nil,optFrame,"UIPanelCloseButton")
optClose:SetPoint("TOPRIGHT",optFrame,"TOPRIGHT",-5,-5)

-- Tab system
local TABS = {"General","Health","Cast Bar","Colors"}
local tabBtns, tabPanels = {}, {}

local colorSwatchRefreshFns = {}

local function selectTab(i)
    for j=1,table.getn(TABS) do
        tabBtns[j]:SetBackdropColor(j==i and 0.3 or 0.1, j==i and 0.3 or 0.1, j==i and 0.3 or 0.1, 1)
        if j==i then tabPanels[j]:Show() else tabPanels[j]:Hide() end
    end
    -- Refresh color swatches whenever the Colors tab (tab 4) is shown
    if i == 4 then
        for _, fn in ipairs(colorSwatchRefreshFns) do fn() end
    end
end

for i, name in ipairs(TABS) do
    local tabIndex = i  -- copy into local so the closure captures the right value
    local btn = CreateFrame("Button",nil,optFrame)
    btn:SetWidth(90); btn:SetHeight(22)
    btn:SetPoint("TOPLEFT",optFrame,"TOPLEFT", 14+(i-1)*93, -48)
    btn:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true,tileSize=16,edgeSize=8,insets={left=2,right=2,top=2,bottom=2}})
    btn:SetBackdropColor(0.1,0.1,0.1,1)
    local lbl=btn:CreateFontString(nil,"OVERLAY","GameFontNormal"); lbl:SetPoint("CENTER",btn,"CENTER",0,0); lbl:SetText(name)
    btn:SetScript("OnClick",function() selectTab(tabIndex) end)
    tabBtns[i]=btn

    local panel=CreateFrame("Frame",nil,optFrame)
    panel:SetPoint("TOPLEFT",optFrame,"TOPLEFT",14,-73)
    panel:SetPoint("BOTTOMRIGHT",optFrame,"BOTTOMRIGHT",-14,45)
    panel:Hide(); tabPanels[i]=panel
end

local cbSeq = 0
local function mkCB(parent,x,y,label,get,set)
    cbSeq = cbSeq + 1
    local cb=CreateFrame("CheckButton","RelPlatesCB"..cbSeq,parent,"UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y)
    local t=getglobal(cb:GetName().."Text")
    if t then t:SetText(label); t:SetFont("Fonts\\FRIZQT__.TTF",11) end
    cb:SetChecked(get() and 1 or 0)
    cb:SetScript("OnClick",function()
        set(this:GetChecked()==1); SaveSettings()
        for f in pairs(registry) do applyDimensions(f.plate) end
    end)
    return cb
end

local slSeq = 0
local function mkSlider(parent,x,y,lbl,mn,mx,step,get,set)
    slSeq = slSeq + 1
    local sl=CreateFrame("Slider","RelPlatesSL"..slSeq,parent,"OptionsSliderTemplate")
    sl:SetWidth(200); sl:SetHeight(16)
    sl:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y)
    sl:SetMinMaxValues(mn,mx); sl:SetValueStep(step); sl:SetValue(get())
    getglobal(sl:GetName().."Low"):SetText(tostring(mn))
    getglobal(sl:GetName().."High"):SetText(tostring(mx))
    getglobal(sl:GetName().."Text"):SetText(lbl..": "..get())
    sl:SetScript("OnValueChanged",function()
        local v=math.floor(this:GetValue()/step+0.5)*step
        set(v); getglobal(this:GetName().."Text"):SetText(lbl..": "..v)
        SaveSettings()
        for f in pairs(registry) do applyDimensions(f.plate) end
    end)
    return sl
end

-- General tab
local g = tabPanels[1]
mkCB(g,5,-5,"Show Mana Bar",function() return S.mpShow end,function(v) S.mpShow=v end)
mkCB(g,5,-30,"Overlap Mode",function() return overlap end,function(v) overlap=v; invalidatePlateLayout() end)
local roleL=g:CreateFontString(nil,"OVERLAY","GameFontNormal")
roleL:SetPoint("TOPLEFT",g,"TOPLEFT",5,-62); roleL:SetText("Role:")
local tbtn=CreateFrame("Button",nil,g,"UIPanelButtonTemplate")
tbtn:SetWidth(60);tbtn:SetHeight(22);tbtn:SetPoint("TOPLEFT",g,"TOPLEFT",50,-57);tbtn:SetText("Tank")
tbtn:SetScript("OnClick",function() playerRole="TANK";SaveSettings();Print("Role: TANK") end)
local dbtn=CreateFrame("Button",nil,g,"UIPanelButtonTemplate")
dbtn:SetWidth(60);dbtn:SetHeight(22);dbtn:SetPoint("LEFT",tbtn,"RIGHT",5,0);dbtn:SetText("DPS")
dbtn:SetScript("OnClick",function() playerRole="DPS";SaveSettings();Print("Role: DPS") end)
local rbtn=CreateFrame("Button",nil,g,"UIPanelButtonTemplate")
rbtn:SetWidth(120);rbtn:SetHeight(22);rbtn:SetPoint("TOPLEFT",g,"TOPLEFT",5,-93);rbtn:SetText("Reset Defaults")
rbtn:SetScript("OnClick",function()
    resetSettings()
    for f in pairs(registry) do applyDimensions(f.plate) end
end)

-- Health tab
local h = tabPanels[2]
mkSlider(h,10,-10,"Bar Width",   60,200,1,function() return S.hpWidth  end,function(v) S.hpWidth=v  end)
mkSlider(h,10,-50,"Bar Height",   4, 30,1,function() return S.hpHeight end,function(v) S.hpHeight=v end)
mkCB    (h,10,-90,"Show HP Text",function() return S.hpTextShow end,function(v) S.hpTextShow=v end)
mkSlider(h,10,-115,"Mana Height", 2, 12,1,function() return S.mpHeight end,function(v) S.mpHeight=v end)

-- Cast Bar tab
local cb = tabPanels[3]
mkCB    (cb,10,-10, "Show Cast Icon",     function() return S.cbIconShow    end,function(v) S.cbIconShow=v    end)
mkCB    (cb,10,-35, "Independent Width",  function() return S.cbIndependent end,function(v) S.cbIndependent=v end)
mkSlider(cb,10,-65, "Cast Bar Height",4,20,1,function() return S.cbHeight end,function(v) S.cbHeight=v end)
mkSlider(cb,10,-110,"Cast Bar Width",60,200,1,function() return S.cbWidth  end,function(v) S.cbWidth=v  end)

-- Colors tab
local co = tabPanels[4]
local colDefs = {
    {"Tank: Aggro",    S, "colorRed"},
    {"Tank: Warning",  S, "colorOrange"},
    {"DPS: Safe",      S, "colorBlue"},
    {"Other Tank",     S, "colorOtherTank"},
    {"Tapped",         S, "colorTapped"},
    {"Friendly",       S, "colorFriendly"},
    {"Neutral",        S, "colorNeutral"},
    {"Mana Bar",       S, "colorMana"},
    {"Target Border",  S, "targetColor"},
}

local hexEditSeq = 0

local function hexToRGB(hex)
    hex = string.gsub(hex, "^#", "")
    if string.len(hex) ~= 6 then return nil end
    local r = tonumber(string.sub(hex,1,2), 16)
    local g = tonumber(string.sub(hex,3,4), 16)
    local b = tonumber(string.sub(hex,5,6), 16)
    if not r or not g or not b then return nil end
    return r/255, g/255, b/255
end

local function rgbToHex(r, g, b)
    return string.format("%02X%02X%02X",
        math.floor(r*255+0.5),
        math.floor(g*255+0.5),
        math.floor(b*255+0.5))
end

for i, def in ipairs(colDefs) do
    local tbl, key = def[2], def[3]
    local y = -5-(i-1)*30
    hexEditSeq = hexEditSeq + 1

    local lbl = co:CreateFontString(nil,"OVERLAY","GameFontNormal")
    lbl:SetPoint("TOPLEFT",co,"TOPLEFT",10,y)
    lbl:SetText(def[1])

    -- Color swatch button (opens color picker)
    local sw = CreateFrame("Button",nil,co)
    sw:SetWidth(20); sw:SetHeight(20)
    sw:SetPoint("TOPLEFT",co,"TOPLEFT",140,y+2)
    local brd = sw:CreateTexture(nil,"BACKGROUND")
    brd:SetTexture(0,0,0,1); brd:SetAllPoints()
    local fill = sw:CreateTexture(nil,"ARTWORK")
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetPoint("TOPLEFT",sw,"TOPLEFT",2,-2)
    fill:SetPoint("BOTTOMRIGHT",sw,"BOTTOMRIGHT",-2,2)

    -- Hex input field
    local hexBox = CreateFrame("EditBox","RelPlatesHex"..hexEditSeq,co,"InputBoxTemplate")
    hexBox:SetWidth(60); hexBox:SetHeight(20)
    hexBox:SetPoint("LEFT",sw,"RIGHT",6,0)
    hexBox:SetAutoFocus(false); hexBox:SetMaxLetters(7)
    hexBox:SetScript("OnEscapePressed",function() this:ClearFocus() end)

    -- getCol handles both direct table and keyed table
    local function getCol() return key and tbl[key] or tbl end

    local function refreshSwatch()
        local c = getCol()
        fill:SetVertexColor(c[1],c[2],c[3],1)
        hexBox:SetText(rgbToHex(c[1],c[2],c[3]))
    end
    table.insert(colorSwatchRefreshFns, refreshSwatch)

    local applying = false
    local function applyHex()
        if applying then return end
        applying = true
        local r,g,b = hexToRGB(hexBox:GetText())
        if r then
            local c = getCol()
            c[1]=r; c[2]=g; c[3]=b
            refreshSwatch(); SaveSettings()
        else
            refreshSwatch()  -- reset bad input
        end
        hexBox:ClearFocus()
        applying = false
    end

    hexBox:SetScript("OnEnterPressed", applyHex)
    hexBox:SetScript("OnEditFocusLost", applyHex)

    sw:SetScript("OnClick",function()
        local c = getCol()
        -- snapshot original color before picker opens
        local origR, origG, origB = c[1], c[2], c[3]
        ColorPickerFrame:Hide()
        ColorPickerFrame.func = function()
            local r,g,b = ColorPickerFrame:GetColorRGB()
            c[1]=r; c[2]=g; c[3]=b
            refreshSwatch(); SaveSettings()
        end
        ColorPickerFrame.cancelFunc = function()
            c[1]=origR; c[2]=origG; c[3]=origB
            refreshSwatch(); SaveSettings()
        end
        ColorPickerFrame.hasOpacity = nil
        ColorPickerFrame:SetColorRGB(c[1],c[2],c[3])
        ShowUIPanel(ColorPickerFrame)
    end)
end

-- Refresh all swatches whenever the options frame is shown
-- (catches colors loaded from SavedVariables after UI was built)
local _origOptShow = optFrame:GetScript("OnShow")
optFrame:SetScript("OnShow", function()
    if _origOptShow then _origOptShow() end
    for _, fn in ipairs(colorSwatchRefreshFns) do fn() end
end)

selectTab(1)

-- ── Tank list GUI ─────────────────────────────────────────────────────────────

local MAX_TANKS = 4
local ROW_H     = 22
local TL_H      = 30 + MAX_TANKS*ROW_H + 8 + 1 + 8 + 22 + 8 + 22 + 20

local tlFrame = CreateFrame("Frame","RelPlatesTankListFrame",UIParent)
tlFrame:SetFrameStrata("DIALOG"); tlFrame:SetFrameLevel(100)
tlFrame:SetWidth(240); tlFrame:SetHeight(TL_H)
tlFrame:SetPoint("CENTER",UIParent,"CENTER",0,50)
tlFrame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
    tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
tlFrame:SetMovable(true); tlFrame:EnableMouse(true)
tlFrame:RegisterForDrag("LeftButton")
tlFrame:SetScript("OnDragStart",function() this:StartMoving() end)
tlFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
tlFrame:Hide()

local tlTitle=tlFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
tlTitle:SetPoint("TOP",tlFrame,"TOP",0,-14); tlTitle:SetText("Off-Tank List")
local tlClose=CreateFrame("Button",nil,tlFrame,"UIPanelCloseButton")
tlClose:SetPoint("TOPRIGHT",tlFrame,"TOPRIGHT",-5,-5)

local tlRows={}
for i=1,MAX_TANKS do
    local y=-30-(i-1)*ROW_H
    local row=CreateFrame("Frame",nil,tlFrame)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", tlFrame,"TOPLEFT", 14,y)
    row:SetPoint("TOPRIGHT",tlFrame,"TOPRIGHT",-14,y)
    row:Hide()
    row.lbl=row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    row.lbl:SetPoint("LEFT",row,"LEFT",2,0); row.lbl:SetJustifyH("LEFT")
    row.btn=CreateFrame("Button",nil,row,"UIPanelButtonTemplate")
    row.btn:SetWidth(52);row.btn:SetHeight(18);row.btn:SetPoint("RIGHT",row,"RIGHT",0,0)
    row.btn:SetText("Remove")
    row.btn:SetScript("OnClick",function()
        if this.tankName then tankList[this.tankName]=nil; SaveSettings(); RelPlates_RefreshTankList() end
    end)
    tlRows[i]=row
end

local tlEmpty=tlFrame:CreateFontString(nil,"OVERLAY","GameFontDisable")
tlEmpty:SetPoint("TOPLEFT",tlFrame,"TOPLEFT",14,-30); tlEmpty:SetText("No off-tanks added yet.")

local tlSepY=-30-MAX_TANKS*ROW_H-6
local tlSep=tlFrame:CreateTexture(nil,"ARTWORK")
tlSep:SetTexture(0.4,0.4,0.4,0.6); tlSep:SetHeight(1)
tlSep:SetPoint("TOPLEFT", tlFrame,"TOPLEFT", 14,tlSepY)
tlSep:SetPoint("TOPRIGHT",tlFrame,"TOPRIGHT",-14,tlSepY)

local tlAddTarget=CreateFrame("Button",nil,tlFrame,"UIPanelButtonTemplate")
tlAddTarget:SetWidth(106);tlAddTarget:SetHeight(22)
tlAddTarget:SetPoint("TOPLEFT",tlFrame,"TOPLEFT",14,tlSepY-8); tlAddTarget:SetText("Add Target")
tlAddTarget:SetScript("OnClick",function()
    if UnitExists("target") and UnitIsPlayer("target") and UnitIsFriend("player","target") then
        local n=string.lower(UnitName("target"))
        if not tankList[n] then tankList[n]=true; SaveSettings(); RelPlates_RefreshTankList() end
    else Print("Target a friendly player") end
end)

local tlClear=CreateFrame("Button",nil,tlFrame,"UIPanelButtonTemplate")
tlClear:SetWidth(90);tlClear:SetHeight(22)
tlClear:SetPoint("TOPRIGHT",tlFrame,"TOPRIGHT",-14,tlSepY-8); tlClear:SetText("Clear All")
tlClear:SetScript("OnClick",function() tankList={}; SaveSettings(); RelPlates_RefreshTankList() end)

local tlInputY=tlSepY-38
local tlInput=CreateFrame("EditBox","RelPlatesTankInput",tlFrame,"InputBoxTemplate")
tlInput:SetWidth(162);tlInput:SetHeight(20)
tlInput:SetPoint("TOPLEFT",tlFrame,"TOPLEFT",14,tlInputY)
tlInput:SetAutoFocus(false); tlInput:SetMaxLetters(32)
tlInput:SetScript("OnEscapePressed",function() this:ClearFocus() end)
tlInput:SetScript("OnEnterPressed",function()
    local n=string.lower(string.gsub(this:GetText(),"^%s*(.-)%s*$","%1"))
    if n~="" then tankList[n]=true;SaveSettings();RelPlates_RefreshTankList();this:SetText("");this:ClearFocus() end
end)

local tlAddName=CreateFrame("Button",nil,tlFrame,"UIPanelButtonTemplate")
tlAddName:SetWidth(44);tlAddName:SetHeight(22)
tlAddName:SetPoint("TOPRIGHT",tlFrame,"TOPRIGHT",-14,tlInputY); tlAddName:SetText("Add")
tlAddName:SetScript("OnClick",function()
    local n=string.lower(string.gsub(tlInput:GetText(),"^%s*(.-)%s*$","%1"))
    if n~="" then tankList[n]=true;SaveSettings();RelPlates_RefreshTankList();tlInput:SetText("");tlInput:ClearFocus() end
end)

function RelPlates_RefreshTankList()
    local names={}
    for n in pairs(tankList) do table.insert(names,n) end
    table.sort(names)
    local count=table.getn(names)
    if count==0 then tlEmpty:Show() else tlEmpty:Hide() end
    for i=1,MAX_TANKS do
        local row=tlRows[i]; local n=names[i]
        if n then row.lbl:SetText(n); row.btn.tankName=n; row:Show()
        else row:Hide() end
    end
end

Print("RelPlates loaded. /rp for commands.")
