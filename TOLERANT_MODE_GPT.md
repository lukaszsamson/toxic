Tolerant Mode Design for Toxic Tokenizer

Overview
- Goal: Add an error-tolerant tokenization mode that never halts on the first error and continues producing a flat, ranged token stream with accurate positions and preserved terminator state.
- Scope: Implement tolerant mode end-to-end across Driver and TokenStream (and sub-tokenizers) without breaking strict mode behavior. Provide predictable recovery at configurable sync points and emit explicit error tokens that downstream parsers can consume.

Modes & Options
- `:error_mode` (TokenStream existing): `:strict | :tolerant` (default tolerant in code, tests use strict).
- `:error_sync` (TokenStream existing): `[:semicolon | :newline | :closer]` determines recovery sync points, ordered by priority.
- Proposed additional options (future-proof):
  - `:error_max_skip` (default: 4096) – cap on characters scanned during recovery before falling back to newline.
  - `:error_insertions` (default: false) – allow synthetic closer insertions, off by default for a minimal, predictable MVP.
  - `:error_limit` (optional) – upper bound on number of error tokens to avoid flooding.

Error Token Shape
- Token form: `{:error_token, meta, reason}`
  - `meta`: always ranged `{{sl, sc}, {el, ec}, extra}` with exclusive end. Start is where the error is detected; end is where we stop after recovery scan.
  - `reason`: the Elixir-style reason tuple already used throughout the code (`{position_kv, message_io, token_io}`) or a compatible structure for internal errors (e.g., mismatched closer metadata).
- No nested payloads; stays linear like every other token emission.

Error Sources (by module)
- Driver-level (EOF and context/terminator stack)
  - `lib/toxic/driver.ex`: pending errors at EOF
    - `missing_interpolation_reason/2` (open `#{`)
    - `missing_terminator_reason/2` (open string/quoted/sigil)
    - `missing_scope_terminator_reason/2` (unclosed `(` `[`, `{`, `<<`, `do`, `fn`)
  - `mismatched_delimiter_reason/3` for immediate mismatches (e.g., `([)` or `([end`)
  - `interpolation_in_quoted_identifier_reason/3` (disallow `#{}` in quoted call identifiers)
- Tokenizer and helpers
  - `lib/toxic/tokenizer.ex`
    - VC conflict marker at line start
    - Unexpected token family (invalid control chars, confusables), number errors (invalid char after number/float, invalid float), `%` map shape errors, keyword spacing (`foo:bar`), reserved tokens `__aliases__/__block__`, alias-followed-by-`(`, escape at EOF, ternary `..//` fallthrough, general unexpected token
  - `lib/toxic/terminator.ex` – unexpected closer with empty stack, mismatched closer, unexpected `end`, alias+`(` error text
  - `lib/toxic/sigil.ex` – invalid name or delimiter, bad heredoc header after `~S"""`
  - `lib/toxic/string.ex` – bad heredoc header (no newline), returns error at the opening site
  - `lib/toxic/interpolation.ex` – invalid bidi/break chars in string/atom/sigil parts
  - `lib/toxic/comment.ex` and `lib/toxic/dot.ex` – invalid bidi/break chars in comments and `.#{...}` comment form
  - `lib/toxic/identifier.ex` – mixed script, unexpected token, NF(K)C and confusable suggestions, unsafe length limit, `@` disallowed in identifier, `existing_atoms_only` failures
  - `lib/toxic/number.ex` – invalid float construction
  - `lib/toxic/unescape.ex` – thrown errors during post-unescape mapping (rare in streaming; handled where unescape is applied)

Recovery Strategy Matrix
- General principles
  - Always make progress: consume at least one codepoint when handling an error to avoid loops.
  - Prefer local minimal drops for lexical errors (bad char, wrong delimiter char) and structured sync for structural errors (terminators, `do/end`).
  - Preserve precise ranges: `meta.start` at detection site; `meta.end` at the first configured sync point reached (exclusive) or after minimum consumption.
  - Do not mutate recent emissions except for required deferral coalescing already in place.

