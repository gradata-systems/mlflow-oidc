"""Read, check and bump the versions pinned by the OIDC image and chart.

The pins live in charts/mlflow-oidc/:
  Chart.yaml   appVersion (MLflow), the `mlflow` dependency version (must equal
               appVersion), the `mlflow-oidc-auth/version` annotation and the
               chart's own `version`.
  values.yaml  mlflow.image.tag, which must be v<MLflow>-oidc<plugin>.

Usage:
  python scripts/versions.py show              # key=value lines for $GITHUB_OUTPUT
  python scripts/versions.py check             # exit 1 if the pins disagree
  python scripts/versions.py latest            # newest upstream releases past the cooldown
  python scripts/versions.py upgrade           # move the pins to those, never downgrading
  python scripts/versions.py set --mlflow 3.19.0 --oidc-auth 11.6.0

Stdlib only, so it runs on a bare runner. Edits are line-level regex
substitutions so comments in the YAML files survive.
"""

import argparse
import json
import os
import re
import sys
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

CHART_DIR = Path(__file__).resolve().parents[1] / "charts" / "mlflow-oidc"
CHART_YAML = CHART_DIR / "Chart.yaml"
VALUES_YAML = CHART_DIR / "values.yaml"

STABLE_VERSION = re.compile(r"^\d+\.\d+\.\d+$")

CHART_VERSION_RE = re.compile(r'^(version: )"?([^"\s]+)"?$', re.MULTILINE)
APP_VERSION_RE = re.compile(r'^(appVersion: )"?([^"\s]+)"?$', re.MULTILINE)
OIDC_ANNOTATION_RE = re.compile(r'^(  mlflow-oidc-auth/version: )"?([^"\s]+)"?$', re.MULTILINE)
DEPENDENCY_RE = re.compile(r'^(  - name: mlflow\n    version: )"?([^"\s]+)"?$', re.MULTILINE)
IMAGE_TAG_RE = re.compile(r'^(    tag: )"?(v[^"\s]+)"?(.*)$', re.MULTILINE)
IMAGE_REPOSITORY_RE = re.compile(r'^(    repository: )"?([^"\s]+)"?$', re.MULTILINE)


@dataclass
class Pins:
    chart_version: str
    mlflow_version: str
    oidc_auth_version: str
    dependency_version: str
    image_tag: str

    @property
    def expected_image_tag(self) -> str:
        return image_tag(self.mlflow_version, self.oidc_auth_version)


def image_tag(mlflow_version: str, oidc_auth_version: str) -> str:
    return f"v{mlflow_version}-oidc{oidc_auth_version}"


def search(pattern: re.Pattern[str], text: str, path: Path) -> str:
    if m := pattern.search(text):
        return m.group(2)
    sys.exit(f"Could not find {pattern.pattern!r} in {path}")


def substitute(pattern: re.Pattern[str], value: str, text: str, path: Path) -> str:
    new_text, count = pattern.subn(lambda m: f'{m.group(1)}"{value}"', text, count=1)
    if count != 1:
        sys.exit(f"Could not find {pattern.pattern!r} in {path}")
    return new_text


def read_pins() -> Pins:
    chart = CHART_YAML.read_text()
    values = VALUES_YAML.read_text()
    return Pins(
        chart_version=search(CHART_VERSION_RE, chart, CHART_YAML),
        mlflow_version=search(APP_VERSION_RE, chart, CHART_YAML),
        oidc_auth_version=search(OIDC_ANNOTATION_RE, chart, CHART_YAML),
        dependency_version=search(DEPENDENCY_RE, chart, CHART_YAML),
        image_tag=search(IMAGE_TAG_RE, values, VALUES_YAML),
    )


