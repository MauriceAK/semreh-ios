#!/usr/bin/env python3
"""Bounded read-only stock session-list and search contract probe.

This probe exercises only the pinned disposable HTTPS deployment.  It reads
the profile-scoped and single-profile session lists with each stock archive
filter and performs one search for the retained synthetic relaunch seed.
Evidence contains request shapes and response schemas/counts, never transcript
text, IDs, paths, or authentication material.
"""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from typing import Any

from direct_hermes_capture import write_fixture
import direct_hermes_probe as stock_probe
from direct_hermes_identity_probe import authenticated
from direct_hermes_reasoning_probe import (
    PROFILE,
    _output_path,
)


SESSION_ROUTE = "/api/profiles/sessions"
SINGLE_PROFILE_SESSION_ROUTE = "/api/sessions"
SEARCH_ROUTE = "/api/sessions/search"
ARCHIVED_FILTERS = ("exclude", "only", "include")
SESSION_LIMIT = 20
SINGLE_PROFILE_SESSION_LIMIT = 100
SINGLE_PROFILE_OFFSETS = (0, 100)
SEARCH_LIMIT = 20
SEARCH_MARKER = "SEMREH_SLICE3_APP_RELAUNCH_SEED_AUTH_V1"


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _keys(value: Any) -> list[str]:
    if not isinstance(value, dict):
        return []
    return sorted(str(key) for key in value)


def _session_summary(payload: Any, *, archived: str, requested_limit: int) -> dict:
    """Validate one stock ``/api/profiles/sessions`` response.

    Only bounded type/key/count information is returned.  In particular, row
    values are inspected for the required filter but never copied into the
    evidence object.
    """
    if not isinstance(payload, dict):
        raise AssertionError("session list response is not an object")
    required = {"sessions", "total", "profile_totals", "limit", "offset", "errors"}
    if not required <= set(payload):
        raise AssertionError("session list envelope is missing required fields")
    rows = payload["sessions"]
    total = payload["total"]
    profile_totals = payload["profile_totals"]
    errors = payload["errors"]
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise AssertionError("session list rows are not objects")
    if not _is_int(total) or total < 0:
        raise AssertionError("session list total is not a non-negative integer")
    if total < len(rows):
        raise AssertionError("session list total is smaller than returned rows")
    if not isinstance(profile_totals, dict):
        raise AssertionError("session list profile_totals is not an object")
    if set(profile_totals) != {PROFILE} or not _is_int(profile_totals.get(PROFILE)):
        raise AssertionError("session list profile totals are not default-scoped")
    if profile_totals[PROFILE] != total:
        raise AssertionError("session list total disagrees with default profile total")
    if payload["limit"] != requested_limit or payload["offset"] != 0:
        raise AssertionError("session list pagination readback differs from request")
    if not isinstance(errors, list) or errors:
        raise AssertionError("session list reported profile read errors")

    archived_values: set[bool] = set()
    pinned_values: list[bool] = []
    row_keys: set[str] = set()
    for row in rows:
        row_keys.update(str(key) for key in row)
        if row.get("profile") != PROFILE or row.get("is_default_profile") is not True:
            raise AssertionError("session row escaped the requested default profile")
        value = row.get("archived")
        if not isinstance(value, bool):
            raise AssertionError("session row archived flag is not boolean")
        archived_values.add(value)
        pinned = row.get("pinned")
        if not isinstance(pinned, bool):
            raise AssertionError("session row pinned flag is not boolean")
        pinned_values.append(pinned)
        if archived == "exclude" and value:
            raise AssertionError("archived=exclude returned an archived row")
        if archived == "only" and not value:
            raise AssertionError("archived=only returned an unarchived row")
    # The pinned route deliberately back-fills pinned rows past the requested
    # window, including when limit=0.  Accept only that source-defined
    # over-fetch; never treat an arbitrary extra row as a valid count result.
    if len(rows) > requested_limit and any(not pinned for pinned in pinned_values[requested_limit:]):
        raise AssertionError("session list exceeded its limit with a non-pinned row")

    return {
        "top_level_keys": _keys(payload),
        "row_keys": sorted(row_keys),
        "row_count": len(rows),
        "total": total,
        "profile_totals_keys": sorted(str(key) for key in profile_totals),
        "archived_values": sorted(archived_values),
        "pinned_overfetch_count": sum(pinned_values[requested_limit:]),
        "errors_count": len(errors),
        "filter_verified": archived,
        "filter_positive_rows_observed": bool(rows),
        "limit": requested_limit,
        "offset": 0,
    }


