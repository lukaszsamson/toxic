%% SPDX-License-Identifier: Apache-2.0
%% SPDX-FileCopyrightText: 2021 The Elixir Team
%% SPDX-FileCopyrightText: 2012 Plataformatec

-module(toxic_tokenizer).
-include("toxic.hrl").
-include("toxic_tokenizer.hrl").
-export([invalid_do_error/1, terminator/1, unescape_tokens/4, tokenize/1]).
-export([ranges_to_legacy/1, collapse_linear_ranges/1, tokenize_single/5]).
%% Driver API exports
-export([current_terminators/1, peek_missing_terminator/1]).

-define(at_op(T),
  T =:= $@).

-define(capture_op(T),
  T =:= $&).

-define(unary_op(T),
  T =:= $!;
  T =:= $^).

-define(range_op(T1, T2),
  T1 =:= $., T2 =:= $.).

-define(concat_op(T1, T2),
  T1 =:= $+, T2 =:= $+;
  T1 =:= $-, T2 =:= $-;
  T1 =:= $<, T2 =:= $>).

-define(concat_op3(T1, T2, T3),
  T1 =:= $+, T2 =:= $+, T3 =:= $+;
  T1 =:= $-, T2 =:= $-, T3 =:= $-).

-define(power_op(T1, T2),
  T1 =:= $*, T2 =:= $*).

-define(mult_op(T),
  T =:= $* orelse T =:= $/).

-define(dual_op(T),
  T =:= $+ orelse T =:= $-).

-define(arrow_op3(T1, T2, T3),
  T1 =:= $<, T2 =:= $<, T3 =:= $<;
  T1 =:= $>, T2 =:= $>, T3 =:= $>;
  T1 =:= $~, T2 =:= $>, T3 =:= $>;
  T1 =:= $<, T2 =:= $<, T3 =:= $~;
  T1 =:= $<, T2 =:= $~, T3 =:= $>;
  T1 =:= $<, T2 =:= $|, T3 =:= $>).

-define(arrow_op(T1, T2),
  T1 =:= $|, T2 =:= $>;
  T1 =:= $~, T2 =:= $>;
  T1 =:= $<, T2 =:= $~).

-define(rel_op(T),
  T =:= $<;
  T =:= $>).

-define(rel_op2(T1, T2),
  T1 =:= $<, T2 =:= $=;
  T1 =:= $>, T2 =:= $=).

-define(comp_op2(T1, T2),
  T1 =:= $=, T2 =:= $=;
  T1 =:= $=, T2 =:= $~;
  T1 =:= $!, T2 =:= $=).

-define(comp_op3(T1, T2, T3),
  T1 =:= $=, T2 =:= $=, T3 =:= $=;
  T1 =:= $!, T2 =:= $=, T3 =:= $=).

-define(ternary_op(T1, T2),
  T1 =:= $/, T2 =:= $/).

-define(and_op(T1, T2),
  T1 =:= $&, T2 =:= $&).

-define(or_op(T1, T2),
  T1 =:= $|, T2 =:= $|).

-define(and_op3(T1, T2, T3),
  T1 =:= $&, T2 =:= $&, T3 =:= $&).

-define(or_op3(T1, T2, T3),
  T1 =:= $|, T2 =:= $|, T3 =:= $|).

-define(match_op(T),
  T =:= $=).

-define(in_match_op(T1, T2),
  T1 =:= $<, T2 =:= $-;
  T1 =:= $\\, T2 =:= $\\).

-define(stab_op(T1, T2),
  T1 =:= $-, T2 =:= $>).

-define(type_op(T1, T2),
  T1 =:= $:, T2 =:= $:).

-define(pipe_op(T),
  T =:= $|).

-define(ellipsis_op3(T1, T2, T3),
  T1 =:= $., T2 =:= $., T3 =:= $.).

%% Deprecated operators

-define(unary_op3(T1, T2, T3),
  T1 =:= $~, T2 =:= $~, T3 =:= $~).

-define(xor_op3(T1, T2, T3),
  T1 =:= $^, T2 =:= $^, T3 =:= $^).

%% Convert range tokens back to legacy metas {Line, Column, Extra}
ranges_to_legacy(TokensWithRanges) ->
  ranges_to_legacy_after_collapse(TokensWithRanges, false, []).

ranges_to_legacy_after_collapse([], _PrevWasEol, Acc) -> lists:reverse(Acc);
ranges_to_legacy_after_collapse([{eol, _} = Tok | T], _PrevWasEol, Acc) ->
  ranges_to_legacy_after_collapse(T, true, [ranges_token_to_legacy(Tok) | Acc]);
ranges_to_legacy_after_collapse([Tok | T], PrevWasEol, Acc) ->
  Conv = ranges_token_to_legacy(Tok),
  Adj = case {PrevWasEol, Conv} of
    %% Preserve actual starting column when it is greater than 1.
    {true, {Type, {Line, Col, Extra}}} when is_integer(Col), Col > 1 -> {Type, {Line, Col, Extra}};
    {true, {Type, {Line, Col, Extra}, V}} when is_integer(Col), Col > 1 -> {Type, {Line, Col, Extra}, V};
    {true, {Type, {Line, Col, Extra}, A, B}} when is_integer(Col), Col > 1 -> {Type, {Line, Col, Extra}, A, B};
    {true, {Type, {Line, Col, Extra}, A, B, C}} when is_integer(Col), Col > 1 -> {Type, {Line, Col, Extra}, A, B, C};
    {true, {Type, {Line, Col, Extra}, A, B, C, D}} when is_integer(Col), Col > 1 -> {Type, {Line, Col, Extra}, A, B, C, D};
    %% Default behaviour
    _ -> Conv
  end,
  ranges_to_legacy_after_collapse(T, false, [Adj | Acc]).

