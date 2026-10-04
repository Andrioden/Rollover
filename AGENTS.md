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
| TOC / load | `Locales\enUS.lua`, `Core\Utils.lua`, `Core\DB.lua`, `Modules\GuildSync.lua`, `UI\*.lua`, `Core\Commands.lua`, `Core\Events.lua`, `Rollover.lua` (loaded last: `ns.version`); `## SavedVariables: RolloverDB` |
| Item reserving | Not started |
| Roll modifiers | Roll popup (`UI\RollFrame.lua`): `/rollover <item-link>` shows the item with Pass and `Roll (+x)` buttons; Roll does `RandomRoll(1, 100)`, reads the result from `CHAT_MSG_SYSTEM` and prints `roll + modifier` in chat as a `Rollover:` message (no /say: the client blocks SAY from event handlers outside instances) |
| Guild modifier tracking / sync | One account-wide modifier table (not guild-scoped). The trusted publisher is chosen with the crown button on a roster row or Tools > Set yourself as publisher (the current publisher's crown is bright yellow, everyone else's is dimmed and gray; clicking your own row or setting yourself as publisher selects you). Sync is manual via Tools > Sync from publisher (Cancel sync while receiving): it streams modifier values over WHISPER directly after an automatic backup. **All sync/publisher feedback is printed to chat (`Rollover:` messages); the main window shows no status text.** Followers have read-only roster edits, but may explicitly import JSON or restore backups. No automatic sync, deltas, revisions, or rollback |
| Main window | Movable, resizable (bottom-right grip, default 520x400, 500x250 to 900x1500; size not persisted) frame `Rollover <version>` (`UI\MainFrame.lua`). Top row: only a right-aligned gear-icon Tools button (tooltip `Tools`); there is deliberately no status text, report everything with `ns.Print`. Below it the guild roster table (class-colored name, a crown publisher button, class, rank, editable modifier; headers are clickable to sort, default rank ascending) in a ScrollBox; toggled by `/rollover`, closes on Escape. The minimum width equals the table width (margins plus columns); widen it if a column or button is added. Opening requests the guild roster and merges current guild data with saved modifiers; roster events refresh the table only while visible. Crown buttons are disabled while receiving a sync. Class/rank data is not persisted |
| Options UI | Not started |
| Tools / recovery | Gear-icon Tools menu in the main window: sync from publisher (becomes cancel sync while receiving), set yourself as publisher, save backup, export JSON, import JSON, restore backup (submenu of dated backups, newest first). Setting yourself as publisher is disabled while receiving a sync. Export and import each have their own window (`UI\ExportFrame.lua`: copy-only text box; `UI\ImportFrame.lua`: paste box plus Import button, hidden after a successful import). Imports/restores also back up the previous state. JSON replaces the modifier table; backups are deep copies and remain until manually removed from SavedVariables |

TODO for the TOC: replace the placeholder `## Notes:` text (the example in 4.2 shows the intended wording) and consider `## AllowLoadGameType: camelot` (see 4.2).

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

Locales\enUS.lua
Core\Utils.lua
Core\DB.lua
Modules\GuildSync.lua
UI\MainFrame.lua
UI\DebugFrame.lua
UI\TextDialog.lua
UI\ExportFrame.lua
UI\ImportFrame.lua
UI\RollFrame.lua
Core\Commands.lua
Core\Events.lua
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
local defaults = { version = 1, modifiers = {}, backups = {}, sync = {} }

function f:ADDON_LOADED(loadedName)
    if loadedName ~= addonName then return end
    RolloverDB = RolloverDB or {}
    for k, v in pairs(defaults) do
        if RolloverDB[k] == nil then RolloverDB[k] = type(v) == "table" and CopyTable(v) or v end
    end
    ns.db = RolloverDB
