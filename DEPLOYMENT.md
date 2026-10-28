# Deployment playbook — small web app to a free Oracle Cloud VPS

Project-agnostic. `<APP_NAME>` is the app's short name (e.g. `myapp`);
substitute it throughout.

---

## 1. Architecture

Two origins, one URL for users:

| Piece | Where | Deployed by | Runs |
| --- | --- | --- | --- |
| Frontend | `https://<user>.github.io/<APP_NAME>/` | `templates/pages.yml` | Static files from `public/`, published by GitHub Actions on push. No server. |
| API + data | `https://<APP_NAME>.<ip>.sslip.io` | `templates/deploy.yml` | One app process on one Oracle VM, database file on disk. |

The QR code / bookmark points at the **frontend**. The frontend learns the API
origin at runtime from `api-config.js`, which the Pages workflow rewrites from
the repository variable `API_BASE_URL`. The API address therefore lives in
exactly one place and never in code.

```
browser ──> https://<user>.github.io/<APP_NAME>/
              │  fetch(window.APP_API_BASE + "/api/...")
              ▼
         https://<APP_NAME>.<ip>.sslip.io
              │  Caddy (TLS) ─> app :PORT ─> database
```

### The rule that bites: HTTPS

- The frontend must be HTTPS if it is on GitHub Pages (it is, free).
- If the frontend and API are on different origins, the **API must also be
  HTTPS** — an HTTPS page calling an `http://` API is blocked as mixed content.
  CORS headers cannot fix this.
- Anything browser-permission-gated (`getUserMedia` for in-app camera
  scanning, geolocation, notifications) is HTTPS-only. The native phone camera
  scanning a QR that opens a URL needs none of this.

### CORS

Cross-origin calls from the Pages origin to the API need:

```
Access-Control-Allow-Origin: <the frontend origin>   # echo the Origin header
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: content-type
```

and `OPTIONS` must return `204` without running the endpoint. Echo the origin
rather than using `*` if you ever add credentials.

---

## 2. Oracle Cloud

### 2.1 Credentials

```
~/.oci/config              # [DEFAULT] user / fingerprint / tenancy / region / key_file
~/.oci/oci_api_key.pem     # private key
```

The fingerprint must match the private key. Two formats exist:

- `c1:68:f3:55:0f:...` — MD5 style, `":"`-joined hex of
  `md5(DER of SubjectPublicKeyInfo)`. **The OCI Python SDK's config validator
  only accepts this format**, so use it in `config` even when the console shows
  a base64 SHA-256 fingerprint.
- `HhibPAtoq...=` — base64 SHA-256,
  `base64(sha256(DER of SubjectPublicKeyInfo))`. This is what the console shows
  for newer keys.

Generate the keypair locally (no `openssl` on Windows — use Python's
`cryptography`):

```python
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pem = key.private_bytes(serialization.Encoding.PEM,
                        serialization.PrivateFormat.PKCS8,
                        serialization.NoEncryption())
pub = key.public_key().public_bytes(serialization.Encoding.PEM,
                                     serialization.PublicFormat.SubjectPublicKeyInfo)
```

### 2.2 The one unavoidable console action

OCI has no self-service API to create API keys. Once per tenancy:

1. Generate the keypair locally.
2. Console → Identity & Security → Users → your user → **API Keys** →
   **Add API Key** → **Paste Public Key**.
3. The console confirms the fingerprint.

Everything after this is API or CLI.

### 2.3 The launch request

`POST https://iaas.<region>.oraclecloud.com/20160918/instances`

Three things cause `400 CannotParseRequest` that isn't obvious:

1. **`availabilityDomain` is required.** Omitting it is the most common cause.
2. **`user_data` must be Base64 encoded.** Raw text is rejected.
3. **`sourceDetails` uses `sourceType: "image"` (lowercase) with `imageId`** in
   the current API — not the older `"IMAGE"` / `sourceId`.

```json
{
  "availabilityDomain": "<from ListAvailabilityDomains>",
  "compartmentId": "<tenancy ocid>",
  "displayName": "<APP_NAME>",
  "shape": "VM.Standard.E2.1.Micro",
  "sourceDetails": {
    "sourceType": "image",
    "imageId": "<platform image ocid>",
    "bootVolumeSizeInGBs": 50
  },
  "createVnicDetails": {
    "subnetId": "<public subnet ocid>",
    "assignPublicIp": true
  },
  "metadata": {
    "ssh_authorized_keys": "<public key>",
    "user_data": "<base64 of bootstrap.sh>"
  }
}
```

