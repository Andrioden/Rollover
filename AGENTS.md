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
| TOC / load | `Locales\enUS.lua`, `Core\Utils.lua`, `Core\DB.lua`, `Sync\SyncCore.lua`, `Sync\SyncMaster.lua`, `Sync\SyncClient.lua`, `UI\*.lua`, `Core\Commands.lua`, `Core\Events.lua`, `Rollover.lua` (loaded last: `ns.version`); `## SavedVariables: RolloverDB` |
| Item reserving | Not started |
| Roll modifiers | Roll popup (`UI\RollFrame.lua`): `/rollover <item-link>` shows the item with Pass and `Roll (+x)` buttons; Roll does `RandomRoll(1, 100)`, reads the result from `CHAT_MSG_SYSTEM` and prints `roll + modifier` in chat as a `Rollover:` message (no /say: the client blocks SAY from event handlers outside instances) |
| Guild modifier tracking / sync | One account-wide modifier table (not guild-scoped). The trusted master is chosen with the ledger button on a roster row or Tools > Set yourself as master (the current master's ledger icon is bright, everyone else's is dimmed and gray; clicking your own row or setting yourself as master selects you). Sync streams modifier values over WHISPER; becoming master also broadcasts the master's `updatedAt` on the GUILD channel so followers who chose that player earlier (while it was offline or not yet master) re-check (see Comm protocol) (the follower saves a backup right before the stream replaces its table). It runs manually via Tools > Sync from master (Cancel sync while receiving) and **automatically**: when a master is selected (full sync, or a note that the master is offline), on login/reload and when the master comes online (cheap up-to-date check comparing the master's `sync.updatedAt`; streams only if it differs). Automatic checks are silent (debug log only) unless a real sync happens. **All sync/master feedback is printed to chat (`Rollover:` messages); the main window shows no status text.** Followers have read-only roster edits and cannot import JSON or restore backups (set yourself as master to edit locally). No push notice when the master edits (online followers stay stale until a check/manual sync; only becoming master announces), no deltas or rollback |
| Main window | Movable, resizable (bottom-right grip, default 520x400, 512x250 to 900x1500; size not persisted) frame `Rollover <version>` (`UI\MainFrame.lua`). Top row: only a right-aligned gear-icon Tools button (tooltip `Tools`); there is deliberately no status text, report everything with `ns.Print`. Below it the guild roster table (class-colored name with a ledger master button at the far left, then class, rank and editable modifier; headers are clickable to sort, default rank ascending) in a ScrollBox; toggled by `/rollover`, closes on Escape. The minimum width equals the table width (margins plus columns); widen it if a column or button is added. Opening requests the guild roster and merges current guild data with saved modifiers; roster events refresh the table only while visible. Ledger buttons are disabled while receiving a sync. Class/rank data is not persisted |
| Options UI | Not started |
| Tools / recovery | Gear-icon Tools menu in the main window: sync from master (becomes cancel sync while receiving; reports "up to date" when nothing changed), set yourself as master, save backup, export JSON, import JSON, restore backup (submenu of dated backups with their name in parentheses, newest first), reset data (confirmation popup; allowed for followers). Setting yourself as master is disabled while receiving a sync. Export and import each have their own window (`UI\ExportFrame.lua`: copy-only text box; `UI\ImportFrame.lua`: paste box plus Import button, hidden after a successful import). Imports/restores (master or no master only) also back up the previous state. JSON is `{"updatedAt": seconds, "modifiers": {name: number}}` and replaces the modifier table; an import whose `updatedAt` is older than the local one is blocked (missing = 0 = oldest; in the future is invalid), and a restore of a backup older than the local data is blocked the same way. Imports and restores adopt the age of the data they bring, never "now". Reset data (`ns.ResetData`) backs up any data, clears all modifiers and sets `updatedAt = 0`, the only way to accept an older import, backup or master; backups are deep copies that carry their `updatedAt`. Manual backups remain until manually removed from SavedVariables; every backup has a required short name for its source (`ns.SaveBackup(name)`: `manual`, `restore`, `import`, `reset`, `sync`, `auto sync`), and backups named `auto sync` (pre-sync backups of automatic checks) are pruned to the newest `ns.MAX_AUTO_BACKUPS` (10) |

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
Sync\SyncCore.lua
Sync\SyncMaster.lua
Sync\SyncClient.lua
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
local defaults = { version = 1, modifiers = {}, backups = {}, sync = {} } -- sync = { master, updatedAt }

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

