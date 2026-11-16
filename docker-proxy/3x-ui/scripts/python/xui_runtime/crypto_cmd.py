"""Subprocess wrappers for xray/openssl (stdlib only, no third-party crypto)."""

from __future__ import annotations

import subprocess


def run_cmd(argv: list[str], *, timeout: float = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def xray_x25519(xray_bin: str) -> str:
    result = run_cmd([xray_bin, "x25519"])
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RuntimeError(
            f"xray x25519 failed (exit {result.returncode})" + (f": {stderr}" if stderr else "")
        )
    return result.stdout


def openssl_self_signed_cert(
    openssl_bin: str,
    key_out: str,
    cert_out: str,
    *,
    days: int = 3650,
    cn: str = "localhost",
) -> None:
    result = run_cmd(
        [
            openssl_bin,
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            key_out,
            "-out",
            cert_out,
            "-days",
            str(days),
            "-subj",
            f"/CN={cn}",
        ],
        timeout=120,
    )
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RuntimeError(
            "openssl self-signed cert generation failed"
            + (f": {stderr}" if stderr else "")
        )