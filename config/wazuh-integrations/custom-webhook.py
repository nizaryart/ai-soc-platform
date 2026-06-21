#!/usr/bin/env python3
"""
Wazuh Manager -> M2 wazuh-integration custom webhook.

Wired in ossec.conf as:

  <integration>
    <name>custom-webhook</name>
    <hook_url>http://192.168.100.152:8002/webhook</hook_url>
    <level>7</level>
    <alert_format>json</alert_format>
  </integration>

Wazuh invokes this script per qualifying alert with these positional args:
  argv[1] = path to a JSON file containing the alert
  argv[2] = API key (unused here)
  argv[3] = hook URL (from <hook_url> in ossec.conf)
  argv[4] = "debug" (optional)

Uses Python stdlib only (urllib). Logs every invocation to
/var/ossec/logs/integrations.log so you can see when alerts were forwarded
and whether the M2 endpoint responded.
"""

import json
import sys
from datetime import datetime
from urllib import request as urlreq
from urllib import error as urlerr

LOG_FILE = "/var/ossec/logs/integrations.log"
TIMEOUT_SECONDS = 120
ERR_BAD_ARGS = 2
ERR_READ_FILE = 6


def log(msg):
    """Best-effort append to integrations.log. Never raises."""
    try:
        ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(LOG_FILE, "a") as f:
            f.write("{0} [custom-webhook] {1}\n".format(ts, msg))
    except Exception:
        pass


def main(argv):
    if len(argv) < 4:
        log("ERROR bad arguments: " + repr(argv))
        sys.exit(ERR_BAD_ARGS)

    alert_file = argv[1]
    hook_url = argv[3]

    # Load alert JSON
    try:
        with open(alert_file, "r") as f:
            alert = json.load(f)
    except Exception as e:
        log("ERROR reading alert file " + alert_file + ": " + str(e))
        sys.exit(ERR_READ_FILE)

    rule = alert.get("rule", {}) or {}
    rule_id = rule.get("id", "?")
    rule_level = rule.get("level", "?")
    rule_desc = rule.get("description", "?")

    # POST to hook URL
    try:
        body = json.dumps(alert).encode("utf-8")
        req = urlreq.Request(
            hook_url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "Wazuh-CustomWebhook/1.0",
            },
            method="POST",
        )
        resp = urlreq.urlopen(req, timeout=TIMEOUT_SECONDS)
        log(
            "POST {0} status={1} rule_id={2} level={3} desc={4!r}".format(
                hook_url, resp.status, rule_id, rule_level, rule_desc
            )
        )
    except urlerr.HTTPError as e:
        log(
            "HTTPError POSTing to {0}: {1} {2} (rule_id={3})".format(
                hook_url, e.code, e.reason, rule_id
            )
        )
    except urlerr.URLError as e:
        log(
            "URLError POSTing to {0}: {1} (rule_id={2})".format(
                hook_url, e.reason, rule_id
            )
        )
    except Exception as e:
        log(
            "ERROR POSTing to {0}: {1} (rule_id={2})".format(
                hook_url, str(e), rule_id
            )
        )


if __name__ == "__main__":
    main(sys.argv)