- No top-level `subnetId` / `imageId` — they belong inside
  `createVnicDetails` / `sourceDetails`.
- `shapeConfig` **only** for Flex shapes
  (`VM.Standard.A1.Flex`: `{"ocpus": 2, "memoryInGBs": 12}`). Fixed shapes must
  not have one.
- `platformConfig` is not required.
- No top-level `assignPublicIp` / `preserveBootVolume` in the current API.

### 2.4 Rate limiting, capacity, quotas are three different things

| Error | Meaning | Response |
| --- | --- | --- |
| `429 TooManyRequests "Too many requests for the user"` | request throttling, caused by your own repeated attempts | stop; wait 10+ minutes; one attempt at a time |
| `Out of host capacity` | no capacity for that shape in that AD | check `oci compute compute-capacity-report create`, try another shape/AD |
| `LimitExceeded` / named limit | tenancy quota | raise the limit or use a smaller shape |

Failed launch attempts still count toward the throttle. **One attempt, then
read the error — never cycle request variants.**

### 2.5 OCI Python SDK 2.189.0 naming quirks

| Thing | Correct name |
| --- | --- |
| Networking client | `oci.core.VirtualNetworkClient` |
| VNIC attachments | `compute.list_vnic_attachments(...)` (compute client, not networking) |
| Security list rule | `oci.core.models.IngressSecurityRule` |
| Shape config | `oci.core.models.LaunchInstanceShapeConfigDetails` |
| Source details | `oci.core.models.InstanceSourceViaImageDetails(source_type="image", image_id=...)` |
| VNIC details | `oci.core.models.CreateVnicDetails(subnet_id=..., assign_public_ip=True)` |
| Availability domains | `oci.identity.IdentityClient(...).list_availability_domains(compartment_id=...)` |
| Waiting for a state | `oci.wait_until(client, client.get_instance(id), property="lifecycle_state", state="RUNNING", ...)` — there is no `Response.wait_for_state` |
| Images | `compute.list_images(compartment_id=...)` is **paginated**; loop on `next_page` |
| OS sources | `list_os_sources` is absent from the identity client in this version — filter `list_images` by display name instead |

Image display names: `Canonical-Ubuntu-24.04-aarch64-2026.09.18-0` (ARM) and
`Canonical-Ubuntu-24.04-2026.09.18-0` (x86_64 — the arch is only spelled out
for aarch64).

### 2.6 OCI CLI on Windows

- `pip install oci_cli` **fails on Python 3.14** (no PyYAML wheel).
- The offline bundle from the `oracle/oci-cli` GitHub release ships wheels for
  cp310–cp313 only.
- Installing under a long path fails with `OSError ... No such file or
  directory` (Windows 260-char path limit) — use a short venv path.

```powershell
# Python 3.13
Invoke-WebRequest https://www.python.org/ftp/python/3.13.7/python-3.13.7-amd64.exe -OutFile py313.exe
Start-Process py313.exe -ArgumentList "/quiet","InstallAllUsers=0","Include_pip=1","TargetDir=$env:LOCALAPPDATA\Python313" -Wait

# short-path venv + offline wheels
C:\Users\hanki\AppData\Local\Python313\python.exe -m venv C:\oci
C:\oci\Scripts\pip.exe install oci_cli `
  --find-links "$env:LOCALAPPDATA\oci-cli\oci-cli-installation\cli-deps\python313.html" `
  --no-index --ignore-requires-python

C:\oci\Scripts\oci.exe compute instance launch ... --no-retry
```

Set `SUPPRESS_LABEL_WARNING=True` to silence the key-label warning. The CLI
reads the same `~/.oci/config`.

**Prefer the CLI for launching** — it Base64-encodes `--user-data-file`,
serialises the body canonically, and `--debug` shows the exact request.

### 2.7 Inventory before you change anything

```bash
oci compute instance list -c <compartment> --query "data[].{name:\"display-name\",state:\"lifecycle-state\",shape:\"shape\"}"
oci network vcn list -c <compartment>
oci network subnet list -c <compartment> --query "data[].{name:\"display-name\",public:\"prohibit-public-ip-on-vnic\",sl:\"security-list-ids\"}"
oci network security-list list -c <compartment>
oci compute image list -c <compartment> --all
oci iam availability-domain list -c <compartment>
oci limits resource-availability get --service-name compute --compartment-id <compartment> --limit-name standard-e2-micro-core-count
```

