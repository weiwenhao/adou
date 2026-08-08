#!/usr/bin/env python3
"""Generate Nature model catalogs from Pi's generator semantics.

Port of vendors/pi/packages/ai/scripts/generate-models.ts (Pi 0.82.1,
commit cced6a2) applied to live upstream data:

  - https://models.dev/api.json
  - https://openrouter.ai/api/v1/models
  - https://ai-gateway.vercel.sh/v1/models
  - NVIDIA NIM /models (best effort, skipped when unreachable)

Emits one file per provider under src/ai/providers/<provider>_models.n
containing `fn models(): [ref<types.model_t>]`.

Only data that Adou consumes is emitted: id/name/api/provider/base_url/
reasoning/context_window/max_tokens/cost(+tiers)/thinking_level_map/headers.
Pi's compat flags are request-builder behavior and are intentionally not
emitted. thinking_level_map null (unsupported level) is encoded as ''.

Usage: python3 scripts/generate-model-catalog.py [--data PATH]
"""

import json
import math
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "src" / "ai" / "providers"

MODELS_DEV_URL = "https://models.dev/api.json"
OPENROUTER_URL = "https://openrouter.ai/api/v1/models"
AI_GATEWAY_URL = "https://ai-gateway.vercel.sh/v1/models"
NVIDIA_URL = "https://integrate.api.nvidia.com/v1/models"

VERTEX_BASE_URL = "https://{location}-aiplatform.googleapis.com"
NVIDIA_BASE_URL = "https://integrate.api.nvidia.com/v1"
NVIDIA_HEADERS = {"NVCF-POLL-SECONDS": "3600"}
TOGETHER_BASE_URL = "https://api.together.ai/v1"
AI_GATEWAY_BASE_URL = "https://ai-gateway.vercel.sh"
CODEX_BASE_URL = "https://chatgpt.com/backend-api"
CODEX_CONTEXT = 272000
CODEX_GPT_56_CONTEXT = 272000
CODEX_SPARK_CONTEXT = 128000
CODEX_MAX_TOKENS = 128000
OPENAI_LONG_CONTEXT_INPUT_THRESHOLD = 272000
KIMI_K3_MAX_TOKENS = 131072
KIMI_K3_COST = {"input": 3, "output": 15, "cacheRead": 0.3, "cacheWrite": 0}
CLOUDFLARE_WORKERS_AI_BASE_URL = "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1"
CLOUDFLARE_AI_GATEWAY_COMPAT_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/compat"
CLOUDFLARE_AI_GATEWAY_OPENAI_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/openai"
CLOUDFLARE_AI_GATEWAY_ANTHROPIC_BASE_URL = "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}/anthropic"

COPILOT_STATIC_HEADERS = {
    "User-Agent": "GitHubCopilotChat/0.35.0",
    "Editor-Version": "vscode/1.107.0",
    "Editor-Plugin-Version": "copilot-chat/0.35.0",
    "Copilot-Integration-Id": "vscode-chat",
}
KIMI_STATIC_HEADERS = {"User-Agent": "KimiCLI/1.5"}

NVIDIA_OPENAI_COMPAT = {
    "supportsStore": False,
    "supportsDeveloperRole": False,
    "supportsReasoningEffort": False,
    "maxTokensField": "max_tokens",
    "supportsStrictMode": False,
    "supportsLongCacheRetention": False,
}

NVIDIA_NIM_UNSUPPORTED_MODELS = {
    "abacusai/dracarys-llama-3.1-70b-instruct",
    "bytedance/seed-oss-36b-instruct",
    "deepseek-ai/deepseek-v4-flash",
    "deepseek-ai/deepseek-v4-pro",
    "google/gemma-2-2b-it",
    "google/gemma-3n-e2b-it",
    "google/gemma-3n-e4b-it",
    "google/gemma-4-31b-it",
    "meta/llama-3.2-1b-instruct",
    "meta/llama-4-maverick-17b-128e-instruct",
    "microsoft/phi-4-mini-instruct",
    "minimaxai/minimax-m2.7",
    "mistralai/mistral-nemotron",
    "nvidia/nemotron-mini-4b-instruct",
    "qwen/qwen3-next-80b-a3b-instruct",
    "qwen/qwen3.5-397b-a17b",
    "sarvamai/sarvam-m",
    "upstage/solar-10.7b-instruct",
}

