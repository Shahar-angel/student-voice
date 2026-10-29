# קול הסטודנטים — instructions for Claude Code

Student feedback chat on Google Apps Script. `apps-script/` holds exactly the files in the Google project: `Code.gs` is the server (all permission checks live here), `Index.html` is the single-page UI (named `Index` in the project). Deployed from the Google account arcobalenochic@gmail.com, which is also the only system admin; data lives in a Google Sheet in that account. User-facing docs are in Hebrew under `docs/`.

`apps-script-sender/` is a second Google project, "קול הסטודנטים - שולח המיילים האישי", deployed "Execute as: User accessing" so staff email goes out from the staff member's own Gmail and quota. It holds no data: it pulls that person's queued mail from the app's `doPost` (`MAIN_URL`) every 10 minutes and reports back. The app's side is `SENDER_URL`, `senderApi_`, the `Senders` and `Outbox` sheets. Keep `MAIN_URL` equal to `appUrl` in `config/deployment.json` (a static test checks it). Only sign-in codes, answers to anonymous requests and the owner's own mail go from the system account; a student must never cause any other mail from it (new-request alerts go from each staff member's own sender to themselves). Full spec: `docs/00-איפיון-המערכת.md`.

Never use the URL parameter names `c` or `sid`: Apps Script reserves them and the web app fails to open. Links use `?course=` and `&view=`.

Links people get are the three permanent ones, never one per course: `exec` (admin), `exec?view=student` and `exec?view=staff` (`studentHome_`/`staffHome_`). After sign-in each person is routed by email to their course, or picks from a list. Per-course links (`studentLink_`/`staffLink_`) appear only in emails and as an optional direct link; a link to a deleted course must fall back to the picker, never a dead end.

## Planning
- Before planning, ask the user questions until the requirements are clear.
- Always plan first, then execute. Do not write code before the user approves the plan. This replaces the earlier "just do it" requests; once the plan is approved, carry it out end to end, including the deploy.
- Use Opus 5.5 for planning and Sonnet 5.5 for execution: plan in the main session, and hand the code and test changes to Sonnet sub-agents (Agent tool, `model: "sonnet"`). Browser deploys and steps that need the user's approval stay in the main session.

## Git and GitHub
- The project lives in a public GitHub repository: https://github.com/Shahar-angel/student-voice. Never commit keys, tokens or personal data.
- Every new feature is developed on its own new branch, never directly on main.
- The live app is deployed only from `main`, and the deploy is automatic: merge the branch after the tests pass and the user approves, push `main`, and the Stop hook runs `tools/deploy-google.ps1` (clasp) when `apps-script*/` changed in what was pushed. It checks clean pushed `main`, runs the tests, and stops without pushing anything on drift (someone edited the code in the Google editor; the pulled copy and a diff go to `backups/google-drift/`). Manual fallback: `powershell -NoProfile -ExecutionPolicy Bypass -File tools\deploy-google.ps1` (`-DryRun` to preview). It only ever updates the existing deployment ids from `config/deployment.json`.
- `apps-script/appsscript.json` (and the sender's) is the project's manifest, pulled verbatim from Google; never change its `webapp` settings casually. Google names the server file `קוד`, not `Code.gs`; the deploy script maps `Code.gs` to it. clasp credentials live only in the user profile (`~/.clasprc.json`); `.clasp.json` and `.clasprc.json` are git-ignored. Never run `clasp create-deployment`/`deploy`.
- `backups/` (the hook's local zip snapshots) stays out of Git (`.gitignore`); Git history is the way back to an earlier version.

## Testing
After every implementation, run and report the actual results:
- E2E tests on the full user flow
- Regression tests, to confirm existing features still work
- Edge cases (empty, missing, very long or invalid input)

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1` (results in `tests/last-results.md`). The full run takes about 4 minutes; `-Quick` (about 20 seconds) skips the activity-log and Google-sync groups and is what the edit hook uses for app code. GitHub Actions and `tools/deploy-google.ps1` always run the full suite. Add a test for every new feature or fixed bug, in the matching group in `tests/server.test.js` or `tests/ui.test.js`.

## Security
- After every stage of execution, run a security review: injection, prompt injection, input validation, and secrets or API keys in code.
- Never put the Claude API key in code or docs; it lives only in the Apps Script property `ANTHROPIC_API_KEY`.
- Student text sent to Claude goes through `studentBlock_()`; render user text with `textContent`, never `innerHTML`.

## Docs
- When behavior, links, limits or setup steps change, update the matching file in `docs/` in the same change. The hook keeps the index in `README.md` and the log in `docs/שינויים.md` up to date on its own.
- After changing anything in `apps-script/` or `apps-script-sender/`, the live app only changes after redeploying from `main`, which the Stop hook does automatically via `tools/deploy-google.ps1` (see `docs/01-התקנה-ופריסה.md`, "עדכון קוד"; browser paste is only the fallback).

## Hook
`.claude/hooks/on-edit.ps1` runs after every Write/Edit:
- any file → zips the whole project into `backups/` (`tools/backup.ps1`, skipped when nothing changed). Restore with `tools/restore-backup.ps1 -Name <zip>`; never delete snapshots marked `_קבוע`.
- edited `docs/*.md` → rebuilds the docs index in `README.md` and logs the change in `docs/שינויים.md`.
- edited `config/deployment.json`, `apps-script/Code.gs` or `tools/build-links.ps1` → rebuilds `קישורים.html` and the links block in `README.md` (never edit those by hand; the link format is read from `studentHome_`/`staffHome_` in Code.gs).
- edited `apps-script/*`, `apps-script-sender/*` or `tests/*` → runs the test suite, logs the result, and returns the result plus a docs/security/redeploy reminder.

`.claude/hooks/on-stop.ps1` (Stop hook, runs at the end of every assistant turn; never blocks):
- completes the pending entries in `יומן-פעולות/רשומות/` (adds `time`, `branch`, `files`, `testSummary`, `done_at`) and rebuilds `יומן-פעולות/index.html` (`tools/build-activity-log.ps1`; never edit it by hand).
- scans what would be committed for secrets (API keys, tokens, private keys); on a hit it commits and pushes nothing and warns.
- commits everything and pushes the current branch to `origin`. On `main` only `יומן-פעולות/` is committed; code changes belong on a feature branch. If the push fails, the commit stays local and the next run pushes it.
- after a successful push of `main`, if `apps-script/` or `apps-script-sender/` files changed in the commits just pushed, runs `tools/deploy-google.ps1` (re-runs the tests, drift check, clasp push + new version on the existing deployment) and appends its one-line result to the message. The Stop hook timeout is 600 seconds for this. `DEPLOY_GOOGLE_SCRIPT` overrides the script (tests only).
- tested against throwaway repos by `tests/activity-log.test.ps1` and `tests/google-sync.test.ps1` (a fake clasp; both part of `run-tests.ps1`); never run the hook or the real deploy to test them, use `ACTIVITY_LOG_ROOT` and `-DryRun`.
- CI: `.github/workflows/tests.yml` runs `tests\run-tests.ps1` on every push and pull request (read-only, no secrets, no deploy).

## Activity log
- At the end of every task write one entry JSON in `יומן-פעולות/רשומות/`, named `YYYY-MM-DD_HH-mm_<short-latin-slug>.json`. Fields: `title` (required), `request`, `done` (array), `decisions` (array), `tests`, `open` (array). The hook adds the automatic fields. The repository is public: no student emails, personal data, keys or tokens in entries.
- At the start of a new session read the latest entries in `יומן-פעולות/רשומות/` (or `index.html`) as secondary memory, after `MEMORY.md`.