---

## 3. Network gotchas

### 3.1 Oracle's image iptables silently drops 80/443

Oracle's Ubuntu cloud images install a rule that **rejects everything except
SSH, before the ufw chains** — so `ufw allow 80` appears to do nothing:

```
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited   <-- fires before ufw
-A INPUT -j ufw-before-input                           <-- never reached
```

Symptom: SSH works, HTTP/HTTPS time out from the internet even though the OCI
security list and ufw both allow the ports.

```bash
sudo iptables -I INPUT 4 -p tcp --dport 80  -j ACCEPT
sudo iptables -I INPUT 5 -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save || sudo sh -c 'iptables-save > /etc/iptables/rules.v4'
```

### 3.2 The security list that matters is the subnet's

Rules attach to security lists, and a subnet can reference a list other than
the VCN default. Check the subnet's `security_list_ids` and open ports there.

### 3.3 Instance metadata may not contain the public IP

`http://169.254.169.254/opc/v2/instance/` in some regions has **no `publicIp`
key** — a script doing `json.load(...)["publicIp"]` dies with `KeyError`.
Fallback: the instance's outbound IP is its public IP, so
`curl -s https://api.ipify.org`. Better: pass the IP in at deploy time.

### 3.4 Route tables decide what "public" means

`public_access` is not on the SDK's `Subnet` model. The real signals are
`prohibit_public_ip_on_vnic` (False = public IPs allowed) and a route table with
an internet gateway (`0.0.0.0/0 -> ocid1.internetgateway...`).

---

## 4. TLS without a domain

`<APP_NAME>.<ip>.sslip.io` is a real public DNS name that resolves to the IP,
so Caddy gets a normal Let's Encrypt certificate with zero DNS setup and zero
cost. `nip.io` works the same way.

```
<APP_NAME>.<ip>.sslip.io {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		-Server
	}
	reverse_proxy 127.0.0.1:<PORT>
}
```

- `tls-alpn-01` needs **443**, `http-01` needs **80**. If both are blocked the
  log says `Error getting validation data` and nothing else.
- `sslip.io` is shared by thousands of people → LE rate limits for that
  registered domain are a real risk. A hostname you own removes it.
- Don't restart Caddy in a loop while it retries; it burns rate limit.
- `systemctl restart caddy` is safer than `reload` (the package may not have
  Caddy running yet).

---

## 5. The deploy pipeline (CI → SSH)

### 5.1 Pattern

```
git push  →  GitHub Actions  →  SSH to VPS  →  /usr/local/bin/<APP_NAME>-deploy
                                             ├─ git fetch + fast-forward main
                                             ├─ npm ci --omit=dev (only if package.json changed)
                                             ├─ write commit SHA to <DATA_DIR>/commit.txt
                                             ├─ systemctl restart <SERVICE>
                                             ├─ health check <HEALTH_URL> for 15s
                                             └─ on failure: git reset --hard <prev> + restart + exit 1
```

The workflow then re-checks the public URL, so a bad deploy is a red X on the
commit and never reaches users.

### 5.2 Wiring

- **VPS**: deploy script at `/usr/local/bin/<APP_NAME>-deploy` (root-owned,
  0755), code at `/opt/<APP_NAME>`, data at `/var/lib/<APP_NAME>` (outside the
  code directory, so deploys never touch data).
- **CI key**: dedicated keypair; public half in
  `/home/<sshuser>/.ssh/authorized_keys`, private half as the GitHub secret
  `DEPLOY_SSH_KEY`.
- **GitHub**: secret `DEPLOY_SSH_KEY`, variable `DEPLOY_HOST`, environment
  `production`.
- The deploy script **self-refreshes**: after merging it copies its own
  repository version over the installed copy. The run that introduces the
  change can't refresh itself — install it once by hand, then it's automatic.

### 5.3 Two bugs worth remembering

- **Compare commits, not trees.** `git diff --quiet HEAD origin/main` compares
  *content*; after a revert that restores identical content the box would say
  "already up to date" and never advance. Use `git rev-parse HEAD` vs
  `git rev-parse origin/main`.
