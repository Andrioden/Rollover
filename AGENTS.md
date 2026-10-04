# AGENTS.md - Rollover

Source of truth for humans and agents. Update it in the same change that alters files, features, SavedVariables, the sync protocol, slash commands, conventions or known platform quirks (checklist in section 9). Describe rules and intent here; leave what the code states plainly (constants, chat text, layout) to the code.

## 1. Overview

Rollover is a guild loot addon for **World of Warcraft: Forever** (Classic+, TOC game type `camelot`). It lives in `Interface\AddOns\Rollover` of the `_classic_beta_` install; the repo is that folder.

| Feature | Status |
| --- | --- |
| Roll modifiers | Every guild member has a numeric modifier. `/rollover <item-link>` opens a roll popup; Roll calls `RandomRoll(1, 100)`, reads the result from `CHAT_MSG_SYSTEM` and prints `roll + modifier` via `ns.Print` (SAY is blocked from event handlers outside instances). |
| Modifier sync | One account-wide modifier table, synced from a single trusted *master* (section 6). |
| Main window | `/rollover`: resizable guild roster (ledger master button, name, class, rank, editable modifier; sortable headers) and a gear Tools menu: sync/cancel, set yourself as master, save backup, export/import JSON, restore backup, reset data. |
| Item reserving, options UI | Not started. |

TODO: consider `## AllowLoadGameType: camelot` in the TOC.

## 2. Platform facts (verified Oct 2026)

