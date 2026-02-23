#!/usr/bin/env python3
"""
Security Auditor — Static analysis of Dart/Flutter code for security anti-patterns.
Checks for crypto misuse, insecure storage, PII leaks, permission issues, and more.
"""

import os
import sys
import json
import re
import argparse
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, asdict


@dataclass
class Finding:
    severity: str  # CRIT, HIGH, MED, LOW
    check: str
    description: str
    file_path: str
    line: int
    code_snippet: str
    recommendation: str


class SecurityAuditor:
    """Static security auditor for Flutter/Dart BLE mesh applications."""

    # Check definitions: (pattern, severity, check_name, description, recommendation, category)
    CRYPTO_CHECKS = [
        (r"\bRandom\(\)",
         "CRIT", "insecure-rng",
         "dart:math Random() is not cryptographically secure",
         "Use sodium.randombytes.buf() or dart:math SecureRandom",
         "crypto"),

        (r"(?:key|secret|password|passphrase)\s*=\s*['\"][^'\"]{1,100}['\"]",
         "CRIT", "hardcoded-secret",
         "Possible hardcoded cryptographic key or secret",
         "Load keys from flutter_secure_storage, never hardcode",
         "crypto"),

        (r"Uint8List\(\d+\)\s*(?:;|,)",
         "HIGH", "zero-nonce",
         "Zero-initialized Uint8List may be used as nonce (all zeros = nonce reuse)",
         "Use sodium.randombytes.buf() for nonces, or verify this is not a nonce",
         "crypto"),

        (r"crypto_aead.*nonce.*=.*(?:0|nonce)",
         "HIGH", "nonce-reuse-risk",
         "Static or reused nonce in AEAD encryption",
         "Generate fresh random nonce per encryption operation",
         "crypto"),

        (r"catch\s*\([^)]*\)\s*\{[^}]*return\s+(?:data|raw|bytes|payload|ciphertext)",
         "CRIT", "crypto-fallback",
         "Catch block returns original data on crypto failure — bypasses encryption",
         "On crypto failure, return null or rethrow. Never fall back to plaintext",
         "crypto"),
    ]

    STORAGE_CHECKS = [
        (r"SharedPreferences.*(?:key|secret|password|token|private)",
         "CRIT", "secret-in-prefs",
         "Cryptographic material stored in SharedPreferences (unencrypted)",
         "Use flutter_secure_storage for all keys and secrets",
         "storage"),

        (r"File\(.*\)\.writeAs(?:String|Bytes).*(?:key|secret|private)",
         "CRIT", "secret-in-file",
         "Possible secret written to plain file",
         "Use flutter_secure_storage, not File I/O for secrets",
         "storage"),

        (r"SecureStorage.*delete\b",
         "LOW", "key-deletion",
         "Key deletion from secure storage — verify this is intentional",
         "Ensure key deletion is part of planned key rotation or app reset",
         "storage"),
    ]

    LOGGING_CHECKS = [
        (r"(?:print|debugPrint|log\.)\s*\([^)]*(?:peerId|peer_id|PeerId|sourceId|destId)",
         "HIGH", "pii-log-peerid",
         "Peer ID logged — identity leak",
         "Use SecureLogger, truncate or hash peer IDs before logging",
         "logging"),

        (r"(?:print|debugPrint|log\.)\s*\([^)]*(?:secretKey|privateKey|private_key|SecureKey)",
         "CRIT", "key-logged",
         "Private key material may be logged",
         "Never log key material. Remove this logging statement",
         "logging"),

        (r"(?:print|debugPrint|log\.)\s*\([^)]*(?:latitude|longitude|lat|lng|coordinates|location)",
         "HIGH", "pii-log-location",
         "GPS coordinates logged — location privacy leak",
         "Use SecureLogger, never log coordinates",
         "logging"),

        (r"(?:print|debugPrint|log\.)\s*\([^)]*(?:passphrase|password|groupKey|group_key)",
         "CRIT", "secret-logged",
         "Secret or passphrase logged",
         "Remove this logging statement immediately",
         "logging"),

        (r"(?:print|debugPrint)\s*\(",
         "LOW", "debug-print",
         "debugPrint/print statement — ensure removed in release builds",
         "Use SecureLogger or conditional logging (kDebugMode guard)",
         "logging"),
    ]

    PROTOCOL_CHECKS = [
        (r"\.decode\([^)]*\)(?!\s*(?:catch|try))",
         "MED", "unguarded-decode",
         "Decoding without try/catch — malformed BLE data may crash the app",
         "Wrap decode in try/catch, return null on failure",
         "protocol"),

        (r"sublist\(\s*\d+",
         "MED", "unchecked-sublist",
         "sublist() without prior length check — may throw RangeError",
         "Check data.length >= offset + needed before sublist()",
         "protocol"),

        (r"ByteData\.view.*getUint(?:8|16|32|64)",
         "MED", "unchecked-bytedata",
         "ByteData access without length validation — potential out-of-bounds",
         "Validate buffer length before ByteData access",
         "protocol"),
    ]

    PERMISSION_CHECKS_ANDROID = [
        (r"ACCESS_BACKGROUND_LOCATION",
         "MED", "background-location",
         "Background location permission requested — high privacy impact",
         "Only request if truly needed for background mesh operation",
         "permissions"),

        (r"android:allowBackup\s*=\s*\"true\"",
         "HIGH", "backup-enabled",
         "Android backup enabled — app data (including messages) extractable via ADB",
         "Set android:allowBackup=\"false\" in AndroidManifest.xml",
         "permissions"),

        (r"android:debuggable\s*=\s*\"true\"",
         "CRIT", "debuggable",
         "App is debuggable — allows runtime inspection and data extraction",
         "Ensure debuggable is false in release builds",
         "permissions"),

        (r"usesCleartextTraffic\s*=\s*\"true\"",
         "MED", "cleartext-traffic",
         "Cleartext HTTP traffic allowed",
         "Set usesCleartextTraffic=\"false\" or use networkSecurityConfig",
         "permissions"),
    ]

    def __init__(self, target_path: str, verbose: bool = False, check_filter: Optional[str] = None):
        self.target_path = Path(target_path)
        self.verbose = verbose
        self.check_filter = check_filter
        self.findings: List[Finding] = []

    def run(self) -> Dict:
        """Execute security audit."""
        print(f"Running security audit on: {self.target_path}")
        if self.check_filter:
            print(f"Filter: {self.check_filter} checks only")

        try:
            self.validate_target()
            self.audit_dart_files()
            self.audit_android_manifest()
            self.audit_ios_plist()
            self.audit_pubspec()
            report = self.generate_report()

            return report

        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)

    def validate_target(self):
        if not self.target_path.exists():
            raise ValueError(f"Target path does not exist: {self.target_path}")

    def _get_checks(self) -> List[Tuple]:
        """Get checks based on filter."""
        all_checks = (
            self.CRYPTO_CHECKS +
            self.STORAGE_CHECKS +
            self.LOGGING_CHECKS +
            self.PROTOCOL_CHECKS
        )

        if self.check_filter:
            return [c for c in all_checks if c[5] == self.check_filter]
        return all_checks

    def audit_dart_files(self):
        """Scan Dart files for security anti-patterns."""
        dart_files = list(self.target_path.rglob("*.dart"))

        # Exclude test files and generated files
        dart_files = [f for f in dart_files
                      if "/test/" not in str(f).replace("\\", "/")
                      and ".g.dart" not in str(f)
                      and ".freezed.dart" not in str(f)]

        print(f"Scanning {len(dart_files)} Dart source files...")

        checks = self._get_checks()

        for dart_file in dart_files:
            try:
                content = dart_file.read_text(encoding="utf-8", errors="ignore")
                lines = content.split("\n")

                for pattern, severity, check_name, desc, rec, category in checks:
                    for i, line in enumerate(lines, 1):
                        # Skip comments
                        stripped = line.strip()
                        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("///"):
                            continue

                        if re.search(pattern, line, re.IGNORECASE):
                            rel_path = str(dart_file.relative_to(self.target_path))
                            self.findings.append(Finding(
                                severity=severity,
                                check=check_name,
                                description=desc,
                                file_path=rel_path,
                                line=i,
                                code_snippet=stripped[:120],
                                recommendation=rec,
                            ))

            except (PermissionError, OSError):
                continue

    def audit_android_manifest(self):
        """Check Android manifest for security issues."""
        if self.check_filter and self.check_filter != "permissions":
            return

        # Look for AndroidManifest.xml
        manifests = list(self.target_path.rglob("AndroidManifest.xml"))
        # Prefer main manifest over debug/profile
        main_manifests = [m for m in manifests if "debug" not in str(m) and "profile" not in str(m)]

        for manifest in (main_manifests or manifests):
            try:
                content = manifest.read_text(encoding="utf-8", errors="ignore")
                lines = content.split("\n")

                for pattern, severity, check_name, desc, rec, _ in self.PERMISSION_CHECKS_ANDROID:
                    for i, line in enumerate(lines, 1):
                        if re.search(pattern, line, re.IGNORECASE):
                            rel_path = str(manifest.relative_to(self.target_path))
                            self.findings.append(Finding(
                                severity=severity,
                                check=check_name,
                                description=desc,
                                file_path=rel_path,
                                line=i,
                                code_snippet=line.strip()[:120],
                                recommendation=rec,
                            ))
            except (PermissionError, OSError):
                continue

    def audit_ios_plist(self):
        """Check iOS Info.plist for security issues."""
        if self.check_filter and self.check_filter != "permissions":
            return

        plists = list(self.target_path.rglob("Info.plist"))
        for plist in plists:
            try:
                content = plist.read_text(encoding="utf-8", errors="ignore")
                # Check for overly permissive background modes
                if "fetch" in content and "bluetooth" in content:
                    rel_path = str(plist.relative_to(self.target_path))
                    self.findings.append(Finding(
                        severity="LOW",
                        check="ios-background-modes",
                        description="Multiple background modes enabled — verify all are necessary",
                        file_path=rel_path,
                        line=0,
                        code_snippet="UIBackgroundModes: bluetooth + fetch",
                        recommendation="Only enable background modes that are actively used",
                    ))
            except (PermissionError, OSError):
                continue

    def audit_pubspec(self):
        """Check pubspec.yaml for dependency issues."""
        if self.check_filter and self.check_filter not in ("crypto", None):
            return

        pubspec = self.target_path / "pubspec.yaml"
        if not pubspec.exists():
            # Try parent
            pubspec = self.target_path.parent / "pubspec.yaml"

        if pubspec.exists():
            try:
                content = pubspec.read_text(encoding="utf-8", errors="ignore")

                # Check for insecure dependency patterns
                if "http:" in content and "http_cache" not in content:
                    self.findings.append(Finding(
                        severity="LOW",
                        check="http-dependency",
                        description="HTTP package dependency — ensure HTTPS is enforced in usage",
                        file_path="pubspec.yaml",
                        line=0,
                        code_snippet="http dependency in pubspec.yaml",
                        recommendation="Verify all HTTP calls use HTTPS endpoints",
                    ))

                # Check sodium_libs is present for crypto apps
                if "sodium_libs" not in content:
                    self.findings.append(Finding(
                        severity="HIGH",
                        check="missing-sodium",
                        description="sodium_libs not found in pubspec — crypto operations may use weak alternatives",
                        file_path="pubspec.yaml",
                        line=0,
                        code_snippet="sodium_libs not in dependencies",
                        recommendation="Add sodium_libs dependency for all cryptographic operations",
                    ))

                if "flutter_secure_storage" not in content:
                    self.findings.append(Finding(
                        severity="HIGH",
                        check="missing-secure-storage",
                        description="flutter_secure_storage not found — secrets may be stored insecurely",
                        file_path="pubspec.yaml",
                        line=0,
                        code_snippet="flutter_secure_storage not in dependencies",
                        recommendation="Add flutter_secure_storage for key and secret persistence",
                    ))

            except (PermissionError, OSError):
                pass

    def generate_report(self) -> Dict:
        """Generate audit report."""
        # Sort by severity
        severity_order = {"CRIT": 0, "HIGH": 1, "MED": 2, "LOW": 3}
        self.findings.sort(key=lambda f: severity_order.get(f.severity, 99))

        # Deduplicate (same check + same file + same line)
        seen = set()
        unique_findings = []
        for f in self.findings:
            key = (f.check, f.file_path, f.line)
            if key not in seen:
                seen.add(key)
                unique_findings.append(f)
        self.findings = unique_findings

        # Summary
        by_severity = {}
        by_check = {}
        for f in self.findings:
            by_severity[f.severity] = by_severity.get(f.severity, 0) + 1
            by_check[f.check] = by_check.get(f.check, 0) + 1

        report = {
            "target": str(self.target_path),
            "total_findings": len(self.findings),
            "by_severity": by_severity,
            "by_check": by_check,
            "findings": [asdict(f) for f in self.findings],
        }

        # Print report
        print("\n" + "=" * 60)
        print("SECURITY AUDIT REPORT")
        print("=" * 60)
        print(f"Target: {self.target_path}")
        print(f"Total findings: {len(self.findings)}")
        print()

        for sev in ["CRIT", "HIGH", "MED", "LOW"]:
            count = by_severity.get(sev, 0)
            if count > 0:
                icon = "!!!" if sev == "CRIT" else "! " if sev == "HIGH" else "  "
                print(f"  {icon} [{sev}] {count} findings")

        if self.findings:
            print()
            print("-" * 60)

            current_severity = None
            for f in self.findings:
                if f.severity != current_severity:
                    current_severity = f.severity
                    print(f"\n--- [{current_severity}] ---")

                print(f"\n  {f.check}: {f.description}")
                print(f"  File: {f.file_path}:{f.line}")
                print(f"  Code: {f.code_snippet}")
                print(f"  Fix:  {f.recommendation}")
        else:
            print("\nNo findings. Clean scan.")

        print("\n" + "=" * 60)
        return report


def main():
    parser = argparse.ArgumentParser(description="Security Auditor for Flutter/Dart Apps")
    parser.add_argument("target", help="Target directory to audit (e.g., lib/)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--check", choices=["crypto", "storage", "logging", "protocol", "permissions"],
                        help="Run only specific category of checks")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--output", "-o", help="Write results to file")

    args = parser.parse_args()

    auditor = SecurityAuditor(args.target, verbose=args.verbose, check_filter=args.check)
    results = auditor.run()

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