- **Self-refresh needs one manual install** (see above).

### 5.4 Test the rollback for real

Push a deliberately broken commit; confirm the workflow goes red while the
public API stays healthy. An unexercised rollback is a rumour.

---

## 6. GitHub Pages specifics

### 6.1 Enabling Pages via the API

```http
POST /repos/{owner}/{repo}/pages      {"build_type": "workflow"}
```

The workflow needs `permissions: { pages: write, id-token: write }` and
`actions/deploy-pages@v4`.

### 6.2 Sub-path hosting

A project site is served from `https://<user>.github.io/<repo>/`, so **absolute
asset paths (`/app.js`) 404**. Use relative paths (`app.js`, `style.css`,
`vendor/x.js`). The API base URL is a separate concern — handle it with a
runtime config variable, not the path.

### 6.3 Injecting config at deploy time

Don't edit the config file in code — let the workflow write it from a repo
variable:

```yaml
- name: Prepare static site
  run: |
    mkdir -p _site
    cp -r public/. _site/
    printf 'window.APP_API_BASE = "%s";\n' '${{ vars.API_BASE_URL }}' > _site/api-config.js
```

Change the API address in **Settings → Secrets and variables → Actions →
Variables** only.

### 6.4 Repository secrets via the API

GitHub encrypts secrets with the repo's public key using a **libsodium sealed
box**:

```python
import base64, requests, nacl.public, nacl.encoding

key_info = requests.get(f"{api}/actions/secrets/public-key", headers=headers).json()
public_key = nacl.public.PublicKey(key_info["key"].encode(), nacl.encoding.Base64Encoder())
sealed = nacl.public.SealedBox(public_key).encrypt(value.encode())  # SealedBox, not public_key.encrypt
requests.put(f"{api}/actions/secrets/{name}", headers=headers, json={
    "encrypted_value": base64.b64encode(sealed).decode(),
    "key_id": key_info["key_id"],
})
```

Variables are plain JSON: `POST /actions/variables` (409 → `PATCH
/actions/variables/{name}` for idempotency).

### 6.5 A token without the GitHub CLI

`gh` may not be installed, but Git Credential Manager holds one on Windows:

```powershell
$cred = "protocol=https`nhost=github.com`n`n" | git credential-manager get
$token = ($cred | Where-Object { $_ -like "password=*" }) -replace '^password=',''
$headers = @{ Authorization = "Bearer $token"; Accept = "application/vnd.github+json" }
```

Keep it in a variable; never write it to disk or commit it.

### 6.6 Manual workflow dispatch

```http
POST /repos/{owner}/{repo}/actions/workflows/<file>.yml/dispatches   {"ref": "main"}
```

---

## 7. Verifying a deployment

| Check | Command |
| --- | --- |
| App alive | `curl https://<APP_NAME>.<ip>.sslip.io/api/health` → `{"ok":true,...,"commit":"<sha>"}` |
| Which commit is live | same call — `commit` comes from `<DATA_DIR>/commit.txt` |
| CORS | `curl -i -X OPTIONS https://<api>/api/config -H "Origin: <frontend origin>" -H "Access-Control-Request-Method: POST"` → `204` + correct `access-control-allow-origin` |
| Pages config | `curl https://<user>.github.io/<repo>/api-config.js` → the injected API base |
| Service state | `ssh … "sudo systemctl status <SERVICE>; sudo journalctl -u <SERVICE> -f"` |
| Boot log | `ssh … "sudo tail -n 120 /var/log/<APP_NAME>-bootstrap.log"` |
| Instance | `oci compute instance get --instance-id <id> --query "data.lifecycle-state" --raw-output` |

### Browser-level end-to-end

The real proof is a headless browser against the **live** frontend URL, because
that exercises the cross-origin path (mixed content, CORS, relative assets):

```powershell
$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
Start-Process $edge -ArgumentList "--headless=new","--remote-debugging-port=9222",`
  "--disable-gpu","--user-data-dir=$env:TEMP\opencode\live-cdp","about:blank" -WindowStyle Hidden
```

Drive it over CDP (`http://localhost:9222/json/list` → WebSocket):
`Emulation.setDeviceMetricsOverride` for a phone viewport, `Page.navigate`,
`Runtime.evaluate` to interact, `Page.captureScreenshot` for evidence. Watch
`Runtime.exceptionThrown` and error-level `Runtime.consoleAPICalled` for silent
failures, and `document.documentElement.scrollWidth` for horizontal overflow.

