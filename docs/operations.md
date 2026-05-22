# Operations Runbook

## Known issues and post-deploy hardening

### 1. Wazuh admin password rotation (TODO before public release)

**Status:** Default `admin/admin` credentials are still active on the Wazuh Indexer and Dashboard. This must be rotated before the platform faces any untrusted network.

**Why it wasn't fixed at deploy time:**
- The `INDEXER_PASSWORD` env var in `.env` configures *service-to-service* auth (manager → indexer keystore), but does NOT propagate into the OpenSearch security index (where the `admin` user's bcrypt hash is stored)
- The `admin` user is marked `reserved: true` in `internal_users.yml`, so the OpenSearch Security REST API rejects in-place password changes (returns `FORBIDDEN`)
- Wazuh ships `wazuh-passwords-tool.sh` to handle this properly, but it requires `sudo` (not installed in the Amazon Linux 2023 base image)
- `securityadmin.sh` (the lower-level alternative) requires a valid admin client certificate whose DN matches `plugins.security.authcz.admin_dn` in `opensearch.yml`. The OnyxLab cert generator (`generate-certs.ps1`) creates node certs with `CN=wazuh-indexer,OU=Security_Operations`, but the upstream `opensearch.yml` expects `CN=admin,OU=Security`. Mismatch.

**Proper rotation procedure (to do):**

1. Generate an admin client cert with the matching DN:
   ```powershell
   openssl req -new -key $RootCADir\admin-key.pem -out $RootCADir\admin.csr `
     -subj "/C=US/ST=California/L=Los Angeles/O=AI-SOC/OU=Security/CN=admin"
   openssl x509 -req -days 3650 -in $RootCADir\admin.csr `
     -CA $RootCADir\root-ca.pem -CAkey $RootCADir\root-ca-key.pem `
     -CAcreateserial -out $RootCADir\admin.pem
   ```

2. Mount the admin cert into `wazuh-indexer:/usr/share/wazuh-indexer/certs/`

3. Generate bcrypt hash of new password:
   ```powershell
   python -c "import bcrypt; print(bcrypt.hashpw(b'NEW_PASSWORD', bcrypt.gensalt(rounds=12)).decode())"
   ```

4. Update `/usr/share/wazuh-indexer/opensearch-security/internal_users.yml` inside the container — replace admin's `hash:` value

5. Push the change via securityadmin.sh:
   ```bash
   docker exec -u root wazuh-indexer bash -c "
     JAVA_HOME=/usr/share/wazuh-indexer/jdk \
     /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
       -cd /usr/share/wazuh-indexer/opensearch-security/ \
       -nhnv \
       -cacert /usr/share/wazuh-indexer/certs/root-ca.pem \
       -cert /usr/share/wazuh-indexer/certs/admin.pem \
       -key /usr/share/wazuh-indexer/certs/admin-key.pem \
       -h localhost
   "
   ```

6. Repeat for `kibanaserver`, `kibanaro`, `logstash`, `readall`, `snapshotrestore` users

7. Update `INDEXER_PASSWORD` and `DASHBOARD_PASSWORD` in `.env` to the new admin and kibanaserver values; recreate the dashboard container so it picks up new auth

**Workaround until properly fixed:** restrict M1's firewall to only allow port 443 from known LAN IPs.

---

### 2. Wazuh index template manual load

**Status:** Resolved at deploy time, but worth automating.

The `wazuh` index template (which tells OpenSearch how to map alert fields) is supposed to be auto-loaded by Filebeat on first start. It sometimes silently skips this step.

**Manual load (one-time after first manager boot):**

```
docker exec wazuh-manager bash -c "
  curl -k -s -X PUT 'https://wazuh-indexer:9200/_template/wazuh' \
    -H 'Content-Type: application/json' \
    -u admin:admin \
    -d @/etc/filebeat/wazuh-template.json
"
```

Expected response: `{"acknowledged":true}`. Verify with:

```
docker exec wazuh-manager curl -s -k -u admin:admin 'https://wazuh-indexer:9200/_cat/templates/wazuh*?v'
```

**To automate:** wrap into a `scripts/post-deploy-wazuh.sh` that runs after `docker compose up`.

---

### 3. Config files must be LF, not CRLF

**Status:** Resolved at deploy time (Python script converted 25 files).

Git on Windows with default `autocrlf=true` converts Unix line endings to CRLF on checkout. Wazuh and several other tools (csyslogd, prometheus) have strict XML/YAML parsers that fail on `\r` characters with cryptic "line 0" errors.

**Prevention:** Add to repo root `.gitattributes`:
```
*.conf text eol=lf
*.yml  text eol=lf
*.yaml text eol=lf
*.xml  text eol=lf
*.json text eol=lf
```

This forces git to preserve LF endings regardless of platform.

---

## 4. Cortex 3.1.7 vs modern analyzer images — known incompatibility

**Status:** Architectural decision, not a bug. Documented for context.

**Symptom:** Cortex spawns the analyzer container successfully (Docker socket mount works, image pulls work), but the analyzer fails immediately at startup with:

```
File "/root/.local/lib/python3.14/site-packages/cortexutils/worker.py", line 37
    self._input = json.load(sys.stdin)
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
```

**Root cause:** Cortex 3.1.7 (released 2022) passes analyzer input via a job directory file (`/job/input/input.json`). The `ghcr.io/thehive-project/*` analyzer images were rebuilt in 2025 using a newer `cortexutils` library that reads from `sys.stdin` instead. Stdin is empty when Cortex 3 invokes the container → JSON decode error on empty string.

This is an upstream maintenance gap — Cortex 3 is essentially frozen while analyzer images continue to be rebuilt with newer dependencies.

**What still works:**
- Cortex is deployed and reachable
- TheHive ↔ Cortex API integration (the case "Run Analyzer" button triggers correctly)
- All 4 analyzers enabled and configured with valid API keys
- The analyzer Docker images pull and start successfully

**What doesn't work:** The analyzer execution itself (Cortex job result shows the JSONDecodeError).

**Architectural choice:** SOAR automation workflows in this project use **Shuffle's native apps for threat intelligence** (built-in AbuseIPDB, VirusTotal, OTX, MaxMind integrations) rather than going through Cortex. This:
- Avoids the Cortex 3 / cortexutils version drift entirely
- Eliminates one hop (no Docker container spawn per analysis)
- Uses the same API keys (configured in Shuffle apps, not Cortex)
- Is the pattern used by many production SOCs that run Shuffle alongside TheHive

Cortex remains deployed for manual analyst use in the TheHive UI once the upstream fixes the version drift (or when migrating to Cortex 4).

**Fix paths if you want Cortex analyzers working:**
1. Pin to older image digests that use old-cortexutils (requires Docker Hub research per analyzer)
2. Upgrade to Cortex 4 (substantial migration — defer until stable)
3. Wait for the upstream `ghcr.io/thehive-project/*` images to address the compat issue

---

## Deploy log

| Date | Event |
|---|---|
| 2026-05-17 | Phase 1 SIEM stack deployed on M1 (Wazuh Manager + Indexer + Dashboard) |
| 2026-05-17 | Wazuh index template loaded manually |
| 2026-05-17 | All upstream config files normalized to LF line endings |
| 2026-05-22 | Discovered Cortex 3.1.7 + new analyzer image incompatibility; pivoted SOAR workflows to Shuffle native apps |
