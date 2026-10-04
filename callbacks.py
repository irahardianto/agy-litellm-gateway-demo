"""
Antigravity Protojson Compatibility Plugin for LiteLLM Proxy.

Loaded via `litellm_settings.callbacks: ["callbacks.antigravity_compat"]` in `config.yaml`.

Why this plugin exists:
LiteLLM Proxy natively exposes `/v1beta/models/{model}:generateContent` and
`/v1beta/models/{model}:streamGenerateContent` and translates non-Gemini models
(such as Vertex AI / GEAP Claude) via `GoogleGenAIAdapter`. However, Antigravity's Go
`protojson` serializer emits a few protobuf-specific wire conventions that strict
downstream providers (like Anthropic on Vertex AI / GEAP) reject without normalization:
  1. `int64` JSON Schema keywords (`minItems`, `maxItems`, `minLength`, etc.) are
     serialized by `protojson` as strings (e.g. `"minItems": "2"`).
  2. `systemInstruction.parts` in Antigravity contains multiple text parts
     (upstream LiteLLM only reads `parts[0]`).
  3. Multiple `functionCall` / `functionResponse` parts with the same function name
     need unique `tool_call_id`s (`call_<name>_<idx>`) for Anthropic compatibility.
  4. Zero-argument tool calls (`{}`) streamed by Anthropic have `arguments=""` and
     must be flushed when `finish_reason` arrives.
  5. When a Gemini 3 request with `thinkingLevel` falls back to Gemini 2.5,
     `thinkingLevel` must be converted to `thinkingBudget`.
"""

from __future__ import annotations

import json
from collections import defaultdict, deque
from typing import Any, Mapping, Sequence, cast

from litellm.integrations.custom_logger import CustomLogger

_INT_SCHEMA_KEYS = frozenset(
    {
        "minItems",
        "maxItems",
        "minLength",
        "maxLength",
        "minProperties",
        "maxProperties",
    }
)
_GEMINI_ONLY_SCHEMA_KEYS = frozenset(
    {
        "propertyOrdering",
        "property_ordering",
        "nullable",
    }
)
_TYPE_MAPPING = {
    "BOOLEAN": "boolean",
    "STRING": "string",
    "ARRAY": "array",
    "OBJECT": "object",
    "NUMBER": "number",
    "INTEGER": "integer",
    "NULL": "null",
}
_THINKING_LEVEL_TO_BUDGET = {
    "HIGH": 16384,
    "MEDIUM": 8192,
    "LOW": 2048,
    "MINIMAL": 1024,
}


def _normalize_protojson_schema(schema: Any, depth: int = 0, max_depth: int = 50) -> Any:
    """Recursively normalizes protojson Schema objects into Draft 2020-12 JSON Schema."""
    if depth >= max_depth or not isinstance(schema, (dict, list)):
        return schema

    if isinstance(schema, list):
        return [_normalize_protojson_schema(item, depth + 1, max_depth) for item in schema]

    normalized: dict[str, Any] = {}
    for key, value in schema.items():
        if key in _GEMINI_ONLY_SCHEMA_KEYS:
            continue
        if key == "type" and isinstance(value, str):
            normalized[key] = _TYPE_MAPPING.get(value.upper(), value.lower())
        elif key in _INT_SCHEMA_KEYS and isinstance(value, str):
            try:
                normalized[key] = int(value)
            except ValueError:
                normalized[key] = value
        elif isinstance(value, (dict, list)):
            normalized[key] = _normalize_protojson_schema(value, depth + 1, max_depth)
        else:
            normalized[key] = value

    if normalized.get("type") == "object" and "properties" not in normalized:
        normalized["properties"] = {}

    return normalized


