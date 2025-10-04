Phase 2 implemented: structural insertions, terminator handling, and EOF synthesis wired into the Driver, gated by
  insert_structural_closers (now default true). Here’s what I changed and how it aligns with TOLERANT_MODE_GPT.md and
  TOLERANT_MODE_COMPARISON.md.

  What I implemented

  - Structural insertions
      - Mismatched closer: Inserts the expected closer token and pops one stack entry.
      - Unexpected closer (empty or misaligned stack): Inserts the corresponding opener and pushes to the stack.
      - EOF pending errors:
          - missing_scope: Emits error token, pops one terminator, and inserts the expected closer.
          - missing_interpolation: Emits error token and inserts {:end_interpolation, …, kind}; pops the interpolation frame.
          - missing_context (open string/sigil/quoted/atom): Emits error token, synthesizes the appropriate end token
            (e.g., :bin_string_end, :list_heredoc_end, :sigil_end, :quoted_identifier_end, :atom_safe_end/unsafe_end) and
            restores parent terminator stack; pops the interpolation frame.
      - Token metas for synthetic openers/closers use zero-length at the current position to avoid consuming underlying text;
        this keeps the actual closer visible next, as designed.
  - Driver options and defaults
      - TokenStream default updated to insert_structural_closers: true (Phase 2 on by default).
      - Previously added error_mode, error_sync, error_max_skip retained; whitespace sync and grapheme-aware scanning from
        Phase 1 remain.
  - State coherence
      - When inserting a synthetic closer, pops the top of scope(terminators).
      - When inserting a synthetic opener, pushes a new entry into scope(terminators) using current indentation.
      - EOF synthesis restores parent terminators after closing a string/sigil/quoted context.
  - Tolerant EOF draining (one per call) enhanced
      - Now queues synthesized structural tokens in output after the error token, while ensuring only one error token is
        emitted per Driver.next/2 call at EOF.
      - Keeps linear, single-token-per-return invariant.
  - Scan-to-sync and deferral guarantees (from Phase 1)
      - Kept bounded scanning (:error_max_skip), stop-before semantics at semicolon/newline/closer/comma/comment/whitespace.
      - Flushed deferrals before error tokens to preserve EOL behavior.

  Key code changes

  - lib/toxic/token_stream.ex
      - options: added insert_structural_closers and set default true
      - default error_sync remains [:semicolon, :newline, :closer, :comma]
      - default error_max_skip retained (4096)
  - lib/toxic/driver.ex
      - Driver struct now carries insert_structural_closers and other error controls
      - Tolerant paths in normal and interpolation contexts convert errors to error_token and synthesize structure (when
        enabled)
      - Grapheme-aware consume_one/2 returns {rest, line, col}
      - Added helpers:
          - synthesize_from_reason/2 to classify mismatched vs unexpected closer and create synthetic tokens + update scope
          - closer_atom_from_chars/1 and opening_for_closer/1
          - synthesize_closing/2 and synthesize_opening/2
          - maybe_tag_zero_len/1 to mark synthetic tokens zero-length at current position
          - synthesize_end_for_kind/3 mapping of kinds to end token types
      - EOF emit_pending_error/2 modified to insert structural end tokens and to pop/restore relevant contexts and
        terminators

  What this delivers per the design docs

  - TOLERANT_MODE_GPT.md Phase 2 items
      - Structural insertions enabled by default; recovery preserves nesting
      - Mismatched and unexpected closers handled (Category 4–5 from CL)
      - EOF draining synthesizes closers for remaining stack and string-like ends
      - Interpolation missing terminator synthesizes :end_interpolation
  - TOLERANT_MODE_COMPARISON.md Phase 2 scope
      - CL’s structural approaches applied, but kept conservative defaults for unexpected end (we do not synthesize do)
      - Driver remains single-token per call at EOF, preserving stream invariants
      - Bounded scanning, deferral flushing, and stop-before semantics preserved

  Notes and limitations

  - Unexpected end (reserved “end”) is still treated as error + continue; no synthetic :do is inserted (by design).
  - Inserted opener/closer metas are zero-length to avoid consuming underlying input; positions remain accurate for the real
    closer token that follows.
  - Synthesized string/sigil/heredoc end tokens carry minimal metadata (delim and indent 0) to keep the stream parseable
    without overcomplicating Phase 2.
  - Some of your tests that assert exact token counts or positions may need slight loosening now that structural tokens are
    inserted (e.g., extra tokens before/after an error). Most tests already assert presence of error_token and continuation
    tokens rather than exact sequences.

  Known test observations

  - Running the full suite shows unrelated failures in strict tests and some tolerance tests that check for exact token
    patterns; most tolerant tests pass.
  - A couple of tolerant tests assume exact token structures/counts that can vary with structural insertion (e.g., in strings
    with bidi/break, alias lookups). These can be adjusted to assert presence and continuation rather than exact sequences.

  Suggested next steps

  - Decide whether insert_structural_closers should default true globally or be set per test harness. If you prefer
    incremental activation, we can set it false by default in TokenStream and enable it in tests where needed.
  - Extend tolerant test expectations to accommodate inserted structural tokens (favor presence/continuation over exact
    sequences).
  - Consider handling ‘unexpected end’ with indentation hints in Phase 3 (synthesizing :do) if desired.

  If you want, I can:

  - Flip insert_structural_closers default back to false and enable it per tolerant test instantiation, to minimize token
    noise in existing tests.
  - Tweak specific tolerant tests to reflect structural token insertions (e.g., not asserting equality of full token lists).
