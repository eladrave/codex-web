#!/usr/bin/env python3

import argparse
import json
import re
from pathlib import Path
from urllib.request import Request, urlopen
from xml.etree import ElementTree


APPCAST_URL = "https://persistent.oaistatic.com/codex-app-prod/appcast.xml"
NPM_METADATA_URL = "https://registry.npmjs.org/@openai%2Fcodex/latest"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9A-Za-z-]+)+$")


def fetch(url: str) -> bytes:
    request = Request(url, headers={"User-Agent": "codex-web-updater/1.0"})
    with urlopen(request, timeout=30) as response:
        return response.read()


def read_source(path: Path | None, url: str) -> bytes:
    return path.read_bytes() if path is not None else fetch(url)


def validate_version(value: str, label: str) -> str:
    value = value.strip()
    if not VERSION_PATTERN.fullmatch(value):
        raise ValueError(f"invalid {label} version: {value!r}")
    return value


def latest_desktop_version(appcast: bytes) -> str:
    root = ElementTree.fromstring(appcast)
    candidates = []
    for item in root.findall("./channel/item"):
        build = item.findtext(f"{{{SPARKLE_NAMESPACE}}}version")
        version = item.findtext(f"{{{SPARKLE_NAMESPACE}}}shortVersionString")
        if build and version:
            candidates.append((int(build), validate_version(version, "desktop")))
    if not candidates:
        raise ValueError("the Codex appcast contained no versioned releases")
    return max(candidates)[1]


def latest_cli_version(metadata: bytes) -> str:
    value = json.loads(metadata).get("version")
    if not isinstance(value, str):
        raise ValueError("the Codex CLI metadata did not contain a version")
    return validate_version(value, "CLI")


def current_arg(dockerfile: str, name: str) -> str:
    match = re.search(rf"^ARG {re.escape(name)}=(\S+)$", dockerfile, re.MULTILINE)
    if match is None:
        raise ValueError(f"Dockerfile does not define ARG {name}")
    return validate_version(match.group(1), name)


def replace_arg(dockerfile: str, name: str, value: str) -> str:
    updated, count = re.subn(
        rf"^ARG {re.escape(name)}=\S+$",
        f"ARG {name}={value}",
        dockerfile,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise ValueError(f"could not update ARG {name}")
    return updated


def write_github_output(path: Path, values: dict[str, object]) -> None:
    with path.open("a", encoding="utf-8") as output:
        for key, value in values.items():
            rendered = str(value).lower() if isinstance(value, bool) else str(value)
            output.write(f"{key}={rendered}\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Detect and optionally pin the latest Codex app and CLI releases."
    )
    parser.add_argument("--dockerfile", type=Path, default=Path("Dockerfile"))
    parser.add_argument("--appcast-file", type=Path)
    parser.add_argument("--npm-metadata-file", type=Path)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    dockerfile = args.dockerfile.read_text(encoding="utf-8")
    current_app = current_arg(dockerfile, "CODEX_APP_VERSION")
    current_cli = current_arg(dockerfile, "CODEX_VERSION")
    latest_app = latest_desktop_version(
        read_source(args.appcast_file, APPCAST_URL)
    )
    latest_cli = latest_cli_version(
        read_source(args.npm_metadata_file, NPM_METADATA_URL)
    )
    app_changed = current_app != latest_app
    cli_changed = current_cli != latest_cli
    changed = app_changed or cli_changed

    if args.write and changed:
        dockerfile = replace_arg(dockerfile, "CODEX_APP_VERSION", latest_app)
        dockerfile = replace_arg(dockerfile, "CODEX_VERSION", latest_cli)
        args.dockerfile.write_text(dockerfile, encoding="utf-8")

    result = {
        "changed": changed,
        "app_changed": app_changed,
        "cli_changed": cli_changed,
        "current_app_version": current_app,
        "current_cli_version": current_cli,
        "app_version": latest_app,
        "cli_version": latest_cli,
    }
    if args.github_output is not None:
        write_github_output(args.github_output, result)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