def _apply_antigravity_patches() -> None:
    """Applies in-place compatibility enhancements to LiteLLM's GoogleGenAIAdapter."""
    import litellm.google_genai.adapters.handler as genai_handler_mod
    import litellm.google_genai.adapters.transformation as genai_transform_mod
    import litellm.litellm_core_utils.json_validation_rule as json_rule_mod
    import litellm.llms.vertex_ai.google_genai.transformation as vertex_genai_mod
    from litellm.types.llms.openai import (
        AllMessageValues,
        ChatCompletionAssistantMessage,
        ChatCompletionAssistantToolCall,
        ChatCompletionImageObject,
        ChatCompletionSystemMessage,
        ChatCompletionTextObject,
        ChatCompletionToolCallFunctionChunk,
        ChatCompletionToolMessage,
        ChatCompletionUserMessage,
    )
    from litellm.types.utils import StreamingChoices

    if getattr(genai_transform_mod, "_antigravity_patched", False):
        return

    # 1. Patch JSON Schema normalization for protojson tool declarations
    def _patched_normalize_tool_schema(tool: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(tool, dict):
            return tool
        normalized_tool = tool.copy()
        if "function" in tool and isinstance(tool["function"], dict):
            normalized_tool["function"] = tool["function"].copy()
            raw_params = tool["function"].get("parameters")
            if raw_params:
                normalized_tool["function"]["parameters"] = _normalize_protojson_schema(raw_params)
            else:
                normalized_tool["function"]["parameters"] = {"type": "object", "properties": {}}
        return normalized_tool

    json_rule_mod.normalize_json_schema_types = _normalize_protojson_schema
    json_rule_mod.normalize_tool_schema = _patched_normalize_tool_schema
    genai_transform_mod.normalize_json_schema_types = _normalize_protojson_schema
    genai_transform_mod.normalize_tool_schema = _patched_normalize_tool_schema

    # 2. Patch GoogleGenAIAdapter._transform_contents_to_messages
    def _patched_transform_contents_to_messages(
        self: Any,
        contents: list[dict[str, Any]],
        system_instruction: Mapping[str, Any] | None = None,
    ) -> list[AllMessageValues]:
        messages: list[AllMessageValues] = []

        if system_instruction and isinstance(system_instruction, Mapping):
            system_parts = system_instruction.get("parts", [])
            sys_texts = [
                p["text"]
                for p in system_parts
                if isinstance(p, Mapping) and isinstance(p.get("text"), str) and p["text"]
            ]
            if sys_texts:
                messages.append(
                    ChatCompletionSystemMessage(role="system", content="\n\n".join(sys_texts))
                )

        call_counter = 0
        pending_call_ids: dict[str, deque[str]] = defaultdict(deque)

        for content in contents:
            role = content.get("role", "user")
            parts: Sequence[Any] = content.get("parts", [])

            # Extract any tool response parts regardless of content role.
            # Antigravity CLI sends functionResponse with role: "model".
            tool_messages: list[ChatCompletionToolMessage] = []
            non_tool_parts: list[Any] = []

            for part in parts:
                if isinstance(part, dict) and ("functionResponse" in part or "function_response" in part):
                    func_response = part.get("functionResponse") or part.get("function_response") or {}
                    fn_name = func_response.get("name", "unknown")
                    explicit_id = func_response.get("id")
                    if explicit_id:
                        call_id = str(explicit_id)
                    elif pending_call_ids[fn_name]:
                        call_id = pending_call_ids[fn_name].popleft()
                    else:
                        call_counter += 1
                        call_id = f"call_{fn_name}_{call_counter}"

                    resp_payload = func_response.get("response", {})
                    tool_messages.append(
                        ChatCompletionToolMessage(
                            role="tool",
                            tool_call_id=call_id,
                            content=(
                                resp_payload
                                if isinstance(resp_payload, str)
                                else json.dumps(resp_payload)
                            ),
                        )
                    )
                else:
                    non_tool_parts.append(part)

            # Tool responses must immediately follow the assistant tool_calls turn
            if tool_messages:
                messages.extend(tool_messages)

            # If there were only tool response parts, this turn is fully converted
            if not non_tool_parts:
                continue

            parts = non_tool_parts

            if role == "user":
                content_parts: list[ChatCompletionTextObject | ChatCompletionImageObject] = []

                for part in parts:
                    if isinstance(part, dict):
                        if "text" in part and not part.get("thought"):
                            content_parts.append(
                                cast(ChatCompletionTextObject, {"type": "text", "text": part["text"]})
                            )
                        elif "inline_data" in part or "inlineData" in part:
                            inline_data = part.get("inline_data") or part.get("inlineData") or {}
                            mime_type = (
                                inline_data.get("mime_type")
                                or inline_data.get("mimeType")
                                or "image/jpeg"
                            )
                            data = inline_data.get("data", "")
                            content_parts.append(
                                cast(
                                    ChatCompletionImageObject,
                                    {
                                        "type": "image_url",
                                        "image_url": {"url": f"data:{mime_type};base64,{data}"},
                                    },
                                )
                            )
                    elif isinstance(part, str):
                        content_parts.append(
                            cast(ChatCompletionTextObject, {"type": "text", "text": part})
                        )

                if content_parts:
                    if (
                        len(content_parts) == 1
                        and isinstance(content_parts[0], dict)
                        and content_parts[0].get("type") == "text"
                    ):
                        text_part = cast(ChatCompletionTextObject, content_parts[0])
                        messages.append(
                            ChatCompletionUserMessage(role="user", content=text_part["text"])
                        )
                    else:
                        messages.append(
                            ChatCompletionUserMessage(role="user", content=content_parts)
                        )

            elif role == "model":
                combined_text = ""
                tool_calls: list[ChatCompletionAssistantToolCall] = []

                for part in parts:
                    if isinstance(part, dict):
                        if part.get("thought") is True:
                            continue
                        if "text" in part and part["text"]:
                            combined_text += part["text"]
                        elif "functionCall" in part or "function_call" in part:
                            func_call = part.get("functionCall") or part.get("function_call") or {}
                            fn_name = func_call.get("name", "unknown")
                            explicit_id = func_call.get("id")
                            if explicit_id:
                                call_id = str(explicit_id)
                            else:
                                call_counter += 1
                                call_id = f"call_{fn_name}_{call_counter}"
                            pending_call_ids[fn_name].append(call_id)

                            tool_calls.append(
                                ChatCompletionAssistantToolCall(
                                    id=call_id,
                                    type="function",
                                    function=ChatCompletionToolCallFunctionChunk(
                                        name=fn_name,
                                        arguments=json.dumps(func_call.get("args", {})),
                                    ),
                                )
                            )
                    elif isinstance(part, str):
                        combined_text += part

                if tool_calls:
                    messages.append(
                        ChatCompletionAssistantMessage(
                            role="assistant",
                            content=combined_text if combined_text else None,
                            tool_calls=tool_calls,
                        )
                    )
                elif combined_text:
                    messages.append(
                        ChatCompletionAssistantMessage(
                            role="assistant",
                            content=combined_text,
                        )
                    )

        return messages

    genai_transform_mod.GoogleGenAIAdapter._transform_contents_to_messages = (
        _patched_transform_contents_to_messages
    )

    # 3. Patch streaming chunk translation to flush zero-argument tool calls & reasoning_content
    _orig_translate_streaming = (
        genai_transform_mod.GoogleGenAIAdapter.translate_streaming_completion_to_generate_content
    )

    def _patched_translate_streaming_completion_to_generate_content(
        self: Any,
        response: Any,
        wrapper: Any,
    ) -> Mapping[str, object] | None:
        choice = response.choices[0] if getattr(response, "choices", None) else None
        if not choice:
            return None

        parts: list[dict[str, Any]] = []
        if isinstance(choice, StreamingChoices) and choice.delta:
            reasoning = getattr(choice.delta, "reasoning_content", None)
            if reasoning:
                parts.append({"text": reasoning, "thought": True})
            delta_parts = self._transform_openai_delta_to_google_genai_parts_with_accumulation(
                choice.delta, wrapper
            )
            if delta_parts:
                parts.extend(delta_parts)
            finish_reason = getattr(choice, "finish_reason", None)
        else:
            return _orig_translate_streaming(self, response, wrapper)

        # If the stream is finishing and there are still accumulated tool calls
        # (e.g. zero-argument tool calls where arguments remained ""), flush them now.
        if finish_reason and getattr(wrapper, "accumulated_tool_calls", None):
            for idx, acc in list(wrapper.accumulated_tool_calls.items()):
                acc_name = acc.get("name")
                acc_args_str = (acc.get("arguments") or "").strip()
                if acc_name:
                    try:
                        parsed_args = json.loads(acc_args_str) if acc_args_str else {}
                    except json.JSONDecodeError:
                        parsed_args = {}
                    parts.append({"functionCall": {"name": acc_name, "args": parsed_args}})
                    del wrapper.accumulated_tool_calls[idx]

        if not parts and not finish_reason:
            return None

        streaming_chunk: dict[str, Any] = {
            "candidates": [
                {
                    "content": {"parts": parts, "role": "model"},
                    "finishReason": self._map_finish_reason(finish_reason) if finish_reason else None,
                    "index": 0,
                    "safetyRatings": [],
                }
            ]
        }

        if finish_reason:
            usage = getattr(response, "usage", None)
            streaming_chunk["usageMetadata"] = (
                self._map_usage(usage)
                if usage
                else {
                    "promptTokenCount": 0,
                    "candidatesTokenCount": 0,
                    "totalTokenCount": 0,
                }
            )

        return streaming_chunk

    genai_transform_mod.GoogleGenAIAdapter.translate_streaming_completion_to_generate_content = (
        _patched_translate_streaming_completion_to_generate_content
    )

    # 4. Preserve HTTP status codes (429/400/404) in GenerateContentToCompletionHandler
    #    so LiteLLM Router fallbacks and retries trigger properly.
    _orig_prepare_kwargs = genai_handler_mod.GenerateContentToCompletionHandler._prepare_completion_kwargs

    @staticmethod  # type: ignore[misc]
    def _patched_prepare_completion_kwargs(*args: Any, **kwargs: Any) -> Any:
        res = _orig_prepare_kwargs(*args, **kwargs)
        if res.get("stream"):
            res.setdefault("stream_options", {"include_usage": True})
        return res

    @staticmethod  # type: ignore[misc]
    async def _patched_async_generate_content_handler(
        model: str,
        contents: Any,
        litellm_params: Any,
        config: dict[str, object] | None = None,
        stream: bool = False,
        **kwargs: object,
    ) -> Any:
        import litellm

        completion_kwargs = (
            genai_handler_mod.GenerateContentToCompletionHandler._prepare_completion_kwargs(
                model=model,
                contents=contents,
                config=config,
                stream=stream,
                litellm_params=litellm_params,
                extra_kwargs=kwargs,
            )
        )
        completion_response = await litellm.acompletion(**completion_kwargs)
        if stream:
            if not hasattr(completion_response, "__aiter__"):
                return genai_handler_mod.GOOGLE_GENAI_ADAPTER.translate_completion_to_generate_content(
                    completion_response
                )
            transformed_stream = (
                genai_handler_mod.GOOGLE_GENAI_ADAPTER.translate_completion_output_params_streaming(
                    completion_response
                )
            )
            if transformed_stream is not None:
                return transformed_stream
            raise ValueError("Failed to transform streaming response")
        return genai_handler_mod.GOOGLE_GENAI_ADAPTER.translate_completion_to_generate_content(
            completion_response
        )

    genai_handler_mod.GenerateContentToCompletionHandler._prepare_completion_kwargs = (
        _patched_prepare_completion_kwargs
    )
    genai_handler_mod.GenerateContentToCompletionHandler.async_generate_content_handler = (
        _patched_async_generate_content_handler
    )

    # 5. Convert Gemini 3 `thinkingLevel` -> `thinkingBudget` when falling back to Gemini 2.5
    _orig_vertex_transform = (
        vertex_genai_mod.VertexAIGoogleGenAIConfig.transform_generate_content_request
    )

    def _patched_vertex_transform_generate_content_request(
        self: Any,
        model: str,
        contents: Any,
        tools: Any | None,
        generate_content_config_dict: dict,
        system_instruction: Any | None = None,
    ) -> dict:
        if generate_content_config_dict and not model.startswith("gemini-3"):
            for tc_key in ("thinking_config", "thinkingConfig"):
                tc = generate_content_config_dict.get(tc_key)
                if isinstance(tc, dict):
                    level = tc.pop("thinkingLevel", None) or tc.pop("thinking_level", None)
                    if level and "thinkingBudget" not in tc and "thinking_budget" not in tc:
                        tc["thinkingBudget"] = _THINKING_LEVEL_TO_BUDGET.get(
                            str(level).upper(), 8192
                        )
        return _orig_vertex_transform(
            self,
            model=model,
            contents=contents,
            tools=tools,
            generate_content_config_dict=generate_content_config_dict,
            system_instruction=system_instruction,
        )

    vertex_genai_mod.VertexAIGoogleGenAIConfig.transform_generate_content_request = (
        _patched_vertex_transform_generate_content_request
    )

    genai_transform_mod._antigravity_patched = True  # type: ignore[attr-defined]


# Apply patches when imported by LiteLLM Proxy at startup
_apply_antigravity_patches()


class AntigravityCompatLogger(CustomLogger):
    """LiteLLM Proxy callback hook for Antigravity CLI compatibility."""

    def __init__(self) -> None:
        super().__init__()
        _apply_antigravity_patches()


antigravity_compat = AntigravityCompatLogger()
