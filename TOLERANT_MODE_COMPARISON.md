# Tolerant Mode Design Comparison & Synthesis

## Overview

This document cross-references two tolerant mode designs (CL and GPT) to identify gaps, conflicts, and improvements. The goal is to synthesize the best ideas from both into a unified implementation plan.

---

## Key Philosophical Differences

### CL Design Philosophy
- **Proactive categorization**: 10 explicit error categories with specific recovery strategies
- **Synthetic token emission**: Liberal use of synthetic closers to maintain parse tree structure
- **Parser-centric**: Assumes parser needs complete structure even with errors
- **Comprehensive**: Detailed per-error-case analysis (63 cases)

### GPT Design Philosophy
- **Minimal intervention**: Prefer dropping tokens over synthesis (MVP approach)
- **Scan-to-sync**: Unified recovery via sync point scanning
- **Conservative**: Avoid insertions by default (`:error_insertions` flag for future)
- **Driver-centric**: Keep recovery logic in Driver, minimize TokenStream changes

---

## Critical Items GPT Got Right (CL Missed or Underspecified)

### 1. **Sync Point Implementation Details** ✓✓✓

**GPT Specification**:
```
- horizontal whitespace/escaped newline - stop before, do not consume
- comment start - stop before, do not consume
- :semicolon: stop before the next `;` (do not consume)
- :newline: stop before the next `\n` (not consuming it)
- :closer: stop before the expected closer (do not consume)
```

**CL Gap**: Listed sync points but didn't specify:
- Whether to consume or leave sync character in stream
- Interaction with whitespace (should stop at space/tab before newline)
- Comment detection as boundary

**Fix**: CL added comment/whitespace to sync points after GPT, but GPT's "stop before, do not consume" rule is critical for correctness.

**Why This Matters**: If we consume sync points, the next tokenization step won't see them, breaking token stream. Example:
- Input: `foo\0; bar`
- Wrong: consume `;` → loses statement separator
- Right: stop before `;`, leave it → next call sees `;` token

---

### 2. **EOF Error Draining Strategy** ✓✓✓

**GPT Specification**:
```elixir
# EOF-specific pending errors (Driver)
- Emit {:error_token, meta, reason}
- Mutate state to make progress:
  - missing_interpolation: pop {:interp, ...} and emit {:end_interpolation, meta, kind}
  - missing_context: pop context, restore parent terminators (NO synthetic end token in MVP)
  - missing_scope: pop ONE stack entry (top) to advance; repeat on next next/2 call
- Once all frames cleared, return {:eof, state}
```

**CL Gap**: Did not specify iterative draining mechanism. CL suggested emitting all error tokens at once, which could:
- Violate single-token-per-call invariant
- Make position tracking complex
- Break checkpoint/rewind semantics

**Fix Needed**: CL should adopt GPT's one-error-per-call strategy:
```elixir
# At EOF with pending errors:
def next([], state) do
  case pending_error(state) do
    nil -> {:eof, state}

    error when error_mode == :tolerant ->
      # Emit ONE error token, pop ONE frame, continue
      {error_token, new_state} = emit_pending_error(error, state)
      {:ok, error_token, [], new_state}  # Next call will handle remaining errors
  end
end
```

**Why This Matters**: Maintains stream invariant that `next/2` returns exactly one token (or EOF).

---

### 3. **`:error_max_skip` Safety Bound** ✓✓

**GPT Addition**:
```elixir
:error_max_skip (default: 4096) – cap on characters scanned during recovery
before falling back to newline
```

**CL Gap**: No safeguard against pathological inputs where sync point is never found.

**Attack Vector**:
```elixir
# Malicious input: single line with no sync points
"foo\0" <> String.duplicate("a", 1_000_000)
```

Without `error_max_skip`, recovery could scan entire megabyte looking for newline.

**Fix Needed**: CL must add bounded scanning:
```elixir
def scan_to_sync(rest, state, opts, chars_scanned \\ 0) do
  max = Keyword.get(opts, :error_max_skip, 4096)

  if chars_scanned >= max do
    # Fallback: consume one char and continue
    {tl(rest), state.line, state.column + 1}
  else
    # ... normal sync detection ...
  end
end
```

---

### 4. **`:error_insertions` Feature Flag** ✓✓

