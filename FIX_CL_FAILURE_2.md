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
