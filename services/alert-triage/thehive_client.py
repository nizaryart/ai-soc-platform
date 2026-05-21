"""
TheHive Client - Alert Triage Service
AI-Augmented SOC

Pushes AI-enriched alerts into TheHive 5 as cases, with observables
(source IP, user, hash, etc.) and tasks derived from LLM recommendations.

This module is an ORIGINAL ADDITION to the OnyxLab AI-SOC reference platform.
The upstream code declared `thehive_url` and `thehive_api_key` settings but
never implemented the actual integration. This file completes that loop so
alerts processed by the AI pipeline automatically appear in the TheHive case
manager with full LLM context.

TheHive 5 API reference:
  POST /api/v1/case               - create a case
  POST /api/v1/case/{id}/observable - add observable to case
  Auth header: Authorization: Bearer <API_KEY>
"""

import logging
from typing import List, Optional, Dict, Any

import httpx

from config import settings
from models import SecurityAlert, TriageResponse, SeverityLevel

logger = logging.getLogger(__name__)


# AI severity (string) -> TheHive severity (int 1-4)
_SEVERITY_MAP = {
    SeverityLevel.LOW: 1,
    SeverityLevel.INFO: 1,
    SeverityLevel.MEDIUM: 2,
    SeverityLevel.HIGH: 3,
    SeverityLevel.CRITICAL: 4,
}


