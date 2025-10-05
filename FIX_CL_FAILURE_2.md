  I added newline consumption for VC merge conflict errors in adjust_recovery so the error span includes the newline,
   and paired it with deferral cleanup so a stale :eol isn’t emitted before the error. The targeted test still shows
  an :eol before the error, meaning the conflict marker error is being raised with state.line already advanced or the
   newline is already in rest not def_rest at that point.
  • Implemented: when error is {:vc, :vc_merge_conflict_marker}, if def_rest starts with \n or \r\n, we advance to
    next line and start column 1.
  • Implemented earlier: drop deferred :eol if new_line > state.line in emit_error_and_advance.

  We likely need to include the newline in scan_to_sync’s default result for this error (so def_rest begins at the
  newline), or detect the case where newline remains in rest and handle it similarly.