- Sync points
  - horizontal whitespace/escaped newline - stop before, do not consume it
  - comment start - stop before, do not consume it
  - `:semicolon`: stop before the next `;` (do not consume it), unless the next `;` is part of a valid operator lexeme (covered upstream).
  - `:newline`: stop before the next `\n` (or `\r\n`), not consuming it; update line/column appropriately.
  - `:closer`: stop before the expected closer for the top of `Driver.current_terminators/1` (e.g., `)`, `]`, `}`, `>>`, `end`), do not consume it. If stack is empty, this sync is a no-op.
  - Resolution order: first available in `error_sync` option; we stop at the earliest occurrence among selected syncs. If none are found within `:error_max_skip`, fall back to `:newline` or consume one codepoint.

- Lexical errors (bad char, invalid delimiter/name, invalid escape at EOF)
  - Emit `{:error_token, meta, reason}`.
  - Advance by one codepoint by default; if message includes a clear offending span (e.g., bad delimiter such as `~s!`), advance to the end of that span; if in string/sigil heredoc header validation, advance to newline when appropriate.
  - Leave terminator stack unchanged (we did not accept or pop any opener/closer).

- Comment errors (bidi/break)
  - Emit error token at offending char.
  - Skip the offending codepoint and continue scanning comment until EOL normally (since the comment tokenizer already stops at newline).

- Identifier and keyword errors
  - Keyword spacing `foo:bar`: emit error at `:`; drop just the `:` and continue on `bar` so subsequent tokens can still be classified.
  - Disallowed `@` in identifiers: emit error at token start; skip `@` only.
  - Mixed script/confusable/NFKC: emit error and drop the minimal offending span (from the provided `wrong` list) so the stream can continue near the next grapheme boundary.
  - Unsafe atom length and `existing_atoms_only`: emit error and drop the whole identifier grapheme sequence that triggered the error.

- Number errors
  - Invalid char after number/float: emit error and drop that single offending char; keep the parsed number token already emitted if it was produced before the error, or treat the number as un-emitted if the error was returned before emission (conservative: error token only, then resume at the offending char+1).
  - Invalid float (overflow or invalid exponent form): emit error and drop the exponent suffix.

- Dot comment errors
  - Same as comment errors; skip offending char and continue scanning until EOL.

- Sigil and string/heredoc errors
  - Invalid sigil name/delimiter: emit error and drop only the invalid delimiter char; continue to next tokenization step (could become identifier or operator next).
  - Bad heredoc header: emit error; prefer scanning to EOL (newline sync) so we realign at the next line; do not push heredoc context.
  - Invalid bidi/break in content: emit error, drop offending codepoint, continue accumulating fragments.
  - Missing string/sigil terminator (EOF or closing delimiter absent): at EOF or when `pending_error` detects an open context, emit error and close the context logically by popping the interpolation/string frame; do not synthesize an end token by default (see below for EOF handling). For MVP, rely on the error token to communicate the missing closer.

- Interpolation errors
  - `missing interpolation terminator`: emit error; pop the `{:interp, ...}` frame; optionally emit `{:end_interpolation, meta, kind}` after the error token for stream symmetry (recommended for linear invariants).
  - Interpolation inside quoted identifier: emit error at `#{`; sync to the next `}` or configured sync; drop the interpolation sequence; continue scanning the quoted identifier contents.

- Terminator errors
  - Unexpected closer with empty stack: emit error; drop the closer; do not mutate stack (already empty).
  - Mismatched closer: emit error; do not consume the closer if `:closer` sync is enabled and it matches the expected closer for any lower frame; otherwise, drop the closer; keep stack unchanged.
  - Unexpected `end`: emit error; drop `end`.
  - Alias followed by `(`: emit error; drop `(`; continue.

- EOF-specific pending errors (Driver)
  - When `rest == []` and `pending_error/1` finds an open context/terminator:
    - Emit `{:error_token, meta, reason}` using the existing reason builders.
    - Mutate state to make progress:
      - `missing_interpolation`: pop the `{:interp, ...}` and, for symmetry, emit `{:end_interpolation, meta, kind}` after the error token.
      - `missing_context` (open string/sigil/quoted identifier): pop the context and restore parent terminators (do not emit synthetic end token in MVP).
      - `missing_scope` (terminator stack non-empty): pop one stack entry (top) to advance; repeat on next `next/2` call until stack empties (bounded by stack depth).
    - Once all frames are cleared, return `{:eof, state}`.

