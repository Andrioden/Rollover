## About

WoW Addon to ....


## How to get started

1. Clone this repo to \World of Warcraft\_classic_beta_\Interface\AddOns\Rollover\
2. [Install lua](https://github.com/rjpcomputing/luaforwindows/releases)
3. Innstall VS Code extension [WoW Api](https://marketplace.visualstudio.com/items?itemName=ketho.wow-api)
4. Start WoW: Forever and run command `/rollover`


## Run tests

Run all
```powershell
lua .\Tests\RolloverTests.lua .
```

Run one suite
```powershell
lua .\Tests\SyncTests.lua .
```


## Workflow tips

- Make a macro `/reload` to reload ui and thereunder the addon
- Make a macro `/rollover` to quickly open the addon when testing
- Run `/rollover debug` to se debug text
- Run `/rollover debug roll` to test item rollout function