class TheHiveClient:
    """
    Asynchronous client for TheHive 5 case management API.

    Designed to be used as fire-and-forget from alert-triage's analyze
    endpoint - case creation never blocks the AI pipeline response.
    """

    def __init__(
        self,
        base_url: Optional[str] = None,
        api_key: Optional[str] = None,
        timeout: float = 30.0,
    ):
        self.base_url = (base_url or settings.thehive_url or "").rstrip("/")
        self.api_key = api_key or settings.thehive_api_key
        self.timeout = timeout

        if not self.base_url or not self.api_key:
            logger.warning(
                "TheHiveClient initialised without url/api_key - "
                "case creation will be skipped"
            )

    @property
    def configured(self) -> bool:
        """True if the client has the credentials needed to call TheHive."""
        return bool(self.base_url and self.api_key)

    def _headers(self) -> Dict[str, str]:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

    # ---------- public ----------

    async def create_case(
        self, alert: SecurityAlert, result: TriageResponse
    ) -> Optional[str]:
        """
        Create a TheHive case from an alert + AI analysis.

        Returns the new case `_id` on success, None on failure.
        Failures are logged but never raised - this is fire-and-forget.
        """
        if not self.configured:
            return None

        try:
            payload = self._build_case_payload(alert, result)

            async with httpx.AsyncClient(
                timeout=self.timeout, verify=False
            ) as client:
                resp = await client.post(
                    f"{self.base_url}/api/v1/case",
                    json=payload,
                    headers=self._headers(),
                )

            if resp.status_code not in (200, 201):
                logger.warning(
                    f"TheHive case creation failed for {alert.alert_id}: "
                    f"HTTP {resp.status_code} - {resp.text[:200]}"
                )
                return None

            case_id = resp.json().get("_id")
            logger.info(
                f"TheHive case {case_id} created for alert {alert.alert_id} "
                f"(severity={payload['severity']}, "
                f"tags={len(payload.get('tags', []))})"
            )

            # Add observables as separate calls (TheHive 5 supports this
            # in the case creation body too, but separate calls give us
            # finer-grained error handling)
            observables = self._extract_observables(alert, result)
            if case_id and observables:
                await self._add_observables(client_base_url=self.base_url,
                                            case_id=case_id,
                                            observables=observables)
            return case_id

        except httpx.TimeoutException:
            logger.warning(
                f"TheHive case creation timed out for {alert.alert_id} "
                f"after {self.timeout}s"
            )
            return None
        except Exception as e:
            logger.warning(
                f"TheHive case creation error for {alert.alert_id}: {e}"
            )
            return None

    # ---------- payload construction ----------

    def _build_case_payload(
        self, alert: SecurityAlert, result: TriageResponse
    ) -> Dict[str, Any]:
        """Translate alert + AI result into a TheHive case body."""

        severity_int = _SEVERITY_MAP.get(result.severity, 2)

        # Build tags from MITRE techniques + alert category + AI-flagged TP/FP
        tags = ["ai-triaged", f"category:{result.category.value}"]
        if result.is_true_positive:
            tags.append("ai-verdict:true-positive")
        else:
            tags.append("ai-verdict:false-positive")
        for tech in result.mitre_techniques or []:
            tags.append(f"mitre:{tech}")

        # Description carries the AI narrative
        description_parts = [
            f"**AI summary** ({result.confidence:.0%} confidence):",
            result.summary,
            "",
            "**Detailed analysis:**",
            result.detailed_analysis or "(none provided)",
            "",
            "**Potential impact:**",
            result.potential_impact or "(none provided)",
            "",
            f"**Wazuh rule:** {alert.rule_id} - {alert.rule_description}",
            f"**Wazuh rule level:** {alert.rule_level}",
            f"**ML prediction:** {result.ml_prediction} "
            f"(confidence={result.ml_confidence})",
        ]
        if not result.is_true_positive and result.false_positive_reason:
            description_parts.extend([
                "",
                "**False positive reasoning:**",
                result.false_positive_reason,
            ])

        # Recommendations become case tasks
        tasks = []
        for rec in result.recommendations or []:
            tasks.append({
                "title": f"[P{rec.priority}] {rec.action}",
                "description": rec.rationale,
                "status": "Waiting",
            })

        payload: Dict[str, Any] = {
            "title": f"[{result.severity.value.upper()}] "
                     f"{alert.rule_description}",
            "description": "\n".join(description_parts),
            "severity": severity_int,
            "tlp": 2,   # amber - typical default for SOC alerts
            "pap": 2,
            "tags": tags,
            "tasks": tasks,
        }
        return payload

    def _extract_observables(
        self, alert: SecurityAlert, result: TriageResponse
    ) -> List[Dict[str, Any]]:
        """Pull observables from the alert and any IOCs the AI found."""
        observables: List[Dict[str, Any]] = []
        seen = set()  # de-dup (datatype, value)

        def add(dt: str, value: Optional[str], tags: Optional[List[str]] = None):
            if not value:
                return
            key = (dt, value)
            if key in seen:
                return
            seen.add(key)
            observables.append({
                "dataType": dt,
                "data": value,
                "tlp": 2,
                "tags": tags or [],
            })

        # From the alert itself
        add("ip", alert.source_ip, ["source-ip"])
        add("ip", alert.dest_ip, ["dest-ip"])
        add("user-account", alert.user, ["user"])
        add("hostname", alert.source_hostname, ["source-host"])
        add("hostname", alert.dest_hostname, ["dest-host"])
        add("filename", alert.file_path, ["file"])

        # From AI-extracted IOCs
        for ioc in result.iocs or []:
            ioc_type = (ioc.ioc_type or "").lower()
            # Map common IOC type strings to TheHive dataTypes
            type_map = {
                "ip": "ip",
                "ip_address": "ip",
                "domain": "domain",
                "url": "url",
                "hash": "hash",
                "md5": "hash",
                "sha1": "hash",
                "sha256": "hash",
                "email": "mail",
                "user": "user-account",
                "process": "filename",
            }
            mapped = type_map.get(ioc_type, "other")
            add(mapped, ioc.value, ["ai-extracted",
                                    f"confidence:{ioc.confidence:.2f}"])

        return observables

    # ---------- observable add ----------

    async def _add_observables(
        self,
        client_base_url: str,
        case_id: str,
        observables: List[Dict[str, Any]],
    ) -> None:
        """Best-effort attach observables to an existing case."""
        async with httpx.AsyncClient(
            timeout=self.timeout, verify=False
        ) as client:
            for obs in observables:
                try:
                    resp = await client.post(
                        f"{client_base_url}/api/v1/case/{case_id}/observable",
                        json=obs,
                        headers=self._headers(),
                    )
                    if resp.status_code not in (200, 201):
                        logger.debug(
                            f"TheHive observable rejected "
                            f"({obs['dataType']}={obs['data']}): "
                            f"HTTP {resp.status_code}"
                        )
                except Exception as e:
                    logger.debug(
                        f"TheHive observable error "
                        f"({obs['dataType']}={obs['data']}): {e}"
                    )
