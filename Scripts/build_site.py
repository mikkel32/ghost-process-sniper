#!/usr/bin/env python3
"""Builds the website in Site/ into a static folder for GitHub Pages.

    python3 Scripts/build_site.py --out _site [--release release.json]

release.json is the output of
`gh release view --json tagName,publishedAt,assets,url` for the latest release. The download
button, version, size and checksum on the page come from it; without it the page links to the
latest release on GitHub instead. Images are copied from Docs/Assets so the README and the site
share one copy.
"""

import argparse
from datetime import datetime
import html
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "mikkel32/ghost-process-sniper"
REPOSITORY_URL = f"https://github.com/{REPOSITORY}"
SITE_URL = "https://mikkel32.github.io/ghost-process-sniper/"


def megabytes(size):
    return f"{size / 1_000_000:.0f} MB" if size >= 10_000_000 else f"{size / 1_000_000:.1f} MB"


def release_values(release):
    """Template values for the latest release, or links to the release list when there is none."""
    values = {
        "version": "",
        "download_url": f"{REPOSITORY_URL}/releases/latest",
        "download_meta": "Free · the latest release on GitHub",
        "release_url": f"{REPOSITORY_URL}/releases/latest",
        "dmg_name": "GhostProcessSniper-<version>.dmg",
        "sha256": "",
    }
    dmg = next((asset for asset in release.get("assets", []) if asset.get("name", "").endswith(".dmg")), None)
    tag = release.get("tagName", "")
    if not dmg or not tag.startswith("v"):
        return values
    version = tag[1:]
    values.update({
        "version": version,
        "download_url": dmg["url"],
        "download_meta": f"Version {version} · {megabytes(dmg['size'])} · Free",
        "release_url": release.get("url") or f"{REPOSITORY_URL}/releases/tag/{tag}",
        "dmg_name": dmg["name"],
    })
    digest = dmg.get("digest") or ""
    if digest.startswith("sha256:"):
        values["sha256"] = digest.removeprefix("sha256:")
    published = release.get("publishedAt")
    if published:
        date = datetime.fromisoformat(published.replace("Z", "+00:00"))
        values["download_meta"] += f" · {date.strftime('%B')} {date.day}, {date.year}"
    return values


def render(template, values):
    page = template
    for key, value in values.items():
        page = page.replace("{{" + key + "}}", html.escape(value, quote=True))
    # A checksum block only makes sense with a checksum.
    start, end = "<!--sha256-->", "<!--/sha256-->"
    if not values["sha256"]:
        while start in page:
            head, rest = page.split(start, 1)
            page = head + rest.split(end, 1)[1]
    else:
        page = page.replace(start, "").replace(end, "")
    leftover = [part.split("}}")[0] for part in page.split("{{")[1:]]
    if leftover:
        raise SystemExit(f"error: unfilled placeholders: {', '.join(sorted(set(leftover)))}")
    return page


def build(out, release):
    values = release_values(release)
    values.update({"site_url": SITE_URL, "repository_url": REPOSITORY_URL})
    source = ROOT / "Site"
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(source, out, ignore=shutil.ignore_patterns("*.html", ".DS_Store"))
    for page in source.glob("*.html"):
        (out / page.name).write_text(render(page.read_text(), values))
    assets = out / "assets"
    assets.mkdir(exist_ok=True)
    for image in (ROOT / "Docs/Assets").glob("*.png"):
        shutil.copy2(image, assets / image.name)
    (out / ".nojekyll").write_text("")
    return values


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--release", type=Path, help="gh release view --json output for the latest release")
    arguments = parser.parse_args(argv)
    release = {}
    if arguments.release and arguments.release.exists():
        text = arguments.release.read_text().strip()
        release = json.loads(text) if text else {}
    values = build(arguments.out, release)
    print(f"Built {arguments.out} for {values['version'] or 'no release'}", file=sys.stderr)


if __name__ == "__main__":
    main()