Driver Integration
- Add `error_mode` and `error_sync` to `Toxic.Driver` via `new(opts)`; store on `scope` or state.
- In `Driver.next/2` error branches:
  - If strict: preserve current behavior (`{:error, reason, rest, state}`).
  - If tolerant: transform the error into an error token and recover-in-place:
    - Compute `start_meta` from state `{line, column}`.
    - Run `scan_to_sync/3` with the configured sync list to find recovery end.
    - Emit `{:error_token, meta(start..end), reason}` via `return_token/3`.
    - Update `line/column` to the scan end; leave or adjust `contexts/scope` as per the matrix above (never leave impossible states that will loop).
    - Ensure deferrals are flushed appropriately before error tokens when necessary (e.g., pending `:eol` adjustments shouldn’t get lost).
- On EOF with `pending_error/1`:
  - If strict: current behavior.
  - If tolerant: consume the pending error(s) as described in EOF-specific pending errors.
- Internal helpers to add:
  - `scan_to_sync(rest, state, opts) :: {new_rest, new_line, new_column}`
    - Fast path: scan bytes/characters, only recognizing `;`, `\n`/`\r\n`, and candidates for closer tokens (see below), up to `:error_max_skip`.
    - Closer recognition: use `Toxic.Driver.current_terminators/1` and `closing_for/1` to derive the expected closer atom and its literal bytes to search for; for multi-char closers (`>>`, `end`), search using prefix matches.
  - `emit_error_and_advance(reason, rest, state)` centralizes the tolerant error conversion.

TokenStream Integration
- Preferred path: Driver never returns `{:error, ...}` in tolerant mode, so `TokenStream`’s `refill_buffer/1` sets no `stream.error`. Strict mode continues to propagate errors unchanged.
- Fallback path (if Driver remains strict for some cases): implement tolerant handling in `next/peek/peek_n` where `stream.error` is set and `:error_mode == :tolerant` by calling a new Driver function `recover_after_error(rest, driver, opts) -> {:ok, entry, rest, driver}` that emits an error token and clears the error, then resume buffering.
- Checkpoint/rewind: already snapshotting `driver` and buffers; tolerant mode must preserve determinism. On rewind, previously emitted error tokens remain in the buffer/push stack; positions must not drift.

Terminator Stack & Context Handling
- Use `Toxic.Driver.current_terminators/1` to compute nearest closer for `:closer` sync.
- Do not push new openers during recovery.
- Only pop frames when handling EOF `pending_error` or when explicitly skipping an invalid closer token.
- Preserve `mismatch_hints` and indentation tracking in `scope`; do not clear hints on recovery; they improve error messages for subsequent pending errors.

Position & Meta Rules
- Start position: `state.line`/`state.column` at error detection.
- End position: where `scan_to_sync` stops (exclusive). For single-codepoint minimal drops, end = start advanced by 1 codepoint.
- For errors in heredocs where content lines had a prepended newline, adjust line accounting the same way `Interpolation` currently does for fragments.
- EOL coalescing: reuse existing `:reset_eol`/`:increase_eol` patterns; error tokens should not break EOL deferral updates. If an error lands while an `:eol` deferral is being built, finalize the deferral before emitting the error token to preserve consistent metas.

Examples
- Input: `([)` with tolerant mode and `[:closer, :newline]`
  - Tokens: `:"(", :"[", {:error_token, meta, mismatched(info)}, :"]"` (the `)` is dropped; stream resumes at `]`).
- Input: `"#{foo` at EOF
  - Tokens: `{:begin_interpolation,...}, {:identifier,..., :foo}, {:error_token, meta, missing_interpolation}, {:end_interpolation, meta, :string}` and then EOF.
- Input: `foo:bar`
  - Tokens: `{:identifier, ... :foo}, {:error_token, meta(at colon), msg(keyword must be followed by space)}, {:identifier, ... :bar}`