**GPT Rationale**:
```
:error_insertions (default: false) – allow synthetic closer insertions,
off by default for a minimal, predictable MVP.
```

**CL Assumption**: Liberal use of synthetic tokens throughout (Category 4, 5).

**Conflict**: CL's synthetic token strategy contradicts GPT's minimal MVP approach.

**Resolution**: Adopt **phased approach**:
- **MVP (Phase 1)**: No synthetic tokens, follow GPT approach
  - Missing closer? → error token only, pop context
  - Mismatched delimiter? → error token, drop bad closer
- **Phase 2**: Add `:error_insertions` flag
  - When enabled, emit synthetic closers as CL describes
  - Default: disabled (GPT's preference)

**Why GPT is Right Here**:
- Synthetic tokens complicate testing (how do parsers distinguish real vs synthetic?)
- Simpler recovery is more predictable
- Can always add insertions later if needed

---

### 5. **EOL Deferral Interaction** ✓✓✓

**GPT Specification**:
```
EOL coalescing: reuse existing :reset_eol/:increase_eol patterns; error tokens
should not break EOL deferral updates. If an error lands while an :eol deferral
is being built, finalize the deferral before emitting the error token.
```

**CL Gap**: Mentioned deferrals but didn't specify ordering.

**Scenario**:
```elixir
# Input: "foo\n\0bar"
# Tokens before error: [:identifier :foo, :eol (deferred)]
# Error at: \0
```

**Wrong Order**: `[:identifier, :error_token, :eol]` → EOL after error breaks semantics
**Right Order**: `[:identifier, :eol, :error_token]` → Finalize EOL before error

**Fix Needed**: CL must specify deferral finalization in recovery:
```elixir
def emit_error_and_advance(reason, rest, state) do
  # 1. Flush any pending deferrals FIRST
  output = state.output ++ Enum.reverse(state.deferrals)

  # 2. Then emit error token
  error_token = {:error_token, compute_meta(state, rest), reason}

  # 3. Update state with cleared deferrals
  %{state | output: output ++ [error_token], deferrals: []}
end
```

---

## Critical Items CL Got Right (GPT Missed or Underspecified)

### 1. **Comprehensive Error Categorization** ✓✓✓

**CL Strength**: 10 categories with 63 specific test cases mapped to recovery strategies.

**GPT Gap**: Recovery matrix is high-level; doesn't map every error in `toxic_erros_test.exs`.

**Examples of CL-only coverage**:
- **Ambiguous bang-before-equals** (`foo!=`) → warn but continue
- **Unnecessary quotes** (`:"foo"` vs `:foo`) → warning, not error
- **Three-of-same-char** (`&&&&`) → warning, not error

These are **warnings**, not errors, but CL's analysis correctly identifies them as non-halting.

**GPT Needs**: Explicit acknowledgment that some "errors" are warnings and don't need recovery.

---

### 2. **Terminator Stack Adjustment Algorithms** ✓✓✓

**CL Detailed Strategy** (Category 5):
```
Case A: Unexpected closing delimiter (no matching opener)
1. Emit error_token at closing position
2. Do NOT consume the closer (leave in stream)
3. Emit synthetic opener before it: e.g., `(` before `)`
4. Then emit the closer as valid token

Case B: Mismatched delimiter ([)
1. Pop terminator stack to find matching opener
2. Emit error_token for the mismatch
3. Emit synthetic expected closer for the opener (e.g., `]` for `[`)
4. Leave actual closer (`)`) in stream for next iteration
```

**GPT Equivalent**:
```
Unexpected closer with empty stack: emit error; drop the closer; do not mutate stack.
Mismatched closer: emit error; do not consume the closer if :closer sync is enabled
and it matches the expected closer for any lower frame; otherwise, drop the closer.
```

**Conflict**: CL synthesizes tokens, GPT drops them.

