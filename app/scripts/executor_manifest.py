#!/usr/bin/env python3
"""Sign or verify ExecutorArtifacts.json using the app's P-256 contract."""

import argparse
import base64
import json
import pathlib
import subprocess
import tempfile
from typing import Optional

ALGORITHM = "P256-SHA256-DER"
KEY_ID = "perch-executor-artifacts-2026-01"
PUBLIC_KEY = b"""-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEw0GxpZZneZlYNcgeHV9sV62TZWoa
xN0UvteMArMUnTaCkLvtKDi1Eiw9I3GFfiNaJ0li9d62h3hWD3TvXnWpEQ==
-----END PUBLIC KEY-----
"""


def canonical_payload(envelope: dict) -> bytes:
    payload = base64.b64decode(envelope["signed_payload"], validate=True)
    parsed = json.loads(payload)
    canonical = json.dumps(
        parsed, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    if payload != canonical:
        raise ValueError("signed_payload is not canonical sorted compact JSON")
    required = {
        "schema_version": 1,
        "containerization_version": "0.33.3",
        "containerization_commit": "a2a1add6c7e1a1665e5397edc49d925c49090b3a",
        "minimum_os": "26.0",
        "architecture": "arm64",
    }
    for key, expected in required.items():
        if parsed.get(key) != expected:
            raise ValueError(f"unexpected {key}: {parsed.get(key)!r}")
    return payload


def run(*args: str, input_data: Optional[bytes] = None) -> bytes:
    return subprocess.run(
        args, input=input_data, check=True, capture_output=True
    ).stdout


def verify(path: pathlib.Path) -> None:
    envelope = json.loads(path.read_text())
    if envelope.get("algorithm") != ALGORITHM or envelope.get("key_id") != KEY_ID:
        raise ValueError("manifest signer contract does not match the app")
    payload = canonical_payload(envelope)
    signature = base64.b64decode(envelope.get("signature", ""), validate=True)
    if not signature:
        raise ValueError("manifest signature is empty")
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        payload_path = root / "payload.json"
        signature_path = root / "signature.der"
        public_path = root / "public.pem"
        payload_path.write_bytes(payload)
        signature_path.write_bytes(signature)
        public_path.write_bytes(PUBLIC_KEY)
        subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(public_path),
                "-signature", str(signature_path), str(payload_path),
            ],
            check=True,
        )


def sign(path: pathlib.Path, private_key: pathlib.Path, output: pathlib.Path) -> None:
    envelope = json.loads(path.read_text())
    payload = canonical_payload(envelope)
    expected_public = run("openssl", "pkey", "-pubin", "-outform", "DER", input_data=PUBLIC_KEY)
    actual_public_pem = run(
        "openssl", "pkey", "-in", str(private_key), "-pubout"
    )
    actual_public = run(
        "openssl", "pkey", "-pubin", "-outform", "DER", input_data=actual_public_pem
    )
    if actual_public != expected_public:
        raise ValueError("private key does not match the embedded P-256 release public key")
    with tempfile.NamedTemporaryFile() as payload_file:
        payload_file.write(payload)
        payload_file.flush()
        signature = run(
            "openssl", "dgst", "-sha256", "-sign", str(private_key), payload_file.name
        )
    envelope["signature"] = base64.b64encode(signature).decode()
    output.write_text(json.dumps(envelope, indent=2, sort_keys=True) + "\n")
    verify(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--sign-key", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    if args.sign_key:
        if not args.output:
            parser.error("--output is required with --sign-key")
        sign(args.manifest, args.sign_key, args.output)
    else:
        verify(args.manifest)


if __name__ == "__main__":
    main()
