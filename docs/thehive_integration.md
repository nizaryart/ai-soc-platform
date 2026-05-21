# TheHive Integration — original contribution

## What this is

A custom integration between the AI alert-triage service and TheHive 5 case
management. Every alert that the AI pipeline successfully analyzes is also
automatically pushed to TheHive as a case, with rich AI context:

- **Severity** mapped from AI verdict (critical/high/medium/low → TheHive 1-4)
- **Description** carries the LLM's natural-language summary, detailed
  analysis, and potential impact assessment
- **Tags** include MITRE ATT&CK techniques the AI identified, alert category,
  and AI true-positive/false-positive verdict
- **Tasks** are auto-created from the AI's prioritized recommendations
  (each recommendation becomes a task with priority prefix and rationale)
- **Observables** extracted from the alert (source IP, dest IP, user,
  hostnames, file paths) plus any IOCs the LLM surfaced from log content

## Why this exists

The OnyxLab AI_SOC upstream repository describes TheHive integration in its
README as a planned feature, and declares `thehive_url` / `thehive_api_key`
settings in `services/alert-triage/config.py`. **But the actual integration
code is missing.** A code search across the entire upstream services tree
returns zero TheHive client implementations.

This file documents the gap and our fill:

```
# In upstream:
grep -rln "thehive\|TheHive" services/
  -> only matches in .env.example, config.py declarations, README, models.py
  -> zero matches for actual API calls or client instantiation
```

## Files added / modified

| File | Status | Purpose |
|---|---|---|
| `services/alert-triage/thehive_client.py` | **NEW** | `TheHiveClient` class with `create_case()`, observable extraction, severity/tag mapping |
| `services/alert-triage/main.py` | modified | Import + initialize `TheHiveClient` at startup; fire-and-forget call after successful analysis |
| `docker-compose/ai-services.yml` | modified | Pass `TRIAGE_THEHIVE_URL` and `TRIAGE_THEHIVE_API_KEY` env vars from `.env` into the alert-triage container |

## Design choices

1. **Fire-and-forget pattern.** Matches the existing `_persist_alert` flow.
   TheHive case creation never blocks the AI pipeline's response — the
   client returns the triage JSON immediately, the case appears in TheHive
   ~1 second later. Failure to create a case logs a warning but doesn't
   affect the response.

2. **Auto-disable when unconfigured.** If `THEHIVE_URL` or `THEHIVE_API_KEY`
   are missing/blank, `TheHiveClient.configured` returns False and the
   integration silently skips. Lets the service run standalone for testing.

3. **Severity remapping.** TheHive uses integers 1-4 for severity. The AI
   uses strings (critical/high/medium/low/informational). A constant
   `_SEVERITY_MAP` keeps the translation explicit.

4. **Observables as a separate API call per item.** TheHive 5 accepts
   observables in the case-create body, but adding them one-by-one gives
   per-observable error handling. If one observable fails (e.g., malformed
   IOC value), the rest still attach.

5. **Recommendations → Tasks.** Each AI recommendation becomes a task in
   TheHive with `[P<priority>]` prefix. Analysts can mark them done
   independently. This turns LLM advice into actionable work items.

## Configuration

In your `.env` on the AI-services host:

```
THEHIVE_URL=http://<M1_IP>:9010
THEHIVE_API_KEY=<your-thehive-user-api-key>
```

The compose file maps these to the `TRIAGE_THEHIVE_URL` and
`TRIAGE_THEHIVE_API_KEY` env vars (TRIAGE_ prefix is required by Pydantic
settings convention in `config.py`).

## Verification

After deploying:

1. POST a synthetic alert to `wazuh-integration:8002/webhook` (or any real
   Wazuh alert routed through)
2. Check alert-triage logs:
   ```
   docker logs alert-triage --tail 30 | grep -i thehive
   ```
   Expected: `TheHive case <id> created for alert <alert_id>`
3. Open TheHive UI (`http://<M1_IP>:9010` → Cases) — new case visible with
   AI severity, summary in description, observables and tasks attached

## Limitations / future work

- TheHive's TLP and PAP are hardcoded to 2 (amber). A future enhancement
  could derive these from alert sensitivity classification.
- We don't yet update existing cases when the same alert recurs — a
  duplicate alert always creates a new case. Correlation handling could
  query TheHive first and append to an existing case if found.
- No Cortex analyzer triggers from this client; that's TheHive's own job
  when the case has observables. Verify Cortex servers are registered in
  TheHive's admin settings.
