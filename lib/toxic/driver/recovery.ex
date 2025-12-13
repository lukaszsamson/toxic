defmodule Toxic.Driver.Recovery do
  @moduledoc false

  import Toxic.Scope
  import Toxic.Token

  alias Toxic.{Error, Util}
  alias Toxic.Driver
  alias Toxic.Driver.Position
  alias Toxic.Driver.Synthesis

  # ============================================================================
  # Phase 1 tolerant mode helpers
  # ============================================================================

  # Emits an error token and advances the input, optionally synthesizing structural tokens.
  #
  # This is the core of tolerant mode error recovery. It handles:
  # 1. Converting legacy error reasons to structured Error structs
  # 2. Scanning forward to a sync point (semicolon, newline, closer, etc.)
  # 3. Context-specific recovery adjustments via adjust_recovery/5
  # 4. Synthesis of matching openers/closers to balance the stream
  # 5. Careful token ordering to maintain deterministic stream structure
  #
  # Token Ordering
  # --------------
  # The emitted token stream follows this strict order:
  #
  #   deferrals + pre_inserted + pre_synth + error_token + post_inserted + post_synth + actual_closer
  #
  # Where:
  # - `deferrals`: Previously deferred tokens (e.g., :eol), filtered for newline crossing
  # - `pre_inserted`: Recovery tokens to emit BEFORE the error (e.g., map % prefix)
  # - `pre_synth`: Structural synthesis before error (currently unused)
  # - `error_token`: The error_token itself with accurate position meta
  # - `post_inserted`: Recovery tokens to emit AFTER the error
  # - `post_synth`: Synthesized structural tokens (openers for unexpected closers, closers for missing/mismatched)
  # - `actual_closer`: The actual closer from input (with zero-length meta) if consumed during recovery
  #
  # Synthesis Behavior
  # ------------------
  # - Unexpected closer: Synthesizes matching opener AFTER error (if insert_structural_closers is true)
  # - Mismatched closer: Synthesizes expected closer AFTER error; actual closer follows with zero-length meta
  # - Missing closer: Synthesizes expected closer AFTER error at EOF
  # - All synthesized tokens use zero-length meta (start_pos == end_pos) to avoid position drift
  #
  # Scope Management
  # ----------------
  # - Synthesized openers are immediately popped (to avoid affecting downstream parsing)
  # - Mismatched closers pop the stack only if the actual closer will be emitted
  # - Missing closers pop one frame per synthesis
  #
  # Forward Progress Guarantee
  # --------------------------
  # Always advances at least one codepoint if recovery didn't move forward, preventing infinite loops.
  #
  def emit_error_and_advance(%Error{} = error, rest, state) do
    {def_rest, def_line, def_col} = Position.scan_to_sync(rest, state)

    # Phase 4: Context-specific minimal recovery (override default scan)
    {new_rest, new_line, new_column, recovery_tokens, scope_after_pre} =
      adjust_recovery(error, rest, state, def_rest, def_line, def_col)

    # Separate pre_inserted (before error) from post_inserted (after error)
    {pre_inserted, post_inserted} =
      Enum.split_with(recovery_tokens, fn
        {:post_error, _} -> false
        _ -> true
      end)

    # Unwrap post_error markers
    post_inserted = Enum.map(post_inserted, fn {:post_error, tok} -> tok end)

    # Always make progress
    {new_rest, new_line, new_column} =
      if new_line == state.line and new_column == state.column do
        Position.consume_one(rest, state)
      else
        {new_rest, new_line, new_column}
      end

    error_meta = meta(state.line, state.column, new_line, new_column, nil)
    error_token = {:error_token, error_meta, error}

    # Optionally synthesize structural tokens for delimiter errors.
    # Always compute proposal, but only keep it if appropriate:
    # - Keep synthesized closers for mismatches even when insert_structural_closers is false
    # - Keep synthesized openers for unexpected closers only when flag is true
    {synth_side, inserted_struct, scope_after_insert} =
      case Synthesis.synthesize_from_reason(error, %{state | scope: scope_after_pre}) do
        {:closer, inserted_all, scope_after_all} ->
          {:closer, inserted_all, scope_after_all}

        {:opener, inserted_all, scope_after_all} when state.insert_structural_closers ->
          {:opener, inserted_all, scope_after_all}

        _ ->
          {:none, [], scope_after_pre}
      end

    # Decide final scope updates
    actual_closer = Synthesis.actual_closer_from_reason(error)

    # Check if we'll emit the actual closer for mismatched case
    will_emit_actual_closer? =
      case {error.code, actual_closer} do
        {:terminator_mismatched_closer, closer_atom} ->
          scope(terminators: terms) = scope_after_insert

          case terms do
            [] -> false
            [{opener, _, _} | _] -> Driver.closing_for(opener) == closer_atom
          end

        _ ->
          false
      end

    scope_for_state =
      cond do
        # If we synthesized an opener for an unexpected closer, pop it now
        synth_side == :opener ->
          scope(terminators: [_ | popped_terms]) = scope_after_insert
          scope(scope_after_insert, terminators: popped_terms)

        # For mismatched closer, pop the stack if we'll emit the matching closer
        will_emit_actual_closer? ->
          scope(terminators: [_ | popped_terms]) = scope_after_insert
          scope(scope_after_insert, terminators: popped_terms)

        true ->
          scope_after_insert
      end

    {pre_synth, post_synth} =
      case synth_side do
        # For unexpected closers, synthesize opener AFTER error (per finalized plan/tests)
        :opener -> {[], inserted_struct}
        # For mismatches/missing closers, synthesize closer AFTER error only
        :closer -> {[], inserted_struct}
        _ -> {[], []}
      end

    # If this error originated from encountering a closer in the input, emit the
    # actual closer token after any synthesized tokens so the stream includes it
    # even when synthesis is disabled. This preserves expected [:error_token, synthetic_opener?, closer]
    # ordering. Use zero-length meta at the current position to avoid position drift.
    # Exception: for unexpected end, we already consumed it in recovery, so don't emit it here.
    # For mismatched closers, only emit if it matches the updated stack; otherwise leave
    # it to be detected as missing/unexpected at EOF.
    post_actual_closer =
      case {error.code, actual_closer} do
        {:reserved_unexpected_end, _} ->
          []

        {_, nil} ->
          []

        {:terminator_mismatched_closer, closer_atom} ->
          # Check if the closer matches the updated stack after synthesis (before final pop)
          scope(terminators: updated_terms) = scope_after_insert

          case updated_terms do
            # No match, will be handled at EOF
            [] ->
              []

            [{opener, _, _} | _] ->
              if Driver.closing_for(opener) == closer_atom do
                [{closer_atom, meta(new_line, new_column, new_line, new_column, nil)}]
              else
                # Doesn't match, will be handled at EOF or next iteration
                []
              end
          end

        {_, closer_atom} ->
          [{closer_atom, meta(new_line, new_column, new_line, new_column, nil)}]
      end

    # If the error span crossed a newline, drop any deferred :eol to avoid
    # emitting a stale end-of-line prior to the error token.
    # Also drop :end tokens when error is unexpected end.
    deferrals_to_emit =
      if new_line > state.line do
        Enum.reject(state.deferrals, fn tok -> elem(tok, 0) == :eol end)
      else
        state.deferrals
      end
      |> then(fn defs ->
        # Remove :end token if error is unexpected end
        if match?(%Error{code: :reserved_unexpected_end}, error) do
          Enum.reject(defs, fn tok -> elem(tok, 0) == :end end)
        else
          defs
        end
      end)

    # Flush deferrals BEFORE error to preserve ordering; merge synthesized tokens on proper sides
    # Order: deferrals + pre_inserted + pre_synth + error + post_inserted + post_synth
    new_output =
      state.output ++
        Enum.reverse(deferrals_to_emit) ++
        pre_inserted ++
        pre_synth ++ [error_token] ++ post_inserted ++ post_synth ++ post_actual_closer

    new_state = %{
      state
      | line: new_line,
        column: new_column,
        deferrals: [],
        output: new_output,
        scope: scope_for_state
    }

    # Return next token in output (could be a flushed deferral, then error token)
    Driver.next(new_rest, new_state)
  end

  # Phase 4: adjust scan target and optionally insert context-specific tokens
  # Code-based recovery only; no message parsing
  defp adjust_recovery(
         %Error{domain: domain, code: code, details: details} = err,
         rest,
         state,
         def_rest,
         def_line,
         def_col
       ) do
    case {domain, code} do
      {:reserved, :reserved_unexpected_end} ->
        # Consume the "end" keyword and an immediate newline if present.
        # We do NOT re-emit the :end token after the error because:
        # 1) It prevents stray :end from appearing in the stream and confusing downstream tools
        # 2) The error itself documents the unexpected end
        # 3) Re-emitting would require synthesizing a matching opener (do/fn), which is ambiguous
        # The error_token's position already captures the "end" location for diagnostics.
        case rest do
          [?e, ?n, ?d, ?\n | tail] ->
            {tail, state.line + 1, 1, [], state.scope}

          [?e, ?n, ?d, ?\r, ?\n | tail] ->
            {tail, state.line + 1, 1, [], state.scope}

          [?e, ?n, ?d | tail] ->
            {tail, state.line, state.column + 3, [], state.scope}

          _ ->
            {def_rest, def_line, def_col, [], state.scope}
        end

      {:alias, :alias_unexpected_paren} ->
        [?( | tail] = rest
        meta_paren = meta(state.line, state.column, state.line, state.column + 1, nil)
        paren_token = {:"(", meta_paren}

        {:ok, _tok, new_scope} = Synthesis.synthesize_opening(:"(", state)

        {tail, state.line, state.column + 1, [paren_token], new_scope}

      {:vc, :vc_merge_conflict_marker} ->
        # Consume the entire conflict marker line including the newline.
        # scan_to_sync may have stopped at whitespace, so we need to scan forward to find the newline.
        case Position.consume_until_newline(def_rest) do
          {new_rest, consumed_newline?} when consumed_newline? ->
            {new_rest, state.line + 1, 1, [], state.scope}

          _ ->
            # No newline found (EOF on same line), use def_rest as-is
            {def_rest, def_line, def_col, [], state.scope}
        end

      {_, :unexpected_token} ->
        # Special-case ternary missing trailing slash before the generic path
        if ternary_missing_slash?(rest) do
          meta_op = meta(state.line, state.column, state.line, state.column + 4, nil)
          op_token = {:identifier, meta_op, :..//}

          {Enum.drop(rest, 4), state.line, state.column + 4, [{:post_error, op_token}],
           state.scope}
        else
          # For generic unexpected tokens, do not scan ahead. Consume exactly one
          # grapheme to bound the error span and immediately continue.
          {new_rest, new_line, new_col} = Position.consume_one(rest, state)
          {new_rest, new_line, new_col, [], state.scope}
        end

      {_, :keyword_missing_space_after_colon} ->
        {[first | rest_chars], [?: | tail]} =
          Enum.split_while(rest, fn ch -> ch != ?: end)

        id_chars = [first | rest_chars]
        id_token = sanitize_identifier_from_chars(id_chars, state.line, state.column, state.scope)
        consumed_len = length(id_chars) + 1
        {tail, state.line, state.column + consumed_len, [id_token], state.scope}

      {_, :map_invalid_open_delimiter} ->
        [?% | _] = rest
        meta_percent = meta(state.line, state.column, state.line, state.column + 1, nil)
        percent_token = {:%, meta_percent}
        rest_after_percent = tl(rest)

        {rest_no_ws, l_after, c_after} = {rest_after_percent, state.line, state.column + 1}

        {rest_no_ws, l_after, c_after, [percent_token], state.scope}

      {_, :terminator_mismatched_closer} ->
        # For mismatched closers, consume normally and let post_actual_closer emit it
        {def_rest, def_line, def_col, [], state.scope}

      {_, :string_missing_terminator} ->
        if Map.get(details, :escape_at_eof?, false) do
          case def_rest do
            [?\n | new_rest] -> {new_rest, def_line + 1, 1, [], state.scope}
            [?\r, ?\n | new_rest] -> {new_rest, def_line + 1, 1, [], state.scope}
            _ -> {def_rest, def_line, def_col, [], state.scope}
          end
        else
          # defensive, this should should not happen
          {def_rest, def_line, def_col, [], state.scope}
        end

      {_, :heredoc_invalid_header} ->
        meta_end = meta(state.line, state.column, state.line, state.column, nil)

        # Infer end token from delimiter in token_display (already set)
        end_token =
          case List.wrap(err.token_display) do
            [?', ?', ?'] = delim -> {:list_heredoc_end, meta_end, delim, 0}
            [?", ?", ?"] = delim -> {:bin_heredoc_end, meta_end, delim, 0}
          end

        inserts = [{:post_error, end_token}]
        {def_rest, def_line, def_col, inserts, state.scope}

      {:identifier, _code} ->
        if state.insert_identifier_sanitization do
          span_chars = take_prefix_until(rest, def_rest)
          id_token = sanitize_identifier_from_chars(span_chars, state.line, state.column, state.scope)

          {def_rest, def_line, def_col, [{:post_error, id_token}], state.scope}
        else
          {def_rest, def_line, def_col, [], state.scope}
        end

      # Consecutive semicolons - now detected by tokenizer
      {:general, :syntax_consecutive_semicolons} ->
        # The first semicolon was already emitted; just consume the second one that triggered the error
        # No additional ; token needed since the first one is already in the stream
        {Enum.drop(rest, 1), state.line, state.column + 1, [], state.scope}

      # Default recovery for all other unhandled error codes
      {_, _} ->
        {def_rest, def_line, def_col, [], state.scope}
    end
  end

  defp sanitize_identifier_from_chars(chars, line, col, scope) do
    # Normalize original erroneous identifier and build ASCII-friendly skeleton
    bin = Util.characters_to_binary(chars)

    skeleton =
      try do
        String.Tokenizer.Security.confusable_skeleton(bin)
      rescue
        _ ->
          # Defensive: fallback if confusable_skeleton raises
          bin
      end

    nfkc = :unicode.characters_to_nfkc_list(skeleton)

    filtered =
      nfkc
      |> Enum.map(fn c -> if allowed_ident_char?(c), do: c, else: ?_ end)
      |> Enum.take(255)
      |> ensure_ident_start()

    # Respect existing_atoms_only: never create a new atom in tolerant recovery.
    # If the sanitized identifier doesn't already exist, fall back to a safe existing atom.
    {id_atom, token_chars} =
      case scope do
        scope(existing_atoms_only: true) ->
          try do
            {List.to_existing_atom(filtered), filtered}
          rescue
            ArgumentError ->
              # Guaranteed-existing atom literal; keeps parsing moving without atom creation.
              {:_, ~c"_"}
          end

        _ ->
          {List.to_atom(filtered), filtered}
      end

    meta_id = meta(line, col, line, col + length(token_chars), token_chars)
    {:identifier, meta_id, id_atom}
  end

  # Take the prefix list elements of `list` up to the exact `tail` list identity.
  # If `tail` is not a suffix of `list`, returns all of `list`.
  defp take_prefix_until(list, tail), do: do_take_prefix_until(list, tail, [])

  defp do_take_prefix_until(list, list, acc), do: Enum.reverse(acc)
  defp do_take_prefix_until([h | t], tail, acc), do: do_take_prefix_until(t, tail, [h | acc])
  # This should not happen
  defp do_take_prefix_until([], _tail, acc), do: Enum.reverse(acc)

  # this is overly restrictive but we are recovering from an error anyway
  defp allowed_ident_char?(c) when c in ?0..?9, do: true
  defp allowed_ident_char?(c) when c in ?A..?Z, do: true
  defp allowed_ident_char?(c) when c in ?a..?z, do: true
  defp allowed_ident_char?(c) when c in [?_, ??, ?!], do: true
  defp allowed_ident_char?(_), do: false

  defp ensure_ident_start([h | _] = list) when h in ?A..?Z or h in ?a..?z or h == ?_, do: list

  defp ensure_ident_start(list) do
    # Identifier starts with invalid character (digit or other); prepend underscore
    [?_ | list]
  end

  defp ternary_missing_slash?(rest) do
    case rest do
      [?., ?., ?/, ?/ | tail] ->
        case tail do
          [?/ | _] ->
            # defensive, this should not happen
            false

          _ ->
            true
        end

      _ ->
        false
    end
  end
end
