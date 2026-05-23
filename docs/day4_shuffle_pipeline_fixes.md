# Day 4 — Shuffle Webhook Pipeline Fixes (2026-05-22 → 2026-05-23)

End-of-day snapshot. The Shuffle SOAR pipeline (TheHive case event → webhook
→ Shuffle workflow execution) is now fully operational end-to-end. Five
discrete bugs were found and fixed during this session. None of the upstream
docs flagged any of them.

---

## What works now

```
M2 webhook POST  →  AI pipeline  →  TheHive case
                                        ↓ notification fires
                              webhook to Shuffle
                                        ↓
                       Shuffle workflow execution created
                                        ↓
                       Orborus polls Org_default queue
                                        ↓
                       Worker container spawned
                                        ↓
                       Shuffle Tools app actions executed
```

Proof: execution `2c003220-ef44-4272-bd97-4048ed27855d` advanced from
`0 / 3 results` to `1 / 3 results` with workers running `set_cache_value`
and `get_cache_value` in sequence.

---

## Five fixes applied tonight

### Fix 1 — TheHive notification config key was wrong (silent failure)

**Symptom:** `notification.endpoints = []` despite our `application.conf`
declaring a webhook endpoint. No log warnings.

**Root cause:** We had used `notification.webhook.endpoints` — that key does
not exist in TheHive 5.2.9. The correct key is `notification.endpoints`,
AND each entry must declare a `type` discriminator (`webhook | http |
mattermost | slack | teams`).

**Fix in `config/thehive/application.conf`:**
```hocon
# WRONG (silently ignored):
notification.webhook.endpoints = [
  { name: shuffle, url: "...", ... }
]

# RIGHT:
notification.endpoints = [
  {
    type: webhook
    name: shuffle
    url: "http://shuffle-backend:5001/api/v1/hooks/webhook_<UUID>"
    version: 0
    wsConfig {}
    includedTheHiveOrganisations: ["*"]
    excludedTheHiveOrganisations: []
  }
]
```

**How we identified it:** `curl /api/config` showed empty endpoints list;
then unpacked `org.thp.thehive-core-5.2.9-1.jar` and ran `python` against
the `Endpoint$.class` bytecode to extract the JSON discriminator field name
and the supported type values.

### Fix 2 — Duplicate UI-created endpoint with wrong URL

**Symptom:** TheHive log showed `Webhook call on http://shuffle-backend:5001/api/v1/hooks/webhook returns 401 Unauthorized` even after Fix 1 — note the URL has no UUID suffix.

**Root cause:** Two `shuffle` endpoints existed — one loaded from
`application.conf` (correct URL with UUID) and one created earlier via the
TheHive UI (placeholder URL without UUID). The notification rule pointed at
the broken one.

**Fix:** Delete the UI-created endpoint via TheHive Admin UI; recreate the
notification rule selecting the config-loaded `shuffle` endpoint.

### Fix 3 — shuffle-backend zombie network attachment

**Symptom:** `docker network inspect soar-backend` didn't list
shuffle-backend, even though `docker inspect soar-shuffle-backend` claimed
it was attached. TheHive's DNS lookup of `shuffle-backend` failed.

**Root cause:** Docker network state corruption from a partial start cycle —
container metadata showed the network but `EndpointID`, `IPAddress`,
`MacAddress` were empty strings.

**Fix:** `docker compose up -d --force-recreate shuffle-backend` — clean
network re-attach. Confirmed with `getent hosts shuffle-backend` from inside
TheHive returning `172.26.0.7`.

### Fix 4 — Orborus polled wrong environment name

**Symptom:** Shuffle execution status stuck at `EXECUTING` indefinitely —
nothing picking it up off the queue.

**Root cause:** Mismatch between Shuffle's configured environment
(`Org_default`, the only one) and the orborus `ENVIRONMENT_NAME` env var
(`Shuffle`, the upstream-default placeholder).

**Fix in `docker-compose/phase2-soar-stack.yml`:**
```yaml
shuffle-orborus:
  environment:
    - ENVIRONMENT_NAME=Org_default   # was: Shuffle
```

### Fix 5 — Worker image path mismatch + side-effect-induced container deletion

**Symptom:** Orborus picked up jobs but failed to spawn workers:
`No such image: ghcr.io/frikky/shuffle-worker:1.4.0`.

**Root cause:** Shuffle was repackaged under the `shuffle` GHCR org but the
orborus default `SHUFFLE_BASE_IMAGE_NAME=frikky` still expects the old path.