- Input: `%[ 1 ]`
  - Tokens: `{:%, ...}, {:error_token, meta(at `[`), msg(expected `%{` ...)}, {:"[", ...}, {:int, ...}, {:"]", ...}`

Test Plan
- Reuse existing strict error tests in `test/toxic_erros_test.exs` to assert strict path unchanged.
- Add tolerant-mode suites that:
  - For each error in `toxic_erros_test.exs`, assert that `TokenStream.new(..., error_mode: :tolerant)` returns a stream where:
    - An `:error_token` appears at the reported position with a message equal (or compatible) to Elixir’s reason; and
    - Tokenization continues and reaches EOF with no crash loops.
  - Add recovery-specific tests:
    - Sync to `:semicolon`, `:newline`, and `:closer` independently and in combination.
    - Nested contexts: missing terminator inside interpolation (`"\#{foo(}"`) recovers and allows resuming after `)` or newline per sync.
    - EOF pending errors are drained by emitting error tokens until the stack is empty.
  - Add lookahead/pushback/rewind tests around error tokens (buffer and push stack keep precise pre-terms and pre-positions).

Implementation Steps
1) Driver options
  - Thread `:error_mode` and `:error_sync` into `Toxic.Driver.new/1` (store in state/scope).
2) Driver tolerant path
  - In `next/2` branches returning `{:error, ...}`, call `emit_error_and_advance/3` in tolerant mode.
  - Implement `scan_to_sync/3` and `emit_error_and_advance/3` helpers.
3) EOF handling
  - Replace `pending_error/1` strict returns with tolerant emissions that pop one frame at a time and optionally emit `:end_interpolation`.
4) Buffer/refill
  - Ensure `TokenStream.fetch_tokens_from_driver/6` observes tolerant behavior (no `{:error, ...}` returned in tolerant mode). Keep strict path intact.
5) Meta/eol/deferrals
  - Audit deferral flows (`:reset_eol`, `:increase_eol`, coalescing) to ensure error tokens do not lose or reorder deferred tokens.
6) Sync: closer matching
  - Implement closer detection based on top-of-stack from `current_terminators/1` and `closing_for/1`; handle multi-char closers and `end`.
7) Tests
  - Add tolerant mode tests mapped to `test/toxic_erros_test.exs` cases plus recovery behavior.

Open Questions / Future Enhancements
- Insertions: should we synthesize closers (e.g., `{:inserted_closer, meta, :")"}`) when `:error_insertions` is enabled to better help higher-level parsers? Proposed as a follow-up feature.
- Unescape errors: where `Toxic.Unescape.unescape_tokens/1` throws, should we convert to `:error_token` in a post-pass or avoid unescape in tolerant mode? For now, keep unescape in the stream layer opt-in and return throw as an `{:error, reason, token}` from `unescape_tokens` (already implemented).
- Cursor completion: tolerant mode should compose predictably with future cursor-completion paths (currently stubs are present).

Appendix: Cross-Reference to Sources
- PLAN.md – items 2 and Next Steps 2 call for tolerant error recovery and `:error_token` emission.
- Strict-mode error cases are covered in tests: `test/toxic_erros_test.exs:1` (module), grouped cases including VC markers, maps, escapes, comments, strings/heredocs, numbers, reserved tokens, keywords, terminators, sigils, aliases, identifiers, dot handling, interpolation, ternary, atoms-only, and indentation hints.
- Primary error-return sites for reference:
  - `lib/toxic/driver.ex:63,68,71,74,96,143,170,441,472` (EOF pending errors, mismatches, interpolation in quoted identifier)
  - `lib/toxic/tokenizer.ex:22,244,302,420,431,433,443,444,480,514,518,522,544,548,613,620,623,656,672,684,691,701,702`
  - `lib/toxic/terminator.ex:19,31,103,126,132` (closer/mismatches/unexpected end)
  - `lib/toxic/sigil.ex:10,39,69,103,142` (name/delimiter/header)
  - `lib/toxic/string.ex:25` (heredoc header)
  - `lib/toxic/interpolation.ex:335` (invalid bidi/break)
  - `lib/toxic/comment.ex:13,17` and `lib/toxic/dot.ex:13,19` (comment bidi/break)
  - `lib/toxic/identifier.ex:32,36,40,42,50,64,68,75,96,161,175,191` (mixed script, unexpected tokens, suggestions, `@`, length)
  - `lib/toxic/number.ex:78` (invalid float)
  - `lib/toxic/util.ex:52,75,86` (unsafe atom length, conversion)

Summary
- Tolerant mode lives primarily in the Driver: transform all error returns into explicit `:error_token` emissions and advance to sync points to guarantee progress, while keeping terminator/context stacks coherent. TokenStream largely stays the same, benefitting from the Driver’s tolerant behavior. This design maps every strict error to a concrete recovery plan and maintains the project’s invariants of a flat, ranged, linear token stream suitable for Pratt parsing and future incremental lexing.

