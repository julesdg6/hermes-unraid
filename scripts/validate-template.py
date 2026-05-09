#!/usr/bin/env python3
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REQUIRED_FIELDS = [
    "Name",
    "Repository",
    "Registry",
    "Support",
    "Project",
    "TemplateURL",
    "Icon",
    "Category",
    "WebUI",
]
REQUIRED_CONFIG_TARGETS = {
    "8642",
    "9119",
    "8787",
    "HERMES_UID",
    "HERMES_GID",
    "HERMES_HOME",
    "/home/hermes/.hermes",
    "WANTED_UID",
    "WANTED_GID",
    "HERMES_GATEWAY_URL",
    "DASHBOARD_PORT",
    "WEBUI_PORT",
    "WEBUI_HOST",
    "DASHBOARD_HOST",
    "TZ",
    "/home/hermeswebui/workspace",
    "/opt/hermes",
}
LEGACY_VOLUME_TARGET = "/opt/hermes"
LEGACY_VOLUME_EXPECTED_ATTRIBUTES = {
    "Type": "Path",
    "Display": "advanced",
    "Required": "false",
    "Default": "",
}
LEGACY_VOLUME_DESCRIPTION_PHRASES = (
    "experimental",
    "Docker named volume",
    "hermes_shared_volume",
    "not user config",
    "backed up",
    "leave blank",
    "not a host filesystem path",
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-template.py <template.xml>", file=sys.stderr)
        return 2

    template_path = Path(sys.argv[1])
    root = ET.parse(template_path).getroot()

    if root.tag != "Container":
        raise SystemExit("template root element must be <Container>")

    missing_fields = []
    for field in REQUIRED_FIELDS:
        value = root.findtext(field)
        if not (value or "").strip():
            missing_fields.append(field)
    if missing_fields:
        raise SystemExit(f"missing required fields: {', '.join(missing_fields)}")

    configs = root.findall("Config")
    if not configs:
        raise SystemExit("template must contain at least one <Config> entry")

    targets = {config.attrib.get("Target", "") for config in configs}
    missing_targets = sorted(REQUIRED_CONFIG_TARGETS - targets)
    if missing_targets:
        raise SystemExit(f"missing required Config targets: {', '.join(missing_targets)}")

    legacy_volume_config = next(
        (config for config in configs if config.attrib.get("Target") == LEGACY_VOLUME_TARGET),
        None,
    )
    if legacy_volume_config is None:
        raise SystemExit(f"missing legacy {LEGACY_VOLUME_TARGET} migration config")

    for attribute, expected_value in LEGACY_VOLUME_EXPECTED_ATTRIBUTES.items():
        actual_value = legacy_volume_config.attrib.get(attribute, "")
        if actual_value != expected_value:
            raise SystemExit(
                f"{LEGACY_VOLUME_TARGET} migration config must set {attribute}={expected_value!r}, got {actual_value!r}"
            )

    description = legacy_volume_config.attrib.get("Description", "")
    for phrase in LEGACY_VOLUME_DESCRIPTION_PHRASES:
        if phrase.lower() not in description.lower():
            raise SystemExit(
                f"{LEGACY_VOLUME_TARGET} migration config description must mention {phrase!r}"
            )

    print(f"Template validation passed for {template_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