**Resolution**:
- **MVP**: Follow GPT (drop, don't synthesize)
- **Phase 2**: CL's algorithm becomes opt-in with `:error_insertions`

**CL's Algorithm Value**: Even if not in MVP, the detailed case analysis is excellent documentation for future implementation.

---

### 3. **Per-Category Recovery Rationale** ✓✓

**CL Advantage**: Each category explains **why** the strategy works.

**Example** (Category 2: Malformed Numbers):
```
Rationale: The valid number prefix has already been identified. Skip the invalid
suffix to avoid treating "123abc" as multiple separate tokens.
```

**GPT Equivalent**: "Invalid char after number/float: emit error and drop that single offending char"

**Comparison**: Both say same thing, but CL explains the decision.

**Value**: Future maintainers understand intent, not just mechanism.

---

### 4. **Testing Strategy Detail** ✓✓

**CL Testing Section**:
- Per-category tests
- Cascade tests (multiple errors in sequence)
- Position accuracy tests
- Terminator stack consistency tests
- Example test cases with assertions

**GPT Testing Section**:
- Reuse strict tests
- Add tolerant suites
- Recovery-specific tests

**Comparison**: CL is more prescriptive about test structure.

**Best Practice**: Combine both:
- GPT's approach: reuse strict tests (good for regression)
- CL's approach: explicit cascade/position/stack tests (good for recovery correctness)

---

### 5. **Migration Path** ✓

**CL**: 5 phases from infrastructure to polish
**GPT**: 7 implementation steps

**CL Phases**:
1. Infrastructure (options, error categories)
2. Categories 1-3 (simpler recoveries)
3. Categories 4-5 (terminator handling)
4. Categories 6-10 (context-specific)
5. Integration & polish

**GPT Steps**:
1. Driver options
2. Driver tolerant path
3. EOF handling
4. Buffer/refill
5. Meta/eol/deferrals
6. Sync: closer matching
7. Tests

**Comparison**:
- CL groups by error type (easier to test incrementally)
- GPT groups by module (easier to code review)

**Best Practice**: Hybrid approach:
1. Infrastructure (GPT step 1)
2. Core recovery (GPT steps 2-6, CL categories 1-3)
3. Complex recovery (CL categories 4-10)
4. Integration (GPT step 4-5, CL phase 5)
5. Tests (GPT step 7, throughout)

---

## Conflicts & Resolutions

### Conflict 1: Synthetic Token Emission

**CL**: Liberal synthesis (Categories 4, 5)
**GPT**: No synthesis in MVP (`:error_insertions` flag for future)

**Resolution**: **GPT wins for MVP, CL provides roadmap for Phase 2**

**Rationale**:
- Simpler implementation (fewer edge cases)
- Easier to reason about (error token = information loss, no magic tokens)
- Can add synthesis later without breaking existing code
- CL's detailed algorithms become implementation guide for Phase 2

---

### Conflict 2: Error Token Count at EOF

**CL Implied**: Emit all pending errors at once
**GPT**: Drain one error per `next/2` call

**Resolution**: **GPT wins**

**Rationale**:
- Preserves single-token-per-call invariant
- Simpler state management
- Better for checkpoint/rewind
- CL likely didn't intend batch emission, just wasn't explicit

---

### Conflict 3: Sync Point Consumption

**CL Original**: Didn't specify
**GPT**: "stop before, do not consume"
**CL Updated**: Added comment/whitespace after reading this

**Resolution**: **GPT's rule is correct**

**Rationale**: See "Sync Point Implementation Details" above.

---

### Conflict 4: Number Error Recovery

**CL**: "Emit what was parsed, skip to next non-identifier char"
**GPT**: "drop that single offending char; keep the parsed number token already emitted if it was produced before the error"

**Subtle Difference**:
- CL assumes number token emitted, error token for suffix
- GPT allows for error before emission

**Resolution**: **Depends on implementation**

**Analysis**:
```elixir
# Input: "123abc"
# Tokenizer.Number.tokenize_number/4 returns:
{:error, reason, original}  # ← Error detected BEFORE token emitted

# So GPT is right: number token not emitted yet, only error token
```

**Correct Recovery**:
1. Emit error token covering entire "123abc"
2. Skip to next non-ident char
3. Do NOT emit number token (it was never created)

**CL Fix Needed**: Clarify that number tokens are emitted OR error tokens, not both.

---

## Items Both Missed

### 1. **Unicode Grapheme Cluster Handling** ⚠️

**Current Code** (`interpolation.ex:311`):
```elixir
case :unicode_util.gc(rest) do
  [char | _] when bidi(char) or break(char) -> {:error, reason}
  [char | new_rest] when is_list(char) ->
    # Multi-codepoint grapheme cluster
  [char | new_rest] when is_integer(char) ->
    # Single codepoint
```

**Issue**: When recovering from error, must advance by grapheme cluster, not single byte.

**Example**:
```
# Input: "foo👨‍👩‍👧‍👦bar"  (family emoji = 7 codepoints)
# If error in middle of emoji, must skip entire cluster
```

**Fix Needed**: Both designs should specify:
```elixir
def scan_to_sync(rest, state, opts) do
  case :unicode_util.gc(rest) of
    [cluster | new_rest] when is_list(cluster) ->
      # Skip entire grapheme cluster, update column by 1
      scan_to_sync(new_rest, state, opts, chars_scanned + 1)
    [codepoint | new_rest] ->
      # Single codepoint
      scan_to_sync(new_rest, state, opts, chars_scanned + 1)
  end
end
```

---

### 2. **Nested Error Recovery** ⚠️

**Scenario**:
```elixir
# Input: "#{foo\0bar(}"
# Errors:
# 1. \0 inside interpolation
# 2. Missing ) for (
# 3. Missing " for string
```

**Question**: In what order are errors emitted?

**Neither Design Specifies**:
- Should errors nest (emit inner errors first)?
- Should errors flatten (emit in source order)?

**Correct Approach** (from code structure):
1. Error 1 (\0): emit error token, sync to next delimiter
2. Continue tokenizing inside interpolation
3. Error 2 at EOF: missing ) → emit error, pop terminator
4. Error 3 at EOF: missing " → emit error, pop context
5. EOF