end
```

Pitfalls: variables are global and are **overwritten after your files run** (never rely on defaults set at file scope); only strings, numbers, booleans and tables persist (no functions/userdata; shared table references become separate copies); keep a `version` field and migrate on load once the addon has released data to preserve (this repo does not migrate development data, see section 7). Files live in `WTF\Account\<ACCOUNT>\SavedVariables\Rollover.lua` (account) and `WTF\Account\<ACCOUNT>\<Realm>\<Char>\SavedVariables\Rollover.lua` (per character). Debug: `/dump RolloverDB`.

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
- Returns an `Enum.SendAddonMessageResult` (0 `Success`, 3 `AddonMessageThrottle`, 5 not in group, 10 not in guild, 11 `AddOnMessageLockdown`, 12 target offline). **Check the result.**
- Throttle: each prefix has an allowance of 10 messages, regained at 1/sec (server may change this). **Queue and rate-limit**; for production use ChatThrottleLib or AceComm.
- Serialize/compress for large payloads: `C_EncodingUtil.SerializeCBOR/SerializeJSON`, `C_EncodingUtil.CompressString` (verify availability on Forever), or LibSerialize + LibDeflate. Rollover uses `SerializeJSON` / `DeserializeJSON` for import/export only; the sync stream is plain tab-separated text. These JSON functions are documented in Blizzard's live API docs but not yet verified on the Forever beta; missing APIs are reported to the player instead of erroring.
- Treat all incoming messages as untrusted: validate sender (guild rank / group leader), version and field types before applying.
- `SendAddonMessageLogged` should be used for user-generated free text (reports to Blizzard GMs); not needed for structured data.

### 4.11 Guild data

`C_GuildInfo.GuildRoster()` requests a roster (ignored if called <10 s apart), then `GUILD_ROSTER_UPDATE` fires; read members with `GetNumGuildMembers()` and `GetGuildRosterInfo(i)` -> `name, rankName, rankIndex, level, classDisplayName, zone, publicNote, officerNote, isOnline, status, classFileName, achievementPoints, achievementRank, isMobile, canSoR, repStanding, guid`. **Observed on the Forever beta: `name` is "First Last" with no realm suffix** (e.g. `Andriod En`); other clients return `Name-Realm`. Never assume or require a `-Realm` part; treat the name as an opaque string and key data by exactly what this call returns. Guild notes (`publicNote`/`officerNote`) are a possible low-tech persistence channel for modifier data; reading officer notes requires permission.

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
- Regression tests: one suite per area (`Tests\DBTests.lua`, `ImportExportTests.lua`, `GuildSyncTests.lua`, `MainFrameTests.lua`, `EventsTests.lua`) run outside the game using the shared WoW API/client mock in `Tests\MockClient.lua` (timers, frames and message delivery). Each suite creates its own mock harness and prints one `PASS`/`FAIL` line per `test(name, fn)` (via `harness.suite`). Run all with `lua .\Tests\RolloverTests.lua .` from the addon folder (or `npm exec --yes --package=fengari-node-cli -- fengari .\Tests\RolloverTests.lua .` without a Lua install); a single suite runs standalone, e.g. `lua .\Tests\GuildSyncTests.lua .`. Add new suites to the list in `RolloverTests.lua`; use `harness.requestSync(client)` to start a sync and get its request ID. Test roster fixtures use plain character names, matching Forever roster data. Mocks do not prove real client behavior (JSON parsing, menu layout, whisper sender format); verify those in game.
- Do not commit `WTF/` data or screenshots; the repo is only this addon folder.

## 6. Coding conventions for this repo

- `local addonName, ns = ...` at the top of every Lua file; share via `ns`. Avoid new globals (allowed: `RolloverDB`, `SLASH_ROLLOVER*`, `SlashCmdList.ROLLOVER`, named frames needed for `UISpecialFrames` such as `RolloverMainFrame`, Addon Compartment functions).
- Slash commands: `/rollover` toggles the main window; `/rollover <item-link>` opens the roll popup for that item; `/rollover debug` opens the debug log window (log via `ns.Debug`); `/rollover debug roll` opens the roll popup with a test item.
- Cache frequently used globals as locals (`local format, pairs = format, pairs`) only when it matters for hot paths.
- One responsibility per file; list files in the TOC in dependency order (core -> data -> logic -> UI -> init).
- All user-visible text goes through a localization table (`ns.L`, `Locales\enUS.lua`); default locale `enUS`. Every key in `enUS.lua` must be used; remove keys when their code goes away. Not yet migrated (legacy hardcoded English): `UI\RollFrame.lua`, `UI\DebugFrame.lua`, the main window title and roster column headers, and the `Usage:` line in `Core\Commands.lua`. Put new strings in `ns.L`.
- Each UI window lives in its own file and creates its own frame (`UI\MainFrame.lua`, `UI\ExportFrame.lua`, `UI\ImportFrame.lua`, `UI\RollFrame.lua`, `UI\DebugFrame.lua`); do not multiplex one window for several purposes. Text-box dialogs share the scaffolding in `UI\TextDialog.lua` (`ns.CreateTextDialog`).
- Modules call each other through `ns` at runtime only (all files are loaded before `ADDON_LOADED`), so no `if ns.Func then` load-order guards.
- Chat output via a single helper (`ns.Print`) with a colored `Rollover:` prefix.
- No `OnUpdate` unless unavoidable; never do heavy work per frame.
- Never block on uncached item data; use async item loading.
- Wrap anything touching restricted/secret data in guards (section 8). Fail soft: do nothing rather than throw errors.
- Keep the stored data model versioned (`RolloverDB.version`). Write migrations once real users have data; until then (addon version 0.0.1, no users) development data is not migrated and obsolete test SavedVariables are reset manually.
- Bump `## Version:` in the TOC on user-visible changes.