---

## 8. Credentials map

| Credential | Where | Scope | Rotate by |
| --- | --- | --- | --- |
| GitHub account token | Git Credential Manager (Windows) or `gh auth login` | repo, workflow, admin | GitHub → Developer settings |
| GitHub secret `DEPLOY_SSH_KEY` | repo → Settings → Secrets and variables → Actions | SSH to the VPS | new keypair → new secret → append new `.pub` to `authorized_keys` → drop the old line |
| GitHub variable `API_BASE_URL` | same page, Variables tab | frontend API origin | edit in the UI |
| GitHub variable `DEPLOY_HOST` | same page, Variables tab | VPS IP for CI | edit in the UI |
| OCI API key | `~/.oci/oci_api_key.pem` + `config` | the tenancy | console → add key → new local keypair → update `config` |

Never commit these; never print a token into a log or file; prefer in-memory
variables.

---

## 9. Build-from-scratch checklist

1. Python 3.13 → venv at `C:\oci` → install the OCI CLI offline.
2. Generate an OCI API keypair locally; upload the public key in the console;
   write `~/.oci/config` with the **MD5-style** fingerprint.
3. Inventory the tenancy: VCNs, subnets, route tables, security lists, images,
   instances, availability domains.
4. Open TCP 80/443 in the security lists **attached to the public subnet**.
5. Launch the instance (CLI preferred): availability domain, `sourceType: image`
   + `imageId`, `createVnicDetails.subnetId` + `assignPublicIp`, Base64
   `user_data`, SSH public key. One attempt, then read the error.
6. Wait for RUNNING; read the public IP from the VNIC.
7. Fix the image-level iptables (accepts for 80/443 before the REJECT rule,
   persisted).
8. Point Caddy at `<APP_NAME>.<ip>.sslip.io`, `caddy validate`,
   `systemctl restart caddy`; wait for the certificate.
9. Create the GitHub repo via API, push, enable Pages with
   `{"build_type": "workflow"}`.
10. Add the Pages workflow with the variable-injection step; set `API_BASE_URL`;
    push; confirm the deployed `api-config.js`.
11. Add the deploy workflow, the CI keypair, the `DEPLOY_SSH_KEY` secret and the
    `DEPLOY_HOST` variable; install the deploy script on the box.
12. **Test the rollback** with a broken commit.
13. Run the browser end-to-end against the live URL.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `400 CannotParseRequest` on launch | missing `availabilityDomain`; raw `user_data`; `"IMAGE"`/`sourceId` | §2.3 |
| `429 TooManyRequests` on launch | throttling from your own repeated attempts | stop; wait 10+ min; one attempt at a time |
| `Out of host capacity` | no capacity for that shape/AD | `compute-capacity-report create`, try another shape/AD |
| SSH works, HTTP/HTTPS time out | Oracle's image iptables REJECTs before ufw | insert accepts before the REJECT rule (§3.1) |
| Ports open in the console but unreachable | wrong security list | open on the subnet's own lists (§3.2) |
| `KeyError: 'publicIp'` in bootstrap | region metadata has no public IP | fall back to `api.ipify.org` (§3.3) |
| `Error getting validation data` (ACME) | LE cannot reach 80/443 | fix iptables; check the security list |
| LE `rate limited` | shared `sslip.io` domain | use your own hostname, or wait |
| Pages asset 404s | absolute paths under a repo sub-path | relative paths (§6.2) |
| Browser mixed-content / CORS error | API not HTTPS, or missing CORS headers | TLS + `Access-Control-Allow-Origin` echo, `OPTIONS` → 204 |
| `InvalidConfig: {'fingerprint': 'malformed'}` | SDK rejects the base64 SHA-256 fingerprint | use the `c1:68:...` MD5-style format |
| SDK `AttributeError` on a model | SDK 2.189.0 renames | see the table in §2.5 |
| `pip install oci_cli` fails | Python 3.14 has no PyYAML wheel | Python 3.13; short venv path (§2.6) |
| Box HEAD lags behind `main` | tree comparison instead of commit comparison | compare `git rev-parse` (§5.3) |
| `systemctl reload caddy` does nothing | Caddy not running yet | `systemctl restart caddy` |
