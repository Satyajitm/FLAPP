#!/usr/bin/env python3
"""
BLE Attack Surface Analyzer — Audits BLE GATT service configuration,
advertising data exposure, and transport security for Flutter BLE mesh apps.
"""

import os
import sys
import json
import re
import argparse
from pathlib import Path
from typing import Dict, List, Optional
from dataclasses import dataclass, asdict


@dataclass
class BLEFinding:
    severity: str
    category: str  # advertising, gatt, connection, transport, config
    description: str
    file_path: str
    line: int
    code_snippet: str
    recommendation: str


class BLEAttackSurfaceAnalyzer:
    """Analyzes BLE attack surface in Flutter apps using flutter_blue_plus and ble_peripheral."""

    def __init__(self, target_path: str, verbose: bool = False):
        self.target_path = Path(target_path)
        self.verbose = verbose
        self.findings: List[BLEFinding] = []
        self.ble_config: Dict = {
            "service_uuids": [],
            "characteristic_uuids": [],
            "advertising_data": [],
            "connection_params": [],
            "scan_settings": [],
        }

    def run(self) -> Dict:
        """Execute BLE attack surface analysis."""
        print(f"Analyzing BLE attack surface in: {self.target_path}")

        try:
            self.validate_target()
            self.extract_ble_config()
            self.audit_advertising()
            self.audit_gatt_permissions()
            self.audit_connection_security()
            self.audit_data_validation()
            self.audit_ble_permissions()
            report = self.generate_report()

            return report

        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)

    def validate_target(self):
        if not self.target_path.exists():
            raise ValueError(f"Target path does not exist: {self.target_path}")

    def _scan_dart_files(self) -> List[Path]:
        """Get all Dart files excluding tests and generated."""
        dart_files = list(self.target_path.rglob("*.dart"))
        return [f for f in dart_files
                if "/test/" not in str(f).replace("\\", "/")
                and ".g.dart" not in str(f)]

    def extract_ble_config(self):
        """Extract BLE configuration from source code."""
        dart_files = self._scan_dart_files()
        print(f"Scanning {len(dart_files)} Dart files for BLE configuration...")

        uuid_pattern = re.compile(r"['\"]([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})['\"]")

        for dart_file in dart_files:
            try:
                content = dart_file.read_text(encoding="utf-8", errors="ignore")

                # Extract UUIDs
                for match in uuid_pattern.finditer(content):
                    uuid = match.group(1).upper()
                    rel_path = str(dart_file.relative_to(self.target_path))
                    line_num = content[:match.start()].count("\n") + 1

                    # Classify UUID
                    context_line = content.split("\n")[line_num - 1] if line_num > 0 else ""
                    if "service" in context_line.lower():
                        self.ble_config["service_uuids"].append({"uuid": uuid, "file": rel_path, "line": line_num})
                    elif "characteristic" in context_line.lower():
                        self.ble_config["characteristic_uuids"].append({"uuid": uuid, "file": rel_path, "line": line_num})
                    else:
                        self.ble_config["service_uuids"].append({"uuid": uuid, "file": rel_path, "line": line_num})

            except (PermissionError, OSError):
                continue

        if self.verbose:
            print(f"  Found {len(self.ble_config['service_uuids'])} service UUIDs")
            print(f"  Found {len(self.ble_config['characteristic_uuids'])} characteristic UUIDs")

    def audit_advertising(self):
        """Check BLE advertising for information leakage."""
        dart_files = self._scan_dart_files()

        advertising_patterns = [
            (r"localName\s*:", "HIGH", "advertising-name",
             "Device name included in BLE advertising — identity leak to nearby devices",
             "Remove localName from advertising data to prevent tracking"),

            (r"manufacturerData\s*:.*(?:peerId|peer|id|identity)",
             "CRIT", "advertising-identity",
             "Peer identity data in manufacturer-specific advertising field",
             "Remove identity data from advertising. Use application-layer identity only"),

            (r"manufacturerData\s*:", "MED", "advertising-manufacturer-data",
             "Manufacturer-specific data in advertising — verify no sensitive info",
             "Review manufacturer data content. Minimize to absolute minimum"),

            (r"serviceData\s*:.*(?!.*uuid)", "MED", "advertising-service-data",
             "Service data in advertising — may leak application state",
             "Minimize service data. Prefer discovery via GATT connection"),

            (r"(?:startAdvertising|advertise).*(?:displayName|userName|name)",
             "HIGH", "advertising-display-name",
             "User display name may be broadcast in BLE advertising",
             "Never include user-visible names in advertising data"),

            (r"txPowerLevel\s*:", "LOW", "advertising-tx-power",
             "TX power level in advertising — enables distance estimation by observers",
             "Consider removing TX power from advertising if not needed"),
        ]

        for dart_file in dart_files:
            try:
                content = dart_file.read_text(encoding="utf-8", errors="ignore")
                lines = content.split("\n")

                for pattern, severity, check, desc, rec in advertising_patterns:
                    for i, line in enumerate(lines, 1):
                        if re.search(pattern, line, re.IGNORECASE):
                            rel_path = str(dart_file.relative_to(self.target_path))
                            self.findings.append(BLEFinding(
                                severity=severity, category="advertising",
                                description=desc, file_path=rel_path, line=i,
                                code_snippet=line.strip()[:120], recommendation=rec,
                            ))
            except (PermissionError, OSError):
                continue

    def audit_gatt_permissions(self):
        """Check GATT characteristic permissions."""
        dart_files = self._scan_dart_files()

        gatt_patterns = [
            (r"(?:read|Read)\s*:\s*true.*(?:key|secret|token|private)",
             "CRIT", "gatt-read-secret",
             "GATT characteristic with read permission may expose secrets",
             "Never expose secrets via GATT characteristics"),

            (r"(?:write|Write).*(?:WithoutResponse|withoutResponse)",
             "MED", "gatt-write-no-response",
             "Write-without-response on GATT — no acknowledgment of writes",
             "Consider write-with-response for reliability and flow control"),

            (r"notify\s*:\s*true",
             "LOW", "gatt-notify",
             "GATT notification enabled — verify notification data doesn't leak sensitive info",
             "Review what data is sent via notifications"),
        ]

        for dart_file in dart_files:
            try:
                content = dart_file.read_text(encoding="utf-8", errors="ignore")
                lines = content.split("\n")

                for pattern, severity, check, desc, rec in gatt_patterns:
                    for i, line in enumerate(lines, 1):
                        if re.search(pattern, line, re.IGNORECASE):
                            rel_path = str(dart_file.relative_to(self.target_path))
                            self.findings.append(BLEFinding(
                                severity=severity, category="gatt",
                                description=desc, file_path=rel_path, line=i,
                                code_snippet=line.strip()[:120], recommendation=rec,
                            ))
            except (PermissionError, OSError):
                continue

    def audit_connection_security(self):
        """Check BLE connection security parameters."""
        dart_files = self._scan_dart_files()

        connection_patterns = [
            (r"autoConnect\s*:\s*true",
             "MED", "auto-connect",
             "Auto-connect enabled — device will connect to known peripherals automatically",
             "Use manual connect with user intent for better security posture"),

            (r"(?:maxCentral|maxConnect).*(?:\d{2,})",
             "MED", "high-max-connections",
             "High max connection limit may allow connection flooding",
             "Limit to 6 (iOS max) or fewer for resource protection"),

            (r"timeout.*(?:0|null|none)",
             "HIGH", "no-connection-timeout",
             "BLE connection without timeout — stale connections hold resources",
             "Set reasonable connection timeout (30-60 seconds)"),

            (r"requestMtu",
             "LOW", "mtu-request",
             "MTU negotiation — verify MTU value doesn't exceed app's handling capacity",
             "Validate negotiated MTU and handle fragments correctly"),
        ]

        for dart_file in dart_files:
            try:
                content = dart_file.read_text(encoding="utf-8", errors="ignore")
                lines = content.split("\n")

                for pattern, severity, check, desc, rec in connection_patterns:
                    for i, line in enumerate(lines, 1):
                        if re.search(pattern, line, re.IGNORECASE):
                            rel_path = str(dart_file.relative_to(self.target_path))
                            self.findings.append(BLEFinding(
                                severity=severity, category="connection",
                                description=desc, file_path=rel_path, line=i,
                                code_snippet=line.strip()[:120], recommendation=rec,
                            ))
            except (PermissionError, OSError):
                continue

    def audit_data_validation(self):
        """Check that BLE received data is validated before processing."""
        dart_files = self._scan_dart_files()

        # Look for BLE data handlers without length checks
        handler_patterns = [
            (r"onValueReceived|onCharacteristicReceived|onData|onValueChanged",
             "callback_found"),
        ]

        validation_patterns = [
            r"\.length\s*[<>=]",
            r"if\s*\(\s*data\.length",
            r"if\s*\(\s*value\.length",
        ]

        for dart_file in dart_files:
            try:
                content = dart_file.read_text(encoding="utf-8", errors="ignore")
                lines = content.split("\n")

                for pattern, _ in handler_patterns:
                    for i, line in enumerate(lines, 1):
                        if re.search(pattern, line, re.IGNORECASE):
                            # Check if there's a length validation within next 10 lines
                            context = "\n".join(lines[i:i + 15])
                            has_validation = any(
                                re.search(vp, context) for vp in validation_patterns
                            )

                            if not has_validation:
                                rel_path = str(dart_file.relative_to(self.target_path))
                                self.findings.append(BLEFinding(
                                    severity="HIGH",
                                    category="transport",
                                    description="BLE data handler without visible length validation — buffer overflow risk",
                                    file_path=rel_path,
                                    line=i,
                                    code_snippet=line.strip()[:120],
                                    recommendation="Validate data length before parsing. Check min/max bounds.",
                                ))
            except (PermissionError, OSError):
                continue

    def audit_ble_permissions(self):
        """Check platform BLE permission configuration."""
        # Android
        manifests = list(self.target_path.rglob("AndroidManifest.xml"))
        for manifest in manifests:
            if "debug" in str(manifest) or "profile" in str(manifest):
                continue
            try:
                content = manifest.read_text(encoding="utf-8", errors="ignore")
                rel_path = str(manifest.relative_to(self.target_path))

                # Check for fine location (needed for BLE scan on Android <12)
                if "ACCESS_FINE_LOCATION" in content and "BLUETOOTH_SCAN" in content:
                    self.findings.append(BLEFinding(
                        severity="LOW", category="config",
                        description="Both FINE_LOCATION and BLUETOOTH_SCAN — FINE_LOCATION needed only for Android <12",
                        file_path=rel_path, line=0,
                        code_snippet="ACCESS_FINE_LOCATION + BLUETOOTH_SCAN",
                        recommendation="Consider conditional permission request based on API level",
                    ))

                # Check for BLUETOOTH_ADVERTISE
                if "BLUETOOTH_ADVERTISE" not in content and "ble_peripheral" in str(self.target_path):
                    self.findings.append(BLEFinding(
                        severity="MED", category="config",
                        description="BLUETOOTH_ADVERTISE permission missing but app uses ble_peripheral",
                        file_path=rel_path, line=0,
                        code_snippet="Missing BLUETOOTH_ADVERTISE",
                        recommendation="Add BLUETOOTH_ADVERTISE permission for Android 12+",
                    ))

            except (PermissionError, OSError):
                continue

        # iOS
        plists = list(self.target_path.rglob("Info.plist"))
        for plist in plists:
            try:
                content = plist.read_text(encoding="utf-8", errors="ignore")
                rel_path = str(plist.relative_to(self.target_path))

                if "NSBluetoothAlwaysUsageDescription" not in content:
                    self.findings.append(BLEFinding(
                        severity="MED", category="config",
                        description="Missing NSBluetoothAlwaysUsageDescription — iOS may reject BLE access",
                        file_path=rel_path, line=0,
                        code_snippet="Missing NSBluetoothAlwaysUsageDescription",
                        recommendation="Add Bluetooth usage description to Info.plist",
                    ))

                # Check background modes
                if "bluetooth-central" in content and "bluetooth-peripheral" in content:
                    if self.verbose:
                        print("  iOS: Both bluetooth-central and bluetooth-peripheral background modes enabled")

            except (PermissionError, OSError):
                continue

    def generate_report(self) -> Dict:
        """Generate BLE attack surface report."""
        severity_order = {"CRIT": 0, "HIGH": 1, "MED": 2, "LOW": 3}
        self.findings.sort(key=lambda f: severity_order.get(f.severity, 99))

        # Deduplicate
        seen = set()
        unique = []
        for f in self.findings:
            key = (f.category, f.description, f.file_path, f.line)
            if key not in seen:
                seen.add(key)
                unique.append(f)
        self.findings = unique

        by_severity = {}
        by_category = {}
        for f in self.findings:
            by_severity[f.severity] = by_severity.get(f.severity, 0) + 1
            by_category[f.category] = by_category.get(f.category, 0) + 1

        report = {
            "target": str(self.target_path),
            "ble_config": self.ble_config,
            "total_findings": len(self.findings),
            "by_severity": by_severity,
            "by_category": by_category,
            "findings": [asdict(f) for f in self.findings],
        }

        # Print report
        print("\n" + "=" * 60)
        print("BLE ATTACK SURFACE REPORT")
        print("=" * 60)
        print(f"Target: {self.target_path}")
        print(f"Total findings: {len(self.findings)}")
        print()

        # BLE Config Summary
        print("BLE Configuration Detected:")
        for uuid_info in self.ble_config["service_uuids"]:
            print(f"  Service: {uuid_info['uuid']} ({uuid_info['file']}:{uuid_info['line']})")
        for uuid_info in self.ble_config["characteristic_uuids"]:
            print(f"  Characteristic: {uuid_info['uuid']} ({uuid_info['file']}:{uuid_info['line']})")

        print()
        print("Findings by Severity:")
        for sev in ["CRIT", "HIGH", "MED", "LOW"]:
            count = by_severity.get(sev, 0)
            if count > 0:
                print(f"  [{sev}] {count}")

        print()
        print("Findings by Category:")
        for cat, count in sorted(by_category.items()):
            print(f"  {cat}: {count}")

        if self.findings:
            print()
            print("-" * 60)
            for f in self.findings:
                print(f"\n  [{f.severity}] {f.category}: {f.description}")
                print(f"  File: {f.file_path}:{f.line}")
                if f.code_snippet:
                    print(f"  Code: {f.code_snippet}")
                print(f"  Fix:  {f.recommendation}")
        else:
            print("\nNo BLE security findings. Clean surface.")

        print("\n" + "=" * 60)
        return report


def main():
    parser = argparse.ArgumentParser(description="BLE Attack Surface Analyzer for Flutter Apps")
    parser.add_argument("target", help="Target directory to analyze (e.g., lib/)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--scan-config", action="store_true", help="Focus on BLE configuration extraction")
    parser.add_argument("--gatt-audit", action="store_true", help="Focus on GATT permission audit")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--output", "-o", help="Write results to file")

    args = parser.parse_args()

    analyzer = BLEAttackSurfaceAnalyzer(args.target, verbose=args.verbose)
    results = analyzer.run()

    if args.json:
        output = json.dumps(results, indent=2)
        if args.output:
            with open(args.output, "w") as f:
                f.write(output)
            print(f"Results written to {args.output}")
        else:
            print(output)


if __name__ == "__main__":
    main()
