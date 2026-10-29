# Git workflow

- Single `main` branch, local commits only. One commit per phase via `./scripts/Save-Phase.ps1 -Message "feat(api): ..."`.
- The script refuses to commit secret files or the dev DB password. Push is off unless `-Push` is passed.
- Never force-push, hard-reset, amend published commits or delete branches. Never commit `appsettings.Development.json`.
- Commit message style: `feat(scope): …`, `fix(scope): …`, `docs: …`.
