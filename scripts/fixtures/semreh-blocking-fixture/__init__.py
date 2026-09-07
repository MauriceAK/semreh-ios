"""Exact, disposable Slice 3 blocking-callback fixture.

This plugin is loaded only when the launcher is given the explicit
``--approval-secret-fixture`` flag.  It has no shell, subprocess, network, or
credential behavior.  The approval tool only enters the stock approval gate;
the secret tool loads a plugin-owned skill so stock ``secret.request`` wiring
is exercised without ever supplying or persisting a real value.
"""

from __future__ import annotations

import json
from pathlib import Path

from tools.approval import request_tool_approval
from tools.skills_tool import skill_view


PLUGIN_TOOLSET = "semreh_blocking_fixture"
APPROVAL_TOOL = "semreh_fixture_approval"
SECRET_TOOL = "semreh_fixture_secret"


def _approval(_args: dict, **_kwargs) -> str:
    decision = request_tool_approval(
        APPROVAL_TOOL,
        "synthetic approval cancellation fixture",
        rule_key="semreh-blocking-fixture:approval",
    )
    return json.dumps(
        {"fixture": "approval", "approved": bool(decision.get("approved"))},
        separators=(",", ":"),
    )


def _secret(_args: dict, **_kwargs) -> str:
    # skill_view is the public skill surface.  Its required environment
    # variable path invokes the stock secret capture callback registered by
    # tui_gateway; an empty response is reported as skipped, never persisted.
    return skill_view("semreh-fixture-empty-secret", preprocess=False)


def register(ctx) -> None:
    ctx.register_tool(
        APPROVAL_TOOL,
        PLUGIN_TOOLSET,
        {
            "name": APPROVAL_TOOL,
            "description": "Disposable no-op approval callback fixture.",
            "parameters": {
                "type": "object",
                "properties": {},
                "additionalProperties": False,
            },
        },
        _approval,
        description="Disposable no-op approval callback fixture.",
    )
    ctx.register_tool(
        SECRET_TOOL,
        PLUGIN_TOOLSET,
        {
            "name": SECRET_TOOL,
            "description": "Disposable empty-value secret callback fixture.",
            "parameters": {
                "type": "object",
                "properties": {},
                "additionalProperties": False,
            },
        },
        _secret,
        description="Disposable empty-value secret callback fixture.",
    )
    ctx.register_skill(
        "empty_secret",
        Path(__file__).parent / "skills" / "empty_secret" / "SKILL.md",
        description="Exact disposable skill that requests one empty secret value.",
    )
