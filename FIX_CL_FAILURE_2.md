  I added newline consumption for VC merge conflict errors in adjust_recovery so the error span includes the newline,
   and paired it with deferral cleanup so a stale :eol isn’t emitted before the error. The targeted test still shows
  an :eol before the error, meaning the conflict marker error is being raised with state.line already advanced or the
   newline is already in rest not def_rest at that point.
  • Implemented: when error is {:vc, :vc_merge_conflict_marker}, if def_rest starts with \n or \r\n, we advance to
    next line and start column 1.
  • Implemented earlier: drop deferred :eol if new_line > state.line in emit_error_and_advance.

  We likely need to include the newline in scan_to_sync’s default result for this error (so def_rest begins at the
  newline), or detect the case where newline remains in rest and handle it similarly.


  Implemented consuming the reserved word end during recovery:
  • In adjust_recovery/6, added a {:reserved, :reserved_unexpected_end} case that:
    • Eats end from rest; if followed by \n or \r\n, it advances to the next line and column 1; otherwise advances
      column by 3.
    • Returns no inserted tokens and the same scope.

  Test impact:
  • The “unexpected end with continuation” test now no longer emits a standalone :end token, but still shows :end in
    the sequence for one variant; full suite remains at 13 failures. Further tuning may be needed around where the
    :end token is being emitted from deferrals vs. direct tokenization.

  Implemented keyword spacing pre-error emission:
  • In adjust_recovery/6 for :keyword_missing_space_after_colon, we now:
    • Split rest at the first :.
    • Emit the identifier before : as a valid token.
    • Consume : from input.
    • Advance position accordingly.
    • Return the inserted identifier token so output order is [:identifier, :error_token, …].

  Quick checks:
  • Specific keyword-spacing tests pass.
  • Full suite remains at 13 failures (unchanged from previous step). One warning suggests switching length(id_chars)
     > 0 to a non-empty list check; I can clean that up next if you want.

  Remaining prominent failures:
  • VC conflict newline/EOL ordering,
  • Ternary continuation around ..//,
  • Unexpected end suppression still emitting :end in one path,
  • Mixed-errors cascade ordering,
  • Mismatched delimiter ordering still adds an extra :( in one case.


  Implemented string continuation and began complex ordering/map follow-ups:
  • String continuation: adjusted closer_starts_with?/2 to accept any atom via terminator_chars/1, so scan_to_sync
    stops at the correct closer. Targeted string error tests now pass. Full suite at 8 failures.
  • Map follow-ups: confirmed %{ path emits separate :%{} + :"{" to match tests; :map_invalid_open_delimiter recovery
     already pre-inserts :% then consumes spaces, which aligns with expectations. The remaining map-related failure
    is in the cascade test expecting a standalone :% in the stream; current tokens show only :%{} and :"{". That test
     specifically checks a different scenario (%{ foo<confusable>bar ;; <bidi>), which still lacks :% because %{ goes
     through the dedicated tokenizer path that emits :%{}. We'll need to special-case that cascade to also emit :%
    when %{ starts but we immediately diverge into identifier/bidi/semi errors.

  Proposed next steps:
  • For the cascade “nested structural + identifier issues”, when %{ path is taken and the following content produces
     an immediate error before a valid { body, also pre-insert :% alongside the existing :"{" so :% appears in the
    stream as expected by tests.
  • Address the remaining ordering issues:
    • Ensure mismatched delimiter test doesn’t duplicate :"(" in ([) case.
    • Ternary ..// continuation ordering.
    • Unexpected end lingering emission in one path.
    • VC conflict EOL redundancy.

Status: I implemented string continuation fixes, then addressed complex ordering and map
  follow-ups. I ran focused tests and the full suite after each change.
  • String continuation validation: Updated closer_starts_with?/2 to handle any atom
    terminator using terminator_chars/1. Targeted string error tests now pass; suite reduced
    to 8 failures.
  • Complex ordering + map follow-ups:
    • Left %{ tokenizer path as-is (it emits :%{} and :"{"), since tests elsewhere rely on
      that. For cascades where an identifier sanitization error happens immediately after
      opening a map, I pre-insert a synthetic :% prior to the error when recent_token was
      :%{} or :"{". This didn’t change the specific failing cascade; it appears the error is
       not hitting the identifier-sanitization recovery path in that case. We’ll revisit
      this with a more precise path if needed.

  Current remaining failures (8):
  • VC conflict EOL ordering,
  • Mixed errors cascade ordering,
  • Ternary ..// continuation sequence,
  • Unexpected end still appears in one path,
  • Mismatched delimiter test duplicates :"(" in ([) case,
  • Keyword spacing alt expectation in one test (now emits identifier before error, which
    breaks one variant expecting error first),
  • Alias continuation assert (presence of Bar in valid tokens) still failing in that test
    setup.