**Fix Needed**: Both designs should add "Nested Error Handling" section with priority rules.

---

### 3. **Checkpoint/Rewind with Error Tokens** ⚠️

**GPT Mentions**: "On rewind, previously emitted error tokens remain in the buffer/push stack"

**But Doesn't Specify**:
- Are error positions deterministic across rewind?
- Can rewinding to before an error cause different recovery path?

**Concern**:
```elixir
stream1 = new("foo\0bar")
{:ok, tok1, stream2} = next(stream1)  # tok1 = :identifier :foo
checkpoint = save_checkpoint(stream2)
{:ok, tok2, stream3} = next(stream2)  # tok2 = :error_token (\0)
stream4 = restore_checkpoint(checkpoint)
{:ok, tok2_again, stream5} = next(stream4)

# Question: is tok2 == tok2_again?
# What if recovery scanning is non-deterministic?
```

**Fix Needed**: Specify determinism guarantee:
```
Recovery Determinism: Given the same input position and Driver state,
scan_to_sync/3 must always return the same end position. This ensures
checkpoint/rewind produces identical token streams.
```

---

### 4. **Warning vs Error Distinction** ⚠️

**CL Identified**: Some test cases are warnings (unnecessary quotes, ambiguous syntax)
**Neither Design Specifies**: How do warnings interact with error recovery?

**Current Code**: Warnings use `Toxic.Scope.prepend_warning/4`, which:
- Accumulates warnings in scope
- Does NOT halt tokenization
- Returned separately from tokens

**Clarification Needed**:
```
Warnings are NOT errors and do not trigger recovery. The error_mode option
only affects error returns ({:error, ...}). Warning paths continue normally
in both strict and tolerant modes.
```

**Both designs should add**: "Warnings vs Errors" section.

---

## Synthesis: Best of Both Designs

### Recommended Hybrid Approach

#### Phase 1: MVP (GPT-based)
1. **No synthetic tokens** (`:error_insertions` = false by default)
2. **GPT's sync point rules** (stop before, don't consume)
3. **GPT's EOF draining** (one error per call)
4. **GPT's bounded scanning** (`:error_max_skip`)
5. **CL's error categorization** (for implementation guide)
6. **GPT's deferral finalization** (flush before error token)

#### Phase 2: Enhanced Recovery (CL-based)
1. Add `:error_insertions` flag
2. Implement CL's Category 4-5 algorithms (synthetic closers)
3. Add CL's terminator stack adjustment strategies
4. Enhanced IDE diagnostics

---

## Specific Fixes Required

