# AGENTS.md - Rollover

> **Maintenance rule:** This file is the source of truth for humans and AI agents working on this repo.
> **Update it whenever the addon grows**: new files/modules, new features, new SavedVariables, new comm messages/prefixes, new slash commands, changed conventions, or newly discovered API quirks. Keep the "Project status" and "Architecture" sections accurate in the same change that alters them.

## 1. What this addon is

**Rollover** is a **World of Warcraft: Forever** (Classic+, internal codename `camelot`) addon for guild/raid loot management. Planned features:

- **Item reserving**: players reserve items they want; the addon tracks and displays reserves.
- **Roll modifiers**: apply modifiers (bonuses/penalties) to item drop rolls.
- **Modifier tracking in guild**: track each member's modifier status and share it across the guild.
- More to come (see "Project status").

Addon folder: `Interface\AddOns\Rollover` inside the `_classic_beta_` install (Forever Beta, TOC `16001`).

## 2. Project status

Update this section as features land.

| Area | Status |
| --- | --- |
| TOC / load | `Core\Utils.lua`, `Core\DB.lua`, `UI\*.lua`, `Core\Commands.lua`, `Core\Events.lua`, `Rollover.lua` (loaded last: `ns.version`); `## SavedVariables: RolloverDB` |
| Item reserving | Not started |
| Roll modifiers | Roll popup (`UI\RollFrame.lua`): `/rollover <item-link>` shows the item with Pass and `Roll (+x)` buttons; Roll does `RandomRoll(1, 100)`, reads the result from `CHAT_MSG_SYSTEM` and prints `roll + modifier` in chat as a `Rollover:` message (no /say: the client blocks SAY from event handlers outside instances) |
| Guild modifier tracking / sync | Local only: numeric modifiers stored in `RolloverDB.modifiers[Name-Realm]` (editable in the roster); no sync yet |
| Main window | Movable, resizable (bottom-right grip, 480x250 to 900x1500; size not persisted) frame `Rollover <version>` (`UI\MainFrame.lua`) showing the guild roster table (class-colored name, class, rank, editable modifier; headers are clickable to sort, default rank ascending) in a ScrollBox; toggled by `/rollover`, closes on Escape. Opening requests the guild roster and merges current guild data with saved modifiers; roster events refresh the table only while visible. Class/rank data is not persisted |
| Options UI | Not started |

TODO for the TOC: replace the placeholder `## Notes:` text, add `## SavedVariables:` once persistence exists, consider `## AllowLoadGameType: camelot` (see 4.2).

## 3. Platform facts (verified against warcraft.wiki.gg, Oct 2026)

