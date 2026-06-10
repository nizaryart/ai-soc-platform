"""
Ollama LLM Client - Alert Triage Service
AI-Augmented SOC

Handles communication with Ollama API for security alert analysis.
Includes prompt engineering, fallback logic, and structured output parsing.
"""

import json
import logging
from typing import Optional, Dict, Any, List
import httpx
from config import settings
from models import SecurityAlert, TriageResponse, SeverityLevel, AlertCategory, IOC, TriageRecommendation
from ml_client import MLInferenceClient, MLPrediction, enrich_llm_prompt_with_ml
from context_manager import ContextManager

logger = logging.getLogger(__name__)


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
- **File path:** {alert.file_path or 'N/A'}
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

**OUTPUT FORMAT (JSON):**
{{
    "severity": "high",
    "category": "intrusion_attempt",
    "confidence": 0.92,
    "summary": "Brief 1-sentence summary",
    "detailed_analysis": "Technical analysis with evidence",
    "potential_impact": "Business/security impact",
    "is_true_positive": true,
    "false_positive_reason": null,
    "iocs": [
        {{"ioc_type": "ip", "value": "203.0.113.42", "confidence": 0.95}}
    ],
    "mitre_techniques": ["T1110.001"],
    "mitre_tactics": ["TA0006"],
    "recommendations": [
        {{
            "action": "Block source IP at firewall",
            "priority": 1,
            "rationale": "Prevent continued brute force attempts"
        }}
    ],
    "investigation_priority": 2,
    "estimated_analyst_time": 15
}}

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