**Critical side effect:** Changing `SHUFFLE_BASE_IMAGE_NAME=shuffle` caused
orborus to misidentify `soar-shuffle-backend` and `soar-shuffle-frontend` as
its own "old worker" containers and `docker rm -f` them on next cleanup
sweep. This took down the SOAR stack mid-session.

**Working fix — leave env var alone, alias the image locally:**
```bash
docker tag ghcr.io/shuffle/shuffle-worker:1.4.0 \
           ghcr.io/frikky/shuffle-worker:1.4.0
```
Orborus finds the image under its expected name and does not touch the
real `soar-*` containers.

### Fix 6 (bonus) — Worker BASE_URL not resolvable from spawned containers

**Symptom:** Workers spawned but logged `dial tcp: lookup shuffle-backend on
192.168.65.7:53: no such host`.

**Root cause:** Orborus spawns worker containers on Docker's default bridge
network, not on `soar-backend`. The default `BASE_URL=http://shuffle-backend:5001`
passed to workers as the backend URL is unresolvable from the bridge net.

**Fix in `docker-compose/phase2-soar-stack.yml`:**
```yaml
shuffle-orborus:
  environment:
    - BASE_URL=http://host.docker.internal:5001   # was: http://shuffle-backend:5001
```
The host gateway is reachable from any Docker network.

---

## Files changed this session

| File | Change |
|---|---|
| `config/thehive/application.conf` | `notification.endpoints` key + `type: webhook` discriminator |
| `docker-compose/phase2-soar-stack.yml` | orborus `ENVIRONMENT_NAME=Org_default`, `BASE_URL=http://host.docker.internal:5001` |

## Local Docker state changes (not in compose)

| Image | Action |
|---|---|
| `ghcr.io/shuffle/shuffle-worker:1.4.0` | Pulled |
| `ghcr.io/frikky/shuffle-worker:1.4.0` | Tagged as alias of above |
| `frikky/shuffle:shuffle-tools_1.2.0` | Pulled (used by workflow actions) |

---

## Outstanding work before Workflow 1 is production-shaped

1. **Stale executions** — many `EXECUTING` ghosts from the broken iterations.
   Clean via Shuffle UI → Workflows → executions tab → stop all old runs.

2. **TheHive webhook body is empty** — TheHive POSTs to Shuffle with
   `Content-Length: 0`. Shuffle backend logs:
   `Failed execution POST unmarshalling for execution - continuing anyway:
   unexpected end of JSON input`.
   The workflow gets triggered but receives no case data to enrich.
   **Fix path:** add a body template to the webhook endpoint config.
   The exact field is not in the WebhookEndpoint constructor we extracted
   from JAR — needs further investigation. Possible options: use `type: http`
   instead of `type: webhook` (HttpRequestEndpoint has a `bodyTemplate`
   field), or use TheHive's notification template syntax with `audit`/`object`
   context vars.

3. **Workflow content is placeholder** — current nodes are
   `set_cache_value` / `get_cache_value` / `repeat_back_to_me` (scaffold from
   workflow creation). Need to replace with:
   - AbuseIPDB IP reputation lookup
   - VirusTotal v3 file/IP/domain lookup
   - AlienVault OTX indicator lookup
   - Python aggregator computing `risk_score` 0-100
   - TheHive `update case` setting custom field + adding comment
   - Conditional branch: if score ≥ 70 → Discord webhook

4. **Day 3 Part B still open** — `mitre_techniques` empty in AI pipeline
   output. Two-pronged fix: strengthen LLM prompt template + populate from
   RAG as deterministic fallback.

---

## Useful debugging commands (kept for resume)

```bash
# Verify TheHive loaded the webhook endpoint
curl -s -u "admin@thehive.local:secret" "http://localhost:9010/api/config" \
  | python -c "import sys,json; d=json.load(sys.stdin); [print(c) for c in d if c['path']=='notification.endpoints']"

# Watch Shuffle backend for incoming webhook calls
docker logs soar-shuffle-backend -f 2>&1 | grep -iE "webhook|hook"

# Watch orborus pick up executions
docker logs soar-shuffle-orborus -f 2>&1 | grep -vE "Zombie|status\":\""

# List worker containers currently running
docker ps --filter "name=worker-" --format "{{.Names}}\t{{.Status}}"

# Inspect a specific execution
SHUFFLE_KEY="b283ce63-9407-484f-8abb-c78f7d7bbe84"
curl -s -H "Authorization: Bearer $SHUFFLE_KEY" \
  -X POST -H "Content-Type: application/json" \
  -d '{"execution_id":"<EXEC_ID>"}' \
  http://localhost:5001/api/v1/streams/results
```
