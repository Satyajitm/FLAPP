#!/usr/bin/env python3
"""
Threat Modeler — STRIDE analysis for Flutter BLE mesh apps.
Scans Dart source code to identify components and generate
STRIDE threat tables per trust boundary.
"""

import os
import sys
import json
import re
import argparse
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, field, asdict
from enum import Enum


class Severity(Enum):
    CRITICAL = "critical"
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


@dataclass
class Threat:
    category: str  # S, T, R, I, D, E
    component: str
    description: str
    severity: str
    mitigation: str
    file_path: Optional[str] = None


@dataclass
class ThreatModel:
    component: str
    trust_boundary: str
    threats: List[Threat] = field(default_factory=list)


# BLE Mesh-specific threat catalog
BLE_MESH_THREATS = {
    "transport": ThreatModel(
        component="BLE Transport",
        trust_boundary="Device ↔ BLE Radio",
        threats=[
            Threat("Spoofing", "BLE Transport", "BLE MAC address cloning to impersonate a peer device", "high",
                   "Use application-layer identity (Ed25519 keys) not BLE addresses"),
            Threat("Tampering", "BLE Transport", "Modification of BLE packets in transit by MITM relay", "medium",
                   "Ed25519 signatures on all packets verify integrity end-to-end"),
            Threat("Info Disclosure", "BLE Transport", "BLE advertising data leaks peer ID, group, or display name", "high",
                   "Minimize advertising payload to service UUID only"),
            Threat("Denial of Service", "BLE Transport", "BLE connection slot exhaustion (max 6 on iOS)", "medium",
                   "Enforce max connection limits, timeout idle connections"),
            Threat("Info Disclosure", "BLE Transport", "BLE signal used for proximity tracking", "medium",
                   "Use BLE MAC rotation, randomize advertising intervals"),
        ]
    ),
    "mesh": ThreatModel(
        component="Mesh Relay",
        trust_boundary="Local Peer ↔ Relay Network",
        threats=[
            Threat("Spoofing", "Mesh Relay", "Forged topology announcements to corrupt routing", "high",
                   "Verify Ed25519 signatures on topology packets"),
            Threat("Tampering", "Mesh Relay", "TTL manipulation to cause infinite relay loops", "medium",
                   "Enforce max TTL (7), decrement on relay, reject TTL > max"),
            Threat("Repudiation", "Mesh Relay", "Relay node denies having forwarded a packet", "low",
                   "Ed25519 signatures provide non-repudiation for origin"),
            Threat("Denial of Service", "Mesh Relay", "Flood attack: unique packets exhaust dedup cache and CPU", "high",
                   "Rate-limit relay, cap dedup cache size (1000), LRU eviction"),
            Threat("Denial of Service", "Mesh Relay", "Dedup cache poisoning to drop legitimate packets", "medium",
                   "Use composite dedup key (source:timestamp:type), time-bound entries"),
        ]
    ),
    "crypto": ThreatModel(
        component="Cryptography",
        trust_boundary="Plaintext ↔ Ciphertext",
        threats=[
            Threat("Spoofing", "Cryptography", "Forged Noise XX handshake to establish rogue session", "critical",
                   "Verify static key in handshake against known/trusted keys"),
            Threat("Tampering", "Cryptography", "Modified ciphertext bypasses AEAD authentication", "critical",
                   "ChaCha20-Poly1305 AEAD rejects any tampered ciphertext"),
            Threat("Info Disclosure", "Cryptography", "Nonce reuse leaks XOR of plaintexts", "critical",
                   "Random nonces for group cipher, counter for Noise sessions"),
            Threat("Info Disclosure", "Cryptography", "Weak Argon2id params allow group key brute-force", "high",
                   "Use opsLimitModerate/memLimitModerate minimum, enforce passphrase length"),
            Threat("Elevation", "Cryptography", "Compromised group key allows decryption of all group traffic", "high",
                   "Key rotation on member leave, periodic re-keying"),
        ]
    ),
    "identity": ThreatModel(
        component="Identity & Storage",
        trust_boundary="App Memory ↔ Persistent Storage",
        threats=[
            Threat("Spoofing", "Identity", "Stolen Ed25519 private key enables peer impersonation", "critical",
                   "Store in flutter_secure_storage (Android Keystore / iOS Keychain)"),
            Threat("Info Disclosure", "Identity", "Keys stored in SharedPreferences readable without root", "critical",
                   "Never use SharedPreferences for crypto material"),
            Threat("Info Disclosure", "Identity", "PII logged: peer IDs, keys, coordinates in debug output", "high",
                   "Use SecureLogger throughout, audit all print/debugPrint calls"),
            Threat("Tampering", "Identity", "Modify persisted group membership to gain unauthorized access", "medium",
                   "Group membership validated via passphrase-derived key, not just storage flag"),
            Threat("Info Disclosure", "Identity", "Chat message JSON files readable on rooted device", "medium",
                   "Accept risk or encrypt message files with group key"),
        ]
    ),
    "protocol": ThreatModel(
        component="Wire Protocol",
        trust_boundary="Application ↔ Binary Packet Format",
        threats=[
            Threat("Tampering", "Protocol", "Malformed packet causes parser crash (DoS via parsing)", "high",
                   "Validate all lengths before parsing, use tryDecode with null return"),
            Threat("Tampering", "Protocol", "Integer overflow in payload length field", "medium",
                   "Cap payload length at 512 bytes, validate before allocation"),
            Threat("Info Disclosure", "Protocol", "Message type byte reveals communication patterns to observer", "low",
                   "Accept risk (metadata analysis) or pad all packets to uniform size"),
            Threat("Spoofing", "Protocol", "Forged source ID in packet header", "high",
                   "Ed25519 signature binds packet to sender's signing key"),
        ]
    ),
}


