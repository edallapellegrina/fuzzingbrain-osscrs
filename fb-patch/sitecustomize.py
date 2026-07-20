# import os

# Base URL of the OpenAI-compatible API server
_BASE = "http://172.17.0.1:11435/v1"
# Dummy API key, required
_KEY  = "dummy"
# Local LLM model
_MODEL = "qwen3-coder:30b"

try:
    import litellm as _l

    # Save the original sync implementation
    _orig_sync = _l.completion
    def _sync_patched(model="", messages=None, **kw):
        """
        Replacement for litellm.completion().
        Ignores the caller's model and injects:
          - API endpoint
          - API key
          - timeout
          - fixed model name
        """
        kw["api_base"] = _BASE
        kw["api_key"]  = _KEY
        kw["timeout"]  = 1800
        # Call the original LiteLLM function using the local model. "openai/" tells LiteLLM to use its OpenAI-compatible provider.
        return _orig_sync(model=f"openai/{_MODEL}", messages=messages, **kw)
    # Replace LiteLLM's sync completion() with the patched version
    _l.completion = _sync_patched

    # Save the original async implementation
    _orig_async = _l.acompletion
    async def _async_patched(model="", messages=None, **kw):
        """
        Async version of the same patch.
        """
        kw["api_base"] = _BASE
        kw["api_key"]  = _KEY
        kw["timeout"]  = 1800
        return await _orig_async(model=f"openai/{_MODEL}", messages=messages, **kw)
    # Replace LiteLLM's async completion() with the patched version
    _l.acompletion = _async_patched

    print(f"[sitecustomize] LiteLLM patched! base={_BASE} model={_MODEL}", flush=True)
except Exception as e:
    print(f"[sitecustomize] LiteLLM patch failed: {e}", flush=True)