## 7. Architecture (files marked "planned" do not exist yet)

```
Rollover.toc
Rollover.lua            -- bootstrap (loaded last): ns.version
Locales\enUS.lua        -- ns.L strings (tools, recovery, sync, roster placeholders)
Core\Utils.lua          -- shared helpers (ns.Print)
Core\DB.lua             -- defaults/ns.InitDB, modifier get/set + validation, edit permissions, guild-member resolution, dated backups, JSON import/export, roster merge (ns.GetRosterList), player helpers
Modules\GuildSync.lua   -- publisher selection, manual streaming WHISPER sync, bounded send queue and failure reporting
UI\MainFrame.lua        -- roster with per-row crown publisher button, gear-icon Tools menu (sync/cancel, backups, import/export)
UI\DebugFrame.lua       -- ns.Debug(msg) in-memory log (200 lines) + copyable window (ns.ToggleDebugFrame, `/rollover debug`)
UI\TextDialog.lua       -- shared movable text-box dialog scaffolding (ns.CreateTextDialog)
UI\ExportFrame.lua      -- copy-only JSON window (ns.ShowExportFrame(text))
UI\ImportFrame.lua      -- paste-JSON window with Import button (ns.ShowImportFrame())
UI\RollFrame.lua        -- roll-for-item popup (ns.ShowRollFrame(link)); Core\DB.lua has ns.GetPlayerModifier
Core\Commands.lua       -- /rollover slash command dispatch
Core\Events.lua         -- ADDON_LOADED (ns.InitDB, ns.InitGuildSync, event registration), CHAT_MSG_ADDON, guild roster/guild changes -> sync context check + visible roster refresh
Tests\MockClient.lua    -- shared mocked WoW client/API wiring for standalone tests (not loaded by TOC)
Tests\RolloverTests.lua -- runner for all suites below (not loaded by TOC)
Tests\DBTests.lua       -- Core\DB.lua: modifiers, backups, publisher/edit permissions, name resolution
Tests\ImportExportTests.lua -- JSON import/export plus export/import/debug windows
Tests\GuildSyncTests.lua    -- Modules\GuildSync.lua: streaming, protocol guards, retries, failures
Tests\MainFrameTests.lua    -- UI\MainFrame.lua: roster rows, crowns, Tools menu
Tests\EventsTests.lua       -- Core\Events.lua: event registration
Modules\Reserves.lua    -- planned: reserve data model + rules
Modules\Modifiers.lua   -- planned: modifier rules and calculations for rolls
Modules\Rolls.lua       -- planned: roll detection/parsing/ranking, announcements
```

