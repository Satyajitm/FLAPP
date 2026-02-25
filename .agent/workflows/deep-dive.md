---
description: Deep-dive security & correctness audit of a specific vertical module
---

# /deep-dive — Vertical Deep-Dive Audit

## When to Use
Run this workflow when you want an exhaustive security, correctness, and quality audit of a single vertical module from the [System Architecture Map](../../security_audit/SYSTEM_ARCHITECTURE_MAP.md).

## Usage
Tell the agent: `/deep-dive V<number>` or `/deep-dive <module name>`

Examples:
- `/deep-dive V6` → Protocol Layer
- `/deep-dive V11` → Emergency Feature
- `/deep-dive mesh` → V4 Mesh Networking

---

## Workflow Steps

### Phase 1: Scope & Context (2 min)

1. **Open the Architecture Map** at `security_audit/SYSTEM_ARCHITECTURE_MAP.md` and identify the target vertical:
   - Which files belong to this vertical?
   - What does it depend on? (upstream)
   - What depends on it? (downstream)
   - Which trust boundary does it sit on?
   - What existing audit coverage exists?

2. **Read any existing audit reports** that partially cover this vertical (listed in the Architecture Map's "Existing Audit Reports" table).

3. **Read all files in the vertical** — every `.dart` file listed under this module. Start with `view_file_outline` for overview, then `view_file` for full contents.

### Phase 2: Structural Analysis (5 min)

4. **Map the internal architecture** of the vertical:
   - Classes, their responsibilities, and relationships
   - Public API surface (what other modules call into)
   - Data flow: what enters, what exits, what's stored
   - Error handling patterns

5. **Identify trust boundaries within the vertical**:
   - Where does untrusted input enter? (from BLE, from user, from disk)
   - Where does sensitive data leave? (to BLE, to disk, to UI)
   - What assumptions does the code make about its inputs?

### Phase 3: Bug Hunting — The 8 Lenses (15 min)

// turbo-all
Apply each of these 8 analysis lenses systematically. For each lens, grep/search the vertical's files for relevant patterns:

6. **🔴 LENS 1: Input Validation & Parsing**
   - Search for: `decode`, `parse`, `fromJson`, `sublist`, `substring`, `int.parse`, `double.parse`
   - Check: bounds validation, integer overflow, null handling, malformed input
   - Question: "What happens if every input field is max/min/zero/negative/empty/malformed?"

7. **🟠 LENS 2: State Management & Race Conditions**
   - Search for: `async`, `await`, `Future`, `Timer`, `StreamController`, `setState`, `dispose`  
   - Check: concurrent access to shared state, use-after-dispose, callback-during-teardown
   - Question: "What if two events fire simultaneously? What if dispose() is called mid-operation?"

8. **🟡 LENS 3: Error Handling & Recovery**
   - Search for: `try`, `catch`, `throw`, `rethrow`, `return null`, `??`, `!`
   - Check: swallowed exceptions, inconsistent error propagation, partial state after failure
   - Question: "What state is the system in after every possible failure point?"

9. **🔵 LENS 4: Security & Cryptography**
   - Search for: `encrypt`, `decrypt`, `sign`, `verify`, `hash`, `key`, `nonce`, `salt`, `secret`, `password`, `token`
   - Check: key management, nonce reuse, timing side-channels, plaintext leaks, auth bypass
   - Question: "Can an attacker control any input to a crypto function? Can they observe any output?"

10. **🟣 LENS 5: Resource Management & Leaks**
    - Search for: `StreamController`, `Timer`, `StreamSubscription`, `dispose`, `close`, `cancel`, `SecureKey`
    - Check: every resource opened has a corresponding cleanup, dispose is called on all paths
    - Question: "If I create 10,000 of these objects, what happens?"

11. **🟤 LENS 6: Data Integrity & Consistency**
    - Search for: `save`, `store`, `write`, `delete`, `update`, `clear`, `cache`
    - Check: atomic writes, partial update recovery, stale cache, data loss on crash
    - Question: "What if the app crashes between these two writes?"

12. **🔶 LENS 7: API Contract & Misuse**
    - Search for: `assert`, `@visibleForTesting`, `typedef`, `abstract`, `@override`
    - Check: preconditions documented but not enforced, API that's easy to misuse
    - Question: "What happens if a caller passes unexpected but technically valid arguments?"

13. **⬛ LENS 8: Performance & Scalability**
    - Search for: `for`, `map`, `where`, `List`, `Map`, `Set`, `O(`, `length`
    - Check: O(n²) loops, unbounded collections, allocation in hot paths, blocking I/O on UI thread
    - Question: "What happens with 1,000 peers? 100,000 messages? 10MB payloads?"

### Phase 4: Cross-Module Integration (5 min)

14. **Trace data flow across trust boundaries:**
    - Pick 2-3 critical data paths that cross from this vertical into upstream/downstream modules
    - Verify that assumptions match at every boundary
    - Example: "Data enters V3 (BLE) → passes through V6 (Protocol decode) → reaches V4 (Mesh) → arrives at V9 (Chat). Are the validation assumptions consistent?"

15. **Check test coverage for this vertical:**
    - Read the relevant test files from `test/`
    - Identify: what's tested, what's NOT tested, what edge cases are missing
    - Note: are negative tests present? (malformed input, concurrent access, resource exhaustion)

### Phase 5: Report (5 min)

16. **Generate the audit report** at `security_audit/DEEP_DIVE_V<N>_<NAME>.md` with this structure:

```markdown
# 🔍 Deep-Dive Audit: V<N> — <Module Name>

**Date:** <today>
**Scope:** <list of files>
**Dependencies:** <upstream modules>
**Depended on by:** <downstream modules>
**Trust boundary:** <where this module sits>

## Summary
<3-5 sentence overview of findings>

## Findings

### [SEVERITY] Finding Title
**File:** `path/to/file.dart`, lines X-Y
**Lens:** <which of the 8 lenses found this>
**Description:** <what's wrong>
**Exploit/Impact:** <what could go wrong>
**Remediation:** <how to fix>

... (repeat for each finding)

## Cross-Module Boundary Issues
<findings from Phase 4>

## Test Coverage Gaps
<findings from Phase 4 step 15>

## Positive Properties
<things done well>
```

17. **Update the Architecture Map** — change the "Audit Status" column for this vertical from ❌ to ✅ with a link to the new report.

---

## Tips for Thoroughness

- **Don't skip lenses** — even if a lens seems irrelevant ("this module doesn't do crypto"), still grep for the patterns. You may be surprised.
- **Follow the data** — pick a concrete data item (e.g., "a chat message from a remote peer") and trace it from BLE radio → protocol decode → mesh relay → chat controller → UI render → disk storage. Every step is a potential bug.
- **Think adversarially** — for each function, ask: "What would a malicious peer send to break this?"
- **Check the boundaries** — most bugs live at the boundary between two modules, not inside a single function.