### For CL Design:
1. ✅ **Add sync point consumption rule**: "stop before, do not consume" (already added)
2. ❌ **Add `:error_max_skip` option** with default 4096
3. ❌ **Change EOF handling**: drain one error per call, not batch
4. ❌ **Add `:error_insertions` flag**: make synthetic tokens opt-in
5. ❌ **Clarify number errors**: token not emitted if error detected during parsing
6. ❌ **Add deferral finalization**: flush before error token
7. ❌ **Add grapheme cluster handling**: skip by cluster, not byte
8. ❌ **Add nested error section**: specify priority rules
9. ❌ **Add determinism guarantee**: checkpoint/rewind produces same tokens
10. ❌ **Add warnings section**: clarify warnings don't trigger recovery

### For GPT Design:
1. ❌ **Add per-category recovery details**: use CL's categorization
2. ❌ **Add test strategy details**: CL's cascade/position/stack tests
3. ❌ **Add grapheme cluster handling**: same as CL
4. ❌ **Add nested error section**: same as CL
5. ❌ **Expand determinism guarantee**: more detail than current mention
6. ❌ **Add warnings section**: same as CL
7. ❌ **Add migration phases**: CL's structure is clearer than GPT's steps

---

## Decision Matrix: CL vs GPT

| Feature | CL | GPT | Winner | Rationale |
|---------|----|----|--------|-----------|
| Error categorization | 10 categories, 63 cases | High-level matrix | **CL** | More comprehensive |
| Sync point rules | Underspecified initially | "stop before, don't consume" | **GPT** | Critical correctness rule |
| Synthetic tokens | Liberal use | Opt-in (`:error_insertions`) | **GPT** | Simpler MVP |
| EOF draining | Implied batch | One per call | **GPT** | Better invariants |
| Bounded scanning | Not specified | `:error_max_skip` | **GPT** | Essential safety |
| Deferral handling | Mentioned | Explicit finalization rule | **GPT** | Prevents bugs |
| Testing strategy | Very detailed | High-level | **CL** | Better test coverage |
| Migration path | 5 phases by category | 7 steps by module | **Tie** | Both valid, hybrid best |
| Terminator algorithms | Detailed case analysis | Minimal specification | **CL** | Better documentation |
| Recovery rationale | Per-category explanations | Brief notes | **CL** | Better maintainability |

**Overall**: Hybrid approach using GPT's correctness-critical rules with CL's comprehensive categorization and documentation.

---

## Recommended Final Design

### Core Principles (from GPT)
1. Stop before sync points, don't consume
2. One error per `next/2` call at EOF
3. Bounded scanning (`:error_max_skip`)
4. Finalize deferrals before error tokens
5. No synthetic tokens in MVP

### Implementation Guide (from CL)
1. Use 10-category classification for clarity
2. Follow per-category recovery strategies
3. Reference 63 test cases for coverage
4. Use detailed terminator algorithms (when Phase 2 adds insertions)
5. Implement cascade/position/stack tests

### New Additions (synthesis)
1. Grapheme cluster awareness in scanning
2. Nested error priority rules
3. Determinism guarantee for checkpoint/rewind
4. Warnings vs errors clarification
5. Hybrid migration path (infrastructure → core → complex → integration)

---

## Action Items

1. **Update CL design** with GPT's correctness rules (10 fixes listed above)
2. **Update GPT design** with CL's categorization and testing detail (7 additions listed above)
3. **Create unified design** merging both with synthesis additions
4. **Begin implementation** following hybrid migration path
5. **Write comprehensive tests** using CL's structure and GPT's reuse strategy

---

## Conclusion

Both designs are strong in different areas:
- **GPT excels at correctness-critical low-level rules** (sync points, bounded scanning, deferral handling)
- **CL excels at comprehensive analysis and documentation** (categorization, rationale, testing)

The synthesis combines:
- GPT's minimal, correct MVP foundation
- CL's detailed implementation roadmap
- New additions addressing gaps in both

**Recommendation**: Implement GPT's MVP first (simpler, safer), using CL's categorization as implementation guide. Phase 2 adds CL's synthetic token strategies when `:error_insertions` flag is enabled.

This approach:
- Delivers working tolerant mode quickly (GPT's MVP)
- Maintains upgrade path to full recovery (CL's algorithms)
- Addresses gaps both designs missed (grapheme clusters, nested errors, determinism)
- Provides excellent documentation for maintainers (CL's rationale + GPT's rules)

---

*Document Version: 1.0*
*Date: 2025-10-03*
*Analysis: Cross-reference of TOLERANT_MODE_CL.md and TOLERANT_MODE_GPT.md*