Data model (SavedVariables `RolloverDB`, development version 1; addon version remains 0.0.1): `version`, `modifiers[name] = number`, `backups[date-time] = copy of modifiers`, `sync = { publisher = name }`, where `name` is the guild roster name exactly as `GetGuildRosterInfo` returns it (no realm suffix on the Forever beta, see 4.11). Date keys include seconds and a suffix when multiple backups share a second. No development-data migrations; existing modifier tables are preserved and new fields default empty. Reset obsolete test SavedVariables manually. No guild state, class, rank or rankIndex is saved. Display rows merge current guild data with saved modifiers (missing values display as 0). Absent-member modifiers are retained locally and included in export/sync. Publishers also send explicit zeros for current roster members without saved modifiers. New imports must be JSON objects mapping roster names (non-empty, at most 96 bytes, no control characters or `|`) to finite numbers (at most `ns.MAX_MEMBERS` = 1000 entries / 200000 input bytes). JSON uses `C_EncodingUtil.SerializeJSON` / `DeserializeJSON`; a missing API and import parse failures are reported to the player. Export does not re-validate stored data (it only ever enters through validated paths); restore does not either. Planned additions: `options`, `reserves[itemID] = { [playerName] = { ... } }`. Player keys are roster names (see above).

Edit permissions: roster edits are allowed when no publisher is selected or you are the selected publisher, and never while receiving a sync. Followers cannot edit but can still import JSON and restore backups. Selecting the already-selected publisher is a no-op; there is no way to clear the publisher except selecting another player (select yourself to edit locally).

Comm protocol: prefix `"Rollover"`, protocol `1`, tab-separated fields, WHISPER only. Every message starts `1<TAB>type<TAB>requestID`; types:

- `REQUEST`: no further fields; asks a guild member who has selected themselves as publisher (clicked their own crown) for modifiers.
- `BEGIN`: entry count (0-1000); clears the receiver's modifier table after the pre-request backup.
- `VALUE`: index of the first entry, then one or more `name<TAB>modifier` pairs packed up to 255 bytes (single-entry messages remain valid; protocol stays `1`); applies immediately. Duplicate names and out-of-order values fail the transfer.
- `END`: entry count; verifies completeness and finishes the transfer. No commit step.
- `ERROR`: `NOT_PUBLISHER`, `BUSY` or `INVALID_TRANSFER`.

Only the explicitly selected publisher's actual chat sender is accepted for the active request ID; requesters/senders must be in the current local guild roster. Names are matched against the roster by exact name, or by realm-less name when that is unambiguous (`ns.ResolveGuildMember`). This assumes the `CHAT_MSG_ADDON` WHISPER sender string matches a `GetGuildRosterInfo` name; **unverified on the Forever beta**, so check it first if sync never completes. No guild identity is tracked; leaving the guild or losing the publisher from the roster ends a transfer. Names/payload lengths/numeric values/counts are bounded (the publisher packs `VALUE` pairs so each message stays within 255 bytes). Secret payloads are ignored. Publishers print each incoming request (sent or declined). Sends run every 0.2 s (using the burst allowance) with at most three queued tasks and a 30-minute transfer timeout (queued messages that expire or whose target/request is gone are dropped and only logged with `ns.Debug`). A requester that asks again within 30 seconds gets an `ERROR BUSY` reply. `Enum.SendAddonMessageResult.AddonMessageThrottle` (not `Throttle`) silently retries after 1 second; `AddOnMessageLockdown` prints once and retries after 5 seconds. Other send errors are reported. Cancel, guild loss, malformed messages and timeout end receiving without rollback; once `BEGIN` arrived the table was cleared, so those paths also print a "may be incomplete, restore a backup" warning (failures before `BEGIN` do not). Import/restore/source changes are blocked only while receiving. Chat feedback per sync: publisher set (or "you are publishing"), requesting, receiving N modifiers, synced N modifiers or a failure with its reason, cancel, and a single "retrying" notice per deferral (not one per retry). Each received `VALUE` message prints `Synced x/N: Name (+mod), ...`. There is no record of when the last sync happened; the player cannot tell whether the publisher has newer edits.

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
- [ ] Added a SavedVariable or changed its shape -> sections 4.5 / 7 (migrate only once real users have data, see section 6).
- [ ] Added a slash command or comm message type -> document it here.
- [ ] Learned a new API quirk or a Forever-specific behavior (especially restrictions) -> sections 3 / 4 / 8.
- [ ] Changed a convention -> section 6.
- [ ] Bumped the TOC `Interface` value -> section 3.
