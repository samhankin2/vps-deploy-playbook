# VPS Deployment Playbook

A reusable, project-agnostic kit for shipping a small web app to a free Oracle
Cloud VPS with a GitHub Pages frontend and an automated CI deploy.

Written from a real deployment (an office rating app) that hit every
interesting failure mode along the way. Everything in here is a lesson paid for
in time, not theory.

## What's in the box

```
DEPLOYMENT.md          the playbook — read this first
AGENTS.md              ground rules for any agent working on a project using this
scripts/
  oci-provision.py     create the VPS, open the ports, launch with cloud-init
  bootstrap.sh         cloud-init: install Node + Caddy, clone, install, serve
  app-deploy.sh        pull -> restart -> health check -> roll back
  app.service          systemd unit template
templates/
  pages.yml            GitHub Pages workflow (injects the API origin)
  deploy.yml           CI -> SSH deploy workflow
  api-config.js        frontend config stub (API base URL)
```

## Quick start for a new project

```bash
# 1. copy the kit
mkdir -p ~/Development/myapp-deploy && cp -r scripts templates ~/Development/myapp-deploy/

# 2. set your values
export APP_NAME=myapp
export REPO_URL=https://github.com/you/myapp.git
export PORT=3000
export HEALTH_PATH=/api/health
export FRONTEND_ORIGIN=https://you.github.io/myapp

# 3. provision the VM (dry run first, then ARENA_LAUNCH=1)
python scripts/oci-provision.py

# 4. push the project, set the GitHub secrets/variables, done
```

Step 3 needs Oracle credentials (see DEPLOYMENT.md §2) and takes a couple of
minutes; the VM then configures itself.

## The shape it produces

```
browser ──> https://you.github.io/myapp/          (static frontend, GitHub Pages)
              │  fetch(window.APP_API_BASE + "/api/...")
              ▼
         https://app.<ip>.sslip.io                 (your app, on a free Oracle VPS)
              │  Caddy (TLS) ─> node :PORT ─> database
```

Push to `main` and both halves deploy. A failed deploy rolls itself back.

## Why these choices

- **GitHub Pages for the frontend** — free HTTPS, a CDN, zero servers. The
  frontend is static files, so a VM would be wasted on it.
- **A single small VM for the API** — the only stateful component. Always Free
  shapes are genuinely free, forever.
- **CI deploys by SSH, not by pulling on a timer** — the commit status tells you
  whether production is healthy, and the rollback is automatic.
- **No containers** — for a zero-dependency Node app, a container registry adds
  moving parts and failure modes without buying anything. The deploy is
  `git pull` + `systemctl restart`, which takes under a second.

## Before you use it

DEPLOYMENT.md §9 is a 13-step build-from-scratch checklist and §10 is a
symptom → cause → fix troubleshooting table. Most of the value is in the parts
that are *not* obvious: the exact OCI launch body, the iptables rule that
silently drops 80/443, the GitHub Pages sub-path trap, and the two GitHub
API tricks (Pages enablement and secret encryption).