- Forever shares **Mainline's UI architecture** and almost all 12.1.5 APIs. In the TOC "game type" system, Forever = `camelot` (name may change before launch), Midnight = `standard`; both are in the `mainline` family.
- Forever **Beta** interface version is `16001` (patch 1.60.1, build 70009). Test/Live values were not published yet; re-check the [TOC format](https://warcraft.wiki.gg/wiki/TOC_format#Interface_version) page. Get the live value in-game with `/dump (select(4, GetBuildInfo()))`.
- Forever launch timeline: Beta Sep 17 - Oct 22 2026, launch Nov 4 2026, raids unlock Dec 9 2026 (Barrow Deeps, Hyjal Summit, Onyxia's Lair). Level cap is 60.
- **Midnight "addon disarmament" is active in Forever**: Secret Values, combat-log removal, and communication restrictions all apply. See section 8 - this directly affects this addon (roll parsing and guild sync).
- Characters have a **first and last name**: `UnitName("player")` returns only the first name ("Andriod"); `GetUnitName("player", true)` returns the full name ("Andriod En"), which is what roll messages use (`ns.GetPlayerName()`).
- The client is **Lua 5.1** (with WoW additions such as `strsplit`, `format`, `wipe`, `tinsert`, `CopyTable`). No `goto`, no `//`, no bitwise operators (use the `bit` library).
- Detect the client in code: `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT`, or `select(4, GetBuildInfo())` between 16000 and 20000. Ruleset: `C_GameRules.IsGameRuleActive(Enum.GameRule.HardcoreRuleset | RPRuleset | PvPRuleset)`.

## 4. How a WoW addon works

### 4.1 Minimum structure

```
Interface\AddOns\Rollover\
  Rollover.toc    -- required; filename MUST match the folder name
  Rollover.lua    -- code, listed in the TOC
```

If the `.toc` name does not match the folder name, the addon is not detected.

### 4.2 TOC file

Plain text. `## Directive: value` metadata, `# comment`, then a list of files loaded **top to bottom**.

```toc
## Interface: 16001
## Title: Rollover
## Notes: Reserve items, roll modifiers and guild modifier tracking for WoW: Forever.
## Author: Andriod
## Version: 0.0.1
## SavedVariables: RolloverDB

Rollover.lua
```

Key directives:

| Directive | Purpose |
| --- | --- |
| `Interface` | Client version the addon targets. Missing/old value => shown as out of date. Comma-separate multiple values: `## Interface: 16001, 120100`. |
| `Title`, `Notes`, `Author`, `Version` | Shown in the AddOns list. `Title-deDE` style suffixes localize. |
| `Category`, `Group`, `IconTexture`, `IconAtlas` | AddOns list presentation. |
| `SavedVariables` | Global variable names persisted per **account**. |
| `SavedVariablesPerCharacter` | Global variable names persisted per **character**. |
| `LoadSavedVariablesFirst: 1` | Load saved variables before the addon's files. |
| `Dependencies` / `OptionalDeps` | Addons that must/may load first. |
| `LoadOnDemand: 1` | Defer loading until `C_AddOns.LoadAddOn()`. |
| `AllowLoadGameType: camelot` | Only load on Forever. Unrecognized game types still load on other clients, so combine with `## ExcludeLoadGameType: standard, classic` if exclusivity matters. |
| `X-Anything` | Custom metadata, read via `C_AddOns.GetAddOnMetadata(addon, "X-Anything")`. |
| `AddonCompartmentFunc` (+ `OnEnter`/`OnLeave`) | Entry in the minimap Addon Compartment dropdown (global function names). |

Per-file/per-line conditions: `File.lua [AllowLoadGameType camelot]`. TOC variables: `[Family]`, `[Game]`, `[TextLocale]` (e.g. `Localization\[TextLocale].lua`). Client-specific TOCs use suffixes such as `Rollover_Camelot.toc`. Use `\` as the path separator. Lines are read up to 1024 characters. `/reload` picks up TOC changes and new files.

### 4.3 Load order and lifecycle

1. Blizzard UI loads.
2. Addon files run, in TOC order. Each file receives `local addonName, ns = ...`.
3. Saved variables for that addon are loaded, then `ADDON_LOADED(addonName)` fires **for that addon**.
4. `PLAYER_LOGIN` fires once all non-load-on-demand addons are loaded.
5. `PLAYER_ENTERING_WORLD(isLogin, isReload)` fires on login, reload and every loading screen.
6. `PLAYER_LOGOUT` fires just before saved variables are written (last chance to modify them).

Saved variables are written on logout, disconnect, quit and `/reload`.

### 4.4 Events

```lua
local addonName, ns = ...

local f = CreateFrame("Frame")
f:SetScript("OnEvent", function(self, event, ...)
    local handler = self[event]
    if handler then handler(self, ...) end
end)

function f:ADDON_LOADED(loadedName)
    if loadedName ~= addonName then return end
    -- saved variables are available here
    self:UnregisterEvent("ADDON_LOADED")
end

f:RegisterEvent("ADDON_LOADED")
```

- Register only events you need; unregister when done.
- `/etrace` shows events live. Event payloads are on warcraft.wiki.gg (`Event:NAME`).
- Prefer events over `OnUpdate` polling. If a timer is needed use `C_Timer.After(seconds, fn)` / `C_Timer.NewTicker`.

### 4.5 SavedVariables

```lua
-- TOC: ## SavedVariables: RolloverDB
local defaults = { version = 1, reserves = {}, modifiers = {}, options = {} }

function f:ADDON_LOADED(loadedName)
    if loadedName ~= addonName then return end
    RolloverDB = RolloverDB or {}
    for k, v in pairs(defaults) do
        if RolloverDB[k] == nil then RolloverDB[k] = type(v) == "table" and CopyTable(v) or v end
    end
    ns.db = RolloverDB
end
```

Pitfalls: variables are global and are **overwritten after your files run** (never rely on defaults set at file scope); only strings, numbers, booleans and tables persist (no functions/userdata; shared table references become separate copies); keep a `version` field and migrate on load. Files live in `WTF\Account\<ACCOUNT>\SavedVariables\Rollover.lua` (account) and `WTF\Account\<ACCOUNT>\<Realm>\<Char>\SavedVariables\Rollover.lua` (per character). Debug: `/dump RolloverDB`.

### 4.6 Slash commands

```lua
SLASH_ROLLOVER1 = "/rollover"
SLASH_ROLLOVER2 = "/ro"
SlashCmdList.ROLLOVER = function(msg, editBox)
    local cmd, rest = strsplit(" ", msg, 2)
    -- dispatch on cmd
end
```

Any `SLASH_<NAME>n` global registers automatically; the handler lives in `SlashCmdList.<NAME>`.

### 4.7 Addon namespace (multi-file)

Every file gets `local addonName, ns = ...` - the **same `ns` table** for all files of the addon. Put shared state/functions on `ns` instead of globals. Expose a global only when required (SavedVariables, slash command globals, Addon Compartment functions, other addons' API).

### 4.8 UI

- Create frames with `CreateFrame(type, name, parent, template)`; use Blizzard templates (e.g. `UIPanelButtonTemplate`, `InterfaceOptionsCheckButtonTemplate`, `BasicFrameTemplateWithInset`).
- Options panel: `Settings.RegisterCanvasLayoutCategory(panel, name)` + `Settings.RegisterAddOnCategory(category)`; open with `Settings.OpenToCategory(categoryID)`. (`InterfaceOptionsFrame_OpenToCategory` was removed in 10.0.0.)
- Tooltips: `GameTooltip`; use `TooltipDataProcessor.AddTooltipPostCall(...)` to add item tooltip lines (e.g. show reserves/modifiers).
- Look at Blizzard's own UI code for patterns: [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source) (use the `forever` branch/tag for Forever) or export it in-game.

### 4.9 Items

`C_Item.GetItemInfo(itemLinkOrID)` returns `nil` if the item is not cached. Use `Item:CreateFromItemID(id):ContinueOnItemLoad(fn)` (or the `GET_ITEM_INFO_RECEIVED` event) for async loading. `C_Item.GetItemInfoInstant` is available for data that needs no cache. Always key stored data by **item ID** (parse from the link with `C_Item.GetItemInfoInstant` or `link:match("item:(%d+)")`), not by name.

### 4.10 Addon-to-addon communication

- `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` (<= 16 chars; use `"Rollover"`) before receiving; listen to `CHAT_MSG_ADDON(prefix, text, channel, sender, ...)`.
- `C_ChatInfo.SendAddonMessage(prefix, message, chatType, target)`: message <= 255 bytes; chat types here: `"GUILD"`, `"OFFICER"`, `"PARTY"`, `"RAID"`, `"INSTANCE_CHAT"`, `"WHISPER"`. (`"CHANNEL"` is disabled on Classic-family clients; check whether Forever allows it before using it.)
- Returns an `Enum.SendAddonMessageResult` (0 success, 3 throttled, 5 not in group, 10 not in guild, 11 `AddOnMessageLockdown`, 12 target offline). **Check the result.**
- Throttle: each prefix has an allowance of 10 messages, regained at 1/sec (server may change this). **Queue and rate-limit**; for production use ChatThrottleLib or AceComm.
- Serialize/compress for large payloads: `C_EncodingUtil.SerializeCBOR/SerializeJSON`, `C_EncodingUtil.CompressString` (verify availability on Forever), or LibSerialize + LibDeflate.
- Treat all incoming messages as untrusted: validate sender (guild rank / group leader), version and field types before applying.
- `SendAddonMessageLogged` should be used for user-generated free text (reports to Blizzard GMs); not needed for structured data.

### 4.11 Guild data

`C_GuildInfo.GuildRoster()` requests a roster (ignored if called <10 s apart), then `GUILD_ROSTER_UPDATE` fires; read members with `GetNumGuildMembers()` and `GetGuildRosterInfo(i)` -> `name (Name-Realm), rankName, rankIndex, level, classDisplayName, zone, publicNote, officerNote, isOnline, status, classFileName, achievementPoints, achievementRank, isMobile, canSoR, repStanding, guid`. Guild notes (`publicNote`/`officerNote`) are a possible low-tech persistence channel for modifier data; reading officer notes requires permission.

### 4.12 Loot and rolls

- Group loot: `START_LOOT_ROLL(rollID, rollTime, lootHandle)`; `GetLootRollItemInfo(rollID)`; `RollOnLoot(rollID, rollType)`; `CONFIRM_LOOT_ROLL`; results via loot chat events (`CHAT_MSG_LOOT`) and global strings (`LOOT_ITEM_*`).
- Manual rolls: `RandomRoll(low, high)` (same as `/random`). The result arrives as a `CHAT_MSG_SYSTEM` message matching the localized global string `RANDOM_ROLL_RESULT` ("%s rolls %d (%d-%d)"). Convert the global string to a pattern instead of hard-coding English.
- `C_LootHistory` is **not** documented for Forever (removed from Standard after 10.1.0); do not depend on it without verifying in-game.
- **Hard constraint:** Need/Greed/Master-loot rolls are resolved server-side; an addon **cannot change a roll's value or outcome**. "Roll modifiers" must therefore be implemented in the addon layer: e.g. a custom roll flow (`/roll`-based, addon computes `roll + modifier` and announces/ranks), displayed results, or loot-council-style assignment by the master looter. Design all modifier features around that.

## 5. Development workflow

- Edit files in place; the addon folder is inside the game install, so **`/reload` in-game** to test changes. New files/TOC changes are picked up by `/reload` too.
- Enable errors: `/console scriptErrors 1`, or install **BugSack + BugGrabber**.
- Debug commands: `/dump <expr>`, `/tinspect <table>`, `/etrace` (events), `/fstack` (frames under the mouse), `/run <lua>`.
- Simulate restrictions: CVars `addonChatRestrictionsForced`, `addonCombatRestrictionsForced`, `addonMapRestrictionsForced`, `addonEncounterRestrictionsForced`, `addonPvPMatchRestrictionsForced`, `addonChallengeModeRestrictionsForced` (set to 1; not persisted across restarts).
- Editor setup: VS Code + **Lua** extension (sumneko) for IntelliSense; the **WoW API** extension (Ketho) adds WoW API definitions. Reference Blizzard code: `wow-ui-source` (`forever` branch) and [Ketho/BlizzardInterfaceResources](https://github.com/Ketho/BlizzardInterfaceResources).
- Testing multi-player features (comms, guild sync) needs at least two clients/accounts; use `"WHISPER"` to yourself to smoke-test comm code.
- Do not commit `WTF/` data or screenshots; the repo is only this addon folder.

## 6. Coding conventions for this repo

- `local addonName, ns = ...` at the top of every Lua file; share via `ns`. Avoid new globals (allowed: `RolloverDB`, `SLASH_ROLLOVER*`, `SlashCmdList.ROLLOVER`, named frames needed for `UISpecialFrames` such as `RolloverMainFrame`, Addon Compartment functions).
- Slash commands: `/rollover` toggles the main window; `/rollover <item-link>` opens the roll popup for that item; `/rollover debug` opens the debug log window (log via `ns.Debug`); `/rollover debug roll` opens the roll popup with a test item.
- Cache frequently used globals as locals (`local format, pairs = format, pairs`) only when it matters for hot paths.
- One responsibility per file; list files in the TOC in dependency order (core -> data -> logic -> UI -> init).
- All user-visible text goes through a localization table (`ns.L`) once the first string is added; default locale `enUS`.
- Chat output via a single helper (`ns.Print`) with a colored `Rollover:` prefix.
- No `OnUpdate` unless unavoidable; never do heavy work per frame.
- Never block on uncached item data; use async item loading.
- Wrap anything touching restricted/secret data in guards (section 8). Fail soft: do nothing rather than throw errors.
- Keep the stored data model versioned (`RolloverDB.version`) and write migrations.
- Bump `## Version:` in the TOC on user-visible changes.

## 7. Planned architecture (adjust as it is built)

```
Rollover.toc
Rollover.lua            -- bootstrap (loaded last): ns.version
Core\Utils.lua          -- shared helpers (ns.Print)
Core\Commands.lua       -- /rollover slash command dispatch
Core\Events.lua         -- event frame (ADDON_LOADED -> ns.InitDB, GUILD_ROSTER_UPDATE -> visible roster refresh)
Core\DB.lua             -- modifier-only RolloverDB defaults, ns.InitDB, ns.RequestGuildRoster, ns.GetRosterList, ns.GetModifier, ns.SetModifier
Modules\Reserves.lua    -- reserve data model + rules
Modules\Modifiers.lua   -- modifier rules and calculations for rolls
Modules\Rolls.lua       -- roll detection/parsing/ranking, announcements
Modules\GuildSync.lua   -- addon messages, versioning, throttled send queue, roster integration
UI\MainFrame.lua        -- main window (ns.ToggleMainFrame); later options panel, reserve list, tooltip hooks
UI\RollFrame.lua        -- roll-for-item popup (ns.ShowRollFrame(link)); Core\DB.lua also has ns.GetPlayerModifier
UI\DebugFrame.lua       -- ns.Debug(msg) in-memory log (200 lines) + copyable window (ns.ToggleDebugFrame, `/rollover debug`)
Locales\                -- enUS.lua first
```

Data model (SavedVariables `RolloverDB`, currently version 1): `version`, `modifiers[Name-Realm] = number`. No migration from the earlier development-only member records; reset old test SavedVariables when testing this shape. Display rows are built from the current guild roster, with missing modifiers treated as 0 without creating saved entries. Saved modifiers for absent members are retained, but those members are not displayed. Player modifier lookup works without opening the roster window. Planned additions: `options`, `reserves[itemID] = { [playerName] = { ... } }`, `sync = { lastFullSync, peers }`. Player keys are `Name-Realm`.

Comm protocol sketch: prefix `"Rollover"`; first field is a protocol version, second a message type (e.g. `HELLO`, `MOD_UPDATE`, `MOD_REQUEST`, `RESERVE_UPDATE`); send on `"GUILD"`; only accept state-changing messages from senders with sufficient guild rank. Document each message type here when implemented.

## 8. Restrictions in Forever that affect this addon

From Blizzard's addon-restriction ("Secret Values") system, active in Forever as in Midnight:

- **Secret values**: tainted (addon) code can store/pass secrets but cannot compare, do arithmetic, use `#`, index, or use them as table keys; doing so raises a Lua error. Test with `issecretvalue(v)` / `canaccessvalue(v)`. Never assume a payload value is usable without checking where the docs mark it secret.
- **Chat messaging lockdown** (`SecretInChatMessagingLockdown`): during encounters, challenge modes, PvP matches, and on communication-restricted maps (dungeons/raids), chat events (including `CHAT_MSG_SYSTEM`, which carries roll results) may deliver **secret** payloads, and **addon messages cannot be sent** (`SendAddonMessage` returns `AddOnMessageLockdown`). Consequences for Rollover:
  - Guard every chat-event handler with `if issecretvalue(text) then return end`.
  - Do sync/announcements **outside** lockdown (in town, before pulls, after encounters); queue messages and flush when allowed (check `C_RestrictedActions` / the send result).
  - Roll parsing in raid may be unavailable at certain times; **verify on the Forever beta** exactly when roll messages are readable and design a fallback (e.g. read results after the encounter, or from Blizzard's roll UI).
- Combat log events are no longer available to addons.
- Protected/secure functions cannot be called by addons in combat; avoid touching secure frames.
- APIs and restrictions are still changing in Forever beta; re-verify on each beta build and update this file.

## 9. Distribution

CurseForge, WoWInterface, wago.io. Keep the TOC `Interface` current for each client version, include a changelog, and use semantic versioning in `## Version:`.

## 10. References

- [Create a WoW AddOn in 15 Minutes](https://warcraft.wiki.gg/wiki/Create_a_WoW_AddOn_in_15_Minutes)
- [TOC format](https://warcraft.wiki.gg/wiki/TOC_format)
- [Saving variables between game sessions](https://warcraft.wiki.gg/wiki/Saving_variables_between_game_sessions)
- [Handling events](https://warcraft.wiki.gg/wiki/Handling_events) / [Events list](https://warcraft.wiki.gg/wiki/Events_(API))
- [Using the AddOn namespace](https://warcraft.wiki.gg/wiki/Using_the_AddOn_namespace)
- [C_ChatInfo.SendAddonMessage](https://warcraft.wiki.gg/wiki/API:C_ChatInfo.SendAddonMessage)
- [Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values)
- [World of Warcraft: Forever](https://warcraft.wiki.gg/wiki/World_of_Warcraft:_Forever) and [Patch 1.60.1 API changes](https://warcraft.wiki.gg/wiki/Patch_1.60.1/API_changes)
- [Blizzard UI source](https://github.com/Gethe/wow-ui-source), [API docs mirror (Townlong Yak)](https://www.townlong-yak.com/framexml/live), [BlizzardInterfaceResources](https://github.com/Ketho/BlizzardInterfaceResources)

## 11. Keeping this file current (checklist)

Before finishing any change that does one of the following, update this file in the same change:

- [ ] Added/removed/renamed a file or module -> section 7 and the TOC example.
- [ ] Shipped or started a feature -> section 2 status table.
- [ ] Added a SavedVariable or changed its shape -> sections 4.5 / 7 (and bump `RolloverDB.version` + migration).
- [ ] Added a slash command or comm message type -> document it here.
- [ ] Learned a new API quirk or a Forever-specific behavior (especially restrictions) -> sections 3 / 4 / 8.
- [ ] Changed a convention -> section 6.
- [ ] Bumped the TOC `Interface` value -> section 3.