`C_GuildInfo.GuildRoster()` requests a roster (ignored if called <10 s apart), then `GUILD_ROSTER_UPDATE` fires; read members with `GetNumGuildMembers()` and `GetGuildRosterInfo(i)` -> `name, rankName, rankIndex, level, classDisplayName, zone, publicNote, officerNote, isOnline, status, classFileName, achievementPoints, achievementRank, isMobile, canSoR, repStanding, guid`. **Observed on the Forever beta: `name` is "First Last" with no realm suffix** (e.g. `Andriod En`); other clients return `Name-Realm`. Never assume or require a `-Realm` part; treat the name as an opaque string and key data by exactly what this call returns. **Verified on the Forever beta: `GUILD_ROSTER_UPDATE` fires passively (`canRequestRosterUpdate=false`, no `GuildRoster()` call or open guild frame needed) when a member goes online/offline**, and the new `isOnline` is already readable in that handler; it fires twice per change (the second shows no difference), so detect online/offline transitions by diffing against the previous snapshot, no polling needed. Guild notes (`publicNote`/`officerNote`) are a possible low-tech persistence channel for modifier data; reading officer notes requires permission.

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
- Regression tests: one suite per area (`Tests\DBTests.lua`, `ImportExportTests.lua`, `SyncClientTests.lua`, `SyncMasterTests.lua`, `SyncTests.lua`, `SyncAutoTests.lua`, `MainFrameTests.lua`, `EventsTests.lua`) run outside the game using the shared WoW API/client mock in `Tests\MockClient.lua` (timers, frames and message delivery). Each suite creates its own mock harness and prints one `PASS`/`FAIL` line per `test(name, fn)` (via `harness.suite`). Run all with `lua .\Tests\RolloverTests.lua .` from the addon folder (or `npm exec --yes --package=fengari-node-cli -- fengari .\Tests\RolloverTests.lua .` without a Lua install); a single suite runs standalone, e.g. `lua .\Tests\SyncTests.lua .`. Sync tests are split by scope: `SyncClientTests.lua` (follower alone, master replies injected by hand), `SyncMasterTests.lua` (master alone, requests injected, sent messages read from `harness.delivered`), `SyncTests.lua` (real master + follower, manual syncs end to end and the data-only-moves-forward rules) and `SyncAutoTests.lua` (automatic checks and announcements); shared helpers are `harness.messagesFrom`, `harness.backupCount` and `harness.login`. Add new suites to the list in `RolloverTests.lua`; use `harness.requestSync(client)` to start a manual sync and get its request ID (it only predicts IDs of syncs it started itself; for others read the ID from `harness.delivered`). Mock guild members are offline unless a test sets `client.online[name] = true`. Test roster fixtures use plain character names, matching Forever roster data. Mocks do not prove real client behavior (JSON parsing, menu layout, whisper sender format); verify those in game.
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
Core\DB.lua             -- defaults/ns.InitDB, modifier get/set + validation, edit permissions, guild-member resolution, dated backups (auto-tagged ones pruned), updatedAt (ns.TouchModifiers), roster online lookup, JSON import/export, roster merge (ns.GetRosterList), player helpers
Sync\SyncCore.lua       -- shared sync transport: ns.Sync helpers (Message, Integer, NewID, Enqueue, QueueLength, IsReady), bounded send queue/pump with throttle + lockdown retries, CHAT_MSG_ADDON envelope validation and routing (ns.OnSyncMessage), ns.InitGuildSync
Sync\SyncMaster.lua     -- master side: GUILD master announcement (ns.AnnounceMaster), REQUEST handling (ns.OnSyncRequest), CURRENT/BEGIN/VALUE/END/ERROR replies, request rate limit
Sync\SyncClient.lua     -- follower side: master selection, manual + automatic (login/master-online/new master) requests, up-to-date checks, ANNOUNCE handling (ns.OnSyncAnnounce), receiving and applying the stream (ns.OnSyncReply)
UI\MainFrame.lua        -- roster with per-row ledger master button, gear-icon Tools menu (sync/cancel, backups, import/export)
UI\DebugFrame.lua       -- ns.Debug(msg) in-memory log (200 lines) + copyable window (ns.ToggleDebugFrame, `/rollover debug`)
UI\TextDialog.lua       -- shared movable text-box dialog scaffolding (ns.CreateTextDialog)
UI\ExportFrame.lua      -- copy-only JSON window (ns.ShowExportFrame(text))
UI\ImportFrame.lua      -- paste-JSON window with Import button (ns.ShowImportFrame())
UI\RollFrame.lua        -- roll-for-item popup (ns.ShowRollFrame(link)); Core\DB.lua has ns.GetPlayerModifier
Core\Commands.lua       -- /rollover slash command dispatch
Core\Events.lua         -- ADDON_LOADED (ns.InitDB, ns.InitGuildSync, event registration), CHAT_MSG_ADDON, PLAYER_ENTERING_WORLD (login check), guild roster/guild changes -> sync context check, master-online detection + visible roster refresh
Tests\MockClient.lua    -- shared mocked WoW client/API wiring for standalone tests (not loaded by TOC)
Tests\RolloverTests.lua -- runner for all suites below (not loaded by TOC)
Tests\DBTests.lua       -- Core\DB.lua: modifiers, backups, master/edit permissions, name resolution
Tests\ImportExportTests.lua -- JSON import/export plus export/import/debug windows
Tests\SyncClientTests.lua  -- Sync\SyncClient.lua alone: injected master replies, transfer validation, atomic apply, retries, cancel/timeout
Tests\SyncMasterTests.lua  -- Sync\SyncMaster.lua alone: injected requests, streaming/packing, CURRENT, BUSY, NOT_MASTER, announcements
Tests\SyncTests.lua        -- master + follower end to end: manual sync, lockdown/throttle recovery, large rosters, older/equal/blank master rules
Tests\SyncAutoTests.lua    -- automatic sync: master selection, login/online checks, CURRENT replies, ANNOUNCE, quiet failures
Tests\MainFrameTests.lua    -- UI\MainFrame.lua: roster rows, ledger buttons, Tools menu
Tests\EventsTests.lua       -- Core\Events.lua: event registration and wiring
Modules\Reserves.lua    -- planned (new `Modules\` folder): reserve data model + rules
Modules\Modifiers.lua   -- planned: modifier rules and calculations for rolls
Modules\Rolls.lua       -- planned: roll detection/parsing/ranking, announcements
```

Data model (SavedVariables `RolloverDB`, development version 1; addon version remains 0.0.1): `version`, `modifiers[name] = number`, `backups[date-time] = { name, updatedAt, modifiers = copy }`, `sync = { master = name, updatedAt = integer }`, where `name` is the guild roster name exactly as `GetGuildRosterInfo` returns it (no realm suffix on the Forever beta, see 4.11). Date keys include seconds and a suffix when multiple backups share a second; the `name` field tells where a backup came from and only `auto sync` backups are pruned. No development-data migrations; existing modifier tables are preserved and new fields default empty. Reset obsolete test SavedVariables manually. No guild state, class, rank or rankIndex is saved. Display rows merge current guild data with saved modifiers (missing values display as 0). Absent-member modifiers are retained locally and included in export/sync. Masters also send explicit zeros for current roster members without saved modifiers. New imports must be JSON objects with a `modifiers` object (and optional `updatedAt`, see 2) mapping roster names (non-empty, at most 96 bytes, no control characters or `|`) to finite numbers (at most `ns.MAX_MEMBERS` = 1000 entries / 200000 input bytes). JSON uses `C_EncodingUtil.SerializeJSON` / `DeserializeJSON`; a missing API and import parse failures are reported to the player. Export does not re-validate stored data (it only ever enters through validated paths); restore does not either. `sync.updatedAt` is the age of the local data: the shared `GetServerTime()` of the last real edit (`ns.TouchModifiers`: strictly increasing, called only by `SetModifier` on a real change). It travels with the data (sync, export/import, backups) and is never set to "now" by import, restore, sync or selecting a master; nil is read as 0 (`ns.GetUpdatedAt`). Imports reject a stamp in the future (server time is shared by all clients, so no tolerance is needed; edits within the same second can push a stamp a few seconds ahead, retry shortly). Protection applies to everyone, masters included. Data only moves forward: a follower rejects `BEGIN` when the master's stamp is lower than its own (before any backup or clearing; automatic checks report this once per stamp, manual syncs every time) and ignores `ANNOUNCE` stamps that are not newer. A stream is buffered and applied (data, stamp and the pre-sync backup) together at `END`, so an interrupted transfer changes nothing. Selecting another master keeps the stamp, so an older master is refused; an equal stamp is answered `CURRENT` and never replaces local data. `0` means reset/empty, so an empty master never overwrites anyone. Planned additions: `options`, `reserves[itemID] = { [playerName] = { ... } }`. Player keys are roster names (see above).

Edit permissions: roster edits are allowed when no master is selected or you are the selected master, and never while receiving a sync. Followers cannot edit, import JSON or restore backups (`ns.CanReplaceModifiers`). Selecting the already-selected master is a no-op; there is no way to clear the master except selecting another player (select yourself to edit locally).

Comm protocol: prefix `"Rollover"`, tab-separated fields, WHISPER except `ANNOUNCE` (GUILD only), no protocol version while the addon is in early development (all clients must run the same version). Every message starts `type<TAB>requestID`; types:

- `REQUEST`: optional `have` field (the requester's `updatedAt`); asks a guild member who has selected themselves as master (clicked their own ledger icon) for modifiers. With `have` equal to the master's `updatedAt` the master answers `CURRENT` instead of streaming. All syncs (manual and automatic) send it (0 when the age is unknown).
- `BEGIN`: entry count (0-1000), then the master's `updatedAt`; the receiver only buffers the stream; at `END` it saves a backup (named `auto sync` for automatic checks, `sync` for manual ones) and replaces its table and `updatedAt`. Rejected up front when the master's `updatedAt` is lower than the receiver's.
- `CURRENT`: no further fields; the requester is up to date (only valid for a request that sent `have`). Not rate limited, not announced in the master's chat; the requester prints "Already up to date" for manual syncs and only logs it for automatic checks.
- `VALUE`: index of the first entry, then one or more `name<TAB>modifier` pairs packed up to 255 bytes (single-entry messages remain valid); applies immediately. Duplicate names and out-of-order values fail the transfer.
- `END`: entry count; verifies completeness, stores the received `updatedAt` and finishes the transfer. No commit step.
- `ERROR`: `NOT_MASTER`, `BUSY` or `INVALID_TRANSFER`.
- `ANNOUNCE`: sent on the GUILD channel (the only message that is, and the only one accepted from it) with the sender's `updatedAt` right after a player sets themselves as master (`ns.AnnounceMaster`; closes the hole where a follower picked a player who was offline or not yet master, so the follower's checks were answered `NOT_MASTER`). A receiver acts only if the sender is the master it selected, it is not the master itself, and the stamp is newer than its own `updatedAt`; it then runs a normal automatic check (REQUEST/CURRENT/stream) after a random delay of 1 s plus up to `clamp(onlineGuildMembers * 0.5, 1, 30)` s (the jitter scales with the online count) so a big guild does not overload the master's send queue. That check ignores the 60 s cooldown and the roster's stale online flag. The sender's own echo is ignored. Re-selecting the current master does not announce again.

Only the explicitly selected master's actual chat sender is accepted for the active request ID; requesters/senders must be in the current local guild roster. Names are matched against the roster by exact name, or by realm-less name when that is unambiguous (`ns.ResolveGuildMember`). This assumes the `CHAT_MSG_ADDON` WHISPER sender string matches a `GetGuildRosterInfo` name; **unverified on the Forever beta**, so check it first if sync never completes. No guild identity is tracked; leaving the guild or losing the master from the roster ends a transfer. Names/payload lengths/numeric values/counts are bounded (the master packs `VALUE` pairs so each message stays within 255 bytes). Secret payloads are ignored. Masters print each incoming request that is streamed or declined (not `CURRENT` replies). Sends run every 0.2 s (using the burst allowance) with at most three queued tasks and a 30-minute transfer timeout (queued messages that expire or whose target/request is gone are dropped and only logged with `ns.Debug`). A requester that asks again within 30 seconds (and is not up to date; `NOT_MASTER` replies do not count) gets an `ERROR BUSY` reply, shown as "The master is busy or was asked too recently" (distinct from the local "A sync is already active"). `Enum.SendAddonMessageResult.AddonMessageThrottle` (not `Throttle`) silently retries after 1 second; `AddOnMessageLockdown` prints once and retries after 5 seconds. Other send errors are reported. Cancel, guild loss, malformed messages and timeout end receiving; nothing was applied, so local data and `updatedAt` are untouched. Import/restore/source changes are blocked while receiving. Chat feedback per sync: master set (or "you are the master"), requesting, receiving N modifiers, synced N modifiers or a failure with its reason, cancel, and a single "retrying" notice per deferral (not one per retry). Each received `VALUE` message prints only the progress `Received x/N` (no names or values; buffered, not yet applied). Automatic checks (`AutoCheck` in `Sync\SyncClient.lua`): triggered by `PLAYER_ENTERING_WORLD` (login/reload; requests the roster and waits for the first `GUILD_ROSTER_UPDATE`, then checks after 2 s if the master is online) and by the master's online flag changing offline -> online across `GUILD_ROSTER_UPDATE`s (checks after 5 s). They are skipped when you are the master, none is set, a sync is pending, the master is offline, or within 60 s of the previous check; an unanswered check times out after 15 s (debug log only) and retries once after 5 s. Failures and lockdown deferrals before `BEGIN` are debug-only; only a real stream prints to chat. Selecting a new master starts a normal sync at once when the master is online (otherwise it prints that the sync will happen when they come online). The player cannot yet see when the last sync happened.

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
