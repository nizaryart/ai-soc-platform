"""
Ollama LLM Client - Alert Triage Service
AI-Augmented SOC

Handles communication with Ollama API for security alert analysis.
Includes prompt engineering, fallback logic, and structured output parsing.
"""

import asyncio
import json
import logging
from typing import Optional, Dict, Any, List
import httpx
from config import settings
from models import SecurityAlert, TriageResponse, SeverityLevel, AlertCategory, IOC, TriageRecommendation
from ml_client import MLInferenceClient, MLPrediction, enrich_llm_prompt_with_ml
from context_manager import ContextManager

logger = logging.getLogger(__name__)


# Class-level semaphore: only one Ollama HTTP call may be in flight at a time
# across the entire alert-triage process. Reason: llama3.2:3b on CPU thrashes
# when 2+ requests are interleaved by Ollama — each request slows by ~3-5x,
# blows past the httpx timeout, and triggers fallback retries that pile on
# more in-flight requests, creating a death spiral that requires manual
# container restart to clear. Serializing here keeps each request at its
# normal per-request latency (~30-90s) and stops the spiral at the source.
_OLLAMA_SEMAPHORE = asyncio.Semaphore(1)


# Category normalization map for LLM responses
CATEGORY_ALIASES = {
    "exfiltration": "data_exfiltration",
    "data_theft": "data_exfiltration",
    "privilege_elevation": "privilege_escalation",
    "privesc": "privilege_escalation",
    "lateral": "lateral_movement",
    "c2": "command_and_control",
    "c&c": "command_and_control",
    "recon": "reconnaissance",
    "scanning": "reconnaissance",
    "intrusion": "intrusion_attempt",
    "attack": "intrusion_attempt",
    "policy": "policy_violation",
    "compliance": "policy_violation",
}


def normalize_category(category: str) -> str:
    """Normalize LLM category responses to valid AlertCategory values."""
    category = category.lower().strip()
    # Check aliases first
    if category in CATEGORY_ALIASES:
        return CATEGORY_ALIASES[category]
    # Check if it's a valid category value
    valid_categories = [c.value for c in AlertCategory]
    if category in valid_categories:
        return category
    # Default to 'other' if unknown
    logger.warning(f"Unknown category '{category}', defaulting to 'other'")
    return "other"