def _single_profile_session_summary(
    payload: Any,
    *,
    archived: str,
    requested_limit: int,
    requested_offset: int,
) -> dict:
    """Validate the official single-profile ``/api/sessions`` envelope.

    This route deliberately has no ``profile_totals`` or ``errors`` fields.
    Pinned rows may be appended past the requested page limit, so only the
    source-defined pinned over-fetch is accepted.
    """
    if not isinstance(payload, dict):
        raise AssertionError("single-profile session response is not an object")
    required = {"sessions", "total", "limit", "offset"}
    if not required <= set(payload):
        raise AssertionError("single-profile session envelope is missing required fields")
    if "profile_totals" in payload or "errors" in payload:
        raise AssertionError("single-profile route returned the profile-aggregate envelope")
    rows = payload["sessions"]
    total = payload["total"]
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise AssertionError("single-profile session rows are not objects")
    if not _is_int(total) or total < 0:
        raise AssertionError("single-profile session total is not a non-negative integer")
    if total < len(rows):
        raise AssertionError("single-profile session total is smaller than its page")
    if payload["limit"] != requested_limit or payload["offset"] != requested_offset:
        raise AssertionError("single-profile pagination readback differs from request")

    archived_values: set[bool] = set()
    pinned_values: list[bool] = []
    row_keys: set[str] = set()
    for row in rows:
        row_keys.update(str(key) for key in row)
        if row.get("profile") != PROFILE or row.get("is_default_profile") is not True:
            raise AssertionError("single-profile row escaped the requested profile")
        value = row.get("archived")
        if not isinstance(value, bool):
            raise AssertionError("single-profile archived flag is not boolean")
        archived_values.add(value)
        pinned = row.get("pinned")
        if not isinstance(pinned, bool):
            raise AssertionError("single-profile pinned flag is not boolean")
        pinned_values.append(pinned)
        if archived == "exclude" and value:
            raise AssertionError("single-profile archived=exclude returned an archived row")
        if archived == "only" and not value:
            raise AssertionError("single-profile archived=only returned an unarchived row")
    if len(rows) > requested_limit and any(not pinned for pinned in pinned_values[requested_limit:]):
        raise AssertionError("single-profile page exceeded its limit with a non-pinned row")

    return {
        "top_level_keys": _keys(payload),
        "row_keys": sorted(row_keys),
        "row_count": len(rows),
        "total": total,
        "archived_values": sorted(archived_values),
        "pinned_overfetch_count": sum(pinned_values[requested_limit:]),
        "filter_verified": archived,
        "filter_positive_rows_observed": bool(rows),
        "limit": requested_limit,
        "offset": requested_offset,
        "profile": PROFILE,
    }


def _search_summary(payload: Any, *, marker: str, requested_limit: int) -> dict:
    """Validate the stock search envelope without retaining result contents."""
    if not isinstance(payload, dict) or not isinstance(payload.get("results"), list):
        raise AssertionError("session search response must contain a results array")
    results = payload["results"]
    required = {"session_id", "lineage_root", "snippet", "role", "archived"}
    result_keys: set[str] = set()
    matching_results = 0
    roles: set[str] = set()
    archived_values: set[bool] = set()
    for result in results:
        if not isinstance(result, dict) or not required <= set(result):
            raise AssertionError("session search result is missing stock fields")
        result_keys.update(str(key) for key in result)
        if not isinstance(result["session_id"], str) or not result["session_id"]:
            raise AssertionError("session search result has no durable session ID")
        if not isinstance(result["lineage_root"], str) or not result["lineage_root"]:
            raise AssertionError("session search result has no lineage root")
        if not isinstance(result["snippet"], str):
            raise AssertionError("session search snippet is not text")
        if result["role"] is not None and not isinstance(result["role"], str):
            raise AssertionError("session search role is not text or null")
        if result["role"] is not None:
            roles.add(result["role"])
        if not isinstance(result["archived"], bool):
            raise AssertionError("session search archived flag is not boolean")
        archived_values.add(result["archived"])
        if marker in result["snippet"]:
            matching_results += 1
    if matching_results < 1:
        raise AssertionError("synthetic relaunch seed was not found in search snippets")
    if matching_results != len(results):
        raise AssertionError("session search returned a non-synthetic result")
    if len(results) > requested_limit:
        raise AssertionError("session search exceeded its bounded limit")

    return {
        "top_level_keys": _keys(payload),
        "result_keys": sorted(result_keys),
        "result_count": len(results),
        "marker_match_count": matching_results,
        "all_results_match_marker": True,
        "roles": sorted(roles),
        "archived_values": sorted(archived_values),
        "limit": requested_limit,
        "profile": PROFILE,
    }