%% Internal helpers to construct ranges for tokens emitted by legacy tokenizer
%% Build meta depending on whether ranges are enabled
make_meta(Line, Column, EndLine, EndColumn, Extra, #toxic_tokenizer{}) ->
  {{Line, Column}, {EndLine, EndColumn}, Extra}.

make_meta_len(Line, Column, Len, Extra, Scope) when is_integer(Line), is_integer(Column), is_integer(Len) ->
  make_meta(Line, Column, Line, Column + Len, Extra, Scope).

%% Meta helpers (work with both legacy and range-shaped metas)
% Helper functions removed for now; keep placeholders to avoid unused warnings
% meta helpers can be reintroduced when migrating more token sites

%% Removed: legacy length inference no longer needed when emitting ranges inline.

%% Map a token with range meta back to legacy meta
ranges_token_to_legacy({Type, Meta}) ->
  {Type, legacy_meta(Meta)};
ranges_token_to_legacy({Type, Meta, Value}) when Type =:= bin_string; Type =:= list_string; Type =:= atom_unsafe; Type =:= atom_safe; Type =:= kw_identifier_unsafe; Type =:= kw_identifier_safe ->
  {Type, legacy_meta(Meta), ranges_convert_parts(Value)};
ranges_token_to_legacy({Type, Meta, Value}) ->
  {Type, legacy_meta(Meta), Value};
ranges_token_to_legacy({Type, Meta, Indent, Parts}) when Type =:= bin_heredoc; Type =:= list_heredoc ->
  {Type, legacy_meta(Meta), Indent, ranges_convert_parts(Parts)};
ranges_token_to_legacy({sigil, Meta, SigilAtom, Parts, Modifiers, Indentation, Delimiter}) ->
  {sigil, legacy_meta(Meta), SigilAtom, ranges_convert_parts(Parts), Modifiers, Indentation, Delimiter};
ranges_token_to_legacy(Other) ->
  %% Fallback: leave unchanged
  Other.

legacy_meta({{Line, Column}, _End, Extra}) -> {Line, Column, Extra};
legacy_meta({Line, Column, Extra}) -> {Line, Column, Extra};
legacy_meta(M) -> M.

ranges_convert_parts(Parts) when is_list(Parts) ->
  [ranges_convert_part(Part) || Part <- Parts];
ranges_convert_parts(Other) ->
  Other.

ranges_convert_part({StartMeta, EndMeta, Tokens}) when is_tuple(StartMeta), is_tuple(EndMeta), is_list(Tokens) ->
  {legacy_meta(StartMeta), legacy_meta(EndMeta), ranges_to_legacy(Tokens)};
ranges_convert_part(Other) ->
  Other.

%% Public: collapse linear markers back to legacy container tokens, preserving range metas
collapse_linear_ranges(Tokens) -> linear_to_legacy(Tokens).

linear_to_legacy(Tokens) ->
  {Out, []} = linear_to_legacy(Tokens, [], []),
  lists:reverse(Out).

linear_to_legacy([{bin_string_start, Meta, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{bin_string, Meta, Delim, []} | Stack]);
linear_to_legacy([{list_string_start, Meta, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{list_string, Meta, Delim, []} | Stack]);
linear_to_legacy([{bin_heredoc_start, Meta, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{bin_heredoc, Meta, Delim, [], undefined} | Stack]);
linear_to_legacy([{list_heredoc_start, Meta, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{list_heredoc, Meta, Delim, [], undefined} | Stack]);
linear_to_legacy([{sigil_start, Meta, SigilAtom, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{sigil, Meta, SigilAtom, Delim, [], nil, pending_end} | Stack]);
linear_to_legacy([{kw_identifier_unsafe_start, Meta, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{kw_identifier_unsafe, Meta, Delim, []} | Stack]);

%% Quoted identifier (from handle_dot) wraps a single identifier token
linear_to_legacy([{quoted_identifier_start, StartMeta, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{quoted_identifier, StartMeta, Delim, []} | Stack]);

%% Quoted atoms (linearized)
linear_to_legacy([{atom_unsafe_start, Meta, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{atom_unsafe, Meta, Delim, []} | Stack]);
linear_to_legacy([{atom_safe_start, Meta, Delim} | T], Out, Stack) ->
  linear_to_legacy(T, Out, [{atom_safe, Meta, Delim, []} | Stack]);

% Handle string_fragment for quoted_identifier - preserve metadata
linear_to_legacy([{string_fragment, FragMeta, Bin} | T], Out, [{quoted_identifier, Meta, Delim, Parts} | Stack]) ->
  linear_to_legacy(T, Out, [{quoted_identifier, Meta, Delim, [{string_fragment, FragMeta, Bin} | Parts]} | Stack]);
% Handle string_fragment for other kinds - just add content
linear_to_legacy([{string_fragment, _FragMeta, Bin} | T], Out, [{K, Meta, Delim, Parts} | Stack]) ->
  linear_to_legacy(T, Out, [{K, Meta, Delim, [Bin | Parts]} | Stack]);
linear_to_legacy([{string_fragment, _FragMeta, Bin} | T], Out, [{K, Meta, Delim, Parts, Extra} | Stack]) when K =:= bin_heredoc; K =:= list_heredoc ->
  linear_to_legacy(T, Out, [{K, Meta, Delim, [Bin | Parts], Extra} | Stack]);
linear_to_legacy([{string_fragment, _FragMeta, Bin} | T], Out, [{sigil, Meta, SigilAtom, Delim, PartsRev, Mods, pending_end} | Stack]) when is_binary(Bin) ->
  case PartsRev of
    [PrevBin | Rest] when is_binary(PrevBin) ->
      Merged = <<PrevBin/binary, Bin/binary>>,
      linear_to_legacy(T, Out, [{sigil, Meta, SigilAtom, Delim, [Merged | Rest], Mods, pending_end} | Stack]);
    _ ->
      linear_to_legacy(T, Out, [{sigil, Meta, SigilAtom, Delim, [Bin | PartsRev], Mods, pending_end} | Stack])
  end;

linear_to_legacy([{begin_interpolation, StartMeta, _Kind} | T], Out, Stack) ->
  %% Push interpolation frame; collect inner tokens
  linear_to_legacy(T, Out, [{interpol, StartMeta, []} | Stack]);
linear_to_legacy([{end_interpolation, EndMeta, _Kind} | T], Out, [{interpol, StartMeta, InnerRev} | StackRest]) ->
  InnerCollapsed = linear_to_legacy(lists:reverse(InnerRev)),
  % Convert range metadata to simple positional metadata for legacy format
  SimpleStartMeta = legacy_meta(StartMeta),
  SimpleEndMeta = legacy_meta(EndMeta),
  Part = {SimpleStartMeta, SimpleEndMeta, InnerCollapsed},
  case StackRest of
    [{K, Meta, Delim, Parts} | Stack] ->
      linear_to_legacy(T, Out, [{K, Meta, Delim, [Part | Parts]} | Stack]);
    [{K, Meta, Delim, Parts, Extra} | Stack] when K =:= bin_heredoc; K =:= list_heredoc ->
      linear_to_legacy(T, Out, [{K, Meta, Delim, [Part | Parts], Extra} | Stack]);
    [{sigil, Meta, SigilAtom, Delim, Parts, Mods, pending_end} | Stack] ->
      linear_to_legacy(T, Out, [{sigil, Meta, SigilAtom, Delim, [Part | Parts], Mods, pending_end} | Stack]);
    _ -> linear_to_legacy(T, [Part | Out], StackRest)
  end;

%% Accumulate inner tokens for interpolation
linear_to_legacy([Tok | T], Out, [{interpol, StartMeta, Inner} | Stack]) ->
  linear_to_legacy(T, Out, [{interpol, StartMeta, [Tok | Inner]} | Stack]);

%% Sigil end and optional modifiers
linear_to_legacy([{sigil_end, EndMeta, SigilAtom, Delim, Indent} | Rest], Out, [{sigil, Meta, SigilAtom, Delim, PartsRev, _Mods, pending_end} | Stack]) ->
  RevParts0 = lists:reverse(PartsRev),
  RevParts = case RevParts0 of [] -> [<<>>]; Other -> Other end,
  Parts1 = case Indent of
    I when is_integer(I) -> strip_heredoc_indentation(RevParts, I);
    _ -> RevParts
  end,
  case Rest of
    [{sigil_modifiers, M, Modifiers} | T] ->
      CM0 = combine_range_meta(Meta, EndMeta),
      CM = combine_range_meta(CM0, M),
      Tok = {sigil, CM, SigilAtom, Parts1, Modifiers, Indent, Delim},
      linear_to_legacy(T, [Tok | Out], Stack);
    _ ->
      CM = combine_range_meta(Meta, EndMeta),
      Tok = {sigil, CM, SigilAtom, Parts1, [], Indent, Delim},
      linear_to_legacy(Rest, [Tok | Out], Stack)
  end;

linear_to_legacy([{bin_string_end, MetaEnd, _Delim1} | T], Out, [{bin_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  CM = combine_range_meta(MetaStart, MetaEnd),
  Parts = case lists:reverse(PartsRev) of
    [] -> [<<>>];  % Empty string should have empty binary part, not empty list
    RevParts -> RevParts
  end,
  Tok = {bin_string, CM, Parts},
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      % Nested inside interpolation - add to interpolation frame
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
    _ ->
      % Top-level - add to output
      linear_to_legacy(T, [Tok | Out], Stack)
  end;
linear_to_legacy([{list_string_end, MetaEnd, _Delim1} | T], Out, [{list_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  CM = combine_range_meta(MetaStart, MetaEnd),
  Parts = case lists:reverse(PartsRev) of
    [] -> [<<>>];  % Empty charlist should use empty binary like bin_string, not empty string
    RevParts -> RevParts
  end,
  Tok = {list_string, CM, Parts},
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      % Nested inside interpolation - add to interpolation frame
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
    _ ->
      % Top-level - add to output
      linear_to_legacy(T, [Tok | Out], Stack)
  end;
linear_to_legacy([{bin_heredoc_end, MetaEnd, _Delim1, Indent} | T], Out, [{bin_heredoc, MetaStart, _Delim2, PartsRev, _} | Stack]) ->
  CM = combine_range_meta(MetaStart, MetaEnd),
  Parts = case lists:reverse(PartsRev) of
    [] -> [<<>>];  % Empty heredoc should use empty binary like bin_string
    RevParts -> 
      StrippedParts = strip_heredoc_indentation(RevParts, Indent),
      add_missing_empty_fragments(StrippedParts, Indent)
  end,
  Tok = {bin_heredoc, CM, Indent, Parts},
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{list_heredoc_end, MetaEnd, _Delim1, Indent} | T], Out, [{list_heredoc, MetaStart, _Delim2, PartsRev, _} | Stack]) ->
  CM = combine_range_meta(MetaStart, MetaEnd),
  Parts = case lists:reverse(PartsRev) of
    [] -> [<<>>];  % Empty heredoc should use empty binary like bin_string
    RevParts -> 
      StrippedParts = strip_heredoc_indentation(RevParts, Indent),
      add_missing_empty_fragments(StrippedParts)
  end,
  Tok = {list_heredoc, CM, Indent, Parts},
  linear_to_legacy(T, [Tok | Out], Stack);
%% Keep EOL tokens in collapsed ranges

%% Also accept string container frames when quoted kw_identifier was tokenized as string
linear_to_legacy([{kw_identifier_unsafe_end, MetaEnd, {Delim, {_EolLine, _EolCol}}} | T], Out, [{bin_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    _ -> {kw_identifier_unsafe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{kw_identifier_safe_end, MetaEnd, {Delim, {_EolLine, _EolCol}}} | T], Out, [{bin_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    _ -> {kw_identifier_safe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{kw_identifier_unsafe_end, MetaEnd, Delim} | T], Out, [{bin_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    _ -> {kw_identifier_unsafe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{kw_identifier_safe_end, MetaEnd, Delim} | T], Out, [{bin_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    _ -> {kw_identifier_safe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{kw_identifier_unsafe_end, MetaEnd, {Delim, {_EolLine, _EolCol}}} | T], Out, [{list_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    _ -> {kw_identifier_unsafe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{kw_identifier_safe_end, MetaEnd, {Delim, {_EolLine, _EolCol}}} | T], Out, [{list_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    _ -> {kw_identifier_safe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{kw_identifier_unsafe_end, MetaEnd, Delim} | T], Out, [{list_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    _ -> {kw_identifier_unsafe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{kw_identifier_safe_end, MetaEnd, Delim} | T], Out, [{list_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    _ -> {kw_identifier_safe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{atom_unsafe_end, MetaEnd, Delim} | T], Out, [{atom_unsafe, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {atom_quoted, CM, binary_to_atom(Bin, utf8)};
    _ -> {atom_unsafe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([{atom_safe_end, MetaEnd, Delim} | T], Out, [{atom_safe, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  CM0 = combine_range_meta(MetaStart, MetaEnd),
  CM = case CM0 of
    {{SL, SC}, {EL, EC}, _} -> {{SL, SC}, {EL, EC}, Delim};
    _ -> CM0
  end,
  Tok = case Parts of
    [Bin] when is_binary(Bin) -> {atom_quoted, CM, binary_to_atom(Bin, utf8)};
    _ -> {atom_safe, CM, Parts}
  end,
  linear_to_legacy(T, [Tok | Out], Stack);

%% Close quoted identifier and emit identifier token
linear_to_legacy([{quoted_identifier_end, _EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  % Convert parts to identifier atom and extract content end position  
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      % Single string fragment - convert to atom and extract end position
      AtomVal = case is_binary(Content) of
        true -> binary_to_atom(Content, utf8);
        false -> list_to_atom(Content)
      end,
      % Extract end position from string fragment
      ContentEndPos = case FragMeta of
        {{_FSL, _FSC}, {FEL, FEC}, _FX} -> {FEL, FEC};
        _ -> {1, 7}  % Fallback 
      end,
      {AtomVal, ContentEndPos};
    Parts when is_list(Parts) andalso length(Parts) > 1 ->
      % Multiple parts - find the last string_fragment and concatenate content
      StringFragments = [Frag || {string_fragment, _, _} = Frag <- Parts],
      case StringFragments of
        [] ->
          % No string fragments - fallback
          {'UNKNOWN', {1, 7}};
        _ ->
          % Extract end position from last string fragment and concatenate all content
          {string_fragment, LastFragMeta, _} = lists:last(StringFragments),
          ContentEndPos = case LastFragMeta of
            {{_FSL, _FSC}, {FEL, FEC}, _FX} -> {FEL, FEC};
            _ -> {1, 7}  % Fallback
          end,
          % Concatenate all string fragment content
          AllContent = [Content || {string_fragment, _, Content} <- StringFragments],
          ConcatContent = case AllContent of
            [SingleBinary] when is_binary(SingleBinary) -> SingleBinary;
            Binaries when is_list(Binaries) -> 
              case lists:all(fun is_binary/1, Binaries) of
                true -> iolist_to_binary(Binaries);
                false -> lists:append(AllContent)
              end
          end,
          AtomVal = case is_binary(ConcatContent) of
            true -> binary_to_atom(ConcatContent, utf8);
            false -> list_to_atom(ConcatContent)
          end,
          {AtomVal, ContentEndPos}
      end;
    [Content] when is_binary(Content) ->
      {binary_to_atom(Content, utf8), {1, 7}};
    [Content] when is_list(Content) ->
      {list_to_atom(Content), {1, 7}};
    _ ->
      % Fallback for unexpected content structure
      {'UNKNOWN', {1, 7}}
  end,
  % Calculate closing quote position - content end + 1 column for closing quote
  % The string fragment ends before the closing quote, so we need to add 1 column
  ClosingQuotePos = case ContentEnd of
    {Line, Column} -> {Line, Column + 1};
    Other -> Other
  end,
  % Create identifier metadata spanning from opening quote to closing quote (inclusive)
  IdentifierMeta = case StartMeta of
    {{SL, SC}, _SEnd, _SX} ->
      % Start position from StartMeta (now correctly positioned at opening quote)
      % End position should be the closing quote position
      {{SL, SC}, ClosingQuotePos, Delim};
    _ ->
      % Fallback 
      {{1, 2}, ClosingQuotePos, Delim}
  end,
  IdentTok = {identifier, IdentifierMeta, Atom},
  linear_to_legacy(T, [IdentTok | Out], Stack);

%% Close quoted identifier followed by do and emit do_identifier + do
linear_to_legacy([{quoted_do_identifier_end, _EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      AtomVal = case is_binary(Content) of true -> binary_to_atom(Content, utf8); false -> list_to_atom(Content) end,
      ContentEndPos = case FragMeta of {{_, _}, {FEL, FEC}, _} -> {FEL, FEC}; _ -> {1, 7} end,
      {AtomVal, ContentEndPos};
    [Content] when is_binary(Content) -> {binary_to_atom(Content, utf8), {1, 7}};
    [Content] when is_list(Content) -> {list_to_atom(Content), {1, 7}};
    _ -> {'UNKNOWN', {1, 7}}
  end,
  ClosingQuotePos = case ContentEnd of {Line, Column} -> {Line, Column + 1}; Other -> Other end,
  IdentifierMeta = case StartMeta of {{SL, SC}, _SEnd, _SX} -> {{SL, SC}, ClosingQuotePos, Delim}; _ -> {{1, 2}, ClosingQuotePos, Delim} end,
  DoIdTok = {do_identifier, IdentifierMeta, Atom},
  %% Don't emit do token here - let normal tokenizer handle it to avoid duplicates
  linear_to_legacy(T, [DoIdTok | Out], Stack);

%% Close quoted identifier where next token is dual_op start -> op_identifier
linear_to_legacy([{quoted_op_identifier_end, _EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      AtomVal = case is_binary(Content) of
        true -> binary_to_atom(Content, utf8);
        false -> list_to_atom(Content)
      end,
      ContentEndPos = case FragMeta of
        {{_FSL, _FSC}, {FEL, FEC}, _FX} -> {FEL, FEC};
        _ -> {1, 7}
      end,
      {AtomVal, ContentEndPos};
    _ -> {'UNKNOWN', {1,7}}
  end,
  ClosingQuotePos = case ContentEnd of
    {Line, Column} -> {Line, Column + 1};
    Other -> Other
  end,
  IdentifierMeta = case StartMeta of
    {{SL, SC}, _SEnd, _SX} -> {{SL, SC}, ClosingQuotePos, Delim};
    _ -> {{1,2}, ClosingQuotePos, Delim}
  end,
  IdentTok = {op_identifier, IdentifierMeta, Atom},
  linear_to_legacy(T, [IdentTok | Out], Stack);

%% Close quoted paren identifier and emit paren_identifier token
linear_to_legacy([{quoted_paren_identifier_end, _EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  % Convert parts to identifier atom and extract content end position  
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      % Single string fragment - convert to atom and extract end position
      AtomVal = case is_binary(Content) of
        true -> binary_to_atom(Content, utf8);
        false -> list_to_atom(Content)
      end,
      % Extract end position from string fragment
      ContentEndPos = case FragMeta of
        {{_FSL, _FSC}, {FEL, FEC}, _FX} -> {FEL, FEC};
        _ -> {1, 7}  % Fallback 
      end,
      {AtomVal, ContentEndPos};
    Parts when is_list(Parts) andalso length(Parts) > 1 ->
      % Multiple parts - find the last string_fragment and concatenate content
      StringFragments = [Frag || {string_fragment, _, _} = Frag <- Parts],
      case StringFragments of
        [] ->
          % No string fragments - fallback
          {'UNKNOWN', {1, 7}};
        _ ->
          % Extract end position from last string fragment and concatenate all content
          {string_fragment, LastFragMeta, _} = lists:last(StringFragments),
          ContentEndPos = case LastFragMeta of
            {{_FSL, _FSC}, {FEL, FEC}, _FX} -> {FEL, FEC};
            _ -> {1, 7}  % Fallback
          end,
          % Concatenate all string fragment content
          AllContent = [Content || {string_fragment, _, Content} <- StringFragments],
          ConcatContent = case AllContent of
            [SingleBinary] when is_binary(SingleBinary) -> SingleBinary;
            Binaries when is_list(Binaries) -> 
              case lists:all(fun is_binary/1, Binaries) of
                true -> iolist_to_binary(Binaries);
                false -> lists:append(AllContent)
              end
          end,
          AtomVal = case is_binary(ConcatContent) of
            true -> binary_to_atom(ConcatContent, utf8);
            false -> list_to_atom(ConcatContent)
          end,
          {AtomVal, ContentEndPos}
      end;
    [Content] when is_binary(Content) ->
      {binary_to_atom(Content, utf8), {1, 7}};
    [Content] when is_list(Content) ->
      {list_to_atom(Content), {1, 7}};
    _ ->
      % Fallback for unexpected content structure
      {'UNKNOWN', {1, 7}}
  end,
  % Calculate closing quote position - content end + 1 column for closing quote
  % The string fragment ends before the closing quote, so we need to add 1 column
  ClosingQuotePos = case ContentEnd of
    {Line, Column} -> {Line, Column + 1};
    Other -> Other
  end,
  % Create paren_identifier metadata spanning from opening quote to closing quote (inclusive)
  IdentifierMeta = case StartMeta of
    {{SL, SC}, _SEnd, _SX} ->
      % Start position from StartMeta (now correctly positioned at opening quote)
      % End position should be the closing quote position
      {{SL, SC}, ClosingQuotePos, Delim};
    _ ->
      % Fallback 
      {{1, 2}, ClosingQuotePos, Delim}
  end,
  IdentTok = {paren_identifier, IdentifierMeta, Atom},
  linear_to_legacy(T, [IdentTok | Out], Stack);

%% Close quoted bracket identifier and emit bracket_identifier token
linear_to_legacy([{quoted_bracket_identifier_end, _EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  % Convert parts to identifier atom and extract content end position  
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      % Single string fragment - convert to atom and extract end position
      AtomVal = case is_binary(Content) of
        true -> binary_to_atom(Content, utf8);
        false -> list_to_atom(Content)
      end,
      % Extract end position from string fragment
      ContentEndPos = case FragMeta of
        {{_FSL, _FSC}, {FEL, FEC}, _FX} -> {FEL, FEC};
        _ -> {1, 7}  % Fallback 
      end,
      {AtomVal, ContentEndPos};
    Parts when is_list(Parts) andalso length(Parts) > 1 ->
      % Multiple parts - find the last string_fragment and concatenate content
      StringFragments = [Frag || {string_fragment, _, _} = Frag <- Parts],
      case StringFragments of
        [] ->
          % No string fragments - fallback
          {'UNKNOWN', {1, 7}};
        _ ->
          % Extract end position from last string fragment and concatenate all content
          {string_fragment, LastFragMeta, _} = lists:last(StringFragments),
          ContentEndPos = case LastFragMeta of
            {{_FSL, _FSC}, {FEL, FEC}, _FX} -> {FEL, FEC};
            _ -> {1, 7}  % Fallback
          end,
          % Concatenate all string fragment content
          AllContent = [Content || {string_fragment, _, Content} <- StringFragments],
          ConcatContent = case AllContent of
            [SingleBinary] when is_binary(SingleBinary) -> SingleBinary;
            Binaries when is_list(Binaries) -> 
              case lists:all(fun is_binary/1, Binaries) of
                true -> iolist_to_binary(Binaries);
                false -> lists:append(AllContent)
              end
          end,
          AtomVal = case is_binary(ConcatContent) of
            true -> binary_to_atom(ConcatContent, utf8);
            false -> list_to_atom(ConcatContent)
          end,
          {AtomVal, ContentEndPos}
      end;
    [Content] when is_binary(Content) ->
      {binary_to_atom(Content, utf8), {1, 7}};
    [Content] when is_list(Content) ->
      {list_to_atom(Content), {1, 7}};
    _ ->
      % Fallback for unexpected content structure
      {'UNKNOWN', {1, 7}}
  end,
  % Calculate closing quote position - content end + 1 column for closing quote
  % The string fragment ends before the closing quote, so we need to add 1 column
  ClosingQuotePos = case ContentEnd of
    {Line, Column} -> {Line, Column + 1};
    Other -> Other
  end,
  % Create bracket_identifier metadata spanning from opening quote to closing quote (inclusive)
  IdentifierMeta = case StartMeta of
    {{SL, SC}, _SEnd, _SX} ->
      % Start position from StartMeta (now correctly positioned at opening quote)
      % End position should be the closing quote position
      {{SL, SC}, ClosingQuotePos, Delim};
    _ ->
      % Fallback 
      {{1, 2}, ClosingQuotePos, Delim}
  end,
  IdentTok = {bracket_identifier, IdentifierMeta, Atom},
  linear_to_legacy(T, [IdentTok | Out], Stack);

%% Pass-through for non-linear tokens
linear_to_legacy([Tok | T], Out, Stack) ->
  case Stack of
    [{quoted_identifier, StartMeta, Delim, PartsRev} | Rest] ->
      %% Accumulate tokens inside quoted identifier
      linear_to_legacy(T, Out, [{quoted_identifier, StartMeta, Delim, [Tok | PartsRev]} | Rest]);
    [{interpol, StartMeta, Inner} | Rest] ->
      linear_to_legacy(T, Out, [{interpol, StartMeta, [Tok | Inner]} | Rest]);
    _ -> linear_to_legacy(T, [Tok | Out], Stack)
  end;
linear_to_legacy([], Out, []) -> {Out, []};
linear_to_legacy([], Out, Stack) -> {Out, Stack}.

%% Combine range-shaped metas into a single span using the start of the first and end of the second.
combine_range_meta({{SL, SC}, _SEnd, _SX}, {_EStart, {EL, EC}, _EX}) -> {{SL, SC}, {EL, EC}, nil};
combine_range_meta(Start, End) -> {Start, End}.

tokenize_single(_, Line, Column, #toxic_tokenizer{} = Scope, Tokens) when not is_integer(Line) orelse not is_integer(Column) ->
  error({badarg, tokenize, line_or_column_not_integer, {Line, Column, Scope, Tokens}});

tokenize_single([$}], Line, Column, #toxic_tokenizer{mode = [normal | _]} = Scope, Tokens) ->
  % TODO: yield(end_interpolation)
  % TODO: pop normal mode from the stack
  % TODO: pop terminator from the stack
  yield([], Line, Column + 1, Scope, Tokens);

tokenize_single([], Line, Column, #toxic_tokenizer{cursor_completion=Cursor} = Scope, Tokens) when Cursor /= false ->
  #toxic_tokenizer{ascii_identifiers_only=Ascii, terminators=Terminators, warnings=Warnings} = Scope,

  {CursorColumn, AccTerminators, AccTokens} =
    add_cursor(Line, Column, Cursor, Terminators, Tokens),

  AllWarnings = maybe_unicode_lint_warnings(Ascii, Tokens, Warnings),
  {ok, Line, CursorColumn, AllWarnings, AccTokens, AccTerminators};

tokenize_single([], EndLine, EndColumn, #toxic_tokenizer{terminators=[{Start, {StartLine, StartColumn, _}, _} | _]} = Scope, Tokens) ->
  End = terminator(Start),
  Hint = missing_terminator_hint(Start, End, Scope),
  Message = "missing terminator: ~ts",
  Formatted = io_lib:format(Message, [End]),
  Meta = [
    {opening_delimiter, Start},
    {expected_delimiter, End},
    {line, StartLine},
    {column, StartColumn},
    {end_line, EndLine},
    {end_column, EndColumn}
  ],
  error({Meta, [Formatted, Hint], []}, [], Scope, Tokens);

tokenize_single([], Line, Column, #toxic_tokenizer{} = Scope, Tokens) ->
  #toxic_tokenizer{ascii_identifiers_only=Ascii, warnings=Warnings} = Scope,
  _AllWarnings = maybe_unicode_lint_warnings(Ascii, Tokens, Warnings),
  % {ok, Line, Column, AllWarnings, Tokens, []};
  yield([], Line, Column + 1, Scope, Tokens);

% VC merge conflict

tokenize_single(("<<<<<<<" ++ _) = Original, Line, 1, Scope, Tokens) ->
  FirstLine = lists:takewhile(fun(C) -> C =/= $\n andalso C =/= $\r end, Original),
  Reason = {make_meta_len(Line, 1, 1, nil, Scope), "found an unexpected version control marker, please resolve the conflicts: ", FirstLine},
  error(Reason, Original, Scope, Tokens);

% Base integers

tokenize_single([$0, $x, H | T], Line, Column, Scope, Tokens) when ?is_hex(H) ->
  {Rest, Number, OriginalRepresentation, Length} = tokenize_hex(T, [H], 1),
  Token = {int, make_meta_len(Line, Column, 2 + Length, Number, Scope), OriginalRepresentation},
  yield(Rest, Line, Column + 2 + Length, Scope, [Token | Tokens]);

tokenize_single([$0, $b, H | T], Line, Column, Scope, Tokens) when ?is_bin(H) ->
  {Rest, Number, OriginalRepresentation, Length} = tokenize_bin(T, [H], 1),
  Token = {int, make_meta_len(Line, Column, 2 + Length, Number, Scope), OriginalRepresentation},
  yield(Rest, Line, Column + 2 + Length, Scope, [Token | Tokens]);

tokenize_single([$0, $o, H | T], Line, Column, Scope, Tokens) when ?is_octal(H) ->
  {Rest, Number, OriginalRepresentation, Length} = tokenize_octal(T, [H], 1),
  Token = {int, make_meta_len(Line, Column, 2 + Length, Number, Scope), OriginalRepresentation},
  yield(Rest, Line, Column + 2 + Length, Scope, [Token | Tokens]);

% Comments

tokenize_single([$# | String], Line, Column, Scope, Tokens) ->
  case tokenize_comment(String, [$#]) of
    {error, Char} ->
      error_comment(Char, [$# | String], Line, Column, Scope, Tokens);
    {Rest, Comment} ->
      preserve_comments(Line, Column, Tokens, Comment, Rest, Scope),
      % Check if comment ends with newline and handle appropriately
      case Rest of
        "\n" ++ ActualRest ->
          % Comment followed by newline - generate eol token
          tokenize_eol(ActualRest, Line, Scope, eol(Line, Column, reset_eol(Tokens), Scope));
        "\r\n" ++ ActualRest ->
          % Comment followed by CRLF - generate eol token
          tokenize_eol(ActualRest, Line, Scope, eol(Line, Column, reset_eol(Tokens), Scope));
        _ ->
          % Comment at EOF or followed by other content - no eol token
          yield(Rest, Line, Column, Scope, reset_eol(Tokens))
      end
  end;

% Sigils

tokenize_single([$~, H | _T] = Original, Line, Column, Scope, Tokens) when ?is_upcase(H) orelse ?is_downcase(H) ->
  tokenize_sigil(Original, Line, Column, Scope, Tokens);

% Char tokens

% We tokenize char literals (?a) as {char, _, CharInt} instead of {number, _,
% CharInt}. This is exactly what Erlang does with Erlang char literals
% ($a). This means we'll have to adjust the error message for char literals in
% toxic_errors.erl as by default {char, _, _} tokens are "hijacked" by Erlang
% and printed with Erlang syntax ($a) in the parser's error messages.

tokenize_single([$?, $\\, H | T], Line, Column, Scope, Tokens) ->
  Char = toxic_interpolation:unescape_map(H),

  NewScope = if
    H =:= Char, H =/= $\\ ->
      case handle_char(Char) of
        {Escape, Name} ->
          Msg = io_lib:format("found ?\\ followed by code point 0x~.16B (~ts), please use ?~ts instead",
                              [Char, Name, Escape]),
          prepend_warning(Line, Column, Msg, Scope);

        false when ?is_downcase(H); ?is_upcase(H) ->
          Msg = io_lib:format("unknown escape sequence ?\\~tc, use ?~tc instead", [H, H]),
          prepend_warning(Line, Column, Msg, Scope);

        false ->
          Scope
      end;
    true ->
      Scope
  end,

  % Check if we have a literal newline after the escape
  {Token, Rest, NewLine, NewColumn} = case {H, T} of
    {$\n, _} ->
      % ?\\\n - escaped newline, consume the actual newline
      {{char, make_meta(Line, Column, Line + 1, 1, [$?, $\\, $\n], Scope), Char}, T, Line + 1, 1};
    _ ->
      % Regular escaped char
      {{char, make_meta_len(Line, Column, 3, [$?, $\\, H], Scope), Char}, T, Line, Column + 3}
  end,
  yield(Rest, NewLine, NewColumn, NewScope, [Token | Tokens]);

tokenize_single([$?, Char | T], Line, Column, Scope, Tokens) ->
  NewScope = case handle_char(Char) of
    {Escape, Name} ->
      Msg = io_lib:format("found ? followed by code point 0x~.16B (~ts), please use ?~ts instead",
                          [Char, Name, Escape]),
      prepend_warning(Line, Column, Msg, Scope);
    false ->
      Scope
  end,
  
  % Check if the char is a newline
  {Token, Rest, NewLine, NewColumn} = case Char of
    $\n ->
      % ?\n - raw newline character, consume it and move to next line
      {{char, make_meta(Line, Column, Line + 1, 1, [$?, $\n], Scope), Char}, T, Line + 1, 1};
    _ ->
      % Regular char
      {{char, make_meta_len(Line, Column, 2, [$?, Char], Scope), Char}, T, Line, Column + 2}
  end,
  yield(Rest, NewLine, NewColumn, NewScope, [Token | Tokens]);

% Heredocs

tokenize_single("\"\"\"" ++ T, Line, Column, Scope, Tokens) ->
  handle_heredocs(T, Line, Column, $", Scope, Tokens);

%% TODO: Remove me in Elixir v2.0
tokenize_single("'''" ++ T, Line, Column, Scope, Tokens) ->
  NewScope = prepend_warning(Line, Column, "single-quoted string represent charlists. Use ~c''' if you indeed want a charlist or use \"\"\" instead", Scope),
  handle_heredocs(T, Line, Column, $', NewScope, Tokens);

% Strings

tokenize_single([$" | T], Line, Column, Scope, Tokens) ->
  handle_strings(T, Line, Column + 1, $", Scope, Tokens);

%% TODO: Remove me in Elixir v2.0
tokenize_single([$' | T], Line, Column, Scope, Tokens) ->
  handle_strings(T, Line, Column + 1, $', Scope, Tokens);

% Operator atoms

tokenize_single(".:" ++ Rest, Line, Column, Scope, Tokens) when ?is_space(hd(Rest)) ->
  yield(Rest, Line, Column + 2, Scope, [{kw_identifier, make_meta_len(Line, Column, 2, nil, Scope), '.'} | Tokens]);

tokenize_single("<<>>:" ++ Rest, Line, Column, Scope, Tokens) when ?is_space(hd(Rest)) ->
  yield(Rest, Line, Column + 5, Scope, [{kw_identifier, make_meta_len(Line, Column, 5, nil, Scope), '<<>>'} | Tokens]);
tokenize_single("%{}:" ++ Rest, Line, Column, Scope, Tokens) when ?is_space(hd(Rest)) ->
  yield(Rest, Line, Column + 4, Scope, [{kw_identifier, make_meta_len(Line, Column, 4, nil, Scope), '%{}'} | Tokens]);
tokenize_single("%:" ++ Rest, Line, Column, Scope, Tokens) when ?is_space(hd(Rest)) ->
  yield(Rest, Line, Column + 2, Scope, [{kw_identifier, make_meta_len(Line, Column, 2, nil, Scope), '%'} | Tokens]);
tokenize_single("&:" ++ Rest, Line, Column, Scope, Tokens) when ?is_space(hd(Rest)) ->
  yield(Rest, Line, Column + 2, Scope, [{kw_identifier, make_meta_len(Line, Column, 2, nil, Scope), '&'} | Tokens]);
tokenize_single("{}:" ++ Rest, Line, Column, Scope, Tokens) when ?is_space(hd(Rest)) ->
  yield(Rest, Line, Column + 3, Scope, [{kw_identifier, make_meta_len(Line, Column, 3, nil, Scope), '{}'} | Tokens]);
tokenize_single("..//:" ++ Rest, Line, Column, Scope, Tokens) when ?is_space(hd(Rest)) ->
  yield(Rest, Line, Column + 5, Scope, [{kw_identifier, make_meta_len(Line, Column, 5, nil, Scope), '..//'} | Tokens]);

tokenize_single(":<<>>" ++ Rest, Line, Column, Scope, Tokens) ->
  yield(Rest, Line, Column + 5, Scope, [{atom, make_meta_len(Line, Column, 5, nil, Scope), '<<>>'} | Tokens]);
tokenize_single(":%{}" ++ Rest, Line, Column, Scope, Tokens) ->
  yield(Rest, Line, Column + 4, Scope, [{atom, make_meta_len(Line, Column, 4, nil, Scope), '%{}'} | Tokens]);
tokenize_single(":%" ++ Rest, Line, Column, Scope, Tokens) ->
  yield(Rest, Line, Column + 2, Scope, [{atom, make_meta_len(Line, Column, 2, nil, Scope), '%'} | Tokens]);
tokenize_single(":{}" ++ Rest, Line, Column, Scope, Tokens) ->
  yield(Rest, Line, Column + 3, Scope, [{atom, make_meta_len(Line, Column, 3, nil, Scope), '{}'} | Tokens]);
tokenize_single(":..//" ++ Rest, Line, Column, Scope, Tokens) ->
  yield(Rest, Line, Column + 5, Scope, [{atom, make_meta_len(Line, Column, 5, nil, Scope), '..//'} | Tokens]);

% ## Three Token Operators
tokenize_single([$:, T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when
    ?unary_op3(T1, T2, T3); ?comp_op3(T1, T2, T3); ?and_op3(T1, T2, T3); ?or_op3(T1, T2, T3);
    ?arrow_op3(T1, T2, T3); ?xor_op3(T1, T2, T3); ?concat_op3(T1, T2, T3); ?ellipsis_op3(T1, T2, T3) ->
  Token = {atom, make_meta_len(Line, Column, 4, nil, Scope), list_to_atom([T1, T2, T3])},
  yield(Rest, Line, Column + 4, Scope, [Token | Tokens]);

% ## Two Token Operators

tokenize_single([$:, $:, $: | Rest], Line, Column, Scope, Tokens) ->
  Message = "atom ::: must be written between quotes, as in :\"::\", to avoid ambiguity",
  NewScope = prepend_warning(Line, Column, Message, Scope),
  Token = {atom, make_meta_len(Line, Column, 3, nil, Scope), '::'},
  yield(Rest, Line, Column + 3, NewScope, [Token | Tokens]);

tokenize_single([$:, T1, T2 | Rest], Line, Column, Scope, Tokens) when
    ?comp_op2(T1, T2); ?rel_op2(T1, T2); ?and_op(T1, T2); ?or_op(T1, T2);
    ?arrow_op(T1, T2); ?in_match_op(T1, T2); ?concat_op(T1, T2); ?power_op(T1, T2);
    ?stab_op(T1, T2); ?range_op(T1, T2) ->
  Token = {atom, make_meta_len(Line, Column, 3, nil, Scope), list_to_atom([T1, T2])},
  yield(Rest, Line, Column + 3, Scope, [Token | Tokens]);

% ## Single Token Operators
tokenize_single([$:, T | Rest], Line, Column, Scope, Tokens) when
    ?at_op(T); ?unary_op(T); ?capture_op(T); ?dual_op(T); ?mult_op(T);
    ?rel_op(T); ?match_op(T); ?pipe_op(T); T =:= $. ->
  Token = {atom, make_meta_len(Line, Column, 2, nil, Scope), list_to_atom([T])},
  yield(Rest, Line, Column + 2, Scope, [Token | Tokens]);

% ## Stand-alone tokens

tokenize_single("=>" ++ Rest, Line, Column, Scope, Tokens) ->
  EOL = previous_was_eol(Tokens),
  Token0 = {assoc_op, make_meta_len(Line, Column, 2, EOL, Scope), '=>'},
  % If previous was EOL, we should not keep the EOL token around; attach its count and drop it
  Tokens1 = case Tokens of
    [{eol, _} | Tail] -> Tail;
    _ -> Tokens
  end,
  yield(Rest, Line, Column + 2, Scope, [Token0 | Tokens1]);

tokenize_single("..//" ++ Rest = String, Line, Column, Scope, Tokens) ->
  case strip_horizontal_space(Rest, 0) of
    {[$/ | _] = Remaining, Extra} ->
      Token = {identifier, make_meta_len(Line, Column, 4, nil, Scope), '..//'},
      yield(Remaining, Line, Column + 4 + Extra, Scope, [Token | Tokens]);
    {_, _} ->
      unexpected_token(String, Line, Column, Scope, Tokens)
  end;

% ## Ternary operator

% ## Three token operators
tokenize_single([T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when ?unary_op3(T1, T2, T3) ->
  handle_unary_op(Rest, Line, Column, unary_op, 3, list_to_atom([T1, T2, T3]), Scope, Tokens);

tokenize_single([T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when ?ellipsis_op3(T1, T2, T3) ->
  handle_unary_op(Rest, Line, Column, ellipsis_op, 3, list_to_atom([T1, T2, T3]), Scope, Tokens);

tokenize_single([T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when ?comp_op3(T1, T2, T3) ->
  handle_op(Rest, Line, Column, comp_op, 3, list_to_atom([T1, T2, T3]), Scope, Tokens);

tokenize_single([T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when ?and_op3(T1, T2, T3) ->
  NewScope = maybe_warn_too_many_of_same_char([T1, T2, T3], Rest, Line, Column, Scope),
  handle_op(Rest, Line, Column, and_op, 3, list_to_atom([T1, T2, T3]), NewScope, Tokens);

tokenize_single([T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when ?or_op3(T1, T2, T3) ->
  NewScope = maybe_warn_too_many_of_same_char([T1, T2, T3], Rest, Line, Column, Scope),
  handle_op(Rest, Line, Column, or_op, 3, list_to_atom([T1, T2, T3]), NewScope, Tokens);

tokenize_single([T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when ?xor_op3(T1, T2, T3) ->
  NewScope = maybe_warn_too_many_of_same_char([T1, T2, T3], Rest, Line, Column, Scope),
  handle_op(Rest, Line, Column, xor_op, 3, list_to_atom([T1, T2, T3]), NewScope, Tokens);

tokenize_single([T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when ?concat_op3(T1, T2, T3) ->
  NewScope = maybe_warn_too_many_of_same_char([T1, T2, T3], Rest, Line, Column, Scope),
  handle_op(Rest, Line, Column, concat_op, 3, list_to_atom([T1, T2, T3]), NewScope, Tokens);

tokenize_single([T1, T2, T3 | Rest], Line, Column, Scope, Tokens) when ?arrow_op3(T1, T2, T3) ->
  handle_op(Rest, Line, Column, arrow_op, 3, list_to_atom([T1, T2, T3]), Scope, Tokens);

% ## Containers + punctuation tokens
tokenize_single([$, | Rest], Line, Column, Scope, Tokens) ->
  Token = {',', make_meta_len(Line, Column, 1, 0, Scope)},
  yield(Rest, Line, Column + 1, Scope, [Token | Tokens]);

tokenize_single([$<, $< | Rest], Line, Column, Scope, Tokens) ->
  Token = {'<<', make_meta_len(Line, Column, 2, nil, Scope)},
  handle_terminator(Rest, Line, Column + 2, Scope, Token, Tokens);

tokenize_single([$>, $> | Rest], Line, Column, Scope, Tokens) ->
  Token = {'>>', make_meta_len(Line, Column, 2, previous_was_eol(Tokens), Scope)},
  handle_terminator(Rest, Line, Column + 2, Scope, Token, Tokens);

tokenize_single([${ | Rest], Line, Column, Scope, [{'%', _} | _] = Tokens) ->
  Message =
    "unexpected space between % and {\n\n"
    "If you want to define a map, write %{...}, with no spaces.\n"
    "If you want to define a struct, write %StructName{...}.\n\n"
    "Syntax error before: ",
  error({?LOC(Line, Column), Message, [${]}, Rest, Scope, Tokens);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when T =:= $(; T =:= ${; T =:= $[ ->
  Token = {list_to_atom([T]), make_meta_len(Line, Column, 1, nil, Scope)},
  handle_terminator(Rest, Line, Column + 1, Scope, Token, Tokens);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when T =:= $); T =:= $}; T =:= $] ->
  Token = {list_to_atom([T]), make_meta_len(Line, Column, 1, previous_was_eol(Tokens), Scope)},
  handle_terminator(Rest, Line, Column + 1, Scope, Token, Tokens);

% ## Two Token Operators
tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?ternary_op(T1, T2) ->
  Op = list_to_atom([T1, T2]),
  Token = {ternary_op, make_meta_len(Line, Column, 2, previous_was_eol(Tokens), Scope), Op},
  yield(Rest, Line, Column + 2, Scope, add_token_with_eol(Token, Tokens));

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?power_op(T1, T2) ->
  handle_op(Rest, Line, Column, power_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?range_op(T1, T2) ->
  handle_op(Rest, Line, Column, range_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?concat_op(T1, T2) ->
  handle_op(Rest, Line, Column, concat_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?arrow_op(T1, T2) ->
  handle_op(Rest, Line, Column, arrow_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?comp_op2(T1, T2) ->
  handle_op(Rest, Line, Column, comp_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?rel_op2(T1, T2) ->
  handle_op(Rest, Line, Column, rel_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?and_op(T1, T2) ->
  handle_op(Rest, Line, Column, and_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?or_op(T1, T2) ->
  handle_op(Rest, Line, Column, or_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?in_match_op(T1, T2) ->
  handle_op(Rest, Line, Column, in_match_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?type_op(T1, T2) ->
  handle_op(Rest, Line, Column, type_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

tokenize_single([T1, T2 | Rest], Line, Column, Scope, Tokens) when ?stab_op(T1, T2) ->
  handle_op(Rest, Line, Column, stab_op, 2, list_to_atom([T1, T2]), Scope, Tokens);

% ## Single Token Operators

tokenize_single([$& | Rest], Line, Column, Scope, Tokens) ->
  Kind =
    case strip_horizontal_space(Rest, 0) of
      {[Int | _], 0} when ?is_digit(Int) ->
        capture_int;

      {[$/ | NewRest], _} ->
        case strip_horizontal_space(NewRest, 0) of
          {[$/ | _], _} -> capture_op;
          {_, _} -> identifier
        end;

      {_, _} ->
        capture_op
    end,

  Token = {Kind, make_meta_len(Line, Column, 1, nil, Scope), '&'},
  yield(Rest, Line, Column + 1, Scope, [Token | Tokens]);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when ?at_op(T) ->
  handle_unary_op(Rest, Line, Column, at_op, 1, list_to_atom([T]), Scope, Tokens);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when ?unary_op(T) ->
  handle_unary_op(Rest, Line, Column, unary_op, 1, list_to_atom([T]), Scope, Tokens);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when ?rel_op(T) ->
  handle_op(Rest, Line, Column, rel_op, 1, list_to_atom([T]), Scope, Tokens);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when ?dual_op(T) ->
  handle_unary_op(Rest, Line, Column, dual_op, 1, list_to_atom([T]), Scope, Tokens);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when ?mult_op(T) ->
  handle_op(Rest, Line, Column, mult_op, 1, list_to_atom([T]), Scope, Tokens);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when ?match_op(T) ->
  handle_op(Rest, Line, Column, match_op, 1, list_to_atom([T]), Scope, Tokens);

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when ?pipe_op(T) ->
  handle_op(Rest, Line, Column, pipe_op, 1, list_to_atom([T]), Scope, Tokens);

% Non-operator Atoms

tokenize_single([$:, H | T], Line, Column, BaseScope, _Tokens) when ?is_quote(H) ->
  % Streaming mode for quoted atoms (mirrors strings)
  Scope = case H == $' of
    true -> prepend_warning(Line, Column, "single quotes around atoms are deprecated. Use double quotes instead", BaseScope);
    false -> BaseScope
  end,
  Kind = case Scope#toxic_tokenizer.existing_atoms_only of true -> atom_safe; false -> atom_unsafe end,
  StartType = case Kind of atom_safe -> atom_safe_start; atom_unsafe -> atom_unsafe_start end,
  % Span ":" and the opening quote
  StartTok = {StartType, make_meta(Line, Column, Line, Column + 2, nil, Scope), H},
  {switch_to_interp, StartTok, T, Line, Column + 2, Scope, Kind, H, []};

tokenize_single([$: | String] = Original, Line, Column, Scope, Tokens) ->
  case tokenize_identifier(String, Line, Column, Scope, false) of
    {_Kind, Unencoded, Atom, Rest, Length, Ascii, _Special} ->
      NewScope = maybe_warn_for_ambiguous_bang_before_equals(atom, Unencoded, Rest, Line, Column, Scope),
      TrackedScope = track_ascii(Ascii, NewScope),
      Token = {atom, make_meta_len(Line, Column, 1 + Length, Unencoded, TrackedScope), Atom},
      yield(Rest, Line, Column + 1 + Length, TrackedScope, [Token | Tokens]);
    empty when Scope#toxic_tokenizer.cursor_completion == false ->
      unexpected_token(Original, Line, Column, Scope, Tokens);
    empty ->
      yield([], Line, Column, Scope, Tokens);
    {unexpected_token, Length} ->
      unexpected_token(lists:nthtail(Length - 1, String), Line, Column + Length - 1, Scope, Tokens);
    {error, Reason} ->
      error(Reason, Original, Scope, Tokens)
  end;

% Integers and floats
% We use int and flt otherwise elixir_parser won't format them
% properly in case of errors.

tokenize_single([H | T], Line, Column, Scope, Tokens) when ?is_digit(H) ->
      case tokenize_number(T, [H], 1, false) of
    {error, Reason, Original} ->
      error({?LOC(Line, Column), Reason, Original}, T, Scope, Tokens);
    {[I | Rest], Number, Original, _Length} when ?is_upcase(I); ?is_downcase(I); I == $_ ->
      if
        Number == 0, (I =:= $x) orelse (I =:= $o) orelse (I =:= $b), Rest == [],
        Scope#toxic_tokenizer.cursor_completion /= false ->
          yield([], Line, Column, Scope, Tokens);

        true ->
          Msg =
            io_lib:format(
              "invalid character \"~ts\" after number ~ts. If you intended to write a number, "
              "make sure to separate the number from the character (using comma, space, etc). "
              "If you meant to write a function name or a variable, note that identifiers in "
              "Elixir cannot start with numbers. Unexpected token: ",
              [[I], Original]
            ),

          error({?LOC(Line, Column), Msg, [I]}, T, Scope, Tokens)
      end;
    {Rest, Number, Original, Length} when is_integer(Number) ->
      Token = {int, make_meta_len(Line, Column, Length, Number, Scope), Original},
      yield(Rest, Line, Column + Length, Scope, [Token | Tokens]);
    {Rest, Number, Original, Length} ->
      Token = {flt, make_meta_len(Line, Column, Length, Number, Scope), Original},
      yield(Rest, Line, Column + Length, Scope, [Token | Tokens])
  end;

% Spaces

tokenize_single([T | Rest], Line, Column, Scope, Tokens) when ?is_horizontal_space(T) ->
  {Remaining, Stripped} = strip_horizontal_space(Rest, 0),
  handle_space_sensitive_tokens(Remaining, Line, Column + 1 + Stripped, Scope, Tokens);

% End of line

tokenize_single(";" ++ Rest, Line, Column, Scope, []) ->
  yield(Rest, Line, Column + 1, Scope, [{';', make_meta_len(Line, Column, 1, 0, Scope)}]);

tokenize_single(";" ++ Rest, Line, Column, Scope, [Top | _] = Tokens) when element(1, Top) /= ';' ->
  yield(Rest, Line, Column + 1, Scope, [{';', make_meta_len(Line, Column, 1, 0, Scope)} | Tokens]);

tokenize_single("\\" = Original, Line, Column, Scope, Tokens) ->
  error({make_meta_len(Line, Column, 1, nil, Scope), "invalid escape \\ at end of file", []}, Original, Scope, Tokens);

tokenize_single("\\\n" = Original, Line, Column, Scope, Tokens) ->
  error({make_meta_len(Line, Column, 2, nil, Scope), "invalid escape \\ at end of file", []}, Original, Scope, Tokens);

tokenize_single("\\\r\n" = Original, Line, Column, Scope, Tokens) ->
  error({make_meta_len(Line, Column, 3, nil, Scope), "invalid escape \\ at end of file", []}, Original, Scope, Tokens);

tokenize_single("\\\n" ++ Rest, Line, _Column, Scope, Tokens) ->
  tokenize_eol(Rest, Line, Scope, Tokens);

tokenize_single("\\\r\n" ++ Rest, Line, _Column, Scope, Tokens) ->
  tokenize_eol(Rest, Line, Scope, Tokens);

tokenize_single("\n" ++ Rest, Line, Column, Scope, Tokens) ->
  tokenize_eol(Rest, Line, Scope, eol(Line, Column, Tokens, Scope));

tokenize_single("\r\n" ++ Rest, Line, Column, Scope, Tokens) ->
  tokenize_eol(Rest, Line, Scope, eol(Line, Column, Tokens, Scope));

% Others

tokenize_single([$%, $( | Rest], Line, Column, Scope, Tokens) ->
  Reason = {make_meta_len(Line, Column, 2, nil, Scope), "expected %{ to define a map, got: ", [$%, $(]},
  error(Reason, Rest, Scope, Tokens);

tokenize_single([$%, $[ | Rest], Line, Column, Scope, Tokens) ->
  Reason = {make_meta_len(Line, Column, 2, nil, Scope), "expected %{ to define a map, got: ", [$%, $[]},
  error(Reason, Rest, Scope, Tokens);

tokenize_single([$%, ${ | T], Line, Column, Scope, Tokens) ->
  Token = {'{', make_meta_len(Line, Column, 2, nil, Scope)},
  handle_terminator(T, Line, Column + 2, Scope, Token, [{'%{}', make_meta_len(Line, Column, 2, nil, Scope)} | Tokens]);

tokenize_single([$% | T], Line, Column, Scope, Tokens) ->
  yield(T, Line, Column + 1, Scope, [{'%', make_meta_len(Line, Column, 1, nil, Scope)} | Tokens]);

tokenize_single([$. | T], Line, Column, Scope, Tokens) ->
  tokenize_dot(T, Line, Column + 1, make_meta_len(Line, Column, 1, nil, Scope), Scope, Tokens);

% Identifiers

tokenize_single(String, Line, Column, OriginalScope, Tokens) ->
  case tokenize_identifier(String, Line, Column, OriginalScope, not previous_was_dot(Tokens)) of
    {Kind, Unencoded, Atom, Rest, Length, Ascii, Special} ->
      HasAt = lists:member(at, Special),
      Scope = track_ascii(Ascii, OriginalScope),

      case Rest of
        [$: | T] when ?is_space(hd(T)) ->
          Token = {kw_identifier, make_meta_len(Line, Column, Length + 1, Unencoded, Scope), Atom},
          yield(T, Line, Column + Length + 1, Scope, [Token | Tokens]);

        [$: | T] when hd(T) =/= $: ->
          AtomName = atom_to_list(Atom) ++ [$:],
          Reason = {make_meta_len(Line, Column, Length + 1, nil, Scope), "keyword argument must be followed by space after: ", AtomName},
          error(Reason, String, Scope, Tokens);

        _ when HasAt ->
          Reason = {make_meta_len(Line, Column, Length, nil, Scope), invalid_character_error(Kind, $@), atom_to_list(Atom)},
          error(Reason, String, Scope, Tokens);

        _ when Atom == '__aliases__'; Atom == '__block__' ->
          error({make_meta_len(Line, Column, Length, nil, Scope), "reserved token: ", atom_to_list(Atom)}, Rest, Scope, Tokens);

        _ when Kind == alias ->
          tokenize_alias(Rest, Line, Column, Unencoded, Atom, Length, Ascii, Special, Scope, Tokens);

        _ when Kind == identifier ->
          NewScope = maybe_warn_for_ambiguous_bang_before_equals(identifier, Unencoded, Rest, Line, Column, Scope),
          Token = check_call_identifier(Line, Column, Unencoded, Atom, Length, Rest, Scope),
          yield(Rest, Line, Column + Length, NewScope, [Token | Tokens]);

        _ ->
          unexpected_token(String, Line, Column, Scope, Tokens)
      end;

    {keyword, Atom, Type, Rest, Length} ->
      tokenize_keyword(Type, Rest, Line, Column, Atom, Length, OriginalScope, Tokens);

    empty when OriginalScope#toxic_tokenizer.cursor_completion == false ->
      unexpected_token(String, Line, Column, OriginalScope, Tokens);

    empty  ->
      case String of
        [$~, L] when ?is_upcase(L); ?is_downcase(L) -> yield([], Line, Column, OriginalScope, Tokens);
        [$~] -> yield([], Line, Column, OriginalScope, Tokens);
        _ -> unexpected_token(String, Line, Column, OriginalScope, Tokens)
      end;

    {unexpected_token, Length} ->
      unexpected_token(lists:nthtail(Length - 1, String), Line, Column + Length - 1, OriginalScope, Tokens);

    {error, Reason} ->
      error(Reason, String, OriginalScope, Tokens)
  end.

previous_was_dot([{'.', _} | _]) -> true;
previous_was_dot(_) -> false.

unexpected_token([T | Rest], Line, Column, Scope, Tokens) ->
  Message =
    case handle_char(T) of
      {_Escaped, Explanation} ->
        io_lib:format("~ts (column ~p, code point U+~4.16.0B)", [Explanation, Column, T]);
      false ->
        io_lib:format("\"~ts\" (column ~p, code point U+~4.16.0B)", [[T], Column, T])
    end,
  error({?LOC(Line, Column), "unexpected token: ", Message}, Rest, Scope, Tokens).

tokenize_eol(Rest, Line, Scope, Tokens) ->
  {StrippedRest, Column} = strip_horizontal_space(Rest, Scope#toxic_tokenizer.column),
  IndentedScope = Scope#toxic_tokenizer{indentation=Column-1},
  yield(StrippedRest, Line + 1, Column, IndentedScope, Tokens).

strip_horizontal_space([H | T], Counter) when ?is_horizontal_space(H) ->
  strip_horizontal_space(T, Counter + 1);
strip_horizontal_space(T, Counter) ->
  {T, Counter}.

% Consume one or more escaped newlines ("\\\n" or "\\\r\n") and following
% horizontal spaces, returning the rest, the number of spaces on the last
% logical line, and the count of escaped newlines seen.
strip_horizontal_space_after_escaped_newlines("\\\n" ++ Rest, _SpacesAcc, EscAcc) ->
  strip_horizontal_space_after_escaped_newlines(Rest, 0, EscAcc + 1);
strip_horizontal_space_after_escaped_newlines("\\\r\n" ++ Rest, _SpacesAcc, EscAcc) ->
  strip_horizontal_space_after_escaped_newlines(Rest, 0, EscAcc + 1);
strip_horizontal_space_after_escaped_newlines([H | T], SpacesAcc, EscAcc) when ?is_horizontal_space(H) ->
  strip_horizontal_space_after_escaped_newlines(T, SpacesAcc + 1, EscAcc);
strip_horizontal_space_after_escaped_newlines(Rest, SpacesAcc, EscAcc) ->
  {Rest, SpacesAcc, EscAcc}.

tokenize_dot(T, Line, Column, DotInfo, Scope, Tokens) ->
  case strip_horizontal_space(T, 0) of
    {[$# | R], _} ->
      case tokenize_comment(R, [$#]) of
        {error, Char} ->
          error_comment(Char, [$# | R], Line, Column, Scope, Tokens);

        {Rest, Comment} ->
          preserve_comments(Line, Column, Tokens, Comment, Rest, Scope),
          tokenize_dot(Rest, Line, Scope#toxic_tokenizer.column, DotInfo, Scope, Tokens)
      end;
    {"\\\r\n" ++ Rest, _} ->
      % Escaped carriage return + newline - continue on next line
      tokenize_dot(Rest, Line + 1, Scope#toxic_tokenizer.column, DotInfo, Scope, Tokens);
    {"\\\n" ++ Rest, _} ->
      % Escaped newline - continue on next line
      tokenize_dot(Rest, Line + 1, Scope#toxic_tokenizer.column, DotInfo, Scope, Tokens);
    {"\r\n" ++ Rest, _} ->
      tokenize_dot(Rest, Line + 1, Scope#toxic_tokenizer.column, DotInfo, Scope, Tokens);
    {"\n" ++ Rest, _} ->
      tokenize_dot(Rest, Line + 1, Scope#toxic_tokenizer.column, DotInfo, Scope, Tokens);
    {Rest, Length} ->
      handle_dot([$. | Rest], Line, Column + Length, DotInfo, Scope, Tokens)
  end.

handle_char(0)   -> {"\\0", "null byte"};
handle_char(7)   -> {"\\a", "alert"};
handle_char($\b) -> {"\\b", "backspace"};
handle_char($\d) -> {"\\d", "delete"};
handle_char($\e) -> {"\\e", "escape"};
handle_char($\f) -> {"\\f", "form feed"};
handle_char($\n) -> {"\\n", "newline"};
handle_char($\r) -> {"\\r", "carriage return"};
handle_char($\s) -> {"\\s", "space"};
handle_char($\t) -> {"\\t", "tab"};
handle_char($\v) -> {"\\v", "vertical tab"};
handle_char(_)  -> false.

%% Handlers

handle_heredocs(T, Line, Column, H, #toxic_tokenizer{} = Scope, _Tokens) ->
  % Linearized streaming mode for heredocs
  % First check if the heredoc header is valid (only whitespace + newline after opening)
  case extract_heredoc_header(T) of
    {ok, Headerless} ->
      {StartType, Kind} = case H of
        $' -> {list_heredoc_start, list_heredoc};
        $" -> {bin_heredoc_start, bin_heredoc}
      end,
      StartTok = {StartType, make_meta(Line, Column, Line, Column + 3, nil, Scope), [H, H, H]},
      % For streaming mode, don't prepend newline - handle it in interpolation extraction
      {switch_to_interp, StartTok, Headerless, Line + 1, 1, Scope, Kind, [H, H, H], []};
    error ->
      Message = "heredoc allows only whitespace characters followed by a new line after opening ",
      error({?LOC(Line, Column + 3), io_lib:format(Message, []), [H, H, H]}, [H, H, H] ++ T, Scope, _Tokens)
  end.

handle_strings(T, Line, Column, H, #toxic_tokenizer{} = Scope, _Tokens) ->
  % Linearized streaming mode
  {StartType, Kind} = case H of
    $' -> {list_string_start, charlist};
    $" -> {bin_string_start, string}
  end,
  StartTok = {StartType, make_meta(Line, Column - 1, Line, Column, nil, Scope), H},
  {switch_to_interp, StartTok, T, Line, Column, Scope, Kind, H, []}.

handle_unary_op([$: | Rest], Line, Column, _Kind, Length, Op, Scope, Tokens) when ?is_space(hd(Rest)) ->
  Token = {kw_identifier, make_meta_len(Line, Column, Length + 1, nil, Scope), Op},
  yield(Rest, Line, Column + Length + 1, Scope, [Token | Tokens]);

handle_unary_op(Rest, Line, Column, Kind, Length, Op, Scope, Tokens) ->
  case strip_horizontal_space(Rest, 0) of
    {[$/ | _] = Remaining, Extra} ->
      Token = {identifier, make_meta_len(Line, Column, Length, nil, Scope), Op},
      yield(Remaining, Line, Column + Length + Extra, Scope, [Token | Tokens]);
    {Remaining, Extra} ->
      %% For unary operators, Elixir does not carry EOL counts in meta
      Token = {Kind, make_meta_len(Line, Column, Length, nil, Scope), Op},
      yield(Remaining, Line, Column + Length + Extra, Scope, [Token | Tokens])
  end.

handle_op([$: | Rest], Line, Column, _Kind, Length, Op, Scope, Tokens) when ?is_space(hd(Rest)) ->
  Token = {kw_identifier, make_meta_len(Line, Column, Length + 1, nil, Scope), Op},
  yield(Rest, Line, Column + Length + 1, Scope, [Token | Tokens]);

handle_op(Rest, Line, Column, Kind, Length, Op, Scope, Tokens) ->
  case strip_horizontal_space(Rest, 0) of
    {[$/ | _] = Remaining, Extra} ->
      Token = {identifier, make_meta_len(Line, Column, Length, nil, Scope), Op},
      yield(Remaining, Line, Column + Length + Extra, Scope, [Token | Tokens]);
    {Remaining, Extra} ->
      NewScope =
        %% TODO: Remove these deprecations on Elixir v2.0
        case Op of
          '^^^' ->
            Msg = "^^^ is deprecated. It is typically used as xor but it has the wrong precedence, use Bitwise.bxor/2 instead",
            prepend_warning(Line, Column, Msg, Scope);

          '~~~' ->
            Msg = "~~~ is deprecated. Use Bitwise.bnot/1 instead for clarity",
            prepend_warning(Line, Column, Msg, Scope);

          '<|>' ->
            Msg = "<|> is deprecated. Use another pipe-like operator",
            prepend_warning(Line, Column, Msg, Scope);

          _ ->
            Scope
        end,

      Token = {Kind, make_meta_len(Line, Column, Length, previous_was_eol(Tokens), Scope), Op},
      yield(Remaining, Line, Column + Length + Extra, NewScope, add_token_with_eol(Token, Tokens))
  end.

% ## Three Token Operators
handle_dot([$., T1, T2, T3 | Rest], Line, Column, DotInfo, Scope, Tokens) when
    ?unary_op3(T1, T2, T3); ?comp_op3(T1, T2, T3); ?and_op3(T1, T2, T3); ?or_op3(T1, T2, T3);
    ?arrow_op3(T1, T2, T3); ?xor_op3(T1, T2, T3); ?concat_op3(T1, T2, T3) ->
  handle_call_identifier(Rest, Line, Column, DotInfo, 3, [T1, T2, T3], Scope, Tokens);

% ## Two Token Operators
handle_dot([$., T1, T2 | Rest], Line, Column, DotInfo, Scope, Tokens) when
    ?comp_op2(T1, T2); ?rel_op2(T1, T2); ?and_op(T1, T2); ?or_op(T1, T2);
    ?arrow_op(T1, T2); ?in_match_op(T1, T2); ?concat_op(T1, T2); ?power_op(T1, T2);
    ?type_op(T1, T2) ->
  handle_call_identifier(Rest, Line, Column, DotInfo, 2, [T1, T2], Scope, Tokens);

% ## Single Token Operators
handle_dot([$., T | Rest], Line, Column, DotInfo, Scope, Tokens) when
    ?at_op(T); ?unary_op(T); ?capture_op(T); ?dual_op(T); ?mult_op(T);
    ?rel_op(T); ?match_op(T); ?pipe_op(T) ->
  handle_call_identifier(Rest, Line, Column, DotInfo, 1, [T], Scope, Tokens);

% ## Exception for .( as it needs to be treated specially in the parser
handle_dot([$., $( | Rest], Line, Column, DotInfo, Scope, Tokens) ->
  TokensSoFar = add_token_with_eol({dot_call_op, DotInfo, '.'}, Tokens),
  yield([$( | Rest], Line, Column, Scope, TokensSoFar);

handle_dot([$., H | T] = _Original, Line, Column, DotInfo, BaseScope, Tokens) when ?is_quote(H) ->
  Scope = case H == $' of
    true ->
      prepend_warning(Line, Column, "single quotes around calls are deprecated. Use double quotes instead", BaseScope);
    false ->
      BaseScope
  end,
  % Use streaming mode: store dot token and emit quoted identifier via switch_to_interp
  TokensSoFar = add_token_with_eol({'.', DotInfo}, Tokens),
  StartTok = {quoted_identifier_start, make_meta(Line, Column, Line, Column + 1, nil, Scope), H},
  % Pass TokensSoFar as the interpolation parameter so the driver can emit stored tokens first
  {switch_to_interp, StartTok, T, Line, Column + 1, Scope, quoted_identifier, H, TokensSoFar};

handle_dot([$. | Rest], Line, Column, DotInfo, Scope, Tokens) ->
  TokensSoFar = add_token_with_eol({'.', DotInfo}, Tokens),
  yield(Rest, Line, Column, Scope, TokensSoFar).

handle_call_identifier(Rest, Line, Column, DotInfo, Length, UnencodedOp, Scope, Tokens) ->
  Token = check_call_identifier(Line, Column, UnencodedOp, list_to_atom(UnencodedOp), Length, Rest, Scope),
  TokensSoFar = add_token_with_eol({'.', DotInfo}, Tokens),
  % TODO: use other command, switch_to_interp is not the best name for this
  % Use switch_to_interp to emit both tokens sequentially: dot first, then identifier
  {switch_to_interp, Token, Rest, Line, Column + Length, Scope, call_identifier, dot, TokensSoFar}.

% ## Ambiguous unary/binary operators tokens
% Keywords are not ambiguous operators
handle_space_sensitive_tokens([Sign, $:, Space | _] = String, Line, Column, Scope, Tokens) when ?dual_op(Sign), ?is_space(Space) ->
  % Continue tokenizing normally so "+:" becomes kw_identifier via operator path
  tokenize_single(String, Line, Column, Scope, Tokens);

% But everything else, except other operators, are
handle_space_sensitive_tokens([Sign, NotMarker | T], Line, Column, Scope, [{identifier, _, _} = H | Tokens]) when
    ?dual_op(Sign), not(?is_space(NotMarker)), NotMarker =/= Sign, NotMarker =/= $/, NotMarker =/= $> ->
  Rest = [NotMarker | T],
  DualOpToken = {dual_op, make_meta_len(Line, Column, 1, nil, Scope), list_to_atom([Sign])},
  yield(Rest, Line, Column + 1, Scope, [DualOpToken, setelement(1, H, op_identifier) | Tokens]);

% Handle cursor completion
handle_space_sensitive_tokens([], Line, Column,
                              #toxic_tokenizer{cursor_completion=Cursor} = Scope,
                              [{identifier, Info, Identifier} | Tokens]) when Cursor /= false ->
  yield([$(], Line, Column+1, Scope, [{paren_identifier, Info, Identifier} | Tokens]);

handle_space_sensitive_tokens(String, Line, Column, Scope, Tokens) ->
  % Continue tokenizing after handling whitespace
  tokenize_single(String, Line, Column, Scope, Tokens).

%% Helpers

eol(_Line, _Column, [{Kind, {Line, Column, Count}} | Tokens], _Scope) 
  when Kind =:= ','; Kind =:= ';'; Kind =:= eol, is_integer(Line) ->
  [{Kind, {Line, Column, Count + 1}} | Tokens];
eol(_Line, _Column, [{Kind, {{Line, Column}, {_EndLine, _EndColumn}, Count}} | Tokens], _Scope)
  when Kind =:= ','; Kind =:= ';'; Kind =:= eol ->
  [{Kind, {{Line, Column}, {Line + Count + 1, 1}, Count + 1}} | Tokens];
eol(Line, Column, Tokens, Scope) ->
  [{eol, make_meta(Line, Column, Line + 1, 1, 1, Scope)} | Tokens].

unsafe_to_atom(Part, Line, Column, #toxic_tokenizer{}) when
    is_binary(Part) andalso byte_size(Part) > 255;
    is_list(Part) andalso length(Part) > 255 ->
  try
    PartList = toxic_utils:characters_to_list(Part),
    {error, {?LOC(Line, Column), "atom length must be less than system limit: ", PartList}}
  catch
    error:#{'__struct__' := 'Elixir.UnicodeConversionError', message := Message} ->
      {error, {?LOC(Line, Column), "invalid encoding in atom: ", toxic_utils:characters_to_list(Message)}}
  end;
unsafe_to_atom(Part, Line, Column, #toxic_tokenizer{static_atoms_encoder=StaticAtomsEncoder}) when
    is_function(StaticAtomsEncoder) ->
  EncodeResult = try
    ValueEncBin = toxic_utils:characters_to_binary(Part),
    ValueEncList = toxic_utils:characters_to_list(Part),
    {ok, ValueEncBin, ValueEncList}
  catch
    error:#{'__struct__' := 'Elixir.UnicodeConversionError', message := Message} ->
      {error, {?LOC(Line, Column), "invalid encoding in atom: ", toxic_utils:characters_to_list(Message)}}
  end,

  case EncodeResult of
    {ok, Value, ValueList} ->
      case StaticAtomsEncoder(Value, [{line, Line}, {column, Column}]) of
        {ok, Term} ->
          {ok, Term};
        {error, Reason} when is_binary(Reason) ->
          {error, {?LOC(Line, Column), toxic_utils:characters_to_list(Reason) ++ ": ", ValueList}}
      end;
    EncError -> EncError
  end;
unsafe_to_atom(Binary, Line, Column, #toxic_tokenizer{existing_atoms_only=true}) when is_binary(Binary) ->
  try
    {ok, binary_to_existing_atom(Binary, utf8)}
  catch
    error:badarg ->
      % Check if it's a UTF-8 issue by trying to convert to list
      try
        List = toxic_utils:characters_to_list(Binary),
        % If we get here, it's not a UTF-8 issue
        {error, {?LOC(Line, Column), "unsafe atom does not exist: ", List}}
      catch
        error:#{'__struct__' := 'Elixir.UnicodeConversionError', message := Message} ->
          {error, {?LOC(Line, Column), "invalid encoding in atom: ", toxic_utils:characters_to_list(Message)}}
      end
  end;
unsafe_to_atom(Binary, Line, Column, #toxic_tokenizer{}) when is_binary(Binary) ->
  try
    {ok, binary_to_atom(Binary, utf8)}
  catch
    error:badarg ->
      % Try to convert using toxic_utils to get proper UnicodeConversionError
      try
        List = toxic_utils:characters_to_list(Binary),
        % If we get here, it's not a UTF-8 issue, so it's some other badarg
        {error, {?LOC(Line, Column), "invalid atom: ", List}}
      catch
        error:#{'__struct__' := 'Elixir.UnicodeConversionError', message := Message} ->
          {error, {?LOC(Line, Column), "invalid encoding in atom: ", toxic_utils:characters_to_list(Message)}}
      end
  end;
unsafe_to_atom(List, Line, Column, #toxic_tokenizer{existing_atoms_only=true}) when is_list(List) ->
  try
    {ok, list_to_existing_atom(List)}
  catch
    error:badarg ->
      % Try to convert using toxic_utils to get proper UnicodeConversionError
      try
        toxic_utils:characters_to_binary(List),
        % If we get here, it's not a UTF-8 issue
        {error, {?LOC(Line, Column), "unsafe atom does not exist: ", List}}
      catch
        error:#{'__struct__' := 'Elixir.UnicodeConversionError', message := Message} ->
          {error, {?LOC(Line, Column), "invalid encoding in atom: ", toxic_utils:characters_to_list(Message)}}
      end
  end;
unsafe_to_atom(List, Line, Column, #toxic_tokenizer{}) when is_list(List) ->
  try
    {ok, list_to_atom(List)}
  catch
    error:badarg ->
      % Try to convert using toxic_utils to get proper UnicodeConversionError
      try
        toxic_utils:characters_to_binary(List),
        % If we get here, it's not a UTF-8 issue, so it's some other badarg
        {error, {?LOC(Line, Column), "invalid atom: ", List}}
      catch
        error:#{'__struct__' := 'Elixir.UnicodeConversionError', message := Message} ->
          {error, {?LOC(Line, Column), "invalid encoding in atom: ", toxic_utils:characters_to_list(Message)}}
      end
  end.

%% Heredocs

extract_heredoc_header("\r\n" ++ Rest) ->
  {ok, Rest};
extract_heredoc_header("\n" ++ Rest) ->
  {ok, Rest};
extract_heredoc_header([H | T]) when ?is_horizontal_space(H) ->
  extract_heredoc_header(T);
extract_heredoc_header(_) ->
  error.

unescape_tokens(Tokens, Line, Column, #toxic_tokenizer{unescape=true}) ->
  case toxic_interpolation:unescape_tokens(Tokens) of
    {ok, Result} ->
      {ok, Result};

    {error, Message, Token} ->
      {error, {?LOC(Line, Column), Message ++ ". Syntax error after: ", Token}}
  end;
unescape_tokens(Tokens, Line, Column, #toxic_tokenizer{unescape=false}) ->
  try
    {ok, tokens_to_binary(Tokens)}
  catch
    error:#{'__struct__' := 'Elixir.UnicodeConversionError', message := Message} ->
      {error, {?LOC(Line, Column), "invalid encoding in tokens: ", toxic_utils:characters_to_list(Message)}}
  end.

tokens_to_binary(Tokens) ->
  [if is_list(Token) -> toxic_utils:characters_to_binary(Token); true -> Token end
   || Token <- Tokens].

%% Integers and floats
%% At this point, we are at least sure the first digit is a number.

%% Check if we have a point followed by a number;
tokenize_number([$., H | T], Acc, Length, false) when ?is_digit(H) ->
  tokenize_number(T, [H, $. | Acc], Length + 2, true);

%% Check if we have an underscore followed by a number;
tokenize_number([$_, H | T], Acc, Length, Bool) when ?is_digit(H) ->
  tokenize_number(T, [H, $_ | Acc], Length + 2, Bool);

%% Check if we have e- followed by numbers (valid only for floats);
tokenize_number([E, S, H | T], Acc, Length, true)
    when (E =:= $E) or (E =:= $e), ?is_digit(H), S =:= $+ orelse S =:= $- ->
  tokenize_number(T, [H, S, E | Acc], Length + 3, true);

%% Check if we have e followed by numbers (valid only for floats);
tokenize_number([E, H | T], Acc, Length, true)
    when (E =:= $E) or (E =:= $e), ?is_digit(H) ->
  tokenize_number(T, [H, E | Acc], Length + 2, true);

%% Finally just numbers.
tokenize_number([H | T], Acc, Length, Bool) when ?is_digit(H) ->
  tokenize_number(T, [H | Acc], Length + 1, Bool);

%% Cast to float...
tokenize_number(Rest, Acc, Length, true) ->
  try
    {Number, Original} = reverse_number(Acc, [], []),
    {Rest, list_to_float(Number), Original, Length}
  catch
    error:badarg -> {error, "invalid float number ", lists:reverse(Acc)}
  end;

%% Or integer.
tokenize_number(Rest, Acc, Length, false) ->
  {Number, Original} = reverse_number(Acc, [], []),
  {Rest, list_to_integer(Number), Original, Length}.

tokenize_hex([H | T], Acc, Length) when ?is_hex(H) ->
  tokenize_hex(T, [H | Acc], Length + 1);
tokenize_hex([$_, H | T], Acc, Length) when ?is_hex(H) ->
  tokenize_hex(T, [H, $_ | Acc], Length + 2);
tokenize_hex(Rest, Acc, Length) ->
  {Number, Original} = reverse_number(Acc, [], []),
  {Rest, list_to_integer(Number, 16), [$0, $x | Original], Length}.

tokenize_octal([H | T], Acc, Length) when ?is_octal(H) ->
  tokenize_octal(T, [H | Acc], Length + 1);
tokenize_octal([$_, H | T], Acc, Length) when ?is_octal(H) ->
  tokenize_octal(T, [H, $_ | Acc], Length + 2);
tokenize_octal(Rest, Acc, Length) ->
  {Number, Original} = reverse_number(Acc, [], []),
  {Rest, list_to_integer(Number, 8), [$0, $o | Original], Length}.

tokenize_bin([H | T], Acc, Length) when ?is_bin(H) ->
  tokenize_bin(T, [H | Acc], Length + 1);
tokenize_bin([$_, H | T], Acc, Length) when ?is_bin(H) ->
  tokenize_bin(T, [H, $_ | Acc], Length + 2);
tokenize_bin(Rest, Acc, Length) ->
  {Number, Original} = reverse_number(Acc, [], []),
  {Rest, list_to_integer(Number, 2), [$0, $b | Original], Length}.

reverse_number([$_ | T], Number, Original) ->
  reverse_number(T, Number, [$_ | Original]);
reverse_number([H | T], Number, Original) ->
  reverse_number(T, [H | Number], [H | Original]);
reverse_number([], Number, Original) ->
  {Number, Original}.

%% Comments

reset_eol([{eol, {Line, Column, _}} | Rest]) when is_integer(Line) -> [{eol, {Line, Column, 0}} | Rest];
reset_eol([{eol, {{Line, Column}, {EndLine, EndColumn}, _}} | Rest]) -> [{eol, {{Line, Column}, {EndLine, EndColumn}, 0}} | Rest];
reset_eol(Rest) -> Rest.

tokenize_comment("\r\n" ++ _ = Rest, Acc) ->
  {Rest, lists:reverse(Acc)};
tokenize_comment("\n" ++ _ = Rest, Acc) ->
  {Rest, lists:reverse(Acc)};
tokenize_comment([H | _Rest], _) when ?bidi(H) ->
  {error, H};
tokenize_comment([H | Rest], Acc) ->
  tokenize_comment(Rest, [H | Acc]);
tokenize_comment([], Acc) ->
  {[], lists:reverse(Acc)}.

error_comment(H, Comment, Line, Column, Scope, Tokens) ->
  Token = io_lib:format("\\u~4.16.0B", [H]),
  Reason = {make_meta_len(Line, Column, 1, nil, Scope), "invalid bidirectional formatting character in comment: ", Token},
  error(Reason, Comment, Scope, Tokens).

preserve_comments(Line, Column, Tokens, Comment, Rest, Scope) ->
  case Scope#toxic_tokenizer.preserve_comments of
    Fun when is_function(Fun) ->
      Fun(Line, Column, Tokens, Comment, Rest);
    nil ->
      ok
  end.

%% Identifiers - restored for identifier_tokenizer API compatibility

tokenize([H | T]) when ?is_upcase(H) ->
  {Acc, Rest, Length, Special} = tokenize_continue(T, [H], 1, []),
  {alias, lists:reverse(Acc), Rest, Length, true, Special};
tokenize([H | T]) when ?is_downcase(H); H =:= $_ ->
  {Acc, Rest, Length, Special} = tokenize_continue(T, [H], 1, []),
  {identifier, lists:reverse(Acc), Rest, Length, true, Special};
tokenize(_List) ->
  {error, empty}.

tokenize_continue([$@ | T], Acc, Length, Special) ->
  tokenize_continue(T, [$@ | Acc], Length + 1, [at | lists:delete(at, Special)]);
tokenize_continue([$! | T], Acc, Length, Special) ->
  {[$! | Acc], T, Length + 1, [punctuation | Special]};
tokenize_continue([$? | T], Acc, Length, Special) ->
  {[$? | Acc], T, Length + 1, [punctuation | Special]};
tokenize_continue([H | T], Acc, Length, Special) when ?is_upcase(H); ?is_downcase(H); ?is_digit(H); H =:= $_ ->
  tokenize_continue(T, [H | Acc], Length + 1, Special);
tokenize_continue(Rest, Acc, Length, Special) ->
  {Acc, Rest, Length, Special}.

tokenize_identifier(String, Line, Column, Scope, MaybeKeyword) ->
  case (Scope#toxic_tokenizer.identifier_tokenizer):tokenize(String) of
    {Kind, Acc, Rest, Length, Ascii, Special} ->
      Keyword = MaybeKeyword andalso maybe_keyword(Rest),

      case keyword_or_unsafe_to_atom(Keyword, Acc, Line, Column, Scope) of
        {keyword, Atom, Type} ->
          {keyword, Atom, Type, Rest, Length};
        {ok, Atom} ->
          {Kind, Acc, Atom, Rest, Length, Ascii, Special};
        {error, _Reason} = Error ->
          Error
      end;

    {error, {mixed_script, Wrong, {Prefix, Suffix}}} ->
      WrongColumn = Column + length(Wrong) - 1,
      case suggest_simpler_unexpected_token_in_error(Wrong, Line, WrongColumn, Scope) of
        no_suggestion ->
          %% we append a pointer to more info if we aren't appending a suggestion
          MoreInfo = "\nSee https://hexdocs.pm/elixir/unicode-syntax.html for more information.",
          {error, {?LOC(Line, Column), {Prefix, Suffix ++ MoreInfo}, Wrong}};

        {_, {Location, _, SuggestionMessage}} = _SuggestionError ->
          {error, {Location, {Prefix, Suffix ++ SuggestionMessage}, Wrong}}
      end;

    {error, {unexpected_token, Wrong}} ->
      WrongColumn = Column + length(Wrong) - 1,
      case suggest_simpler_unexpected_token_in_error(Wrong, Line, WrongColumn, Scope) of
        no_suggestion ->
          [T | _] = lists:reverse(Wrong),
          case suggest_simpler_unexpected_token_in_error([T], Line, WrongColumn, Scope) of
            no_suggestion -> {unexpected_token, length(Wrong)};
            SuggestionError -> SuggestionError
          end;

        SuggestionError ->
          SuggestionError
      end;

    {error, empty} ->
      empty
  end.

%% heuristic: try nfkc; try confusability skeleton; try calling this again w/just failed codepoint
suggest_simpler_unexpected_token_in_error(Wrong, Line, WrongColumn, Scope) ->
  NFKC = unicode:characters_to_nfkc_list(Wrong),
  case (Scope#toxic_tokenizer.identifier_tokenizer):tokenize(NFKC) of
    {error, _Reason} ->
       ConfusableSkeleton = 'Elixir.String.Tokenizer.Security':confusable_skeleton(Wrong),
       case (Scope#toxic_tokenizer.identifier_tokenizer):tokenize(ConfusableSkeleton) of
         {_, Simpler, _, _, _, _} ->
           Message = suggest_change("Codepoint failed identifier tokenization, but a simpler form was found.",
                                    Wrong,
                                    "You could write the above in a similar way that is accepted by Elixir:",
                                    Simpler,
                                    "See https://hexdocs.pm/elixir/unicode-syntax.html for more information."),
           {error, {?LOC(Line, WrongColumn), "unexpected token: ", Message}};
         _other ->
           no_suggestion
       end;
    {_, _NFKC, _, _, _, _} ->
      Message = suggest_change("Elixir expects unquoted Unicode atoms, variables, and calls to use allowed codepoints and to be in NFC form.",
                               Wrong,
                               "You could write the above in a compatible format that is accepted by Elixir:",
                               NFKC,
                               "See https://hexdocs.pm/elixir/unicode-syntax.html for more information."),
          {error, {?LOC(Line, WrongColumn), "unexpected token: ", Message}}
    end.

suggest_change(Intro, WrongForm, Hint, HintedForm, Ending) ->
  WrongCodepoints = list_to_codepoint_hex(WrongForm),
  HintedCodepoints = list_to_codepoint_hex(HintedForm),
  io_lib:format("~ts\n\nGot:\n\n    \"~ts\" (code points~ts)\n\n"
                "Hint: ~ts\n\n    \"~ts\" (code points~ts)\n\n~ts",
                [Intro, WrongForm, WrongCodepoints, Hint, HintedForm, HintedCodepoints, Ending]).

maybe_keyword([]) -> true;
maybe_keyword([$:, $: | _]) -> true;
maybe_keyword([$: | _]) -> false;
maybe_keyword(_) -> true.

list_to_codepoint_hex(List) ->
  [io_lib:format(" 0x~5.16.0B", [Codepoint]) || Codepoint <- List].

tokenize_alias(Rest, Line, Column, Unencoded, Atom, Length, Ascii, Special, Scope, Tokens) ->
  if
    not Ascii or (Special /= []) ->
      Invalid = hd([C || C <- Unencoded, (C < $A) or (C > 127)]),
      Reason = {make_meta_len(Line, Column, Length, nil, Scope), invalid_character_error("alias (only ASCII characters, without punctuation, are allowed)", Invalid), Unencoded},
      error(Reason, Unencoded ++ Rest, Scope, Tokens);

    true ->
      AliasesToken = {alias, make_meta_len(Line, Column, Length, Unencoded, Scope), Atom},
      yield(Rest, Line, Column + Length, Scope, [AliasesToken | Tokens])
  end.

%% Check if it is a call identifier (paren | bracket | do)

check_call_identifier(Line, Column, Info, Atom, Length, [$( | _], Scope) ->
  {paren_identifier, make_meta_len(Line, Column, Length, Info, Scope), Atom};
check_call_identifier(Line, Column, Info, Atom, Length, [$[ | _], Scope) ->
  {bracket_identifier, make_meta_len(Line, Column, Length, Info, Scope), Atom};
check_call_identifier(Line, Column, Info, Atom, Length, _Rest, Scope) ->
  {identifier, make_meta_len(Line, Column, Length, Info, Scope), Atom}.

add_token_with_eol({unary_op, _, _} = Left, T) -> [Left | T];
add_token_with_eol(Left, [{eol, _} | T]) -> [Left | T];
add_token_with_eol(Left, T) -> [Left | T].

previous_was_eol([Token | _]) ->
  case Token of
    {';', {{_, _}, {_, _}, Count}} when Count > 0 -> Count;
    {',', {{_, _}, {_, _}, Count}} when Count > 0 -> Count;
    {eol, {{_, _}, {_, _}, Count}} when Count > 0 -> Count;
    {eol, {_, _, Count}} when Count > 0 -> Count;
    _ -> nil
  end;
previous_was_eol([]) -> nil.

%% Terminators

handle_terminator(Rest, _, _, Scope, {'(', {Line, Column, _}}, [{alias, _, Alias} | Tokens]) when is_atom(Alias) ->
  Reason =
    io_lib:format(
      "unexpected ( after alias ~ts. Function names and identifiers in Elixir "
      "start with lowercase characters or underscore. For example:\n\n"
      "    hello_world()\n"
      "    _starting_with_underscore()\n"
      "    numb3rs_are_allowed()\n"
      "    may_finish_with_question_mark?()\n"
      "    may_finish_with_exclamation_mark!()\n\n"
      "Unexpected token: ",
      [Alias]
    ),

  error({?LOC(Line, Column), Reason, ["("]}, atom_to_list(Alias) ++ [$( | Rest], Scope, Tokens);
handle_terminator(Rest, Line, Column, #toxic_tokenizer{terminators=none} = Scope, Token, Tokens) ->
  yield(Rest, Line, Column, Scope, [Token | Tokens]);
handle_terminator(Rest, Line, Column, Scope, Token, Tokens) ->
  #toxic_tokenizer{terminators=Terminators} = Scope,

  case check_terminator(Token, Terminators, Scope) of
    {error, Reason} ->
      error(Reason, atom_to_list(element(1, Token)) ++ Rest, Scope, Tokens);
    {ok, New} ->
      yield(Rest, Line, Column, New, [Token | Tokens])
  end.

check_terminator({Start, Meta}, Terminators, Scope)
    when Start == '('; Start == '['; Start == '{'; Start == '<<' ->
  Indentation = Scope#toxic_tokenizer.indentation,
  {ok, Scope#toxic_tokenizer{terminators=[{Start, Meta, Indentation} | Terminators]}};

check_terminator({Start, Meta}, Terminators, Scope) when Start == 'fn'; Start == 'do' ->
  Indentation = Scope#toxic_tokenizer.indentation,

  NewScope =
    case Terminators of
      %% If the do is indented equally or less than the previous do, it may be a missing end error!
      [{Start, _, PreviousIndentation} = Previous | _] when Indentation =< PreviousIndentation ->
        Scope#toxic_tokenizer{mismatch_hints=[Previous | Scope#toxic_tokenizer.mismatch_hints]};

      _ ->
        Scope
    end,

  {ok, NewScope#toxic_tokenizer{terminators=[{Start, Meta, Indentation} | Terminators]}};

% Range-aware: 'end' with ranges meta
check_terminator({'end', {{EndLine, _EndColumn}, _EndPos, _}}, [{'do', _, Indentation} | Terminators], Scope) ->
  NewScope =
    %% If the end is more indented than the do, it may be a missing do error!
    case Scope#toxic_tokenizer.indentation > Indentation of
      true ->
        Hint = {'end', EndLine, Scope#toxic_tokenizer.indentation},
        Scope#toxic_tokenizer{mismatch_hints=[Hint | Scope#toxic_tokenizer.mismatch_hints]};
      false ->
        Scope
    end,
  {ok, NewScope#toxic_tokenizer{terminators=Terminators}};

check_terminator({'end', {EndLine, _, _}}, [{'do', _, Indentation} | Terminators], Scope) ->
  NewScope =
    %% If the end is more indented than the do, it may be a missing do error!
    case Scope#toxic_tokenizer.indentation > Indentation of
      true ->
        Hint = {'end', EndLine, Scope#toxic_tokenizer.indentation},
        Scope#toxic_tokenizer{mismatch_hints=[Hint | Scope#toxic_tokenizer.mismatch_hints]};

      false ->
        Scope
    end,

  {ok, NewScope#toxic_tokenizer{terminators=Terminators}};

% Range-aware: mismatched closer with ranges meta for both opener and closer
check_terminator({End, {{EndLine, EndColumn}, _EndPos, _}}, [{Start, {{StartLine, StartColumn}, _StartPos, _}, _} | Terminators], Scope)
    when End == 'end'; End == ')'; End == ']'; End == '}'; End == '>>' ->
  case terminator(Start) of
    End ->
      {ok, Scope#toxic_tokenizer{terminators=Terminators}};

    ExpectedEnd ->
      Meta = [
        {line, StartLine},
        {column, StartColumn},
        {end_line, EndLine},
        {end_column, EndColumn},
        {error_type, mismatched_delimiter},
        {opening_delimiter, Start},
        {closing_delimiter, End},
        {expected_delimiter, ExpectedEnd}
     ],
     {error, {Meta, unexpected_token_or_reserved(End), [atom_to_list(End)]}}
  end;

check_terminator({End, {EndLine, EndColumn, _}}, [{Start, {StartLine, StartColumn, _}, _} | Terminators], Scope)
    when End == 'end'; End == ')'; End == ']'; End == '}'; End == '>>' ->
  case terminator(Start) of
    End ->
      {ok, Scope#toxic_tokenizer{terminators=Terminators}};

    ExpectedEnd ->
      Meta = [
        {line, StartLine},
        {column, StartColumn},
        {end_line, EndLine},
        {end_column, EndColumn},
        {error_type, mismatched_delimiter},
        {opening_delimiter, Start},
        {closing_delimiter, End},
        {expected_delimiter, ExpectedEnd}
     ],
     {error, {Meta, unexpected_token_or_reserved(End), [atom_to_list(End)]}}
  end;

% Range-aware: stray 'end'
check_terminator({'end', {{Line, Column}, _EndPos, _}}, [], #toxic_tokenizer{mismatch_hints=Hints}) ->
  Suffix =
    case lists:keyfind('end', 1, Hints) of
      {'end', HintLine, _Indentation} ->
        io_lib:format("\n~ts the \"end\" on line ~B may not have a matching \"do\" "
                      "defined before it (based on indentation)", [toxic_errors:prefix(hint), HintLine]);
      false ->
        ""
    end,

  {error, {?LOC(Line, Column), {"unexpected reserved word: ", Suffix}, "end"}};

check_terminator({'end', {Line, Column, _}}, [], #toxic_tokenizer{mismatch_hints=Hints}) ->
  Suffix =
    case lists:keyfind('end', 1, Hints) of
      {'end', HintLine, _Indentation} ->
        io_lib:format("\n~ts the \"end\" on line ~B may not have a matching \"do\" "
                      "defined before it (based on indentation)", [toxic_errors:prefix(hint), HintLine]);
      false ->
        ""
    end,

  {error, {?LOC(Line, Column), {"unexpected reserved word: ", Suffix}, "end"}};

% Range-aware: stray closer
check_terminator({End, {{Line, Column}, _EndPos, _}}, [], _Scope)
    when End == ')'; End == ']'; End == '}'; End == '>>' ->
  {error, {?LOC(Line, Column), "unexpected token: ", atom_to_list(End)}};

check_terminator(_, _, Scope) ->
  {ok, Scope}.

unexpected_token_or_reserved('end') -> "unexpected reserved word: ";
unexpected_token_or_reserved(_) -> "unexpected token: ".

missing_terminator_hint(Start, End, #toxic_tokenizer{mismatch_hints=Hints}) ->
  case lists:keyfind(Start, 1, Hints) of
    {Start, {HintLine, _, _}, _} ->
      io_lib:format("\n~ts it looks like the \"~ts\" on line ~B does not have a matching \"~ts\"",
                    [toxic_errors:prefix(hint), Start, HintLine, End]);
    false ->
      ""
  end.

sigil_terminator($() -> $);
sigil_terminator($[) -> $];
sigil_terminator(${) -> $};
sigil_terminator($<) -> $>;
sigil_terminator(O) -> O.

terminator('fn') -> 'end';
terminator('do') -> 'end';
terminator('(')  -> ')';
terminator('[')  -> ']';
terminator('{')  -> '}';
terminator('<<') -> '>>'.

%% Keywords checking

keyword_or_unsafe_to_atom(true, "fn", _Line, _Column, _Scope) -> {keyword, 'fn', terminator};
keyword_or_unsafe_to_atom(true, "do", _Line, _Column, _Scope) -> {keyword, 'do', terminator};
keyword_or_unsafe_to_atom(true, "end", _Line, _Column, _Scope) -> {keyword, 'end', terminator};
keyword_or_unsafe_to_atom(true, "true", _Line, _Column, _Scope) -> {keyword, 'true', token};
keyword_or_unsafe_to_atom(true, "false", _Line, _Column, _Scope) -> {keyword, 'false', token};
keyword_or_unsafe_to_atom(true, "nil", _Line, _Column, _Scope) -> {keyword, 'nil', token};

keyword_or_unsafe_to_atom(true, "not", _Line, _Column, _Scope) -> {keyword, 'not', unary_op};
keyword_or_unsafe_to_atom(true, "and", _Line, _Column, _Scope) -> {keyword, 'and', and_op};
keyword_or_unsafe_to_atom(true, "or", _Line, _Column, _Scope) -> {keyword, 'or', or_op};
keyword_or_unsafe_to_atom(true, "when", _Line, _Column, _Scope) -> {keyword, 'when', when_op};
keyword_or_unsafe_to_atom(true, "in", _Line, _Column, _Scope) -> {keyword, 'in', in_op};

keyword_or_unsafe_to_atom(true, "after", _Line, _Column, _Scope) -> {keyword, 'after', block};
keyword_or_unsafe_to_atom(true, "else", _Line, _Column, _Scope) -> {keyword, 'else', block};
keyword_or_unsafe_to_atom(true, "catch", _Line, _Column, _Scope) -> {keyword, 'catch', block};
keyword_or_unsafe_to_atom(true, "rescue", _Line, _Column, _Scope) -> {keyword, 'rescue', block};

keyword_or_unsafe_to_atom(_, Part, Line, Column, Scope) ->
  unsafe_to_atom(Part, Line, Column, Scope).

tokenize_keyword(terminator, Rest, Line, Column, Atom, Length, Scope, Tokens) ->
  case tokenize_keyword_terminator(Line, Column, Atom, Tokens, Scope) of
    {ok, [Check | T]} ->
      handle_terminator(Rest, Line, Column + Length, Scope, Check, T);
    {error, Message, Token} ->
      error({make_meta_len(Line, Column, Length, nil, Scope), Message, Token}, Token ++ Rest, Scope, Tokens)
  end;

tokenize_keyword(token, Rest, Line, Column, Atom, Length, Scope, Tokens) ->
  Token = {Atom, make_meta_len(Line, Column, Length, nil, Scope)},
  yield(Rest, Line, Column + Length, Scope, [Token | Tokens]);

tokenize_keyword(block, Rest, Line, Column, Atom, Length, Scope, Tokens) ->
  Meta = make_meta_len(Line, Column, Length, nil, Scope),
  Token = {block_identifier, Meta, Atom},
  yield(Rest, Line, Column + Length, Scope, [Token | Tokens]);

tokenize_keyword(Kind, Rest, Line, Column, Atom, Length, Scope, Tokens) ->
  % Handle escaped newline(s) + horizontal spaces between 'not' and 'in' on the same logical line
  case Atom of
    'not' ->
      case strip_horizontal_space_after_escaped_newlines(Rest, 0, 0) of
        {"in" ++ InRest, SpacesAfter, EscapedCount} when EscapedCount > 0 ->
          EndLine = Line + EscapedCount,
          EndColumn = 2 + SpacesAfter,
          Meta = make_meta(Line, Column, EndLine, EndColumn + 1, nil, Scope),
          NewTokens = add_token_with_eol({in_op, Meta, 'not in'}, Tokens),
          yield(InRest, EndLine, EndColumn + 1, Scope, NewTokens);
        _ ->
          normal_keyword_processing(Kind, Rest, Line, Column, Atom, Length, Scope, Tokens)
      end;
    _ ->
      normal_keyword_processing(Kind, Rest, Line, Column, Atom, Length, Scope, Tokens)
  end.

normal_keyword_processing(Kind, Rest, Line, Column, Atom, Length, Scope, Tokens) ->
  NewTokens =
    case strip_horizontal_space(Rest, 0) of
      {[$/ | _], _} ->
        [{identifier, make_meta_len(Line, Column, Length, nil, Scope), Atom} | Tokens];

      _ ->
        case {Kind, Tokens} of
          %% Across EOL: allow top tokens to be not and eol in any order
          {in_op, [{eol, _} | [{unary_op, NotInfo, 'not'} | T]]} ->
            Start = case NotInfo of
              {{SL, SC}, _, _} -> {SL, SC};
              {SL, SC, _} -> {SL, SC}
            end,
            {_, ExtraSpaces} = strip_horizontal_space(Rest, 0),
            EndLine = Line,
            EndColumn = Column + Length + ExtraSpaces,
            %% previous_was_eol(T) remains accurate for remaining tail
            Meta = make_meta(element(1, Start), element(2, Start), EndLine, EndColumn, 1, Scope),
            add_token_with_eol({in_op, Meta, 'not in'}, T);

          {in_op, [{unary_op, NotInfo, 'not'} | [{eol, _} | T]]} ->
            Start = case NotInfo of
              {{SL, SC}, _, _} -> {SL, SC};
              {SL, SC, _} -> {SL, SC}
            end,
            {_, ExtraSpaces} = strip_horizontal_space(Rest, 0),
            EndLine = Line,
            EndColumn = Column + Length + ExtraSpaces,
            Meta = make_meta(element(1, Start), element(2, Start), EndLine, EndColumn, 1, Scope),
            add_token_with_eol({in_op, Meta, 'not in'}, T);

          {in_op, [{unary_op, NotInfo, 'not'} | T]} ->
            %% Build a range from the start of 'not' to the end of 'in'
            Start = case NotInfo of
              {{SL, SC}, _, _} -> {SL, SC};
              {SL, SC, _} -> {SL, SC}
            end,
            EndLine = Line,
            %% Include any horizontal spaces between 'not' and 'in' in the range
            {_, ExtraSpaces} = strip_horizontal_space(Rest, 0),
            EndColumn = Column + Length + ExtraSpaces,
            Meta = make_meta(element(1, Start), element(2, Start), EndLine, EndColumn, previous_was_eol(T), Scope),
            add_token_with_eol({in_op, Meta, 'not in'}, T);

          {_, _} ->
            PrevEol = previous_was_eol(Tokens),
            Meta = make_meta_len(Line, Column, Length, PrevEol, Scope),
            add_token_with_eol({Kind, Meta, Atom}, Tokens)
        end
    end,

  yield(Rest, Line, Column + Length, Scope, NewTokens).

tokenize_sigil([$~ | T], Line, Column, Scope, Tokens) ->
  case tokenize_sigil_name(T, [], Line, Column + 1, Scope, Tokens) of
    {ok, Name, Rest, NewLine, NewColumn, NewScope, NewTokens} ->
      tokenize_sigil_contents(Rest, Name, NewLine, NewColumn, NewScope, NewTokens);

    {error, Message, Token} ->
      Reason = {make_meta_len(Line, Column, 1, nil, Scope), Message, Token},
      error(Reason, T, Scope, Tokens)
  end.

% A one-letter sigil is ok both as upcase as well as downcase.
tokenize_sigil_name([S | T], [], Line, Column, Scope, Tokens) when ?is_downcase(S) ->
  tokenize_lower_sigil_name(T, [S], Line, Column + 1, Scope, Tokens);
tokenize_sigil_name([S | T], [], Line, Column, Scope, Tokens) when ?is_upcase(S) ->
    tokenize_upper_sigil_name(T, [S], Line, Column + 1, Scope, Tokens).

tokenize_lower_sigil_name([S | _T] = Original, [_ | _] = NameAcc, _Line, _Column, _Scope, _Tokens) when ?is_downcase(S) ->
  SigilName = lists:reverse(NameAcc) ++ Original,
  {error, sigil_name_error(), [$~] ++ SigilName};
tokenize_lower_sigil_name(T, NameAcc, Line, Column, Scope, Tokens) ->
  {ok, lists:reverse(NameAcc), T, Line, Column, Scope, Tokens}.

% If we have an uppercase letter, we keep tokenizing the name.
% A digit is allowed but an uppercase letter or digit must proceed it.
tokenize_upper_sigil_name([S | T], NameAcc, Line, Column, Scope, Tokens) when ?is_upcase(S); ?is_digit(S) ->
  tokenize_upper_sigil_name(T, [S | NameAcc], Line, Column + 1, Scope, Tokens);
% With a lowercase letter and a non-empty NameAcc we return an error.
tokenize_upper_sigil_name([S | _T] = Original, [_ | _] = NameAcc, _Line, _Column, _Scope, _Tokens) when ?is_downcase(S) ->
  SigilName = lists:reverse(NameAcc) ++ Original,
  {error,  sigil_name_error(), [$~] ++ SigilName};
% We finished the letters, so the name is over.
tokenize_upper_sigil_name(T, NameAcc, Line, Column, Scope, Tokens) ->
  {ok, lists:reverse(NameAcc), T, Line, Column, Scope, Tokens}.

sigil_name_error() ->
  "invalid sigil name, it should be either a one-letter lowercase letter or an " ++
  "uppercase letter optionally followed by uppercase letters and digits, got: ".

tokenize_sigil_contents([H, H, H | T] = Original, [S | _] = SigilName, Line, Column, Scope, Tokens)
    when ?is_quote(H) ->
  % Streaming mode for sigil heredocs
  case extract_heredoc_header(T) of
    {ok, Headerless} ->
      SigilAtom = list_to_atom("sigil_" ++ SigilName),
      StartCol = Column - length(SigilName) - 1,
      StartTok = {sigil_start, make_meta(Line, StartCol, Line, Column + 3, nil, Scope), SigilAtom, <<H,H,H>>},
      % Switch to interpolation streaming; pass closing delimiter [H,H,H]
      % Store sigil info in interpolation payload: {sigil_info, SigilAtom, Interpol?, StartDelim}
      Interp = {sigil_info, SigilAtom, ?is_downcase(S), <<H,H,H>>},
      {switch_to_interp, StartTok, Headerless, Line + 1, 1, Scope, sigil, [H, H, H], Interp};
    {error, Message} ->
      error({make_meta_len(Line, Column - 1 - length(SigilName), 1, nil, Scope), "heredoc allows only whitespace characters followed by a new line after opening ", Message}, [$~] ++ SigilName ++ Original, Scope, Tokens)
  end;

tokenize_sigil_contents([H | T] = _Original, [S | _] = SigilName, Line, Column, Scope, _Tokens)
    when ?is_sigil(H) ->
  % Streaming mode for regular sigils
  SigilAtom = list_to_atom("sigil_" ++ SigilName),
  StartCol = Column - length(SigilName) - 1,
  StartTok = {sigil_start, make_meta(Line, StartCol, Line, Column + 1, nil, Scope), SigilAtom, <<H>>},
  Interp = {sigil_info, SigilAtom, ?is_downcase(S), <<H>>},
  % Switch to interpolation with closing terminator derived from opening
  {switch_to_interp, StartTok, T, Line, Column + 1, Scope, sigil, sigil_terminator(H), Interp};

tokenize_sigil_contents([H | _] = Original, SigilName, Line, Column, Scope, Tokens) ->
  MessageString =
    "\"~ts\" (column ~p, code point U+~4.16.0B). The available delimiters are: "
    "//, ||, \"\", '', (), [], {}, <>",
  Message = io_lib:format(MessageString, [[H], Column, H]),
  ErrorColumn = Column - 1 - length(SigilName),
  error({make_meta_len(Line, ErrorColumn, 1, nil, Scope), "invalid sigil delimiter: ", Message}, [$~] ++ SigilName ++ Original, Scope, Tokens);

% Incomplete sigil.
tokenize_sigil_contents([], _SigilName, Line, Column, Scope, Tokens) ->
  % Yield directly - incomplete sigil case
  yield([], Line, Column, Scope, Tokens).

%% Fail early on invalid do syntax. For example, after
%% most keywords, after comma and so on.
tokenize_keyword_terminator(DoLine, DoColumn, do, [{identifier, {Line, Column, Meta}, Atom} | T], Scope) ->
  {ok, add_token_with_eol({do, make_meta_len(DoLine, DoColumn, 2, nil, Scope)},
                          [{do_identifier, {Line, Column, Meta}, Atom} | T])};
tokenize_keyword_terminator(_Line, _Column, do, [{'fn', _} | _], _Scope) ->
  {error, invalid_do_with_fn_error("unexpected reserved word: "), "do"};
tokenize_keyword_terminator(Line, Column, do, Tokens, Scope) ->
  case is_valid_do(Tokens) of
    true  -> {ok, add_token_with_eol({do, make_meta_len(Line, Column, 2, nil, Scope)}, Tokens)};
    false -> {error, invalid_do_error("unexpected reserved word: "), "do"}
  end;
tokenize_keyword_terminator(Line, Column, Atom, Tokens, Scope) ->
  AtomLen = length(atom_to_list(Atom)),
  {ok, [{Atom, make_meta_len(Line, Column, AtomLen, nil, Scope)} | Tokens]}.

is_valid_do([{Atom, _} | _]) ->
  case Atom of
    ','      -> false;
    ';'      -> false;
    'not'    -> false;
    'and'    -> false;
    'or'     -> false;
    'when'   -> false;
    'in'     -> false;
    'after'  -> false;
    'else'   -> false;
    'catch'  -> false;
    'rescue' -> false;
    '.'      -> false;  % do after dot should be treated as identifier
    _        -> true
  end;
is_valid_do(_) ->
  true.

invalid_character_error(What, Char) ->
  io_lib:format("invalid character \"~ts\" (code point U+~4.16.0B) in ~ts: ", [[Char], Char, What]).

invalid_do_error(Prefix) ->
  {Prefix, ". In case you wanted to write a \"do\" expression, "
  "you must either use do-blocks or separate the keyword argument with comma. "
  "For example, you should either write:\n\n"
  "    if some_condition? do\n"
  "      :this\n"
  "    else\n"
  "      :that\n"
  "    end\n\n"
  "or the equivalent construct:\n\n"
  "    if(some_condition?, do: :this, else: :that)\n\n"
  "where \"some_condition?\" is the first argument and the second argument is a keyword list.\n\n"
  "You may see this error if you forget a trailing comma before the \"do\" in a \"do\" block"}.

invalid_do_with_fn_error(Prefix) ->
  {Prefix, ". Anonymous functions are written as:\n\n"
  "    fn pattern -> expression end\n\nPlease remove the \"do\" keyword"}.

% TODO: Turn into an error on v2.0
maybe_warn_too_many_of_same_char([T | _] = Token, [T | _] = _Rest, Line, Column, Scope) ->
  Message = io_lib:format(
    "found \"~ts\" followed by \"~ts\", please use a space between \"~ts\" and the next \"~ts\"",
    [Token, [T], Token, [T]]
  ),
  prepend_warning(Line, Column, Message, Scope);
maybe_warn_too_many_of_same_char(_Token, _Rest, _Line, _Column, Scope) ->
  Scope.

%% TODO: Turn into an error on v2.0
maybe_warn_for_ambiguous_bang_before_equals(Kind, Unencoded, [$= | _], Line, Column, Scope) ->
  {What, Identifier} =
    case Kind of
      atom -> {"atom", [$: | Unencoded]};
      identifier -> {"identifier", Unencoded}
    end,

  case lists:last(Identifier) of
    Last when Last =:= $!; Last =:= $? ->
      Msg = io_lib:format("found ~ts \"~ts\", ending with \"~ts\", followed by =. "
                          "It is unclear if you mean \"~ts ~ts=\" or \"~ts =\". Please add "
                          "a space before or after ~ts to remove the ambiguity",
                          [What, Identifier, [Last], lists:droplast(Identifier), [Last], Identifier, [Last]]),
      prepend_warning(Line, Column, Msg, Scope);
    _ ->
      Scope
  end;
maybe_warn_for_ambiguous_bang_before_equals(_Kind, _Atom, _Rest, _Line, _Column, Scope) ->
  Scope.

prepend_warning(Line, Column, Msg, #toxic_tokenizer{warnings=Warnings} = Scope) ->
  Scope#toxic_tokenizer{warnings = [{{Line, Column}, Msg} | Warnings]}.

%% Heredoc indentation stripping helpers

strip_heredoc_indentation(Parts, Indent) ->
  Fun = fun(Part) -> strip_heredoc_part_indent(Part, Indent) end,
  lists:map(Fun, Parts).

strip_heredoc_part_indent(Part, Indent) when is_binary(Part) ->
  % First trim indentation from the beginning of the content
  CharList = binary_to_list(Part),
  {TrimmedStart, _} = trim_space_heredoc(CharList, Indent),
  strip_heredoc_part_indent(TrimmedStart, [], Indent);
strip_heredoc_part_indent(Part, _Indent) ->
  Part.

strip_heredoc_part_indent([$\n | Rest], Acc, Indent) ->
  {Trimmed, _ShouldWarn} = trim_space_heredoc(Rest, Indent),
  strip_heredoc_part_indent(Trimmed, [$\n | Acc], Indent);
strip_heredoc_part_indent([Head | Rest], Acc, Indent) ->
  strip_heredoc_part_indent(Rest, [Head | Acc], Indent);
strip_heredoc_part_indent([], Acc, _Indent) ->
  list_to_binary(lists:reverse(Acc)).

trim_space_heredoc(Rest, 0) -> {Rest, false};
trim_space_heredoc([$\r, $\n | _] = Rest, _) -> {Rest, false};
trim_space_heredoc([$\n | _] = Rest, _) -> {Rest, false};
trim_space_heredoc([H | T], Spaces) when ?is_horizontal_space(H) -> trim_space_heredoc(T, Spaces - 1);
trim_space_heredoc([], _Spaces) -> {[], false};
trim_space_heredoc(Rest, _Spaces) -> {Rest, true}.

%% Add missing empty fragments for heredocs where interpolation starts at column 1
add_missing_empty_fragments(Parts) ->
  case Parts of
    [{{_, Column, _}, _, _} | _] when Column == 1 ->
      % First part is an interpolation at column 1 - add empty string before it
      [<<>> | Parts];
    _ ->
      % First part is not an interpolation at column 1 or Parts is empty
      fix_missing_spaces_in_parts(Parts)
  end.

%% Add missing empty fragments for heredocs where interpolation starts at column 1 
%% with indentation-aware space restoration
add_missing_empty_fragments(Parts, Indent) ->
  case Parts of
    [{{_, Column, _}, _, _} | _] when Column == 1 ->
      % First part is an interpolation at column 1 - add empty string before it
      if 
        Indent > 0 ->
          % Apply targeted space restoration only when there's actual indentation
          [<<>> | fix_missing_spaces_in_parts(Parts, Indent)];
        true ->
          % No indentation stripping, no need for space restoration
          [<<>> | Parts]
      end;
    _ ->
      % First part is not an interpolation at column 1 or Parts is empty
      if 
        Indent > 0 ->
          % Apply targeted space restoration only when there's actual indentation
          fix_missing_spaces_in_parts(Parts, Indent);
        true ->
          % No indentation stripping, no need for space restoration
          Parts
      end
  end.

%% Fix missing spaces in final fragments due to indentation stripping
%% Only apply fixes when there is actual indentation (indent > 0)
fix_missing_spaces_in_parts(Parts) ->
  Parts.

%% Fix missing spaces with indentation context
fix_missing_spaces_in_parts(Parts, Indent) when Indent > 0 ->
  % Only apply space restoration when there's actual indentation stripping
  fix_indentation_over_stripping(Parts);
fix_missing_spaces_in_parts(Parts, _Indent) ->
  % No indentation stripping, return parts as-is
  Parts.

%% Fix cases where indentation stripping removed content spaces
fix_indentation_over_stripping(Parts) ->
  fix_indentation_over_stripping(Parts, []).

fix_indentation_over_stripping([], Acc) ->
  lists:reverse(Acc);
fix_indentation_over_stripping([Part | Rest], Acc) when is_binary(Part) ->
  % For binary parts, check if this fragment follows an interpolation on the same line
  FixedPart = case should_restore_leading_space(Part, Acc) of
    true -> restore_leading_space(Part);
    false -> Part
  end,
  fix_indentation_over_stripping(Rest, [FixedPart | Acc]);
fix_indentation_over_stripping([Part | Rest], Acc) ->
  % For interpolation parts, keep as-is
  fix_indentation_over_stripping(Rest, [Part | Acc]).

%% Check if a binary part should have its leading space restored
should_restore_leading_space(Part, Acc) ->
  % If the part doesn't start with newline and follows an interpolation,
  % it likely had its content space incorrectly stripped as indentation
  case {binary:at(Part, 0), Acc} of
    {Char, [{{_, Column, _}, _, _} | _]} when Column > 1 andalso Char =/= $\n ->
      % Previous part was an interpolation not at column 1, and this part doesn't start with newline
      % This means this part continues from the middle of a line, so leading spaces are content
      true;
    _ ->
      false
  end.

%% Restore one leading space to a binary part
restore_leading_space(Part) ->
  <<" ", Part/binary>>.

track_ascii(true, Scope) -> Scope;
track_ascii(false, Scope) -> Scope#toxic_tokenizer{ascii_identifiers_only=false}.

maybe_unicode_lint_warnings(_Ascii=false, Tokens, Warnings) ->
  'Elixir.String.Tokenizer.Security':unicode_lint_warnings(lists:reverse(Tokens)) ++ Warnings;
maybe_unicode_lint_warnings(_Ascii=true, _Tokens, Warnings) ->
  Warnings.

error(Reason, Rest, #toxic_tokenizer{warnings=Warnings}, Tokens) ->
  {error, Reason, Rest, Warnings, Tokens}.

%% Cursor handling

add_cursor(_Line, Column, noprune, Terminators, Tokens) ->
  {Column, Terminators, Tokens};
add_cursor(Line, Column, prune_and_cursor, Terminators, Tokens) ->
  PrePrunedTokens = prune_identifier(Tokens),
  PrunedTokens = prune_tokens(PrePrunedTokens, []),
  CursorTokens = [
    {')', {Line, Column + 11, nil}},
    {'(', {Line, Column + 10, nil}},
    {paren_identifier, {Line, Column, nil}, '__cursor__'}
    | PrunedTokens
  ],
  {Column + 12, Terminators, CursorTokens}.

prune_identifier([{identifier, _, _} | Tokens]) -> Tokens;
prune_identifier(Tokens) -> Tokens.

%%% Any terminator needs to be closed
prune_tokens([{'end', _} | Tokens], Opener) ->
  prune_tokens(Tokens, ['end' | Opener]);
prune_tokens([{')', _} | Tokens], Opener) ->
  prune_tokens(Tokens, [')' | Opener]);
prune_tokens([{']', _} | Tokens], Opener) ->
  prune_tokens(Tokens, [']' | Opener]);
prune_tokens([{'}', _} | Tokens], Opener) ->
  prune_tokens(Tokens, ['}' | Opener]);
prune_tokens([{'>>', _} | Tokens], Opener) ->
  prune_tokens(Tokens, ['>>' | Opener]);
%%% Close opened terminators
prune_tokens([{'fn', _} | Tokens], ['end' | Opener]) ->
  prune_tokens(Tokens, Opener);
prune_tokens([{'do', _} | Tokens], ['end' | Opener]) ->
  prune_tokens(Tokens, Opener);
prune_tokens([{'(', _} | Tokens], [')' | Opener]) ->
  prune_tokens(Tokens, Opener);
prune_tokens([{'[', _} | Tokens], [']' | Opener]) ->
  prune_tokens(Tokens, Opener);
prune_tokens([{'{', _} | Tokens], ['}' | Opener]) ->
  prune_tokens(Tokens, Opener);
prune_tokens([{'<<', _} | Tokens], ['>>' | Opener]) ->
  prune_tokens(Tokens, Opener);
%%% or it is time to stop...
prune_tokens([{';', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{'eol', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{',', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{'fn', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{'do', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{'(', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{'[', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{'{', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{'<<', _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{identifier, _, _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{block_identifier, _, _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{kw_identifier, _, _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{kw_identifier_safe, _, _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{kw_identifier_unsafe, _, _} | _] = Tokens, []) ->
  Tokens;
prune_tokens([{OpType, _, _} | _] = Tokens, [])
  when OpType =:= comp_op; OpType =:= at_op; OpType =:= unary_op; OpType =:= and_op;
       OpType =:= or_op; OpType =:= arrow_op; OpType =:= match_op; OpType =:= in_op;
       OpType =:= in_match_op; OpType =:= type_op; OpType =:= dual_op; OpType =:= mult_op;
       OpType =:= power_op; OpType =:= concat_op; OpType =:= range_op; OpType =:= xor_op;
       OpType =:= pipe_op; OpType =:= stab_op; OpType =:= when_op; OpType =:= assoc_op;
       OpType =:= rel_op; OpType =:= ternary_op; OpType =:= capture_op; OpType =:= ellipsis_op ->
  Tokens;
%%% or we traverse until the end.
prune_tokens([_ | Tokens], Opener) ->
  prune_tokens(Tokens, Opener);
prune_tokens([], _Opener) ->
  [].

%% =============================================================================
%% Helper functions for tokenize_single
%% =============================================================================

%% @doc Yield a single token from tokenize_single
%% Converts the old pattern tokenize(Rest, NewLine, NewColumn, NewScope, [Token | Tokens])
%% to {token, Token, Rest, NewLine, NewColumn, NewScope}
yield(Rest, NewLine, NewColumn, NewScope, [Token | _Tokens]) ->
  {token, Token, Rest, NewLine, NewColumn, NewScope};
yield(_Rest, NewLine, NewColumn, NewScope, []) ->
  {eof, NewLine, NewColumn, NewScope}.

%% =============================================================================
%% Driver input consumption helpers
%% =============================================================================

%% @doc Get current terminator stack from driver
%% @spec current_terminators(Driver) -> [{Start, Meta, Indent}]
current_terminators(#toxic_driver{scope = #toxic_tokenizer{terminators = Terminators}}) ->
  Terminators.

%% @doc Peek at potentially missing terminator
%% @spec peek_missing_terminator(Driver) -> End | nil
peek_missing_terminator(Driver) ->
  case current_terminators(Driver) of
    [] -> 
      nil;
    [{Opener, _Meta, _Indent} | _] -> 
      terminator(Opener)
  end.