ZAI_TOOL_STREAM_UNSUPPORTED_MODELS = {"glm-4.5", "glm-4.5-air", "glm-4.5-flash", "glm-4.5v"}
ZAI_GLM52_THINKING_LEVEL_MAP = {"minimal": None, "low": "high", "medium": "high", "high": "high", "max": "max"}
OPENCODE_GO_GLM52_THINKING_LEVEL_MAP = {"off": None, "minimal": None, "low": None, "medium": None, "high": "high", "max": "max"}
EAGER_TOOL_INPUT_STREAMING_UNSUPPORTED_ANTHROPIC_MODELS = {
    "github-copilot:claude-haiku-4.5",
    "github-copilot:claude-sonnet-4",
    "github-copilot:claude-sonnet-4.5",
}
DEEPSEEK_V4_THINKING_LEVEL_MAP = {"minimal": None, "low": None, "medium": None, "high": "high", "max": "max"}
ANT_LING_RING_THINKING_LEVEL_MAP = {"off": None, "minimal": None, "low": None, "medium": None, "high": "high", "xhigh": "xhigh"}
BEDROCK_INFERENCE_PROFILE_ONLY_MODEL_IDS = {"anthropic.claude-opus-5"}
MODELS_DEV_OPENAI_UNSUPPORTED_MODEL_IDS = {"gpt-5.6"}
OPENAI_TOOL_SEARCH_MODEL_IDS = {"gpt-5.4", "gpt-5.4-mini", "gpt-5.4-pro", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"}
OPENAI_SHORT_CONTEXT_CAPPED_MODEL_IDS = {"gpt-5.4", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"}
OPENAI_LONG_CONTEXT_PRICING_MODEL_IDS = {"gpt-5.4", "gpt-5.4-pro", "gpt-5.5", "gpt-5.5-pro", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"}
OPENAI_RESPONSES_NONE_REASONING_MODELS = {"gpt-5.1", "gpt-5.2", "gpt-5.3-codex", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"}
XAI_RESPONSES_MODEL_ID = "grok-4.5"
XAI_BUILTIN_EXCLUDED_MODEL_IDS = {"grok-3", "grok-3-fast", "grok-4.20-0309-non-reasoning", "grok-4.20-0309-reasoning", "grok-code-fast-1"}
XAI_RESPONSES_EFFORT_LEVEL_MAP = {"off": None, "minimal": None}
XAI_RESPONSES_COMPAT = {"supportsLongCacheRetention": False}
OPENCODE_OPENAI_COMPLETIONS_LONG_CACHE_RETENTION_UNSUPPORTED_MODELS = {
    "opencode:deepseek-v4-flash",
    "opencode:deepseek-v4-pro",
    "opencode:kimi-k2.5",
    "opencode:kimi-k2.6",
    "opencode:minimax-m2.7",
    "opencode-go:kimi-k2.6",
}
GITHUB_COPILOT_EXTENDED_CONTEXT_MODELS = {
    "claude-fable-5",
    "claude-opus-4.6",
    "claude-opus-4.7",
    "claude-opus-4.8",
    "claude-opus-5",
    "claude-sonnet-4.6",
    "claude-sonnet-5",
    "gpt-5.3-codex",
    "gpt-5.4",
    "gpt-5.5",
}
GITHUB_COPILOT_THINKING_LEVEL_OVERRIDES = {
    "claude-opus-4.7": {"minimal": "low"},
    "claude-opus-4.8": {"minimal": "low"},
    "claude-opus-5": {"minimal": "low"},
    "claude-sonnet-4.6": {"minimal": "low", "max": "max"},
}
OPENAI_GRAMMAR_TOOL_PROVIDERS = {"openai", "openai-codex", "azure-openai-responses", "github-copilot", "opencode", "cloudflare-ai-gateway"}
OPENAI_GRAMMAR_TOOL_APIS = {"openai-responses", "azure-openai-responses", "openai-codex-responses"}
AZURE_CONTEXT_WINDOW_OVERRIDES = {"gpt-5.4": 1050000, "gpt-5.5": 1050000, "gpt-5.6-luna": 1050000, "gpt-5.6-sol": 1050000, "gpt-5.6-terra": 1050000}
OPENROUTER_KIMI_K3_MODEL_IDS = {"moonshotai/kimi-k3", "~moonshotai/kimi-latest"}
KIMI_CODING_IMPLIED_COSTS = {
    "k3": KIMI_K3_COST,
    "kimi-for-coding": {"input": 0.95, "output": 4, "cacheRead": 0.19, "cacheWrite": 0},
    "kimi-for-coding-highspeed": {"input": 1.9, "output": 8, "cacheRead": 0.38, "cacheWrite": 0},
    "kimi-k2-thinking": {"input": 0.6, "output": 2.5, "cacheRead": 0.15, "cacheWrite": 0},
}
MINIMAX_DIRECT_SUPPORTED_IDS = {"MiniMax-M2.7", "MiniMax-M2.7-highspeed", "MiniMax-M3"}

TOGETHER_REASONING_ONLY_MODELS = {"deepseek-ai/DeepSeek-R1", "MiniMaxAI/MiniMax-M2.7"}
TOGETHER_REASONING_EFFORT_MODELS = {"openai/gpt-oss-20b", "openai/gpt-oss-120b"}
TOGETHER_TOGGLE_REASONING_EFFORT_MODELS = {"deepseek-ai/DeepSeek-V4-Pro"}
TOGETHER_BASE_COMPAT = {"supportsStore": False, "supportsDeveloperRole": False, "supportsReasoningEffort": False, "maxTokensField": "max_tokens", "supportsStrictMode": False, "supportsLongCacheRetention": False}
TOGETHER_TOGGLE_REASONING_COMPAT = dict(TOGETHER_BASE_COMPAT, thinkingFormat="together")
TOGETHER_REASONING_EFFORT_COMPAT = dict(TOGETHER_BASE_COMPAT, supportsReasoningEffort=True, thinkingFormat="openai")
TOGETHER_TOGGLE_REASONING_EFFORT_COMPAT = dict(TOGETHER_TOGGLE_REASONING_COMPAT, supportsReasoningEffort=True)
TOGETHER_FIXED_REASONING_LEVEL_MAP = {"off": None, "minimal": None, "low": None, "medium": None}
TOGETHER_REASONING_EFFORT_LEVEL_MAP = {"off": None, "minimal": None}
TOGETHER_DEEPSEEK_V4_THINKING_LEVEL_MAP = {"minimal": None, "low": None, "medium": None, "high": "high", "xhigh": None}
TOGETHER_TOGGLE_REASONING_LEVEL_MAP = {"minimal": None, "low": None, "medium": None}

MOONSHOT_COMPAT = {
    "supportsStore": False,
    "supportsDeveloperRole": False,
    "supportsReasoningEffort": False,
    "maxTokensField": "max_tokens",
    "supportsStrictMode": False,
    "thinkingFormat": "deepseek",
}
XIAOMI_COMPAT = {"requiresReasoningContentOnAssistantMessages": True, "thinkingFormat": "deepseek"}
QWEN_TOKEN_PLAN_COMPAT = {"thinkingFormat": "qwen", "supportsDeveloperRole": False, "supportsStore": False}
DEEPSEEK_COMPAT = {"requiresReasoningContentOnAssistantMessages": True, "thinkingFormat": "deepseek"}
ANT_LING_COMPAT = {"supportsStore": False, "supportsDeveloperRole": False, "supportsReasoningEffort": False, "maxTokensField": "max_tokens", "supportsLongCacheRetention": False}

OPENAI_COMPLETIONS_DEFAULT_COMPAT = {
    "supportsStore": True,
    "supportsDeveloperRole": True,
    "supportsReasoningEffort": True,
    "supportsUsageInStreaming": True,
    "maxTokensField": "max_completion_tokens",
    "requiresToolResultName": False,
    "requiresAssistantAfterToolResult": False,
    "requiresThinkingAsText": False,
    "requiresReasoningContentOnAssistantMessages": False,
    "thinkingFormat": "openai",
    "openRouterRouting": {},
    "vercelGatewayRouting": {},
    "chatTemplateKwargs": {},
    "zaiToolStream": False,
    "supportsStrictMode": True,
    "supportsOpenAIGrammarTools": False,
    "sendSessionAffinityHeaders": False,
    "supportsLongCacheRetention": True,
}

THINKING_LEVELS = ["minimal", "low", "medium", "high", "xhigh", "max"]


def round_cost(value: float) -> float:
    return round(value, 6)


def get_effort_thinking_level_map(options):
    effort_values = [v for o in options if o.get("type") == "effort" for v in o.get("values", [])]
    if not effort_values:
        return None
    supported = set(effort_values)
    if not any(level in supported for level in THINKING_LEVELS) and "none" not in supported:
        return None
    mapping = {"off": "none" if "none" in supported else None}
    for level in THINKING_LEVELS:
        mapping[level] = level if level in supported else None
    return mapping


def get_models_dev_cost(cost):
    tiers = []
    for tier in (cost or {}).get("tiers") or []:
        context = tier.get("tier") or {}
        if context.get("type") != "context" or context.get("size") is None:
            continue
        tiers.append({
            "inputTokensAbove": context["size"],
            "input": tier.get("input") or 0,
            "output": tier.get("output") or 0,
            "cacheRead": tier.get("cache_read") or 0,
            "cacheWrite": tier.get("cache_write") or 0,
        })
    result = {
        "input": (cost or {}).get("input") or 0,
        "output": (cost or {}).get("output") or 0,
        "cacheRead": (cost or {}).get("cache_read") or 0,
        "cacheWrite": (cost or {}).get("cache_write") or 0,
    }
    if tiers:
        result["tiers"] = tiers
    return result


def with_openai_long_context_pricing(cost):
    return {
        **cost,
        "tiers": [{
            "inputTokensAbove": OPENAI_LONG_CONTEXT_INPUT_THRESHOLD,
            "input": cost.get("input", 0) * 2,
            "output": cost.get("output", 0) * 1.5,
            "cacheRead": cost.get("cacheRead", 0) * 2,
            "cacheWrite": cost.get("cacheWrite", 0) * 2,
        }],
    }


def get_together_compat(model_id, reasoning):
    if not reasoning:
        return TOGETHER_BASE_COMPAT
    if model_id in TOGETHER_REASONING_EFFORT_MODELS:
        return TOGETHER_REASONING_EFFORT_COMPAT
    if model_id in TOGETHER_TOGGLE_REASONING_EFFORT_MODELS:
        return TOGETHER_TOGGLE_REASONING_EFFORT_COMPAT
    if model_id in TOGETHER_REASONING_ONLY_MODELS:
        return TOGETHER_BASE_COMPAT
    return TOGETHER_TOGGLE_REASONING_COMPAT


def get_together_thinking_level_map(model_id, reasoning):
    if not reasoning:
        return None
    if model_id in TOGETHER_REASONING_EFFORT_MODELS:
        return dict(TOGETHER_REASONING_EFFORT_LEVEL_MAP)
    if model_id in TOGETHER_TOGGLE_REASONING_EFFORT_MODELS:
        return dict(TOGETHER_DEEPSEEK_V4_THINKING_LEVEL_MAP)
    if model_id in TOGETHER_REASONING_ONLY_MODELS:
        return dict(TOGETHER_FIXED_REASONING_LEVEL_MAP)
    return dict(TOGETHER_TOGGLE_REASONING_LEVEL_MAP)


def get_bedrock_base_url(model_id):
    return "https://bedrock-runtime.eu-central-1.amazonaws.com" if model_id.startswith("eu.") else "https://bedrock-runtime.us-east-1.amazonaws.com"


def normalize_nvidia_model_id(model_id):
    return model_id.lower().replace("_", ".")


def supports_openai_xhigh(model_id):
    return any(marker in model_id for marker in ["gpt-5.2", "gpt-5.3", "gpt-5.4", "gpt-5.5", "gpt-5.6"])


def supports_openai_max(model):
    return "gpt-5.6" in model["id"] and model["api"] in ("openai-responses", "azure-openai-responses", "openai-codex-responses", "openai-completions")


def is_anthropic_adaptive_thinking_model(model_id):
    return any(marker in model_id for marker in [
        "opus-4-6", "opus-4.6", "opus-4-7", "opus-4.7", "opus-4-8", "opus-4.8",
        "opus-5", "opus.5", "sonnet-4-6", "sonnet-4.6", "sonnet-5", "sonnet.5", "fable-5",
    ])


def is_anthropic_temperature_unsupported_model(model_id):
    lower = model_id.lower()
    return any(marker in lower for marker in ["opus-4-7", "opus-4.7", "opus-4-8", "opus-4.8", "opus-5", "opus.5"])


def get_anthropic_messages_compat(provider, model_id):
    compat = {}
    key = f"{provider}:{model_id}"
    if key in EAGER_TOOL_INPUT_STREAMING_UNSUPPORTED_ANTHROPIC_MODELS:
        compat["supportsEagerToolInputStreaming"] = False
    if provider == "xiaomi" or provider.startswith("xiaomi-token-plan-"):
        compat["allowEmptySignature"] = True
    return compat if compat else None


def detect_openai_completions_compat(model):
    provider = model["provider"]
    base_url = model["baseUrl"]
    is_zai = provider in ("zai", "zai-coding-cn") or "api.z.ai" in base_url or "open.bigmodel.cn" in base_url
    is_together = provider == "together" or "api.together.ai" in base_url or "api.together.xyz" in base_url
    is_moonshot = provider in ("moonshotai", "moonshotai-cn") or "api.moonshot." in base_url
    is_openrouter = provider == "openrouter" or "openrouter.ai" in base_url
    is_cloudflare_workers_ai = provider == "cloudflare-workers-ai" or "api.cloudflare.com" in base_url
    is_cloudflare_ai_gateway = provider == "cloudflare-ai-gateway" or "gateway.ai.cloudflare.com" in base_url
    is_nvidia = provider == "nvidia" or "integrate.api.nvidia.com" in base_url
    is_ant_ling = provider == "ant-ling" or "api.ant-ling.com" in base_url
    is_together_reasoning_only = is_together and model["id"] in TOGETHER_REASONING_ONLY_MODELS

    is_non_standard = (
        is_nvidia
        or provider == "cerebras"
        or "cerebras.ai" in base_url
        or provider == "xai"
        or "api.x.ai" in base_url
        or is_together
        or "chutes.ai" in base_url
        or "deepseek.com" in base_url
        or is_zai
        or is_moonshot
        or provider == "opencode"
        or "opencode.ai" in base_url
        or is_cloudflare_workers_ai
        or is_cloudflare_ai_gateway
        or is_ant_ling
    )
    use_max_tokens = (
        "chutes.ai" in base_url or is_moonshot or is_cloudflare_ai_gateway or is_together or is_nvidia or is_ant_ling or is_zai
    )
    is_grok = provider == "xai" or "api.x.ai" in base_url
    is_deep_seek = provider == "deepseek" or "deepseek.com" in base_url
    is_openrouter_developer_role_model = is_openrouter and (model["id"].startswith("anthropic/") or model["id"].startswith("openai/"))
    cache_control_format = "anthropic" if (provider == "openrouter" and re.match(r"^~?anthropic/", model["id"])) else None

    if is_deep_seek:
        thinking_format = "deepseek"
    elif is_zai:
        thinking_format = "zai"
    elif is_together and not is_together_reasoning_only:
        thinking_format = "together"
    elif is_ant_ling:
        thinking_format = "ant-ling"
    elif is_openrouter:
        thinking_format = "openrouter"
    else:
        thinking_format = "openai"

    compat = {
        "supportsStore": not is_non_standard,
        "supportsDeveloperRole": is_openrouter_developer_role_model or (not is_non_standard and not is_openrouter),
        "supportsReasoningEffort": not (is_grok or is_zai or is_moonshot or is_together or is_cloudflare_ai_gateway or is_nvidia or is_ant_ling),
        "supportsUsageInStreaming": True,
        "maxTokensField": "max_tokens" if use_max_tokens else "max_completion_tokens",
        "requiresToolResultName": False,
        "requiresAssistantAfterToolResult": False,
        "requiresThinkingAsText": False,
        "requiresReasoningContentOnAssistantMessages": is_deep_seek,
        "thinkingFormat": thinking_format,
        "openRouterRouting": {},
        "vercelGatewayRouting": {},
        "chatTemplateKwargs": {},
        "zaiToolStream": False,
        "supportsStrictMode": not (is_moonshot or is_together or is_cloudflare_ai_gateway or is_nvidia),
        "supportsOpenAIGrammarTools": False,
        "sendSessionAffinityHeaders": False,
        "supportsLongCacheRetention": not (is_together or is_cloudflare_workers_ai or is_cloudflare_ai_gateway or is_nvidia or is_ant_ling),
    }
    if cache_control_format:
        compat["cacheControlFormat"] = cache_control_format
    return compat


def is_plain_empty_object(value):
    return isinstance(value, dict) and len(value) == 0


def openai_completions_compat_delta(compat):
    delta = {}
    for key, value in compat.items():
        default_value = OPENAI_COMPLETIONS_DEFAULT_COMPAT.get(key)
        if default_value is None:
            delta[key] = value
            continue
        if is_plain_empty_object(value) and is_plain_empty_object(default_value):
            continue
        if value != default_value:
            delta[key] = value
    return delta


def supports_direct_reasoning_effort(model):
    if model["api"] == "anthropic-messages":
        return bool((model.get("compat") or {}).get("forceAdaptiveThinking"))
    if model["api"] in ("openai-responses", "azure-openai-responses", "openai-codex-responses"):
        return True
    if model["api"] != "openai-completions":
        return False
    detected = detect_openai_completions_compat(model)
    compat = {**detected, **(model.get("compat") or {})}
    return compat.get("thinkingFormat") == "openai" and compat.get("supportsReasoningEffort")


def fetch_json(url, timeout=30):
    request = urllib.request.Request(url, headers={"User-Agent": "adou-model-catalog-generator/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_models_dev(path=None):
    if path:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return fetch_json(MODELS_DEV_URL)


def fetch_nvidia_nim_ids():
    try:
        data = fetch_json(NVIDIA_URL)
        return {item["id"] for item in data.get("data", [])}
    except Exception:
        return None


def fetch_openrouter_models():
    try:
        data = fetch_json(OPENROUTER_URL)
    except Exception as error:
        print(f"warning: openrouter fetch failed: {error}", file=sys.stderr)
        return []
    models = []
    for model in data.get("data", []):
        supported = model.get("supported_parameters") or []
        if "tools" not in supported:
            continue
        input_modality = ["text"]
        architecture = model.get("architecture") or {}
        if "image" in (architecture.get("modality") or []):
            input_modality.append("image")
        pricing = model.get("pricing") or {}
        top_provider = model.get("top_provider") or {}
        models.append({
            "id": model["id"],
            "name": model.get("name") or model["id"],
            "api": "openai-completions",
            "baseUrl": "https://openrouter.ai/api/v1",
            "provider": "openrouter",
            "reasoning": "reasoning" in supported,
            "input": input_modality,
            "cost": {
                "input": round_cost(float(pricing.get("prompt") or 0) * 1_000_000),
                "output": round_cost(float(pricing.get("completion") or 0) * 1_000_000),
                "cacheRead": round_cost(float(pricing.get("input_cache_read") or 0) * 1_000_000),
                "cacheWrite": round_cost(float(pricing.get("input_cache_write") or 0) * 1_000_000),
            },
            "contextWindow": top_provider.get("context_length") or model.get("context_length") or 4096,
            "maxTokens": top_provider.get("max_completion_tokens") or 4096,
        })
    print(f"fetched {len(models)} tool-capable models from OpenRouter")
    return models


def fetch_ai_gateway_models():
    try:
        data = fetch_json(AI_GATEWAY_URL)
    except Exception as error:
        print(f"warning: vercel ai gateway fetch failed: {error}", file=sys.stderr)
        return []
    models = []
    for model in data.get("data", []):
        tags = model.get("tags") or []
        if "tool-use" not in tags:
            continue
        input_modality = ["text"]
        if "vision" in tags:
            input_modality.append("image")
        pricing = model.get("pricing") or {}

        def to_number(value):
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                return float(value) if math.isfinite(float(value)) else 0.0
            try:
                parsed = float(value or 0)
            except (TypeError, ValueError):
                parsed = 0.0
            return parsed if math.isfinite(parsed) else 0.0

        models.append({
            "id": model["id"],
            "name": model.get("name") or model["id"],
            "api": "anthropic-messages",
            "baseUrl": AI_GATEWAY_BASE_URL,
            "provider": "vercel-ai-gateway",
            "reasoning": "reasoning" in tags,
            "input": input_modality,
            "cost": {
                "input": round_cost(to_number(pricing.get("input")) * 1_000_000),
                "output": round_cost(to_number(pricing.get("output")) * 1_000_000),
                "cacheRead": round_cost(to_number(pricing.get("input_cache_read")) * 1_000_000),
                "cacheWrite": round_cost(to_number(pricing.get("input_cache_write")) * 1_000_000),
            },
            "contextWindow": model.get("context_window") or 4096,
            "maxTokens": model.get("max_tokens") or 4096,
        })
    print(f"fetched {len(models)} tool-capable models from Vercel AI Gateway")
    return models


def load_models_dev_models(data, nvidia_nim_ids):
    models = []

    def base_model(provider_id, model_id, m, api, base_url, reasoning=None, cost_override=None, context_override=None, max_tokens_override=None, compat=None, headers=None):
        model = {
            "id": model_id,
            "name": m.get("name") or model_id,
            "api": api,
            "provider": provider_id,
            "baseUrl": base_url,
            "reasoning": m.get("reasoning") is True if reasoning is None else reasoning,
            "input": ["text", "image"] if (m.get("modalities") or {}).get("input", []).__contains__("image") else ["text"],
            "cost": get_models_dev_cost(m.get("cost")) if cost_override is None else cost_override,
            "contextWindow": (m.get("limit") or {}).get("context") or 4096 if context_override is None else context_override,
            "maxTokens": (m.get("limit") or {}).get("output") or 4096 if max_tokens_override is None else max_tokens_override,
        }
        if compat:
            model["compat"] = compat
        if headers:
            model["headers"] = headers
        return model

    # amazon-bedrock
    if data.get("amazon-bedrock", {}).get("models"):
        for model_id, m in data["amazon-bedrock"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            if model_id in BEDROCK_INFERENCE_PROFILE_ONLY_MODEL_IDS:
                continue
            if model_id.startswith("ai21.jamba"):
                continue
            if model_id.startswith("mistral.mistral-7b-instruct-v0"):
                continue
            model = base_model("amazon-bedrock", model_id, m, "bedrock-converse-stream", get_bedrock_base_url(model_id))
            if m.get("structured_output") is True:
                model["compat"] = {"supportsStrictMode": True}
            models.append(model)

    # anthropic
    if data.get("anthropic", {}).get("models"):
        for model_id, m in data["anthropic"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            models.append(base_model("anthropic", model_id, m, "anthropic-messages", "https://api.anthropic.com"))

    # google
    if data.get("google", {}).get("models"):
        for model_id, m in data["google"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            source = m
            if model_id == "gemini-flash-latest":
                source = data["google"]["models"].get("gemini-3.5-flash") or m
            if model_id == "gemini-flash-lite-latest":
                source = data["google"]["models"].get("gemini-3.1-flash-lite") or m
            models.append(base_model("google", model_id, m, "google-generative-ai", "https://generativelanguage.googleapis.com/v1beta", reasoning=source.get("reasoning") is True, cost_override=get_models_dev_cost(source.get("cost")), context_override=(source.get("limit") or {}).get("context") or 4096, max_tokens_override=(source.get("limit") or {}).get("output") or 4096))

    # google-vertex
    if data.get("google-vertex", {}).get("models"):
        for model_id, m in data["google-vertex"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            if not model_id.startswith("gemini-"):
                continue
            if model_id == "gemini-3.1-flash-lite-preview":
                continue
            source = m
            if model_id == "gemini-flash-latest":
                source = data["google-vertex"]["models"].get("gemini-3.5-flash") or m
            if model_id == "gemini-flash-lite-latest":
                source = data["google-vertex"]["models"].get("gemini-3.1-flash-lite") or m
            cache_read = 0.03 if model_id == "gemini-2.5-flash" else (source.get("cost") or {}).get("cache_read") or 0
            cost = get_models_dev_cost(source.get("cost"))
            cost["cacheRead"] = cache_read
            cost["cacheWrite"] = 0
            models.append(base_model("google-vertex", model_id, m, "google-vertex", VERTEX_BASE_URL, reasoning=source.get("reasoning") is True, cost_override=cost, context_override=(source.get("limit") or {}).get("context") or 4096, max_tokens_override=(source.get("limit") or {}).get("output") or 4096))

    # openai
    if data.get("openai", {}).get("models"):
        for model_id, m in data["openai"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            if model_id in MODELS_DEV_OPENAI_UNSUPPORTED_MODEL_IDS:
                continue
            models.append(base_model("openai", model_id, m, "openai-responses", "https://api.openai.com/v1"))

    # groq
    if data.get("groq", {}).get("models"):
        for model_id, m in data["groq"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            models.append(base_model("groq", model_id, m, "openai-completions", "https://api.groq.com/openai/v1"))

    # cerebras
    if data.get("cerebras", {}).get("models"):
        for model_id, m in data["cerebras"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            models.append(base_model("cerebras", model_id, m, "openai-completions", "https://api.cerebras.ai/v1"))

    # cloudflare-workers-ai
    if data.get("cloudflare-workers-ai", {}).get("models"):
        for model_id, m in data["cloudflare-workers-ai"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            models.append(base_model("cloudflare-workers-ai", model_id, m, "openai-completions", CLOUDFLARE_WORKERS_AI_BASE_URL, compat={"sendSessionAffinityHeaders": True}))

    # cloudflare-ai-gateway
    if data.get("cloudflare-ai-gateway", {}).get("models"):
        for prefixed_id, m in data["cloudflare-ai-gateway"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            slash = prefixed_id.find("/")
            if slash == -1:
                continue
            upstream = prefixed_id[:slash]
            native_id = prefixed_id[slash + 1:]
            if upstream == "openai":
                api = "openai-responses"
                base_url = CLOUDFLARE_AI_GATEWAY_OPENAI_BASE_URL
                model_id = native_id
            elif upstream == "anthropic":
                api = "anthropic-messages"
                base_url = CLOUDFLARE_AI_GATEWAY_ANTHROPIC_BASE_URL
                model_id = native_id
            elif upstream == "workers-ai":
                api = "openai-completions"
                base_url = CLOUDFLARE_AI_GATEWAY_COMPAT_BASE_URL
                model_id = prefixed_id
            else:
                continue
            compat = {"sendSessionAffinityHeaders": True} if upstream in ("anthropic", "workers-ai") else None
            models.append(base_model("cloudflare-ai-gateway", model_id, m, api, base_url, compat=compat))

    # xai
    if data.get("xai", {}).get("models"):
        for model_id, m in data["xai"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            use_responses = model_id == XAI_RESPONSES_MODEL_ID
            compat = dict(XAI_RESPONSES_COMPAT) if use_responses else None
            models.append(base_model("xai", model_id, m, "openai-responses" if use_responses else "openai-completions", "https://api.x.ai/v1", compat=compat))

    # zai (zai-coding-plan)
    if data.get("zai-coding-plan", {}).get("models"):
        for provider, base_url in [("zai", "https://api.z.ai/api/coding/paas/v4"), ("zai-coding-cn", "https://open.bigmodel.cn/api/coding/paas/v4")]:
            for model_id, m in data["zai-coding-plan"]["models"].items():
                if m.get("tool_call") is not True:
                    continue
                compat = {
                    "supportsDeveloperRole": False,
                    "thinkingFormat": "zai",
                }
                if model_id == "glm-5.2":
                    compat["supportsReasoningEffort"] = True
                if model_id not in ZAI_TOOL_STREAM_UNSUPPORTED_MODELS:
                    compat["zaiToolStream"] = True
                thinking_map = dict(ZAI_GLM52_THINKING_LEVEL_MAP) if model_id == "glm-5.2" else None
                model = base_model(provider, model_id, m, "openai-completions", base_url, compat=compat)
                if thinking_map:
                    model["thinkingLevelMap"] = thinking_map
                models.append(model)

    # mistral
    if data.get("mistral", {}).get("models"):
        for model_id, m in data["mistral"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            cost = get_models_dev_cost(m.get("cost"))
            if not (m.get("cost") or {}).get("cache_read"):
                cost["cacheRead"] = round_cost((m.get("cost") or {}).get("input") * 0.1) if (m.get("cost") or {}).get("input") else 0
            models.append(base_model("mistral", model_id, m, "mistral-conversations", "https://api.mistral.ai", cost_override=cost))

    # huggingface
    if data.get("huggingface", {}).get("models"):
        for model_id, m in data["huggingface"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            models.append(base_model("huggingface", model_id, m, "openai-completions", "https://router.huggingface.co/v1", compat={"supportsDeveloperRole": False}))

    # fireworks
    if data.get("fireworks-ai", {}).get("models"):
        for model_id, m in data["fireworks-ai"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            compat = {
                "sendSessionAffinityHeaders": True,
                "supportsEagerToolInputStreaming": False,
                "supportsCacheControlOnTools": False,
                "supportsLongCacheRetention": False,
            }
            models.append(base_model("fireworks", model_id, m, "anthropic-messages", "https://api.fireworks.ai/inference", compat=compat))

    # nvidia
    if data.get("nvidia", {}).get("models"):
        for model_id, m in data["nvidia"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            modalities = m.get("modalities") or {}
            if "text" not in (modalities.get("input") or []):
                continue
            if "text" not in (modalities.get("output") or []):
                continue
            if nvidia_nim_ids is None:
                continue
            live_id = model_id
            if live_id not in nvidia_nim_ids:
                normalized = normalize_nvidia_model_id(model_id)
                live_id = normalized if normalized in nvidia_nim_ids else None
            if not live_id:
                continue
            if live_id in NVIDIA_NIM_UNSUPPORTED_MODELS:
                continue
            model = base_model("nvidia", live_id, m, "openai-completions", NVIDIA_BASE_URL, compat=dict(NVIDIA_OPENAI_COMPAT), headers=dict(NVIDIA_HEADERS))
            model["name"] = m.get("name") or live_id
            models.append(model)

    # together
    together_provider = data.get("together") or data.get("togetherai") or data.get("together-ai")
    if together_provider and together_provider.get("models"):
        for model_id, m in together_provider["models"].items():
            if m.get("tool_call") is not True:
                continue
            if m.get("status") == "deprecated":
                continue
            reasoning = m.get("reasoning") is True
            thinking_map = get_together_thinking_level_map(model_id, reasoning)
            model = base_model("together", model_id, m, "openai-completions", TOGETHER_BASE_URL, reasoning=reasoning, compat=get_together_compat(model_id, reasoning))
            if thinking_map:
                model["thinkingLevelMap"] = thinking_map
            models.append(model)

    # opencode / opencode-go
    opencode_variants = [
        {"key": "opencode", "provider": "opencode", "base_path": "https://opencode.ai/zen"},
        {"key": "opencode-go", "provider": "opencode-go", "base_path": "https://opencode.ai/zen/go"},
    ]
    for variant in opencode_variants:
        if not data.get(variant["key"], {}).get("models"):
            continue
        for model_id, m in data[variant["key"]]["models"].items():
            if m.get("tool_call") is not True:
                continue
            if m.get("status") == "deprecated":
                continue
            npm = (m.get("provider") or {}).get("npm")
            compat = None
            if npm == "@ai-sdk/openai":
                api = "openai-responses"
                base_url = f"{variant['base_path']}/v1"
                compat = {"sessionAffinityFormat": "openai-nosession"}
            elif npm == "@ai-sdk/anthropic":
                api = "anthropic-messages"
                base_url = variant["base_path"]
            elif npm == "@ai-sdk/google":
                api = "google-generative-ai"
                base_url = f"{variant['base_path']}/v1"
            elif npm == "@ai-sdk/alibaba":
                api = "openai-completions"
                base_url = f"{variant['base_path']}/v1"
                compat = {"cacheControlFormat": "anthropic"}
            else:
                api = "openai-completions"
                base_url = f"{variant['base_path']}/v1"
            if variant["provider"] == "opencode" and model_id == "grok-build-0.1":
                compat = {**(compat or {}), "supportsReasoningEffort": False}
            if variant["provider"] in ("opencode", "opencode-go") and model_id == "kimi-k2.6":
                compat = {**(compat or {}), "thinkingFormat": "deepseek", "supportsReasoningEffort": False}
            if variant["provider"] == "opencode-go":
                if model_id == "minimax-m2.7":
                    api = "openai-completions"
                    base_url = f"{variant['base_path']}/v1"
                if model_id in ("qwen3.5-plus", "qwen3.6-plus"):
                    api = "openai-completions"
                    base_url = f"{variant['base_path']}/v1"
                    compat = {**(compat or {}), "thinkingFormat": "qwen"}
            if api == "openai-completions":
                compat = {**(compat or {}), "maxTokensField": "max_tokens"}
                if f"{variant['provider']}:{model_id}" in OPENCODE_OPENAI_COMPLETIONS_LONG_CACHE_RETENTION_UNSUPPORTED_MODELS:
                    compat = {**compat, "supportsLongCacheRetention": False}
            models.append(base_model(variant["provider"], model_id, m, api, base_url, compat=compat or None))

    # github-copilot
    if data.get("github-copilot", {}).get("models"):
        for model_id, m in data["github-copilot"]["models"].items():
            if m.get("tool_call") is not True:
                continue
            if m.get("status") == "deprecated":
                continue
            is_copilot_claude = re.match(r"^claude-(haiku|sonnet|opus)-[45]([.\-]|$)", model_id) is not None
            needs_responses = model_id.startswith("gpt-5") or model_id.startswith("oswe") or model_id.startswith("mai-")
            if is_copilot_claude:
                api = "anthropic-messages"
            elif needs_responses:
                api = "openai-responses"
            else:
                api = "openai-completions"
            anthropic_compat = get_anthropic_messages_compat("github-copilot", model_id) if api == "anthropic-messages" else None
            completions_compat = {"supportsStore": False, "supportsDeveloperRole": False, "supportsReasoningEffort": False} if api == "openai-completions" else None
            cost = get_models_dev_cost(m.get("cost"))
            model = base_model(
                "github-copilot", model_id, m, api, "https://api.individual.githubcopilot.com",
                cost_override=cost,
                context_override=(m.get("limit") or {}).get("context") or 128000,
                max_tokens_override=(m.get("limit") or {}).get("output") or 8192,
                compat=anthropic_compat or completions_compat,
                headers=dict(COPILOT_STATIC_HEADERS),
            )
            models.append(model)

    # minimax / minimax-cn
    for key, provider, base_url in [("minimax", "minimax", "https://api.minimax.io/anthropic"), ("minimax-cn", "minimax-cn", "https://api.minimaxi.com/anthropic")]:
        if data.get(key, {}).get("models"):
            for model_id, m in data[key]["models"].items():
                if m.get("tool_call") is not True:
                    continue
                models.append(base_model(provider, model_id, m, "anthropic-messages", base_url))

    # kimi-for-coding
    if data.get("kimi-for-coding", {}).get("models"):
        kimi_models = data["kimi-for-coding"]["models"]
        has_canonical = "kimi-for-coding" in kimi_models
        kimi_aliases = {"k2p5", "k2p6", "k2p7"}
        for model_id, m in kimi_models.items():
            if m.get("tool_call") is not True:
                continue
            if model_id in kimi_aliases and has_canonical:
                continue
            normalized_id = "kimi-for-coding" if model_id in kimi_aliases else model_id
            normalized_name = "Kimi For Coding" if model_id in kimi_aliases else (m.get("name") or normalized_id)
            is_k3 = normalized_id == "k3"
            allow_empty = is_k3 or normalized_id == "kimi-for-coding"
            implied = KIMI_CODING_IMPLIED_COSTS.get(normalized_id)
            compat = {}
            if allow_empty:
                compat["allowEmptySignature"] = True
            compat["forceAdaptiveThinking"] = True
            cost = get_models_dev_cost(m.get("cost"))
            if implied:
                cost = {
                    "input": cost["input"] or implied["input"],
                    "output": cost["output"] or implied["output"],
                    "cacheRead": cost["cacheRead"] or implied["cacheRead"],
                    "cacheWrite": cost["cacheWrite"] or implied["cacheWrite"],
                }
            model = base_model(
                "kimi-coding", normalized_id, m, "anthropic-messages", "https://api.kimi.com/coding",
                reasoning=is_k3 or m.get("reasoning") is True, cost_override=cost, compat=compat,
                headers=dict(KIMI_STATIC_HEADERS),
            )
            model["name"] = normalized_name
            models.append(model)

    # moonshotai / moonshotai-cn
    for key, provider, base_url in [("moonshotai", "moonshotai", "https://api.moonshot.ai/v1"), ("moonshotai-cn", "moonshotai-cn", "https://api.moonshot.cn/v1")]:
        provider_models = data.get(key, {}).get("models") or {}
        for model_id, m in provider_models.items():
            if m.get("tool_call") is not True:
                continue
            is_k3 = model_id == "kimi-k3"
            compat = dict(MOONSHOT_COMPAT)
            if is_k3:
                compat.update({
                    "requiresReasoningContentOnAssistantMessages": True,
                    "deferredToolsMode": "kimi",
                    "thinkingFormat": "openai",
                    "supportsReasoningEffort": True,
                })
            cost = get_models_dev_cost(m.get("cost"))
            if is_k3:
                cost = {
                    "input": cost["input"] or KIMI_K3_COST["input"],
                    "output": cost["output"] or KIMI_K3_COST["output"],
                    "cacheRead": cost["cacheRead"] or KIMI_K3_COST["cacheRead"],
                    "cacheWrite": cost["cacheWrite"] or KIMI_K3_COST["cacheWrite"],
                }
            models.append(base_model(provider, model_id, m, "openai-completions", base_url, reasoning=is_k3 or m.get("reasoning") is True, cost_override=cost, compat=compat))

    # xiaomi family
    xiaomi_variants = [
        ("xiaomi", "xiaomi", "https://api.xiaomimimo.com/v1"),
        ("xiaomi-token-plan-cn", "xiaomi-token-plan-cn", "https://token-plan-cn.xiaomimimo.com/v1"),
        ("xiaomi-token-plan-ams", "xiaomi-token-plan-ams", "https://token-plan-ams.xiaomimimo.com/v1"),
        ("xiaomi-token-plan-sgp", "xiaomi-token-plan-sgp", "https://token-plan-sgp.xiaomimimo.com/v1"),
    ]
    for source, provider, base_url in xiaomi_variants:
        provider_models = data.get(source, {}).get("models")
        if not provider_models:
            continue
        for model_id, m in provider_models.items():
            if m.get("tool_call") is not True:
                continue
            models.append(base_model(provider, model_id, m, "openai-completions", base_url, compat=dict(XIAOMI_COMPAT)))

    # qwen-token-plan
    qwen_variants = [
        ("alibaba-token-plan", "qwen-token-plan", "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"),
        ("alibaba-token-plan-cn", "qwen-token-plan-cn", "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"),
    ]
    for source, provider, base_url in qwen_variants:
        provider_models = data.get(source, {}).get("models")
        if not provider_models:
            continue
        for model_id, m in provider_models.items():
            if m.get("tool_call") is not True:
                continue
            models.append(base_model(provider, model_id, m, "openai-completions", base_url, compat=dict(QWEN_TOKEN_PLAN_COMPAT)))

    print(f"loaded {len(models)} tool-capable models from models.dev")
    return models


def build_models(dev_data_path=None):
    models_dev = fetch_models_dev(dev_data_path)
    nvidia_nim_ids = fetch_nvidia_nim_ids()
    all_models = load_models_dev_models(models_dev, nvidia_nim_ids)
    all_models.extend(fetch_openrouter_models())
    all_models.extend(fetch_ai_gateway_models())

    all_models = [m for m in all_models if not (m["provider"] == "xai" and m["id"] in XAI_BUILTIN_EXCLUDED_MODEL_IDS)]
    all_models = [m for m in all_models if not ((m["provider"] in ("opencode", "opencode-go")) and m["id"] == "gpt-5.3-codex-spark")]

    # overrides
    for candidate in all_models:
        if candidate["provider"] == "github-copilot" and candidate["id"] in GITHUB_COPILOT_EXTENDED_CONTEXT_MODELS:
            candidate["contextWindow"] = 1000000
        if candidate["provider"] in ("anthropic", "opencode", "opencode-go") and candidate["id"] in ("claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4.6", "claude-sonnet-4.6"):
            candidate["contextWindow"] = 1000000
        if candidate["provider"] in ("opencode", "opencode-go") and candidate["id"] in ("claude-sonnet-4-5", "claude-sonnet-4"):
            candidate["contextWindow"] = 200000
        if candidate["provider"] in ("opencode", "opencode-go") and candidate["id"] == "gpt-5.4":
            candidate["contextWindow"] = 272000
            candidate["maxTokens"] = 128000
        if candidate["provider"] == "openai" and candidate["id"] in OPENAI_SHORT_CONTEXT_CAPPED_MODEL_IDS:
            candidate["contextWindow"] = OPENAI_LONG_CONTEXT_INPUT_THRESHOLD
            candidate["maxTokens"] = 128000
        if candidate["provider"] == "openai" and candidate["id"] in OPENAI_LONG_CONTEXT_PRICING_MODEL_IDS:
            candidate["cost"] = with_openai_long_context_pricing(candidate["cost"])
        if candidate["provider"] == "openai" and candidate["id"] == "gpt-5-pro":
            candidate["maxTokens"] = 128000
        if (candidate["provider"] == "openrouter" and candidate["id"] in OPENROUTER_KIMI_K3_MODEL_IDS) or (candidate["provider"] == "vercel-ai-gateway" and candidate["id"] == "moonshotai/kimi-k3"):
            candidate["maxTokens"] = KIMI_K3_MAX_TOKENS
        if candidate["provider"] == "openrouter" and candidate["id"] == "moonshotai/kimi-k2.5":
            candidate["cost"]["input"] = 0.41
            candidate["cost"]["output"] = 2.06
            candidate["cost"]["cacheRead"] = 0.07
            candidate["maxTokens"] = 4096
        if candidate["provider"] == "openrouter" and candidate["id"].startswith("moonshotai/kimi-k2.6"):
            candidate["compat"] = {
                **(candidate.get("compat") or {}),
                "supportsDeveloperRole": False,
                "requiresReasoningContentOnAssistantMessages": True,
            }
        if candidate["provider"] == "openrouter" and candidate["id"] == "z-ai/glm-5":
            candidate["cost"]["input"] = 0.6
            candidate["cost"]["output"] = 1.9
            candidate["cost"]["cacheRead"] = 0.119
        if candidate["provider"] == "fireworks" and "glm-5p2" in candidate["id"]:
            candidate["api"] = "openai-completions"
            candidate["baseUrl"] = "https://api.fireworks.ai/inference/v1"
            candidate["compat"] = {"supportsStore": False, "supportsDeveloperRole": False}

    # missing openai models
    missing_openai = [
        ("gpt-5.6-sol", "GPT-5.6 Sol", with_openai_long_context_pricing({"input": 5, "output": 30, "cacheRead": 0.5, "cacheWrite": 6.25})),
        ("gpt-5.6-terra", "GPT-5.6 Terra", with_openai_long_context_pricing({"input": 2.5, "output": 15, "cacheRead": 0.25, "cacheWrite": 3.125})),
        ("gpt-5-chat-latest", "GPT-5 Chat Latest", {"input": 1.25, "output": 10, "cacheRead": 0.125, "cacheWrite": 0}),
    ]
    existing_openai = {(m["provider"], m["id"]) for m in all_models}
    for model_id, name, cost in missing_openai:
        if ("openai", model_id) not in existing_openai:
            all_models.append({
                "id": model_id,
                "name": name,
                "api": "openai-responses",
                "baseUrl": "https://api.openai.com/v1",
                "provider": "openai",
                "reasoning": True,
                "input": ["text", "image"],
                "cost": cost,
                "contextWindow": OPENAI_LONG_CONTEXT_INPUT_THRESHOLD,
                "maxTokens": 128000,
            })

    # hardcoded deepseek v4
    deepseek_compat = dict(DEEPSEEK_COMPAT)
    for model_id, name, input_cost, output_cost, cache_read in [
        ("deepseek-v4-flash", "DeepSeek V4 Flash", 0.14, 0.28, 0.0028),
        ("deepseek-v4-pro", "DeepSeek V4 Pro", 0.435, 0.87, 0.003625),
    ]:
        all_models.append({
            "id": model_id,
            "name": name,
            "api": "openai-completions",
            "baseUrl": "https://api.deepseek.com",
            "provider": "deepseek",
            "reasoning": True,
            "input": ["text"],
            "cost": {"input": input_cost, "output": output_cost, "cacheRead": cache_read, "cacheWrite": 0},
            "contextWindow": 1000000,
            "maxTokens": 384000,
            "compat": dict(deepseek_compat),
        })

    # hardcoded ant-ling
    for model_id, name, reasoning, input_cost, output_cost in [
        ("Ling-2.6-flash", "Ling 2.6 Flash", False, 0.01, 0.02),
        ("Ling-2.6-1T", "Ling 2.6 1T", False, 0.06, 0.25),
        ("Ring-2.6-1T", "Ring 2.6 1T", True, 0.06, 0.25),
    ]:
        compat = dict(ANT_LING_COMPAT)
        if reasoning:
            compat["thinkingFormat"] = "ant-ling"
        model = {
            "id": model_id,
            "name": name,
            "api": "openai-completions",
            "baseUrl": "https://api.ant-ling.com/v1",
            "provider": "ant-ling",
            "reasoning": reasoning,
            "input": ["text"],
            "cost": {"input": input_cost, "output": output_cost, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 262144,
            "maxTokens": 65536,
            "compat": compat,
        }
        if reasoning:
            model["thinkingLevelMap"] = dict(ANT_LING_RING_THINKING_LEVEL_MAP)
        all_models.append(model)

    # deepseek-v4 compat for openai-completions models elsewhere
    for candidate in all_models:
        if candidate["api"] == "openai-completions" and "deepseek-v4" in candidate["id"]:
            if candidate["provider"] in ("openrouter", "opencode"):
                candidate["compat"] = {**(candidate.get("compat") or {}), "requiresReasoningContentOnAssistantMessages": DEEPSEEK_COMPAT["requiresReasoningContentOnAssistantMessages"]}
            else:
                candidate["compat"] = {**(candidate.get("compat") or {}), **DEEPSEEK_COMPAT}

    # minimax direct supported only
    all_models = [m for m in all_models if not ((m["provider"] in ("minimax", "minimax-cn")) and m["id"] not in MINIMAX_DIRECT_SUPPORTED_IDS)]

    # codex models
    codex_models = [
        ("gpt-5.3-codex-spark", "GPT-5.3 Codex Spark", True, ["text"], {"input": 1.75, "output": 14, "cacheRead": 0.175, "cacheWrite": 0}, CODEX_SPARK_CONTEXT),
        ("gpt-5.4", "GPT-5.4", True, ["text", "image"], with_openai_long_context_pricing({"input": 2.5, "output": 15, "cacheRead": 0.25, "cacheWrite": 0}), CODEX_CONTEXT),
        ("gpt-5.4-mini", "GPT-5.4 mini", True, ["text", "image"], {"input": 0.75, "output": 4.5, "cacheRead": 0.075, "cacheWrite": 0}, CODEX_CONTEXT),
        ("gpt-5.5", "GPT-5.5", True, ["text", "image"], with_openai_long_context_pricing({"input": 5, "output": 30, "cacheRead": 0.5, "cacheWrite": 0}), CODEX_CONTEXT),
        ("gpt-5.6-luna", "GPT-5.6 Luna", True, ["text", "image"], with_openai_long_context_pricing({"input": 1, "output": 6, "cacheRead": 0.1, "cacheWrite": 1.25}), CODEX_GPT_56_CONTEXT),
        ("gpt-5.6-sol", "GPT-5.6 Sol", True, ["text", "image"], with_openai_long_context_pricing({"input": 5, "output": 30, "cacheRead": 0.5, "cacheWrite": 6.25}), CODEX_GPT_56_CONTEXT),
        ("gpt-5.6-terra", "GPT-5.6 Terra", True, ["text", "image"], with_openai_long_context_pricing({"input": 2.5, "output": 15, "cacheRead": 0.25, "cacheWrite": 3.125}), CODEX_GPT_56_CONTEXT),
    ]
    for model_id, name, reasoning, input_modality, cost, context in codex_models:
        all_models.append({
            "id": model_id,
            "name": name,
            "api": "openai-codex-responses",
            "provider": "openai-codex",
            "baseUrl": CODEX_BASE_URL,
            "reasoning": reasoning,
            "input": input_modality,
            "cost": cost,
            "contextWindow": context,
            "maxTokens": CODEX_MAX_TOKENS,
        })

    # mistral medium 3.5
    if not any(m["provider"] == "mistral" and m["id"] == "mistral-medium-3.5" for m in all_models):
        all_models.append({
            "id": "mistral-medium-3.5",
            "name": "Mistral Medium 3.5",
            "api": "mistral-conversations",
            "provider": "mistral",
            "baseUrl": "https://api.mistral.ai",
            "reasoning": True,
            "input": ["text", "image"],
            "cost": {"input": 1.5, "output": 7.5, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 262144,
            "maxTokens": 262144,
        })

    # qwen3.8-max-preview for token plan providers
    for qwen_tp in ("qwen-token-plan", "qwen-token-plan-cn"):
        if not any(m["provider"] == qwen_tp and m["id"] == "qwen3.8-max-preview" for m in all_models):
            base_url = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1" if qwen_tp == "qwen-token-plan" else "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
            all_models.append({
                "id": "qwen3.8-max-preview",
                "name": "Qwen3.8 Max Preview",
                "api": "openai-completions",
                "provider": qwen_tp,
                "baseUrl": base_url,
                "compat": {"thinkingFormat": "qwen", "supportsDeveloperRole": False, "supportsStore": False},
                "reasoning": True,
                "input": ["text", "image"],
                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                "contextWindow": 1000000,
                "maxTokens": 65536,
            })

    # openrouter auto
    if not any(m["provider"] == "openrouter" and m["id"] == "auto" for m in all_models):
        all_models.append({
            "id": "auto",
            "name": "Auto",
            "api": "openai-completions",
            "provider": "openrouter",
            "baseUrl": "https://openrouter.ai/api/v1",
            "reasoning": True,
            "input": ["text", "image"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 2000000,
            "maxTokens": 30000,
        })

    # openrouter fusion
    if not any(m["provider"] == "openrouter" and m["id"] == "openrouter/fusion" for m in all_models):
        all_models.append({
            "id": "openrouter/fusion",
            "name": "OpenRouter: Fusion",
            "api": "openai-completions",
            "provider": "openrouter",
            "baseUrl": "https://openrouter.ai/api/v1",
            "reasoning": True,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 1000000,
            "maxTokens": 30000,
        })

    # azure clones
    azure_models = []
    for model in all_models:
        if model["provider"] == "openai" and model["api"] == "openai-responses":
            azure_models.append({
                **model,
                "api": "azure-openai-responses",
                "provider": "azure-openai-responses",
                "baseUrl": "",
                "cost": {
                    "input": model["cost"].get("input", 0),
                    "output": model["cost"].get("output", 0),
                    "cacheRead": model["cost"].get("cacheRead", 0),
                    "cacheWrite": model["cost"].get("cacheWrite", 0),
                    **({"tiers": model["cost"]["tiers"]} if model["cost"].get("tiers") else {}),
                },
                "contextWindow": AZURE_CONTEXT_WINDOW_OVERRIDES.get(model["id"], model["contextWindow"]),
            })
    all_models.extend(azure_models)

    # metadata passes
    reasoning_options = {}

    def record_reasoning_options(provider, model_id, m):
        if m.get("reasoning_options") is not None:
            reasoning_options[f"{provider}:{model_id}"] = m["reasoning_options"]

    # records collected during load are lost; re-collect from the source data
    for provider_id, section in [
        ("amazon-bedrock", "amazon-bedrock"), ("anthropic", "anthropic"), ("google", "google"),
        ("google-vertex", "google-vertex"), ("openai", "openai"), ("groq", "groq"), ("cerebras", "cerebras"),
        ("cloudflare-workers-ai", "cloudflare-workers-ai"), ("cloudflare-ai-gateway", "cloudflare-ai-gateway"),
        ("xai", "xai"), ("mistral", "mistral"), ("huggingface", "huggingface"), ("fireworks", "fireworks-ai"),
        ("nvidia", "nvidia"), ("together", "together"), ("opencode", "opencode"), ("opencode-go", "opencode-go"),
        ("github-copilot", "github-copilot"), ("minimax", "minimax"), ("minimax-cn", "minimax-cn"),
        ("kimi-coding", "kimi-for-coding"), ("moonshotai", "moonshotai"), ("moonshotai-cn", "moonshotai-cn"),
        ("xiaomi", "xiaomi"), ("xiaomi-token-plan-cn", "xiaomi-token-plan-cn"), ("xiaomi-token-plan-ams", "xiaomi-token-plan-ams"),
        ("xiaomi-token-plan-sgp", "xiaomi-token-plan-sgp"), ("qwen-token-plan", "alibaba-token-plan"), ("qwen-token-plan-cn", "alibaba-token-plan-cn"),
        ("zai", "zai-coding-plan"), ("zai-coding-cn", "zai-coding-plan"),
    ]:
        for model_id, m in (models_dev.get(section, {}).get("models") or {}).items():
            record_reasoning_options(provider_id, model_id, m)

    for model in all_models:
        apply_openai_completions_compat_metadata(model)
        options = reasoning_options.get(f"{model['provider']}:{model['id']}")
        if options and supports_direct_reasoning_effort(model):
            effort_map = get_effort_thinking_level_map(options)
            if effort_map:
                merge_thinking_level_map(model, effort_map)
        apply_thinking_level_metadata(model)
        apply_strict_tool_compat_metadata(model)
        apply_openai_grammar_tool_compat_metadata(model)
        apply_openai_tool_search_metadata(model)
        apply_openai_explicit_prompt_cache_metadata(model)

    return all_models


def merge_thinking_level_map(model, mapping):
    merged = dict(model.get("thinkingLevelMap") or {})
    merged.update(mapping)
    model["thinkingLevelMap"] = merged


def apply_openai_completions_compat_metadata(model):
    if model["api"] != "openai-completions":
        return
    detected = openai_completions_compat_delta(detect_openai_completions_compat(model))
    merged = {**detected, **(model.get("compat") or {})}
    if merged:
        model["compat"] = merged
    else:
        model.pop("compat", None)


def apply_strict_tool_compat_metadata(model):
    if model["provider"] == "openai" and model["api"] == "openai-responses":
        model["compat"] = {**(model.get("compat") or {}), "supportsStrictMode": True}
    elif model["provider"] == "anthropic" and model["api"] == "anthropic-messages":
        model["compat"] = {**(model.get("compat") or {}), "supportsStrictTools": True}


def apply_openai_grammar_tool_compat_metadata(model):
    if model["api"] not in OPENAI_GRAMMAR_TOOL_APIS or model["provider"] not in OPENAI_GRAMMAR_TOOL_PROVIDERS:
        return
    match = re.match(r"^gpt-(\d+)", model["id"])
    if not match or int(match.group(1)) < 5:
        return
    model["compat"] = {**(model.get("compat") or {}), "supportsOpenAIGrammarTools": True}


def apply_openai_tool_search_metadata(model):
    is_openai = model["provider"] == "openai" and model["api"] == "openai-responses"
    is_codex = model["provider"] == "openai-codex" and model["api"] == "openai-codex-responses"
    if (is_openai or is_codex) and model["id"] in OPENAI_TOOL_SEARCH_MODEL_IDS:
        model["compat"] = {**(model.get("compat") or {}), "supportsToolSearch": True}


def apply_openai_explicit_prompt_cache_metadata(model):
    if model["provider"] != "openai" or model["api"] != "openai-responses":
        return
    if not (model["cost"].get("cacheWrite") or 0) > 0:
        return
    model["compat"] = {**(model.get("compat") or {}), "supportsExplicitPromptCacheMode": True}


def is_gemini3_pro_model(model_id):
    return re.search(r"gemini-3(?:\.\d+)?-pro", model_id.lower()) is not None


def is_gemini3_flash_model(model_id):
    lower = model_id.lower()
    return re.search(r"gemini-3(?:\.\d+)?-flash", lower) is not None or lower in ("gemini-flash-latest", "gemini-flash-lite-latest")


def is_gemma4_model(model_id):
    return re.search(r"gemma-?4", model_id.lower()) is not None


def apply_thinking_level_metadata(model):
    if model["api"] in ("openai-responses", "azure-openai-responses") and model["id"].startswith("gpt-5"):
        merge_thinking_level_map(model, {"off": None})
    if model["provider"] == "github-copilot" and model["id"].startswith("gpt-5"):
        merge_thinking_level_map(model, {"minimal": "low"})
    if model["api"] == "openai-responses" and model["provider"] == "openai" and model["id"] in OPENAI_RESPONSES_NONE_REASONING_MODELS:
        merge_thinking_level_map(model, {"off": "none"})
    if model["provider"] == "xai" and model["api"] == "openai-responses" and model["id"] == XAI_RESPONSES_MODEL_ID:
        merge_thinking_level_map(model, dict(XAI_RESPONSES_EFFORT_LEVEL_MAP))
    if supports_openai_xhigh(model["id"]):
        merge_thinking_level_map(model, {"xhigh": "xhigh"})
    if supports_openai_max(model):
        merge_thinking_level_map(model, {"max": "max"})
    if model["provider"] == "openai" and model["id"] == "gpt-5.5":
        merge_thinking_level_map(model, {"minimal": None})
    if model["id"].endswith("gpt-5.5-pro"):
        merge_thinking_level_map(model, {"off": None, "minimal": None, "low": None})
    if any(marker in model["id"] for marker in ["opus-4-6", "opus-4.6", "sonnet-4-6", "sonnet-4.6"]):
        merge_thinking_level_map(model, {"max": "max"})
    if any(marker in model["id"] for marker in ["opus-4-7", "opus-4.7", "opus-4-8", "opus-4.8", "opus-5", "opus.5", "sonnet-5", "sonnet.5"]):
        merge_thinking_level_map(model, {"xhigh": "xhigh", "max": "max"})
    if "fable-5" in model["id"]:
        merge_thinking_level_map(model, {"off": None, "xhigh": "xhigh", "max": "max"})
    if model["api"] == "anthropic-messages" and is_anthropic_adaptive_thinking_model(model["id"]):
        model["compat"] = {**(model.get("compat") or {}), "forceAdaptiveThinking": True}
    if model["api"] == "anthropic-messages" and is_anthropic_temperature_unsupported_model(model["id"]):
        model["compat"] = {**(model.get("compat") or {}), "supportsTemperature": False}
    if model["api"] == "openai-completions" and "deepseek-v4" in model["id"]:
        mapping = dict(DEEPSEEK_V4_THINKING_LEVEL_MAP)
        if model["provider"] == "openrouter":
            mapping = {**mapping, "xhigh": "xhigh", "max": None}
        merge_thinking_level_map(model, mapping)
    if model["api"] in ("google-generative-ai", "google-vertex"):
        if is_gemini3_pro_model(model["id"]):
            merge_thinking_level_map(model, {"off": None, "minimal": None, "low": "LOW", "medium": None, "high": "HIGH"})
        if is_gemini3_flash_model(model["id"]):
            merge_thinking_level_map(model, {"off": None})
        if is_gemma4_model(model["id"]):
            merge_thinking_level_map(model, {"off": None, "minimal": "MINIMAL", "low": None, "medium": None, "high": "HIGH"})
    if model["provider"] == "groq" and model["id"] == "qwen/qwen3-32b":
        merge_thinking_level_map(model, {"minimal": None, "low": None, "medium": None, "high": "default"})
    if model["provider"] == "openai-codex" and supports_openai_xhigh(model["id"]):
        merge_thinking_level_map(model, {"minimal": "low"})
    if model["provider"] in ("moonshotai", "moonshotai-cn") and model["id"] in ("kimi-k2.7-code", "kimi-k2.7-code-highspeed"):
        merge_thinking_level_map(model, {"off": None})
    if model["provider"] == "openrouter" and model["id"].startswith("inception/mercury-2"):
        merge_thinking_level_map(model, {"off": None})
    if model["provider"] == "openrouter" and model["id"] == "z-ai/glm-5.2":
        merge_thinking_level_map(model, {"xhigh": "xhigh"})
    if model["provider"] == "fireworks" and "glm-5p2" in model["id"]:
        merge_thinking_level_map(model, {"off": "none", "minimal": None, "low": "high", "medium": "high", "max": "max"})
    if model["provider"] == "opencode-go" and model["id"] == "glm-5.2":
        merge_thinking_level_map(model, dict(OPENCODE_GO_GLM52_THINKING_LEVEL_MAP))
    if model["provider"] == "opencode-go" and model["id"] == "kimi-k2.6":
        merge_thinking_level_map(model, {"minimal": None, "low": None, "medium": None})
    if model["provider"] == "opencode" and model["id"] == "grok-build-0.1":
        merge_thinking_level_map(model, {"off": None, "minimal": None, "low": None, "medium": None})
    if model["provider"] == "ant-ling" and model["reasoning"]:
        merge_thinking_level_map(model, dict(ANT_LING_RING_THINKING_LEVEL_MAP))
    if model["provider"] == "github-copilot" and model["id"] in GITHUB_COPILOT_THINKING_LEVEL_OVERRIDES:
        merge_thinking_level_map(model, GITHUB_COPILOT_THINKING_LEVEL_OVERRIDES[model["id"]])


PROVIDER_DEFS = [
    # (id, name, api, base_url, env_vars, headers)
    ("deepseek", "DeepSeek", "openai-completions", "https://api.deepseek.com", ["DEEPSEEK_API_KEY"], {}),
    ("qwen-token-plan", "Qwen Token Plan", "openai-completions", "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1", ["QWEN_TOKEN_PLAN_API_KEY"], {}),
    ("qwen-token-plan-cn", "Qwen Token Plan CN", "openai-completions", "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", ["QWEN_TOKEN_PLAN_CN_API_KEY"], {}),
    ("xiaomi", "Xiaomi", "openai-completions", "https://api.xiaomimimo.com/v1", ["XIAOMI_API_KEY"], {}),
    ("xiaomi-token-plan-ams", "Xiaomi Token Plan AMS", "openai-completions", "https://token-plan-ams.xiaomimimo.com/v1", ["XIAOMI_TOKEN_PLAN_AMS_API_KEY"], {}),
    ("xiaomi-token-plan-cn", "Xiaomi Token Plan CN", "openai-completions", "https://token-plan-cn.xiaomimimo.com/v1", ["XIAOMI_TOKEN_PLAN_CN_API_KEY"], {}),
    ("xiaomi-token-plan-sgp", "Xiaomi Token Plan SGP", "openai-completions", "https://token-plan-sgp.xiaomimimo.com/v1", ["XIAOMI_TOKEN_PLAN_SGP_API_KEY"], {}),
    ("zai", "Z.AI", "openai-completions", "https://api.z.ai/api/coding/paas/v4", ["ZAI_API_KEY"], {}),
    ("zai-coding-cn", "Z.AI Coding CN", "openai-completions", "https://open.bigmodel.cn/api/coding/paas/v4", ["ZAI_CODING_CN_API_KEY"], {}),
    ("together", "Together", "openai-completions", "https://api.together.ai/v1", ["TOGETHER_API_KEY"], {}),
    ("cerebras", "Cerebras", "openai-completions", "https://api.cerebras.ai/v1", ["CEREBRAS_API_KEY"], {}),
    ("openrouter", "OpenRouter", "openai-completions", "https://openrouter.ai/api/v1", ["OPENROUTER_API_KEY"], {}),
    ("groq", "Groq", "openai-completions", "https://api.groq.com/openai/v1", ["GROQ_API_KEY"], {}),
    ("moonshotai", "Moonshot AI", "openai-completions", "https://api.moonshot.ai/v1", ["MOONSHOT_API_KEY"], {}),
    ("moonshotai-cn", "Moonshot AI CN", "openai-completions", "https://api.moonshot.cn/v1", ["MOONSHOT_API_KEY"], {}),
    ("nvidia", "NVIDIA", "openai-completions", "https://integrate.api.nvidia.com/v1", ["NVIDIA_API_KEY"], {"NVCF-POLL-SECONDS": "3600"}),
    ("huggingface", "Hugging Face", "openai-completions", "https://router.huggingface.co/v1", ["HF_TOKEN"], {}),
    ("ant-ling", "Ant Ling", "openai-completions", "https://api.ant-ling.com/v1", ["ANT_LING_API_KEY"], {}),
    ("cloudflare-workers-ai", "Cloudflare Workers AI", "openai-completions", "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai/v1", ["CLOUDFLARE_API_KEY", "CLOUDFLARE_ACCOUNT_ID"], {}),
    ("cloudflare-ai-gateway", "Cloudflare AI Gateway", "openai-completions", "https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}", ["CLOUDFLARE_API_KEY", "CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_GATEWAY_ID"], {}),
    ("opencode", "OpenCode Zen", "openai-completions", "https://opencode.ai/zen", ["OPENCODE_API_KEY"], {}),
    ("opencode-go", "OpenCode Zen Go", "openai-completions", "https://opencode.ai/zen/go", ["OPENCODE_API_KEY"], {}),
    ("fireworks", "Fireworks", "openai-completions", "https://api.fireworks.ai/inference", ["FIREWORKS_API_KEY"], {}),
    ("github-copilot", "GitHub Copilot", "openai-completions", "https://api.individual.githubcopilot.com", ["COPILOT_GITHUB_TOKEN"], {}),
    ("xai", "xAI", "openai-completions", "https://api.x.ai/v1", ["XAI_API_KEY"], {}),
    ("anthropic", "Anthropic", "anthropic-messages", "https://api.anthropic.com", ["ANTHROPIC_API_KEY"], {}),
    ("kimi-coding", "Kimi For Coding", "anthropic-messages", "https://api.kimi.com/coding", ["KIMI_API_KEY"], {}),
    ("minimax", "MiniMax", "anthropic-messages", "https://api.minimax.io/anthropic", ["MINIMAX_API_KEY"], {}),
    ("minimax-cn", "MiniMax CN", "anthropic-messages", "https://api.minimaxi.com/anthropic", ["MINIMAX_CN_API_KEY"], {}),
    ("vercel-ai-gateway", "Vercel AI Gateway", "anthropic-messages", "https://ai-gateway.vercel.sh", ["AI_GATEWAY_API_KEY"], {}),
    ("openai", "OpenAI", "openai-responses", "https://api.openai.com/v1", ["OPENAI_API_KEY"], {}),
    ("azure-openai-responses", "Azure OpenAI", "azure-openai-responses", "", ["AZURE_OPENAI_API_KEY"], {}),
    ("openai-codex", "OpenAI Codex", "openai-codex-responses", "https://chatgpt.com/backend-api", [], {}),
    ("google", "Google", "google-generative-ai", "https://generativelanguage.googleapis.com/v1beta", ["GEMINI_API_KEY"], {}),
    ("google-vertex", "Google Vertex", "google-vertex", "https://{location}-aiplatform.googleapis.com", [], {}),
    ("mistral", "Mistral", "mistral-conversations", "https://api.mistral.ai", ["MISTRAL_API_KEY"], {}),
    ("amazon-bedrock", "Amazon Bedrock", "bedrock-converse-stream", "https://bedrock-runtime.us-east-1.amazonaws.com", [], {}),
]


def write_provider_def(provider_id, name, api, base_url, env_vars, headers):
    defs = ", ".join(nat_string(v) for v in env_vars)
    header = f"""// Provider definition for {name}.
// Metadata follows vendors/pi/packages/ai/src/providers/{provider_id}.ts.
import adou.src.ai.providers.{provider_id.replace('-', '_')}_models
import adou.src.ai.types

fn def(): types.provider_def_t {{
    return types.provider_def_t {{id: {nat_string(provider_id)}, name: {nat_string(name)}, api: {nat_string(api)}, base_url: {nat_string(base_url)}, env_vars: [{defs}], headers: {{}},}}
}}

fn models(): [ref<types.model_t>] {{
    return {provider_id.replace('-', '_')}_models.models()
}}
"""
    (OUT_DIR / f"{provider_id.replace('-', '_')}.n").write_text(header, encoding="utf-8")


def nat_float(value):
    if value is None:
        return "0.0"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return f"{value}.0"
    if isinstance(value, float):
        text = f"{value:.10f}".rstrip("0").rstrip(".")
        if text in ("", "-"):
            text = "0"
        if "e" in text or "E" in text:
            text = f"{value:.10f}"
        return text + ".0" if "." not in text else text
    return str(value)


def nat_string(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def nat_map(mapping):
    return ", ".join(f"{nat_string(key)}: {nat_string(value)}" for key, value in mapping.items())


def emit_model_entries(models):
    lines = []
    counter = 0
    for model in models:
        cost = model["cost"]
        tiers = cost.get("tiers") or []
        tiers_arg = "[]"
        if tiers:
            tier_parts = []
            for tier in tiers:
                tier_parts.append(
                    "types.cost_tier_t {input_tokens_above: %d, input: %s, output: %s, cache_read: %s, cache_write: %s,}"
                    % (tier["inputTokensAbove"], nat_float(tier["input"]), nat_float(tier["output"]), nat_float(tier["cacheRead"]), nat_float(tier["cacheWrite"]))
                )
            tiers_arg = "[" + ", ".join(tier_parts) + "]"
        args = ", ".join([
            nat_string(model["id"]),
            nat_string(model.get("name") or model["id"]),
            nat_string(model["api"]),
            nat_string(model["provider"]),
            nat_string(model["baseUrl"]),
            "true" if model.get("reasoning") else "false",
            str(model["contextWindow"]),
            str(model["maxTokens"]),
            nat_float(cost.get("input", 0)),
            nat_float(cost.get("output", 0)),
            nat_float(cost.get("cacheRead", 0)),
            nat_float(cost.get("cacheWrite", 0)),
            tiers_arg,
        ])
        thinking_map = model.get("thinkingLevelMap") or {}
        headers = model.get("headers") or {}
        if not thinking_map and not headers:
            lines.append(f"    result.push(model_builder.build({args}))")
            continue
        var_name = f"m{counter}"
        counter += 1
        lines.append(f"    var {var_name} = model_builder.build({args})")
        for key, value in thinking_map.items():
            encoded = value if value is not None else ""
            lines.append(f"    {var_name}.thinking_level_map[{nat_string(key)}] = {nat_string(encoded)}")
        for key, value in headers.items():
            lines.append(f"    {var_name}.headers[{nat_string(key)}] = {nat_string(value)}")
        lines.append(f"    result.push({var_name})")
    return "\n".join(lines)


def write_catalog(provider_id, models):
    header = f"""// Auto-generated by scripts/generate-model-catalog.py
// Port of Pi vendors/pi/packages/ai/scripts/generate-models.ts ({len(models)} models)
// Do not edit by hand; regenerate with: python3 scripts/generate-model-catalog.py
import adou.src.ai.providers.model_builder
import adou.src.ai.types

fn models(): [ref<types.model_t>] {{
    [ref<types.model_t>] result = []
{emit_model_entries(models)}
    return result
}}
"""
    (OUT_DIR / f"{provider_id.replace('-', '_')}_models.n").write_text(header, encoding="utf-8")


def main():
    data_path = None
    if len(sys.argv) > 1 and sys.argv[1] == "--data" and len(sys.argv) > 2:
        data_path = sys.argv[2]
    models = build_models(data_path)
    providers = {}
    for model in models:
        if model["provider"] not in providers:
            providers[model["provider"]] = {}
        if model["id"] not in providers[model["provider"]]:
            providers[model["provider"]][model["id"]] = model
    total = 0
    for provider_id in sorted(providers):
        provider_models = [providers[provider_id][model_id] for model_id in sorted(providers[provider_id])]
        write_catalog(provider_id, provider_models)
        total += len(provider_models)
        print(f"{provider_id}: {len(provider_models)} models")
    for provider_id, name, api, base_url, env_vars, headers in PROVIDER_DEFS:
        write_provider_def(provider_id, name, api, base_url, env_vars, headers)
    print(f"total: {total} models across {len(providers)} providers")
    print(f"provider defs: {len(PROVIDER_DEFS)}")


if __name__ == "__main__":
    main()
