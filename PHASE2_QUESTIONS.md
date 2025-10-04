1. Phase 2 Test Suite with Structural Insertions

  Analysis: Currently, test suite has insert_structural_closers: true by default (inherited from TokenStream). Tests
  checking for missing terminators (lines 635-704) expect error tokens but don't verify synthetic tokens.

  Impact Areas:
  - Lines 635-704: Missing terminator tests would have synthetic end tokens
  - Lines 676-682: Missing terminators inside interpolation would have synthetic closers + end_interpolation
  - Lines 267+: Mismatched/unexpected delimiter tests would have synthetic openers/closers

  Recommendation: ✅ Add Phase 2-specific tests, don't modify existing

  describe "Phase 2: Structural synthesis (insert_structural_closers: true)" do
    test "missing string terminator synthesizes bin_string_end" do
      tokens = tokenize_tolerant("\"foo")

      assert {:error_token, _, _} in token_types(tokens)
      assert {:bin_string_end, _, _} in token_types(tokens)  # Synthetic
    end

    test "unexpected closer synthesizes opener" do
      tokens = tokenize_tolerant(")")

      types = token_types(tokens)
      assert :error_token in types
      assert :"(" in types  # Synthetic opener
      assert :")" in types  # Actual closer
    end

    test "mismatched closer synthesizes expected" do
      tokens = tokenize_tolerant("([)")

      # Should see: (, [, error, ], error, )
      # Synthetic ] inserted before actual )
    end

    test "EOF drains multiple errors with synthesis" do
      tokens = tokenize_tolerant("#{foo(")
      
      # Should see:
      # - error (missing ))
      # - synthetic )
      # - error (missing })
      # - synthetic end_interpolation
      # - error (missing ")
      # - synthetic bin_string_end
    end
  end

  describe "Phase 2: Disabled synthesis (insert_structural_closers: false)" do
    defp tokenize_no_synthesis(string) do
      tokenize_tolerant(string, insert_structural_closers: false)
    end
    
    test "missing string terminator has no synthesis" do
      tokens = tokenize_no_synthesis("\"foo")
      
      assert {:error_token, _, _} in token_types(tokens)
      refute {:bin_string_end, _, _} in token_types(tokens)
    end
  end

  Verdict: Keep existing tests as-is (they verify error emission works). Add ~10-15 new tests for Phase 2 synthesis
  verification.

  ---
  2. Unexpected end with Indentation Hints - Phase 3?

  Current Behavior (terminator.ex:108-127):
  def check_terminator({:end, meta}, [], scope) do
    # Unexpected end with no matching do
    # Checks mismatch_hints for indentation-based suggestion
    # Returns error with hint message
    {:error, {meta, "unexpected reserved word: end" <> hint, "end"}}
  end

  Current Phase 2 (driver.ex:1316):
  defp opening_for_closer(:end), do: nil  # Does NOT synthesize :do

  Analysis:

  Why :end is special:
  1. Unlike (), [], {}, >> (paired delimiters), do...end is contextual
  2. end can close do, fn, and sometimes appears without opener (module boundaries)
  3. Indentation hints suggest where do might go, but it's ambiguous
  4. Synthesizing do could be misleading (wrong block type)

  Examples:
  # Input: "end\nfoo"
  # Wrong synthesis: :do, :end, :identifier (implies do-end block exists)
  # Current behavior: :error_token, :end, :identifier (marks as error, continues)

  # Input: "if true\n  :ok\nend"
  # Missing: , do: (keyword syntax)
  # Synthesizing :do would be wrong here

  Recommendation: ✅ Keep unexpected end in Phase 3 (or never)

  Rationale:
  1. :do synthesis is ambiguous (block vs keyword vs fn)
  2. Indentation hints are just suggestions, not proof of missing do
  3. Current behavior (emit :end after error) is reasonable for parsers
  4. Phase 2 spec (GPT line 100) says: "still emit :end so parsers can handle it" - already done

  What Phase 3 could add:
  - Synthesize :do only if indentation hint is strong + no ambiguity
  - Add context tracking to distinguish fn, do, block types
  - Heuristic: if end appears after expression + newline + indent, maybe synthesize do

  Verdict: Phase 3 or skip entirely. Current behavior is correct per spec.

  ---
  3. :insert_identifier_sanitization - Should It Be Implemented?

  What It Would Do (GPT spec line 77):
  # Mixed script/confusable/NFKC errors
  # Current: emit error, drop offending span
  # With sanitization: emit error + sanitized identifier token

  # Example:
  input = "foοbar"  # Greek omicron (confusable)
  # Current: error_token only
  # With sanitization: error_token + {:identifier, meta, :foobar}

  Error Cases (identifier.ex):
  1. Mixed script (line 36): Latin + Cyrillic/Greek/etc.
  2. Confusables (line 162): Characters that look like ASCII but aren't
  3. NFKC normalization failures
  4. Unsafe atom length (>255 bytes)
  5. existing_atoms_only failures

  What We'd Miss If Skipped:

  Missing Feature 1: IDE Recovery

  # Without sanitization:
  "foοbar + 1"  # Greek omicron
  → error_token, :dual_op, :int
  # Parser sees: [error] + 1 (incomplete expression)

  # With sanitization:
  → error_token, :identifier(:foobar), :dual_op, :int
  # Parser sees: foobar + 1 (complete expression, just flagged)

  Impact: IDE autocomplete, refactoring, type inference break on confusables

  Missing Feature 2: Partial Compilation

  # Large file with one confusable identifier
  # Without sanitization: Can't generate AST for that function
  # With sanitization: Can compile with warning, use sanitized name

  Impact: Incremental compilation, hot reload fail on identifier errors

  Missing Feature 3: Typo Correction

  # Error message with confusable
  "unexpected token: о (Greek omicron). Did you mean: o (Latin)?"
  # With sanitization, could suggest: "Using 'o' instead"

  Impact: Developer experience (correction suggestions less actionable)

  Missing Feature 4: Atom Length Truncation

  # Very long identifier (>255 bytes atom limit)
  # Without sanitization: error_token only
  # With sanitization: error + truncated atom

  Impact: Can't represent AST for long identifiers (crashes downstream)

  ---
  Recommendation: ⚠️ Implement if building IDE/tooling, skip for basic parser

  Implement If:

  1. Building language server / IDE integration ✅
  2. Need partial compilation on errors ✅
  3. Want best-in-class error recovery ✅
  4. Targeting production Elixir compatibility ✅

  Skip If:

  1. Building basic parser only ✅
  2. Errors should halt analysis ✅
  3. Minimizing scope for MVP ✅
  4. Can add later without breaking changes ✅

  Implementation Complexity: MEDIUM

  What's needed:
  # In identifier.ex error paths:
  {:error, {:mixed_script, wrong, {prefix, suffix}}} ->
    if opts[:insert_identifier_sanitization] do
      sanitized = String.replace(wrong, confusable_map)
      {error_token, {:identifier, meta, String.to_atom(sanitized)}}
    else
      {error_token}
    end

  Estimated effort:
  - Core logic: 50-100 LOC (sanitization helpers)
  - Tests: 10-15 new test cases
  - Integration: Already has flag infrastructure
  - Total: ~4-6 hours

  ---
  Summary & Recommendations

  | Question                    | Recommendation                                                    | Priority | Effort
    |
  |-----------------------------|-------------------------------------------------------------------|----------|---------
  --|
  | 1. Phase 2 test suite       | ✅ Add 10-15 new tests for synthesis verification                  | HIGH     | 2-3
  hours |
  | 2. Unexpected end synthesis | ⏸️ Defer to Phase 3 or skip (ambiguous, current behavior correct) | LOW      | N/A
    |
  | 3. Identifier sanitization  | 🤔 Implement if building IDE tooling, skip for MVP parser         | MEDIUM   | 4-6
  hours |

  Recommended Next Steps:

  Short Term (should do):
  1. ✅ Add Phase 2 synthesis verification tests
  2. ✅ Document :end special case (no synthesis by design)

  Medium Term (consider):
  1. Evaluate use case: IDE tooling vs basic parser?
  2. If IDE: implement :insert_identifier_sanitization
  3. If basic: skip and revisit later

  Long Term (maybe):
  1. Phase 3: Smart :do synthesis with context analysis
  2. Add heuristics for ambiguous cases
  3. Expand sanitization to cover more recovery scenarios
