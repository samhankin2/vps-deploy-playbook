# AGENTS.md

Ground rules for any agent (or human) deploying a project with this kit.

## Read this first

**`DEPLOYMENT.md`** — the playbook. Read it before touching infrastructure.
The value is in the parts that are *not* obvious: the exact OCI launch body
(a missing `availabilityDomain` and non-Base64 `user_data` are the two
reasons a launch 400s), the iptables rule that silently drops 80/443, the
GitHub Pages sub-path trap, and the 429-vs-quota-vs-capacity distinction.

## Using the kit for a new project

1. Copy `scripts/` and `templates/` into the project.
2. Substitute `__APP_NAME__` / `APP_NAME` everywhere (service name, app dir,
   data dir, Caddy hostname, systemd unit).
3. Set the env vars: `APP_NAME`, `REPO_URL`, `PORT`, `HEALTH_PATH`,
   `FRONTEND_ORIGIN`.
4. `python scripts/oci-provision.py` (dry run) → `ARENA_LAUNCH=1` to launch.
5. Add `templates/pages.yml` and `templates/deploy.yml` to
   `.github/workflows/`, and put `templates/api-config.js` in `public/`.
6. Create the GitHub secret `DEPLOY_SSH_KEY` (libsodium sealed box — see
   DEPLOYMENT.md §6.4) and the variables `API_BASE_URL` and `DEPLOY_HOST`.
7. Install `scripts/app-deploy.sh` on the box as
   `/usr/local/bin/<APP_NAME>-deploy` (root-owned, 0755) and add the CI public
   key to `/home/ubuntu/.ssh/authorized_keys`.
8. **Test the rollback** with a deliberately broken commit before you trust it.

## Hard rules

- **Never commit a secret.** Tokens, keys and passwords live in GitHub Actions
  secrets/variables and in `~/.oci/`. Keep tokens in shell variables; never
  write them to a file or a log.
- **Data never lives in the code directory.** Keep the database in
  `/var/lib/<APP_NAME>/` so deploys can't touch it.
- **Asset paths in the frontend must be relative** (`app.js`, not `/app.js`) —
  GitHub Pages serves project sites from a sub-path.
- **Never edit the injected config file in code.** Change the `API_BASE_URL`
  repository variable; the workflow rewrites it.
- **One launch attempt, then read the error.** Don't cycle request variants —
  you will hit the 429 throttle.
- **Exercise the rollback path before relying on it.**

## Verifying

- `curl https://<APP_NAME>.<ip>.sslip.io/api/health` → `{"ok":true,...,"commit":"<sha>"}`
- The `commit` field tells you exactly what is live.
- For UI work, drive the live Pages URL in headless Edge over CDP — that is
  the only way to catch mixed-content and CORS failures (DEPLOYMENT.md §7).
