# AGENTS.md

Tongues is a chat filter and text-expansion addon for **WoW Forever 1.60.1**
(`## Interface: 16001`). The repository root is the addon root:
`Tongues.toc` is here.

## Shared workflow (all addons)

- The user tests manually in WoW Forever. Static checks never count as an
  in-game result; install the build and give a numbered test script.
- Back up the installed copy before replacing it:
  ```powershell
  Remove-Item -Recurse -Force D:\projects\Convenient\backups\Tongues-previous -ErrorAction SilentlyContinue
  Copy-Item -Recurse -Force "G:\Games\World of Warcraft\_forever_\Interface\AddOns\Tongues" "D:\projects\Convenient\backups\Tongues-previous"
  ```
- Install only the addon files (`*.lua`, `*.toc`, `Core/`) to
  `G:\Games\World of Warcraft\_forever_\Interface\AddOns\Tongues`.
  Never copy `.git`, docs, tooling or build output.
- New features and fixes use `feature/<short-name>` or `fix/<short-name>`,
  are installed and tested from that branch, and merge to `main` only after
  the user's test passes. `main` stays releasable.

## Tongues rules

- CurseForge project `1791127`; game version `16001` only. Do not add Retail
  (`120105`) or Mists (`50504`).
- Keep `.pkgmeta` at the repository root: `package-as: Tongues`, with
  `README.md`, `LICENSE`, `CHANGELOG.md` and `AGENTS.md` excluded.
- The **pushed tag** triggers CurseForge; the GitHub release does not.
- Never commit the CurseForge webhook token.

## Checks

```powershell
foreach($f in @('Core.lua','UI.lua','Core\Events.lua','Core\Expansions.lua','Core\Filter.lua','Core\Scripts.lua','Core\Words.lua')) {
  powershell -NoProfile -File D:\projects\Convenient\tools\check-lua.ps1 -Path $f
}
```
