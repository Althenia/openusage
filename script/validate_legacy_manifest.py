import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit


def validate_manifest(path):
    manifest = json.loads(path.read_bytes())
    if not isinstance(manifest, dict) or manifest.get("version") != "0.6.28":
        raise ValueError("expected a version 0.6.28 manifest object")
    platforms = manifest.get("platforms")
    if not isinstance(platforms, dict) or not platforms:
        raise ValueError("platforms must be a nonempty object")
    for name, entry in platforms.items():
        if not isinstance(name, str) or not name.strip() or not isinstance(entry, dict):
            raise ValueError("each platform must name an update object")
        signature = entry.get("signature")
        if not isinstance(signature, str) or not signature.strip():
            raise ValueError("each platform requires a nonempty signature")
        url = entry.get("url")
        if not isinstance(url, str) or not url.strip():
            raise ValueError("each platform requires an HTTPS URL")
        parsed = urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ValueError("each platform requires an HTTPS URL")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    arguments = parser.parse_args()
    try:
        validate_manifest(arguments.manifest)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Invalid legacy updater manifest: {error}\n")