def parse_version(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def bump_chart_version(current: str, *, minor: bool) -> str:
    major, minor_part, patch = parse_version(current)
    return f"{major}.{minor_part + 1}.0" if minor else f"{major}.{minor_part}.{patch + 1}"


def cmd_show(_: argparse.Namespace) -> None:
    pins = read_pins()
    image_repository = search(IMAGE_REPOSITORY_RE, VALUES_YAML.read_text(), VALUES_YAML)
    print(f"chart_name={CHART_DIR.name}")
    print(f"chart_version={pins.chart_version}")
    print(f"mlflow_version={pins.mlflow_version}")
    print(f"oidc_auth_version={pins.oidc_auth_version}")
    print(f"image_repository={image_repository}")
    print(f"image_tag={pins.image_tag}")
    # Charts are published next to the image, e.g. ghcr.io/<owner>/charts.
    print(f"chart_registry=oci://{image_repository.rsplit('/', 1)[0]}/charts")


def cmd_check(_: argparse.Namespace) -> None:
    pins = read_pins()
    errors = []
    for name, value in [
        ("chart version", pins.chart_version),
        ("appVersion", pins.mlflow_version),
        ("mlflow-oidc-auth/version annotation", pins.oidc_auth_version),
    ]:
        if not STABLE_VERSION.match(value):
            errors.append(f"{name} {value!r} is not a X.Y.Z version")
    if pins.dependency_version != pins.mlflow_version:
        errors.append(
            f"mlflow dependency version {pins.dependency_version!r} in {CHART_YAML.name} "
            f"must equal appVersion {pins.mlflow_version!r}"
        )
    if pins.image_tag != pins.expected_image_tag:
        errors.append(
            f"mlflow.image.tag {pins.image_tag!r} in {VALUES_YAML.name} "
            f"must be {pins.expected_image_tag!r}"
        )
    if errors:
        sys.exit("\n".join(errors) + "\nRun `scripts/versions.py set` to rewrite them.")
    print("Version pins are consistent.")


def cmd_set(args: argparse.Namespace) -> None:
    pins = read_pins()
    write_pins(pins, args.mlflow or pins.mlflow_version, args.oidc_auth or pins.oidc_auth_version)


def cmd_upgrade(args: argparse.Namespace) -> None:
    """Move each pin to the newest release past the cooldown, never downgrading."""
    pins = read_pins()
    cutoff = datetime.now(UTC) - timedelta(days=args.cooldown_days)
    mlflow_version = max(pins.mlflow_version, latest_mlflow(cutoff), key=parse_version)
    oidc_auth_version = max(pins.oidc_auth_version, latest_oidc_auth(cutoff), key=parse_version)
    changed = write_pins(pins, mlflow_version, oidc_auth_version)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as f:
            f.write(f"changed={str(changed).lower()}\n")
            f.write(f"mlflow_version={mlflow_version}\n")
            f.write(f"oidc_auth_version={oidc_auth_version}\n")


def write_pins(pins: Pins, mlflow_version: str, oidc_auth_version: str) -> bool:
    for value in (mlflow_version, oidc_auth_version):
        if not STABLE_VERSION.match(value):
            sys.exit(f"{value!r} is not a X.Y.Z version")

    mlflow_changed = mlflow_version != pins.mlflow_version
    oidc_changed = oidc_auth_version != pins.oidc_auth_version
    if not (mlflow_changed or oidc_changed):
        print("Versions unchanged.")
        return False

    chart_version = bump_chart_version(pins.chart_version, minor=mlflow_changed)

    chart = CHART_YAML.read_text()
    chart = substitute(CHART_VERSION_RE, chart_version, chart, CHART_YAML)
    chart = substitute(APP_VERSION_RE, mlflow_version, chart, CHART_YAML)
    chart = substitute(OIDC_ANNOTATION_RE, oidc_auth_version, chart, CHART_YAML)
    chart = substitute(DEPENDENCY_RE, mlflow_version, chart, CHART_YAML)
    CHART_YAML.write_text(chart, newline="\n")

    values = VALUES_YAML.read_text()
    tag = image_tag(mlflow_version, oidc_auth_version)
    values, count = IMAGE_TAG_RE.subn(lambda m: f'{m.group(1)}"{tag}"{m.group(3)}', values, count=1)
    if count != 1:
        sys.exit(f"Could not find the image tag in {VALUES_YAML}")
    VALUES_YAML.write_text(values, newline="\n")

    print(f"chart {pins.chart_version} -> {chart_version}")
    print(f"mlflow {pins.mlflow_version} -> {mlflow_version}")
    print(f"mlflow-oidc-auth {pins.oidc_auth_version} -> {oidc_auth_version}")
    if mlflow_changed:
        print("The mlflow dependency changed: run `helm dependency update` to refresh Chart.lock.")
    return True


def fetch_json(url: str) -> object:
    headers = {"Accept": "application/json", "User-Agent": "mlflow-oidc-versions"}
    if url.startswith("https://api.github.com/") and (token := os.environ.get("GH_TOKEN")):
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as resp:
        return json.load(resp)


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def latest_mlflow(cutoff: datetime) -> str:
    releases = fetch_json("https://api.github.com/repos/mlflow/mlflow/releases?per_page=100")
    candidates = [
        r["tag_name"].removeprefix("v")
        for r in releases
        if not r["draft"]
        and not r["prerelease"]
        and STABLE_VERSION.match(r["tag_name"].removeprefix("v"))
        and r["published_at"]
        and parse_time(r["published_at"]) <= cutoff
    ]
    if not candidates:
        sys.exit("No stable MLflow release found past the cooldown")
    return max(candidates, key=parse_version)


def latest_oidc_auth(cutoff: datetime) -> str:
    releases = fetch_json("https://pypi.org/pypi/mlflow-oidc-auth/json")["releases"]
    candidates = [
        version
        for version, files in releases.items()
        if STABLE_VERSION.match(version)
        and files
        and not any(f["yanked"] for f in files)
        and min(parse_time(f["upload_time_iso_8601"]) for f in files) <= cutoff
    ]
    if not candidates:
        sys.exit("No stable mlflow-oidc-auth release found past the cooldown")
    return max(candidates, key=parse_version)


def cmd_latest(args: argparse.Namespace) -> None:
    cutoff = datetime.now(UTC) - timedelta(days=args.cooldown_days)
    print(f"mlflow_version={latest_mlflow(cutoff)}")
    print(f"oidc_auth_version={latest_oidc_auth(cutoff)}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(required=True)

    sub.add_parser("show", help="Print the pinned versions").set_defaults(func=cmd_show)
    sub.add_parser("check", help="Verify the pins agree").set_defaults(func=cmd_check)

    set_parser = sub.add_parser("set", help="Rewrite the pins and bump the chart version")
    set_parser.add_argument("--mlflow", help="MLflow version, e.g. 3.19.0")
    set_parser.add_argument("--oidc-auth", help="mlflow-oidc-auth version, e.g. 11.6.0")
    set_parser.set_defaults(func=cmd_set)

    latest_parser = sub.add_parser("latest", help="Find the newest upstream releases")
    latest_parser.add_argument(
        "--cooldown-days",
        type=int,
        default=7,
        help="Ignore releases newer than this, matching the repo's package cooldown (default: 7)",
    )
    latest_parser.set_defaults(func=cmd_latest)

    upgrade_parser = sub.add_parser(
        "upgrade", help="Set the pins to the newest releases past the cooldown (never downgrades)"
    )
    upgrade_parser.add_argument("--cooldown-days", type=int, default=7)
    upgrade_parser.set_defaults(func=cmd_upgrade)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