- Forever uses Mainline's UI and nearly all 12.1.5 APIs. Lua 5.1 plus WoW extras (`strsplit`, `wipe`, `CopyTable`); no `goto`, `//` or bitwise operators (use `bit`).
- Beta: patch 1.60.1, interface `16001`; Test/Live values are unpublished. Check in game with `/dump (select(4, GetBuildInfo()))`; detect in code with `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT`.
- Timeline: beta Sep 17 - Oct 22 2026, launch Nov 4 2026, raids Dec 9 2026 (Barrow Deeps, Hyjal Summit, Onyxia's Lair); level cap 60.
- Characters are "First Last": `UnitName("player")` returns the first name only, `GetUnitName("player", true)` the full name (`ns.GetPlayerName`). Guild roster names have **no realm suffix**; never require `-Realm` and key data by exactly what `GetGuildRosterInfo` returns.
- `GUILD_ROSTER_UPDATE` fires on its own (twice) when a member goes online or offline, with `isOnline` already current; detect transitions by diffing snapshots, without polling. `C_GuildInfo.GuildRoster()` is ignored within 10 s of the previous call.
- Midnight's addon restrictions are active (section 7).

## 3. WoW API guide

### 3.1 Patterns to copy from this repo

| Pattern | Where |
| --- | --- |
| Event frame, `ADDON_LOADED` init, dispatch | `Core\Events.lua` |
| SavedVariables defaults (`ns.InitDB`), guild roster iteration (`ns.GetRosterList`) | `Core\DB.lua` |
| Slash command, item-link parsing | `Core\Commands.lua` |
| Addon messages: prefix registration, send queue, result codes, secret guards | `Sync\SyncCore.lua` |
| Timers (`C_Timer.After` / `NewTimer`) | `Sync\SyncClient.lua`, `Sync\SyncCore.lua` |
| Movable window that Escape closes (`UISpecialFrames`) | `UI\Window.lua` |
| ScrollBox list, `MenuUtil` context menu with submenu, `StaticPopupDialogs` confirmation, sortable headers, resize grip | `UI\MainFrame.lua` |
| Multi-line EditBox in a ScrollFrame | `UI\TextDialog.lua` |
| `RandomRoll` + parsing a localized global string, item icon/tooltip from a link | `UI\RollFrame.lua` |

### 3.2 Use the modern API

Training data often shows the legacy form; the legacy form is removed or deprecated on this client.

| Use | Not |
| --- | --- |
| `C_GuildInfo.GuildRoster()` | `GuildRoster()` |
| `C_AddOns.GetAddOnMetadata`, `C_AddOns.LoadAddOn` | `GetAddOnMetadata`, `LoadAddOn` |
| `C_Item.GetItemInfo`, `C_Item.GetItemInfoInstant` | `GetItemInfo`, `GetItemInfoInstant` |
| `C_ChatInfo.SendAddonMessage`, `C_ChatInfo.RegisterAddonMessagePrefix` | `SendAddonMessage`, `RegisterAddonMessagePrefix` |
| `MenuUtil.CreateContextMenu` | `UIDropDownMenu`, `EasyMenu` |
| ScrollBox (`WowScrollBoxList`, `CreateScrollBoxListLinearView`, `ScrollUtil`) | `FauxScrollFrame`, `HybridScrollFrame` |
| `frame:SetResizeBounds` | `SetMinResize`, `SetMaxResize` |
| `Settings.RegisterCanvasLayoutCategory` + `Settings.RegisterAddOnCategory`, `Settings.OpenToCategory` | `InterfaceOptions_AddCategory`, `InterfaceOptionsFrame_OpenToCategory` |
| `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, fn)` | hooking `OnTooltipSetItem` |
| `"BackdropTemplate"` in `CreateFrame` before `SetBackdrop` | `SetBackdrop` on a plain frame |

### 3.3 API facts

- Lifecycle: files run in TOC order (each gets `local addonName, ns = ...`), then SavedVariables load and `ADDON_LOADED(addonName)` fires; `PLAYER_LOGIN` once all addons are loaded; `PLAYER_ENTERING_WORLD(isLogin, isReload)` on login, reload and every loading screen; `PLAYER_LOGOUT` is the last chance to change SavedVariables.
- SavedVariables replace file-scope values, persist only strings, numbers, booleans and tables (shared references become copies), and are written on logout, disconnect and `/reload`. Account file: `WTF\Account\<ACCOUNT>\SavedVariables\Rollover.lua`; `SavedVariablesPerCharacter` lives under `<Realm>\<Char>\`.
- TOC: `## Interface` takes comma-separated versions. Other directives: `SavedVariablesPerCharacter`, `Dependencies` / `OptionalDeps`, `LoadOnDemand: 1`, `IconTexture`, `AddonCompartmentFunc` (minimap compartment entry), `X-*` custom metadata. `AllowLoadGameType: camelot` limits loading to Forever (add `ExcludeLoadGameType` for exclusivity); per-file `[AllowLoadGameType camelot]` and the `[TextLocale]` variable exist. The `.toc` name must match the folder.
- `GetGuildRosterInfo(i)` returns `name, rankName, rankIndex, level, classDisplayName, zone, publicNote, officerNote, isOnline, status, classFileName, achievementPoints, achievementRank, isMobile, canSoR, repStanding, guid`. Officer notes need permission to read.
- Addon messages: register the prefix (at most 16 chars) first, then listen to `CHAT_MSG_ADDON(prefix, text, channel, sender)`. Messages are at most 255 bytes, about 10 per prefix in a burst, then 1/s. `Enum.SendAddonMessageResult`: 0 `Success`, 3 `AddonMessageThrottle` (not `Throttle`), 5 not in group, 10 not in guild, 11 `AddOnMessageLockdown`, 12 target offline. `CHANNEL` is disabled on Classic-family clients. Use `SendAddonMessageLogged` for player-written free text. Treat every message as untrusted.
- `C_EncodingUtil.SerializeJSON` / `DeserializeJSON` (import/export) are documented but unverified on Forever; a missing API is reported to the player.
- Items: `C_Item.GetItemInfo` returns nil until the item is cached; wait with `Item:CreateFromItemID(id):ContinueOnItemLoad(fn)` or `GET_ITEM_INFO_RECEIVED`. Key item data by item ID (`C_Item.GetItemInfoInstant(link)` or `link:match("item:(%d+)")`).
- Rolls: `RandomRoll(low, high)` results arrive as `CHAT_MSG_SYSTEM` text matching the localized `RANDOM_ROLL_RESULT`; build the pattern from it. Group loot: `START_LOOT_ROLL(rollID, rollTime, lootHandle)`, `GetLootRollItemInfo`, `RollOnLoot(rollID, rollType)`, `CONFIRM_LOOT_ROLL`, results in `CHAT_MSG_LOOT` (`LOOT_ITEM_*` global strings). Need/Greed/master-loot rolls are server-side and **cannot be changed by an addon**, so modifiers live entirely in the addon's own roll flow. `C_LootHistory` is undocumented for Forever.

## 4. Workflow

- Edit in place and `/reload` in game (this also picks up TOC changes and new files). Never commit `WTF/` data or screenshots.
- Debugging: `/console scriptErrors 1` (or BugSack), `/dump`, `/tinspect`, `/etrace`, `/fstack`. `/rollover debug` shows the `ns.Debug` log; `/rollover debug roll` opens the roll popup with a test item. Force restrictions with the `addon*RestrictionsForced` CVars (e.g. `addonChatRestrictionsForced 1`).
- Editor: VS Code with the Lua (sumneko) and WoW API (Ketho) extensions. Blizzard UI code: `Gethe/wow-ui-source`, `forever` branch.
- Tests run outside the game: `lua .\Tests\RolloverTests.lua .` runs all suites, `lua .\Tests\<Suite>.lua .` one suite. Without Lua, use `npm exec --yes --package=fengari-node-cli -- fengari .\Tests\RolloverTests.lua .`.
  - `Tests\MockClient.lua` mocks the WoW API per client (frames, timers, roster, message delivery) and provides the helpers `requestSync`, `messagesFrom`, `backupCount`, `login`, `printedSince`, `count` and `last`. Mock guild members are offline unless a test sets `client.online[name] = true`.
  - Suites by scope: `DBTests` (Core\DB), `ImportExportTests` (JSON and text windows), `SyncClientTests` (follower alone, replies injected), `SyncMasterTests` (master alone, requests injected), `SyncTests` (master and follower, manual syncs), `SyncAutoTests` (automatic checks and announcements), `MainFrameTests`, `EventsTests`. Register new suites in `RolloverTests.lua`.
  - Test each behavior once, in the suite that owns it. Don't re-assert what the mock enforces (the 255-byte limit) or what was removed.
  - Mocks don't prove client behavior (JSON parsing, menu layout, whisper sender format); verify those in game. Multiplayer features need two accounts.
- Distribution (later): CurseForge, WoWInterface, wago.io, with a changelog and semantic versions.

## 5. Conventions

- Share state through `ns`, never globals. Allowed globals: `RolloverDB`, `SLASH_ROLLOVER1`, `SlashCmdList.ROLLOVER` and named frames listed in `UISpecialFrames`. Modules call each other through `ns` at runtime (everything loads before `ADDON_LOADED`), so no load-order guards.
- One responsibility per file; TOC order is locale -> core -> sync -> UI -> commands/events -> `Rollover.lua`.
- User-visible text goes through `ns.L` (`Locales\enUS.lua`), and every key must be used. Still hardcoded English: `UI\RollFrame.lua`, `UI\DebugFrame.lua`, the main window title and column headers, and the `Usage:` line.
- Chat output only through `ns.Print`, diagnostics through `ns.Debug`. The main window deliberately has no status text.
- One window per file, built on `ns.CreateWindow` (`UI\Window.lua`); text-box dialogs use `ns.CreateTextDialog`.
- No `OnUpdate`; use events and `C_Timer`. Never block on uncached items.
- Check `issecretvalue` wherever the client may hand over secrets (chat event payloads, roster names) and fail soft.
- Validate data where it enters (edits, JSON import, sync messages) and trust it afterwards; don't guard states the code cannot produce.
- `RolloverDB.version` stays 1 and development data is not migrated (version 0.0.1, no users), so reset obsolete SavedVariables by hand. Add migrations once real users exist.
- Bump `## Version:` on user-visible changes.

## 6. Architecture

```
Rollover.toc
Locales\enUS.lua      ns.L
Core\Utils.lua        ns.Print
Core\DB.lua           SavedVariables, modifiers, permissions, updatedAt, backups/restore/reset, JSON import/export, roster helpers
Sync\SyncCore.lua     transport: message format, bounded send queue with throttle/lockdown retries, CHAT_MSG_ADDON routing
Sync\SyncMaster.lua   master side: answers REQUESTs, announces becoming master
Sync\SyncClient.lua   follower side: master selection, manual and automatic requests, receiving and applying streams
UI\Window.lua         ns.CreateWindow: movable window that Escape closes
UI\MainFrame.lua      roster table and Tools menu
UI\DebugFrame.lua     ns.Debug log (last 200 lines) and its window
UI\TextDialog.lua     ns.CreateTextDialog
UI\ExportFrame.lua    copy-only JSON window
UI\ImportFrame.lua    paste-JSON window
UI\RollFrame.lua      roll popup
Core\Commands.lua     /rollover
Core\Events.lua       event registration and dispatch
Rollover.lua          ns.version (loaded last)
Tests\                standalone suites, not in the TOC (section 4)
```

Planned: `Modules\Reserves.lua`, `Modules\Modifiers.lua`, `Modules\Rolls.lua`, and SavedVariables `options` and `reserves[itemID][playerName]`.

### 6.1 Data model

```lua
RolloverDB = {
    version = 1,
    modifiers = { [name] = number },
    backups = { ["YYYY-MM-DD HH:MM:SS"] = { name = source, updatedAt = integer, modifiers = copy } },
    sync = { master = name, updatedAt = integer },
}
```

- `name` is the roster name. Class and rank are never saved; the roster view merges live guild data with saved modifiers (a missing modifier is 0). Modifiers of members who left are kept, synced and exported.
- `updatedAt` is the age of the data: the server time (shared by all clients) of the last real edit, strictly increasing (`ns.TouchModifiers`). It travels with the data through sync, import/export and backups and is never set to "now" any other way. Missing means 0, the oldest.
- **Data only moves forward:** imports, restores and synced streams older than the local `updatedAt` are refused, an equal stamp counts as up to date, and an import stamp from the future is invalid. Tools > Reset data (clears modifiers and sets `updatedAt = 0`; allowed for followers) is the only way to accept older data, so an empty master (stamp 0) can never overwrite anyone.
- Every replace (import, restore, reset of non-empty data, completed sync) first backs up the previous state, named by its source: `manual`, `import`, `restore`, `reset`, `sync` or `auto sync`. Only `auto sync` backups are pruned (the newest `ns.MAX_AUTO_BACKUPS` are kept).
- Import JSON: `{"updatedAt": seconds, "modifiers": {name: number}}`. Names are non-empty, at most 96 bytes, with no control characters or `|`; values are finite numbers; at most `ns.MAX_MEMBERS` (1000) entries and 200000 bytes.

### 6.2 Master and permissions

- Each player chooses one master with the ledger button on a roster row (or Tools > Set yourself as master); clicking the current master's button deselects it. Choosing yourself makes you the master, which sends `ANNOUNCE` if you have data.
- Only the master edits, imports and restores, and nobody does while a sync is receiving. With no master everything is read-only.

### 6.3 Sync protocol

Prefix `Rollover`. Messages are tab-separated `type, requestID, fields...` and sent by WHISPER, except `ANNOUNCE`, which is GUILD-only and the only message accepted from GUILD. There is no protocol version, so all clients must run the same addon version during development.

| Message | Fields | Meaning |
| --- | --- | --- |
| `REQUEST` | `have` | A follower asks its master; `have` is the follower's `updatedAt`. |
| `CURRENT` | - | `have` equals the master's stamp, so there is nothing to send. Not rate limited and not printed by the master. |
| `BEGIN` | count, `updatedAt` | Starts a stream (count <= 1000). The follower refuses a stamp older than its own. |
| `VALUE` | first index, `name, value` pairs | As many pairs as fit in 255 bytes; indexes are contiguous and duplicates are invalid. |
| `END` | count | Completes the stream. |
| `ERROR` | `NOT_MASTER`, `BUSY` or `INVALID_TRANSFER` | Declined. `BUSY` means the same requester asked within 30 s or the send queue is full. |
| `ANNOUNCE` | `updatedAt` | Sent to the guild on becoming master. A follower that chose this master and has older data runs an automatic check after a random delay that grows with the number of online members. |

- Followers buffer the stream and apply it (backup, data and stamp together) only at a valid `END`. Cancelling, a timeout, malformed input, losing the master from the roster or leaving the guild never changes local data.
- Only the selected master, answering the active request ID, is accepted. Senders and requesters must be in the local guild roster (`ns.ResolveGuildMember`: the exact name, or an unambiguous realm-less name). **Unverified on Forever:** whether the WHISPER sender string matches the roster name. Check this first if sync never completes.
- Masters send explicit zeros for roster members without a saved modifier.
- Send queue: at most three tasks and paced sends. Throttled sends retry silently; a lockdown prints one notice and retries. Stale tasks (target gone, request cancelled, no longer master) are dropped.
- Automatic checks print only if data actually streams (otherwise they only log to the debug window). They run on login/reload once the roster shows the master online, when the master comes online, and after `ANNOUNCE`. They are skipped if you have no master or are the master, a sync is pending, the master is offline or within a cooldown, and an unanswered check is retried once. An older master is reported once per stamp by automatic checks and every time by manual syncs. Choosing an online master syncs immediately. A manual sync is not started while the master is offline per the roster; it prints "Sync not initiated: master X is offline."
- A master's edits are not pushed; followers catch up at their next check or manual sync. The time of the last sync is not recorded.

## 7. Forever restrictions (Secret Values)

- Tainted code may store and pass secret values but cannot compare, index or do arithmetic on them, take `#`, or use them as table keys (all raise a Lua error). Test with `issecretvalue` / `canaccessvalue`.
- Chat messaging lockdown (encounters, challenge modes, PvP matches, dungeon/raid maps): chat events, including the `CHAT_MSG_SYSTEM` roll results, may deliver secrets, and `SendAddonMessage` returns `AddOnMessageLockdown`. Guard every chat handler with `issecretvalue`, sync outside lockdown, and queue and retry sends. **Verify on the beta** when roll results can be read in raids, and plan a fallback.
- Addons get no combat log events and cannot call protected functions in combat.
- APIs still change during the beta; re-verify on each build and update this file.

## 8. References

- [TOC format](https://warcraft.wiki.gg/wiki/TOC_format), [Saving variables](https://warcraft.wiki.gg/wiki/Saving_variables_between_game_sessions), [Events](https://warcraft.wiki.gg/wiki/Events_(API)), [AddOn namespace](https://warcraft.wiki.gg/wiki/Using_the_AddOn_namespace)
- [C_ChatInfo.SendAddonMessage](https://warcraft.wiki.gg/wiki/API:C_ChatInfo.SendAddonMessage), [Secret Values](https://warcraft.wiki.gg/wiki/Secret_Values)
- [World of Warcraft: Forever](https://warcraft.wiki.gg/wiki/World_of_Warcraft:_Forever), [Patch 1.60.1 API changes](https://warcraft.wiki.gg/wiki/Patch_1.60.1/API_changes)
- [Blizzard UI source](https://github.com/Gethe/wow-ui-source), [API docs (Townlong Yak)](https://www.townlong-yak.com/framexml/live), [BlizzardInterfaceResources](https://github.com/Ketho/BlizzardInterfaceResources)

## 9. Update checklist

Update this file in the same change when you:

- add, remove or rename a file (section 6 and the TOC);
- ship or start a feature (section 1);
- change SavedVariables (6.1), permissions (6.2) or the protocol (6.3);
- add a slash command (sections 1 and 4) or a convention (section 5);
- introduce a new kind of WoW pattern (a row in 3.1) or meet a legacy/modern API mix-up (3.2);
- learn a platform quirk or restriction (sections 2, 3 and 7), or bump `## Interface` (section 2).