class ThreatModeler:
    """STRIDE threat modeler for Flutter BLE mesh applications."""

    def __init__(self, target_path: str, verbose: bool = False, profile: str = "ble-mesh"):
        self.target_path = Path(target_path)
        self.verbose = verbose
        self.profile = profile
        self.results: Dict = {"threats": [], "summary": {}, "components_found": []}

    def run(self) -> Dict:
        """Execute threat modeling analysis."""
        print(f"Running STRIDE threat model on: {self.target_path}")
        print(f"Profile: {self.profile}")

        try:
            self.validate_target()
            self.scan_components()
            self.apply_threat_catalog()
            self.check_custom_threats()
            self.generate_report()

            print("\nThreat modeling complete.")
            return self.results

        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)

    def validate_target(self):
        if not self.target_path.exists():
            raise ValueError(f"Target path does not exist: {self.target_path}")

    def scan_components(self):
        """Scan Dart files to identify which security components are present."""
        dart_files = list(self.target_path.rglob("*.dart"))
        print(f"Scanning {len(dart_files)} Dart files...")

        component_patterns = {
            "transport": [r"BleTransport", r"Transport\b", r"ble_transport", r"flutter_blue_plus", r"ble_peripheral"],
            "mesh": [r"MeshService", r"RelayController", r"Deduplicator", r"TopologyTracker", r"GossipSync"],
            "crypto": [r"NoiseProtocol", r"NoiseSession", r"GroupCipher", r"Signatures\b", r"sodium", r"ChaCha"],
            "identity": [r"IdentityManager", r"PeerId", r"GroupManager", r"SecureStorage", r"UserProfile"],
            "protocol": [r"FluxonPacket", r"BinaryProtocol", r"MessageType", r"packet\.dart"],
        }

        found_components = set()

        for dart_file in dart_files:
            try:
                content = dart_file.read_text(encoding="utf-8", errors="ignore")
                for component, patterns in component_patterns.items():
                    for pattern in patterns:
                        if re.search(pattern, content):
                            found_components.add(component)
                            break
            except (PermissionError, OSError):
                continue

        self.results["components_found"] = sorted(found_components)
        if self.verbose:
            print(f"Components detected: {', '.join(found_components) or 'none'}")

    def apply_threat_catalog(self):
        """Apply BLE mesh threat catalog for detected components."""
        for component in self.results["components_found"]:
            if component in BLE_MESH_THREATS:
                model = BLE_MESH_THREATS[component]
                for threat in model.threats:
                    self.results["threats"].append(asdict(threat))

        # Always include all threats if no components detected (conservative)
        if not self.results["components_found"]:
            print("WARNING: No components detected. Including all threats (conservative).")
            for model in BLE_MESH_THREATS.values():
                for threat in model.threats:
                    self.results["threats"].append(asdict(threat))

    def check_custom_threats(self):
        """Scan for additional threat indicators in source code."""
        dart_files = list(self.target_path.rglob("*.dart"))
        custom_threats = []

        risk_patterns = [
            (r"Random\(\)", "dart:math Random() usage — not cryptographically secure", "critical", "crypto"),
            (r"SharedPreferences.*(?:key|secret|password)", "Possible secret in SharedPreferences", "critical", "identity"),
            (r"print\(.*(key|secret|password|peerId|peer_id)", "Possible PII/key in print statement", "high", "identity"),
            (r"debugPrint\(.*(key|secret|password|peerId|peer_id)", "Possible PII/key in debugPrint", "high", "identity"),
            (r"(?:http://)", "HTTP URL (not HTTPS) — cleartext network traffic", "medium", "transport"),
            (r"allowBackup.*true", "Android backup enabled — app data extractable", "medium", "identity"),
            (r"\.decode\(.*\)(?!.*try)", "Decoding without try/catch — potential crash on malformed input", "medium", "protocol"),
        ]

        for dart_file in dart_files:
            try:
                content = dart_file.read_text(encoding="utf-8", errors="ignore")
                for pattern, desc, severity, component in risk_patterns:
                    matches = re.finditer(pattern, content, re.IGNORECASE)
                    for match in matches:
                        line_num = content[:match.start()].count("\n") + 1
                        rel_path = str(dart_file.relative_to(self.target_path))
                        custom_threats.append({
                            "category": "Custom",
                            "component": component,
                            "description": desc,
                            "severity": severity,
                            "mitigation": "Review and fix",
                            "file_path": f"{rel_path}:{line_num}",
                        })
            except (PermissionError, OSError):
                continue

        self.results["threats"].extend(custom_threats)
        self.results["custom_findings"] = len(custom_threats)

    def generate_report(self):
        """Generate and display the threat model report."""
        threats = self.results["threats"]

        # Summary counts
        by_severity = {}
        by_category = {}
        for t in threats:
            sev = t["severity"]
            cat = t["category"]
            by_severity[sev] = by_severity.get(sev, 0) + 1
            by_category[cat] = by_category.get(cat, 0) + 1

        self.results["summary"] = {
            "total_threats": len(threats),
            "by_severity": by_severity,
            "by_category": by_category,
            "components_analyzed": self.results["components_found"],
        }

        # Print report
        print("\n" + "=" * 60)
        print("STRIDE THREAT MODEL REPORT")
        print("=" * 60)
        print(f"Target: {self.target_path}")
        print(f"Profile: {self.profile}")
        print(f"Components: {', '.join(self.results['components_found']) or 'all (conservative)'}")
        print(f"Total threats: {len(threats)}")
        print()

        print("By Severity:")
        for sev in ["critical", "high", "medium", "low"]:
            count = by_severity.get(sev, 0)
            if count > 0:
                marker = "!!!" if sev == "critical" else "! " if sev == "high" else "  "
                print(f"  {marker} {sev.upper()}: {count}")

        print()
        print("By STRIDE Category:")
        for cat, count in sorted(by_category.items()):
            print(f"  {cat}: {count}")

        # Print critical/high threats
        critical_high = [t for t in threats if t["severity"] in ("critical", "high")]
        if critical_high:
            print()
            print("-" * 60)
            print("CRITICAL & HIGH THREATS")
            print("-" * 60)
            for t in critical_high:
                print(f"\n  [{t['severity'].upper()}] {t['category']} — {t['component']}")
                print(f"  {t['description']}")
                print(f"  Mitigation: {t['mitigation']}")
                if t.get("file_path"):
                    print(f"  Location: {t['file_path']}")

        print("\n" + "=" * 60)


def main():
    parser = argparse.ArgumentParser(description="STRIDE Threat Modeler for Flutter BLE Mesh Apps")
    parser.add_argument("target", help="Target Dart source directory (e.g., lib/)")
    parser.add_argument("--profile", default="ble-mesh", choices=["ble-mesh", "minimal"],
                        help="Threat profile to apply (default: ble-mesh)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--output", "-o", help="Write results to file")

    args = parser.parse_args()

    modeler = ThreatModeler(args.target, verbose=args.verbose, profile=args.profile)
    results = modeler.run()

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