async def exercise(client, evidence: dict) -> None:
    """Run only GET requests against an already-authenticated client."""
    session_checks = []
    for archived in ARCHIVED_FILTERS:
        params = {
            "profile": PROFILE,
            "limit": SESSION_LIMIT,
            "offset": 0,
            "archived": archived,
            "order": "recent",
        }
        response = await client.get(SESSION_ROUTE, params=params)
        if response.status_code != 200:
            raise RuntimeError("profile session list request failed")
        payload = response.json()
        session_checks.append({
            "request": {"method": "GET", "path": SESSION_ROUTE, "params": dict(params)},
            "response_status": response.status_code,
            "response": _session_summary(payload, archived=archived, requested_limit=SESSION_LIMIT),
        })

        count_params = dict(params)
        count_params["limit"] = 0
        count_response = await client.get(SESSION_ROUTE, params=count_params)
        if count_response.status_code != 200:
            raise RuntimeError("profile session count request failed")
        count_payload = count_response.json()
        session_checks.append({
            "request": {"method": "GET", "path": SESSION_ROUTE, "params": dict(count_params)},
            "response_status": count_response.status_code,
            "response": _session_summary(count_payload, archived=archived, requested_limit=0),
        })

    single_profile_checks = []
    for archived in ARCHIVED_FILTERS:
        for offset in SINGLE_PROFILE_OFFSETS:
            params = {
                "profile": PROFILE,
                "limit": SINGLE_PROFILE_SESSION_LIMIT,
                "offset": offset,
                "archived": archived,
                "order": "recent",
            }
            response = await client.get(SINGLE_PROFILE_SESSION_ROUTE, params=params)
            if response.status_code != 200:
                raise RuntimeError("single-profile session list request failed")
            payload = response.json()
            single_profile_checks.append({
                "request": {
                    "method": "GET",
                    "path": SINGLE_PROFILE_SESSION_ROUTE,
                    "params": dict(params),
                },
                "response_status": response.status_code,
                "response": _single_profile_session_summary(
                    payload,
                    archived=archived,
                    requested_limit=SINGLE_PROFILE_SESSION_LIMIT,
                    requested_offset=offset,
                ),
            })

        count_params = {
            "profile": PROFILE,
            "limit": 0,
            "offset": 0,
            "archived": archived,
            "order": "recent",
        }
        count_response = await client.get(
            SINGLE_PROFILE_SESSION_ROUTE, params=count_params
        )
        if count_response.status_code != 200:
            raise RuntimeError("single-profile session count request failed")
        single_profile_checks.append({
            "request": {
                "method": "GET",
                "path": SINGLE_PROFILE_SESSION_ROUTE,
                "params": dict(count_params),
            },
            "response_status": count_response.status_code,
            "response": _single_profile_session_summary(
                count_response.json(),
                archived=archived,
                requested_limit=0,
                requested_offset=0,
            ),
        })

    search_params = {"q": SEARCH_MARKER, "profile": PROFILE, "limit": SEARCH_LIMIT}
    search_response = await client.get(SEARCH_ROUTE, params=search_params)
    if search_response.status_code != 200:
        raise RuntimeError("session search request failed")
    search_payload = search_response.json()
    evidence["session_lists"] = session_checks
    evidence["single_profile_session_lists"] = single_profile_checks
    evidence["search"] = {
        "request": {"method": "GET", "path": SEARCH_ROUTE, "params": dict(search_params)},
        "response_status": search_response.status_code,
        "response": _search_summary(
            search_payload, marker=SEARCH_MARKER, requested_limit=SEARCH_LIMIT
        ),
    }


async def _run_authenticated(credentials: dict, evidence: dict) -> None:
    async with authenticated(
        credentials,
        evidence,
        base=stock_probe.HTTPS_ORIGIN,
        origin=stock_probe.HTTPS_ORIGIN,
    ) as (client, _ticket):
        await exercise(client, evidence)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    return parser


def run(output: Path) -> None:
    """Validate the exact stock fixture, then authenticate and probe GETs."""
    stock_probe.validate()
    credentials_path = stock_probe.RUNTIME / "credentials.json"
    credentials = json.loads(credentials_path.read_text(encoding="utf-8"))
    evidence = {
        "sanitized": True,
        "outcome": "failed",
        "source_pin": stock_probe.PIN,
        "deployment": stock_probe.HTTPS_ORIGIN,
        "profile": PROFILE,
        "bounded_read_only": True,
        "phase": "authenticated read-only session convenience requests",
        "cleanup_errors": [],
    }
    try:
        asyncio.run(_run_authenticated(credentials, evidence))
        if evidence["cleanup_errors"]:
            raise AssertionError("fixture authentication cleanup failed")
        evidence["outcome"] = "passed"
    except Exception as error:
        evidence["error_type"] = type(error).__name__
        write_fixture(output, evidence)
        output.chmod(0o600)
        raise RuntimeError(f"Session convenience probe failed; evidence: {output}") from None
    write_fixture(output, evidence)
    output.chmod(0o600)
    print(f"Session convenience assertions passed; sanitized evidence: {output}")


if __name__ == "__main__":
    args = build_parser().parse_args()
    run(_output_path(args.output))