class OllamaClient:
    """
    Client for interacting with Ollama LLM API.

    Implements:
    - Security-focused prompt engineering
    - Structured JSON output
    - Model fallback logic
    - Error handling and retries
    """

    def __init__(self):
        self.base_url = settings.ollama_host
        self.primary_model = settings.primary_model
        self.fallback_model = settings.fallback_model
        self.timeout = settings.llm_timeout

        # Initialize ML inference client
        self.ml_client = MLInferenceClient(
            ml_api_url=settings.ml_api_url,
            timeout=settings.ml_timeout,
            enabled=settings.ml_enabled
        )

        # Initialize context manager for Phase 4 contextual memory
        self.context_manager = ContextManager(
            feedback_service_url=settings.feedback_service_url,
            enabled=settings.context_enabled,
            timeout=settings.context_timeout,
            history_limit=settings.context_history_limit,
            environment_context=settings.environment_context,
        )

    async def check_health(self) -> bool:
        """
        Check if Ollama service is reachable.

        Returns:
            bool: True if Ollama is available
        """
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                response = await client.get(f"{self.base_url}/api/tags")
                return response.status_code == 200
        except Exception as e:
            logger.error(f"Ollama health check failed: {e}")
            return False

    def _build_triage_prompt(
        self,
        alert: SecurityAlert,
        context: str = "",
        rag_techniques: Optional[List[str]] = None,
    ) -> str:
        """
        Construct security-focused prompt for alert triage.

        Uses structured prompting with clear instructions for JSON output.
        An optional context block (environment knowledge, alert history,
        analyst feedback) is injected between the system instructions and
        the alert data so the LLM has background knowledge before reading
        the specific alert.

        Args:
            alert:          SecurityAlert object
            context:        Pre-formatted context string from ContextManager.
                            Empty string means no context injection.
            rag_techniques: Optional list of MITRE technique IDs retrieved
                            from the RAG service. Injected into the prompt
                            so the LLM is strongly nudged to include them
                            in its mitre_techniques output. Used as a
                            deterministic fallback (Day 3 Part B) when the
                            LLM omits the field entirely.

        Returns:
            str: Formatted prompt for LLM
        """
        # Build the context separator — only present when context was fetched
        context_section = ""
        if context:
            context_section = f"\n\n**ANALYST CONTEXT (use to inform your assessment):**\n{context}\n\n---\n"

        # Inject RAG-suggested MITRE techniques so the LLM is anchored
        if rag_techniques:
            techniques_csv = ", ".join(rag_techniques)
            context_section += (
                f"\n**SUGGESTED MITRE TECHNIQUES (from threat-intel vector DB):** "
                f"{techniques_csv}\n"
                f"Treat these as strong candidates — include relevant ones in your "
                f"`mitre_techniques` output unless the alert clearly does not match.\n\n---\n"
            )

        sysmon_block = ""
        if alert.sysmon_context:
            lines = [f"  - {k}: {v}" for k, v in alert.sysmon_context.items()]
            sysmon_block = "\n- **Sysmon parent / file context:**\n" + "\n".join(lines)

        prompt = f"""You are an expert cybersecurity analyst performing alert triage for a Security Operations Center (SOC).

**TASK:** Analyze the following security alert and provide a structured assessment.
{context_section}
**ALERT DETAILS:**
- Alert ID: {alert.alert_id}
- Rule: {alert.rule_description} (Level {alert.rule_level})
- Timestamp: {alert.timestamp}
- Source IP: {alert.source_ip or 'N/A'}
- Destination IP: {alert.dest_ip or 'N/A'}
- User: {alert.user or 'N/A'}
- Process: {alert.process or 'N/A'}
- **Command line:** {alert.command or 'N/A'}
- **Decoded command (if -enc / -EncodedCommand was used):** {alert.command_decoded or 'N/A'}
- **File path:** {alert.file_path or 'N/A'}{sysmon_block}
- Raw Log: {(alert.raw_log or 'N/A')[:600]}

**YOUR ANALYSIS MUST INCLUDE:**
1. **Severity Assessment:** Classify as critical/high/medium/low/informational
2. **Category:** Identify attack category (malware, intrusion, exfiltration, etc)
3. **True/False Positive:** Determine if this is a genuine threat
4. **IOC Extraction:** Extract all Indicators of Compromise (IPs, domains, hashes, files)
5. **MITRE ATT&CK:** Map to relevant techniques and tactics. **REQUIRED:** populate the `mitre_techniques` array with at least one technique ID (e.g., "T1110.001"). If unsure, prefer the SUGGESTED techniques above over leaving the field empty
6. **Recommendations:** Provide 3-5 prioritized response actions

**CRITICAL RULES:**
- Base assessment ONLY on provided evidence
- If information is insufficient, state "INSUFFICIENT_DATA"
- Do NOT hallucinate IOCs or details not present in the log
- Provide confidence score (0.0-1.0) for your assessment
- Be concise but thorough

**COMMAND-LINE INTERPRETATION GUIDE (apply when the indicator is present):**
- `-nop` / `-NoProfile` — skips loading PowerShell profile. Common in both admin scripts and malware;
 weak on its own, suspicious when combined with the others.
- `-w hidden` / `-WindowStyle Hidden` — hides the PowerShell console window from the interactive
user. Strong stealth indicator. Maps to MITRE T1564.003 (Hidden Window).
- `-enc` / `-EncodedCommand` — payload is base64(UTF-16LE)-encoded. MITRE T1027 (Obfuscated Files or
Information). When the **Decoded command** is provided above, ground your assessment in the DECODED
contents — the encoding itself is the stealth indicator, the decoded text is what the attacker is
actually running.
- `IEX` / `Invoke-Expression` combined with `DownloadString` / `DownloadFile` / `WebClient` /
`Net.WebRequest` — classic download-and-execute cradle. MITRE T1059.001 + T1105.
- `FromBase64String` — inline base64 decoding in the script body, similar T1027 implication.
- Parent process `winword.exe` / `excel.exe` / `powerpnt.exe` / `outlook.exe` spawning `cmd.exe` /
`powershell.exe` — Office macro execution. MITRE T1566.001 + T1059.

**GROUNDING REQUIREMENT:** when one or more of the indicators above is present in **Command line** or
 **Decoded command**, your `summary` and at least one of your `recommendations.rationale` fields MUST
 explicitly name that indicator (e.g. "-w hidden", "base64-encoded payload `echo Test`", "Office
macro chain"). Generic phrasing like "potential malicious activity" without naming an indicator
counts as a wrong answer.

**OUTPUT FORMAT — JSON only. No markdown, no prose outside the JSON.**

The JSON schema is:
- "severity": "critical" | "high" | "medium" | "low" | "informational"
- "category": "malware" | "intrusion_attempt" | "data_exfiltration" | "privilege_escalation" | "lateral_movement" | "command_and_control" | "reconnaissance" | "policy_violation" | "other"
- "confidence": float 0.0-1.0
- "summary": single sentence summarising THIS specific alert. MUST quote concrete details from ALERT DETAILS above (command line, process, file path, IPs, user, or hashes). Generic phrasing like "potential malicious activity" is forbidden.
- "detailed_analysis": 2-4 sentences citing evidence taken FROM THIS ALERT.
- "potential_impact": 1 sentence on business/security impact.
- "is_true_positive": boolean
- "false_positive_reason": string or null
- "iocs": [ {{"ioc_type": "ip|domain|hash|file|url|email", "value": "...", "confidence": 0.0-1.0}} ]
- "mitre_techniques": [MITRE technique IDs — prefer the SUGGESTED TECHNIQUES above when relevant]
- "mitre_tactics": [MITRE tactic IDs, e.g. "TA0002"]
- "recommendations": [ {{"action": "...", "priority": 1-5, "rationale": "..."}} ] — each rationale MUST reference specific evidence from THIS alert, never generic guidance.
- "investigation_priority": int 1-5
- "estimated_analyst_time": int minutes

**EXAMPLES (FORMAT REFERENCE ONLY — DO NOT COPY THESE VALUES INTO YOUR ANSWER. These are unrelated alerts shown only to illustrate the JSON shape):**

Example 1 — a brute force SSH alert (DIFFERENT alert, do not reuse):
{{
    "severity": "high",
    "category": "intrusion_attempt",
    "confidence": 0.88,
    "summary": "Repeated failed SSH logins from 203.0.113.42 against user root within 60s — consistent with credential brute force.",
    "detailed_analysis": "Source IP 203.0.113.42 attempted 47 SSH logins as user 'root' in 58 seconds. Pattern matches automated credential stuffing.",
    "potential_impact": "If credentials are weak, attacker gains shell access to the SSH host.",
    "is_true_positive": true,
    "false_positive_reason": null,
    "iocs": [{{"ioc_type": "ip", "value": "203.0.113.42", "confidence": 0.95}}],
    "mitre_techniques": ["T1110.001"],
    "mitre_tactics": ["TA0006"],
    "recommendations": [
        {{"action": "Block 203.0.113.42 at edge firewall", "priority": 1, "rationale": "Source IP produced 47 failed root logins in 58s — confirmed hostile."}}
    ],
    "investigation_priority": 2,
    "estimated_analyst_time": 15
}}

Example 2 — a malicious document executing macros (DIFFERENT alert, do not reuse):
{{
    "severity": "critical",
    "category": "malware",
    "confidence": 0.93,
    "summary": "winword.exe spawned cmd.exe which launched powershell.exe downloading payload.exe from 198.51.100.7 — classic phishing payload chain.",
    "detailed_analysis": "Parent process chain winword.exe -> cmd.exe -> powershell.exe with DownloadFile against 198.51.100.7/payload.exe matches T1566.001 macro execution leading to T1105 ingress tool transfer.",
    "potential_impact": "Initial foothold via Office macro; payload may persist via scheduled task or registry run key.",
    "is_true_positive": true,
    "false_positive_reason": null,
    "iocs": [
        {{"ioc_type": "ip", "value": "198.51.100.7", "confidence": 0.9}},
        {{"ioc_type": "url", "value": "http://198.51.100.7/payload.exe", "confidence": 0.9}}
    ],
    "mitre_techniques": ["T1566.001", "T1059.001", "T1105"],
    "mitre_tactics": ["TA0001", "TA0002"],
    "recommendations": [
        {{"action": "Isolate the workstation that ran winword.exe", "priority": 1, "rationale": "Office spawned a downloader chain — host is compromised until verified."}},
        {{"action": "Hunt for payload.exe on disk and in execution history", "priority": 2, "rationale": "URL 198.51.100.7/payload.exe in the command line confirms a dropped binary."}}
    ],
    "investigation_priority": 1,
    "estimated_analyst_time": 30
}}

**REMEMBER:** the two examples above are for SHAPE only. Your JSON must describe the CURRENT alert in ALERT DETAILS, using evidence from THAT alert. If you copy any of the IPs, recommendations, or summaries above verbatim, your answer is WRONG.

Begin your analysis now:"""

        return prompt

    async def _call_ollama(
        self,
        prompt: str,
        model: str,
        temperature: float = 0.1
    ) -> Optional[str]:
        """
        Make API call to Ollama.

        Args:
            prompt: Text prompt
            model: Model identifier
            temperature: Sampling temperature

        Returns:
            Optional[str]: Model response or None on error
        """
        # Serialize Ollama calls across the whole process. See module-level
        # _OLLAMA_SEMAPHORE docstring for rationale.
        async with _OLLAMA_SEMAPHORE:
            queue_wait_done = True  # marker for clarity in profiling later
            try:
                async with httpx.AsyncClient(timeout=self.timeout) as client:
                    payload = {
                        "model": model,
                        "prompt": prompt,
                        "stream": False,
                        "options": {
                            "temperature": temperature,
                            "num_predict": settings.max_tokens,
                        },
                        "format": "json"  # Request JSON output
                    }

                    logger.info(f"Calling Ollama model: {model}")
                    response = await client.post(
                        f"{self.base_url}/api/generate",
                        json=payload
                    )

                    if response.status_code == 200:
                        result = response.json()
                        return result.get("response")
                    else:
                        logger.error(f"Ollama API error: {response.status_code} - {response.text}")
                        return None

            except httpx.TimeoutException:
                logger.error(f"Ollama request timeout after {self.timeout}s")
                return None
            except Exception as e:
                logger.error(f"Ollama API call failed: {e}")
                return None

    def _parse_llm_response(
        self,
        alert: SecurityAlert,
        llm_output: str,
        model_used: str
    ) -> Optional[TriageResponse]:
        """
        Parse LLM JSON output into TriageResponse model.

        Handles malformed JSON, markdown code blocks, and missing fields gracefully.

        Args:
            alert: Original alert
            llm_output: Raw LLM response
            model_used: Model identifier

        Returns:
            Optional[TriageResponse]: Parsed response or None
        """
        try:
            # Extract JSON from markdown code blocks if present
            json_text = llm_output.strip()

            # Handle markdown code blocks: ```json ... ``` or ``` ... ```
            if json_text.startswith("```"):
                # Find the content between ``` markers
                lines = json_text.split("\n")
                # Remove first line (```json or ```) and last line (```)
                json_text = "\n".join(lines[1:-1])

            # Handle inline code: `{...}`
            if json_text.startswith("`") and json_text.endswith("`"):
                json_text = json_text[1:-1]

            parsed = json.loads(json_text)

            # Map parsed data to Pydantic model
            response = TriageResponse(
                alert_id=alert.alert_id,
                severity=SeverityLevel(parsed.get("severity", "medium")),
                category=AlertCategory(normalize_category(parsed.get("category", "other"))),
                confidence=float(parsed.get("confidence", 0.5)),
                summary=parsed.get("summary", "No summary provided"),
                detailed_analysis=parsed.get("detailed_analysis", ""),
                potential_impact=parsed.get("potential_impact", ""),
                is_true_positive=parsed.get("is_true_positive", True),
                false_positive_reason=parsed.get("false_positive_reason"),
                iocs=[IOC(**ioc) for ioc in parsed.get("iocs", [])],
                mitre_techniques=parsed.get("mitre_techniques", []),
                mitre_tactics=parsed.get("mitre_tactics", []),
                recommendations=[
                    TriageRecommendation(**rec)
                    for rec in parsed.get("recommendations", [])
                ],
                investigation_priority=int(parsed.get("investigation_priority", 3)),
                estimated_analyst_time=parsed.get("estimated_analyst_time"),
                model_used=model_used
            )

            return response

        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse LLM JSON output: {e}")
            logger.debug(f"Raw output: {llm_output[:500]}")
            return None
        except Exception as e:
            logger.error(f"Error constructing TriageResponse: {e}")
            return None

    async def _fetch_rag_mitre(self, alert: SecurityAlert) -> List[str]:
        """
        Query the rag-service for MITRE technique IDs relevant to this alert.

        Used in two places:
          1. Prompt injection — gives the LLM strong candidates to consider
          2. Deterministic fallback — if the LLM still omits mitre_techniques,
             we populate the field from RAG so the TheHive case never has
             an empty MITRE tags list (Day 3 Part B).

        Silent failure: returns empty list if RAG is disabled, unreachable,
        or returns unexpected shape. Never blocks triage.

        Args:
            alert: SecurityAlert being analyzed

        Returns:
            List[str]: Deduplicated MITRE technique IDs (e.g. ["T1110.001"]).
        """
        if not settings.rag_enabled:
            return []

        # Build search query from the most discriminative alert fields
        query_parts = [alert.rule_description or ""]
        if alert.source_ip:
            query_parts.append(f"from {alert.source_ip}")
        if alert.user:
            query_parts.append(f"user {alert.user}")
        if alert.mitre_technique:
            query_parts.extend([f"MITRE {t}" for t in alert.mitre_technique])
        query = " ".join(p for p in query_parts if p).strip()

        if not query:
            return []

        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                response = await client.post(
                    f"{settings.rag_service_url}/retrieve",
                    json={
                        "query": query,
                        "collection": "mitre_attack",
                        "top_k": settings.rag_top_k,
                        "min_similarity": 0.5,
                    },
                )

            if response.status_code != 200:
                logger.debug(
                    f"RAG returned {response.status_code} for alert {alert.alert_id}"
                )
                return []

            data = response.json()
            techniques: List[str] = []
            for r in data.get("results", []):
                tid = (r.get("metadata") or {}).get("technique_id")
                if tid:
                    techniques.append(tid)

            # Dedupe while preserving the (relevance-ranked) order
            seen = set()
            deduped = []
            for t in techniques:
                if t not in seen:
                    seen.add(t)
                    deduped.append(t)

            if deduped:
                logger.info(
                    f"RAG retrieved {len(deduped)} MITRE techniques for "
                    f"alert {alert.alert_id}: {deduped}"
                )
            return deduped

        except httpx.TimeoutException:
            logger.debug(f"RAG timeout for alert {alert.alert_id}")
            return []
        except Exception as e:
            logger.debug(f"RAG fetch failed for alert {alert.alert_id}: {e}")
            return []

    async def analyze_alert(self, alert: SecurityAlert) -> Optional[TriageResponse]:
        """
        Main entrypoint: Analyze security alert using LLM with ML enhancement.

        Workflow:
        1. Attempt ML prediction for additional context
        2. Fetch contextual memory (environment, alert history, analyst feedback)
        2.5 Fetch MITRE techniques from RAG (Day 3 Part B fallback)
        3. Inject context + RAG techniques into base prompt, then enrich with ML signal
        4. Try primary model (Foundation-Sec-8B)
        5. Fall back to secondary model (LLaMA 3.1) if primary fails
        6. Backfill mitre_techniques from RAG if LLM omitted them
        7. Return None if all models failed

        Args:
            alert: SecurityAlert to analyze

        Returns:
            Optional[TriageResponse]: Analysis result or None
        """
        # Step 1: Get ML prediction (if available)
        ml_prediction = None
        if settings.ml_enabled:
            logger.debug("Attempting ML prediction...")
            ml_prediction = await self.ml_client.predict_with_fallback(alert)
            if ml_prediction:
                logger.info(
                    f"ML prediction: {ml_prediction.prediction} "
                    f"(confidence={ml_prediction.confidence:.2f})"
                )

        # Step 2: Fetch contextual memory and inject into base prompt
        context_block = await self.context_manager.build_context(alert)

        # Step 2.5: Fetch MITRE techniques from RAG service. Used for prompt
        # injection AND as deterministic fallback if the LLM omits the field.
        rag_techniques = await self._fetch_rag_mitre(alert)

        base_prompt = self._build_triage_prompt(
            alert,
            context=context_block,
            rag_techniques=rag_techniques,
        )

        # Step 3: Enrich with ML prediction signal
        enriched_prompt = enrich_llm_prompt_with_ml(base_prompt, ml_prediction)

        # Step 4: Try primary model
        logger.info(f"Analyzing alert {alert.alert_id} with {self.primary_model}")
        llm_output = await self._call_ollama(
            enriched_prompt,
            self.primary_model,
            settings.llm_temperature
        )

        if llm_output:
            response = self._parse_llm_response(alert, llm_output, self.primary_model)
            if response:
                # Add ML metadata to response
                if ml_prediction:
                    response.ml_prediction = ml_prediction.prediction
                    response.ml_confidence = ml_prediction.confidence
                # Day 3 Part B: backfill mitre_techniques from RAG if LLM omitted
                if not response.mitre_techniques and rag_techniques:
                    response.mitre_techniques = rag_techniques
                    logger.info(
                        f"Backfilled mitre_techniques from RAG for "
                        f"{alert.alert_id}: {rag_techniques}"
                    )
                logger.info(f"Alert {alert.alert_id} analyzed successfully")
                return response

        # Step 5: Fallback to secondary model
        logger.warning(f"Primary model failed, trying fallback: {self.fallback_model}")
        llm_output = await self._call_ollama(
            enriched_prompt,
            self.fallback_model,
            settings.llm_temperature
        )

        if llm_output:
            response = self._parse_llm_response(alert, llm_output, self.fallback_model)
            if response:
                # Add ML metadata to response
                if ml_prediction:
                    response.ml_prediction = ml_prediction.prediction
                    response.ml_confidence = ml_prediction.confidence
                # Day 3 Part B: backfill mitre_techniques from RAG if LLM omitted
                if not response.mitre_techniques and rag_techniques:
                    response.mitre_techniques = rag_techniques
                    logger.info(
                        f"Backfilled mitre_techniques from RAG for "
                        f"{alert.alert_id}: {rag_techniques}"
                    )
                logger.info(f"Alert {alert.alert_id} analyzed with fallback model")
                return response

        # Both models failed
        logger.error(f"Failed to analyze alert {alert.alert_id} with all models")
        return None


# TODO: Week 5 - Add RAG integration
# class RAGEnhancedClient(OllamaClient):
#     """Extended client with RAG capabilities"""
#     async def get_rag_context(self, alert: SecurityAlert) -> str:
#         """Query RAG service for relevant context"""
#         pass
