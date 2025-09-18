%% SPDX-License-Identifier: Apache-2.0
%% SPDX-FileCopyrightText: 2021 The Elixir Team
%% SPDX-FileCopyrightText: 2012 Plataformatec

-module(toxic_tokenizer).
-include("toxic.hrl").
-include("toxic_tokenizer.hrl").
-export([ranges_to_legacy/1, collapse_linear_ranges/1]).

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
    %% Default behaviour
    _ -> Conv
  end,
  ranges_to_legacy_after_collapse(T, false, [Adj | Acc]).

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
  {sigil, legacy_meta(Meta), SigilAtom, ranges_convert_parts(Parts), Modifiers, Indentation, Delimiter}.

legacy_meta({{Line, Column}, _End, Extra}) -> {Line, Column, Extra};
legacy_meta({Line, Column, Extra}) -> {Line, Column, Extra}.

ranges_convert_parts(Parts) when is_list(Parts) ->
  [ranges_convert_part(Part) || Part <- Parts].

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
  linear_to_legacy(T, Out, [{sigil, Meta, SigilAtom, Delim, [Bin | PartsRev], Mods, pending_end} | Stack]);

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
      linear_to_legacy(T, Out, [{sigil, Meta, SigilAtom, Delim, [Part | Parts], Mods, pending_end} | Stack])
  end;

%% Accumulate inner tokens for interpolation
linear_to_legacy([Tok | T], Out, [{interpol, StartMeta, Inner} | Stack]) ->
  linear_to_legacy(T, Out, [{interpol, StartMeta, [Tok | Inner]} | Stack]);

%% Sigil end and optional modifiers
linear_to_legacy([{sigil_end, EndMeta, _Delim, Indent} | Rest], Out, [{sigil, Meta, SigilAtom, Delim, PartsRev, _Mods, pending_end} | Stack]) ->
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
      case Stack of
        [{interpol, InterpMeta, InnerRev} | StackRest] ->
          % If inside interpolation, add sigil token to interpolation frame
          linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
        _ ->
          linear_to_legacy(T, [Tok | Out], Stack)
      end;
    _ ->
      CM = combine_range_meta(Meta, EndMeta),
      Tok = {sigil, CM, SigilAtom, Parts1, [], Indent, Delim},
      case Stack of
        [{interpol, InterpMeta, InnerRev} | StackRest] ->
          % If inside interpolation, add sigil token to interpolation frame
          linear_to_legacy(Rest, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
        _ ->
          linear_to_legacy(Rest, [Tok | Out], Stack)
      end
  end;

linear_to_legacy([{bin_string_end, MetaEnd, _Delim1} | T], Out, [{bin_string, MetaStart, _Delim2, PartsRev} | Stack]) ->
  CM = combine_range_meta(MetaStart, MetaEnd),
  Parts = case lists:reverse(PartsRev) of
    [] ->
      [<<>>];  % Empty string should have empty binary part, not empty list
    RevParts -> RevParts
  end,
  Final = unescape_binary_parts(Parts),
  Tok = {bin_string, CM, Final},
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
    [] ->
      [<<>>];  % Empty charlist should use empty binary like bin_string, not empty string
    RevParts -> RevParts
  end,
  Final = unescape_binary_parts(Parts),
  Tok = {list_string, CM, Final},
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
  TrimmedEscaped = strip_heredoc_indentation(lists:reverse(PartsRev), Indent),
  Parts = unescape_binary_parts(TrimmedEscaped),
  Tok = {bin_heredoc, CM, Indent, Parts},
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      % Nested inside interpolation - add to interpolation frame
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
    _ ->
      % Top-level - add to output
      linear_to_legacy(T, [Tok | Out], Stack)
  end;
linear_to_legacy([{list_heredoc_end, MetaEnd, _Delim1, Indent} | T], Out, [{list_heredoc, MetaStart, _Delim2, PartsRev, _} | Stack]) ->
  CM = combine_range_meta(MetaStart, MetaEnd),
  TrimmedEscaped = strip_heredoc_indentation(lists:reverse(PartsRev), Indent),
  Parts = unescape_binary_parts(TrimmedEscaped),
  Tok = {list_heredoc, CM, Indent, Parts},
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      % Nested inside interpolation - add to interpolation frame
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
    _ ->
      % Top-level - add to output
      linear_to_legacy(T, [Tok | Out], Stack)
  end;
%% Keep EOL tokens in collapsed ranges

linear_to_legacy([{kw_identifier_unsafe_end, MetaEnd, Delim} | T], Out, [{Kind, MetaStart, _Delim2, PartsRev} | Stack]) when Kind =:= bin_string; Kind =:= list_string ->
  Parts = lists:reverse(PartsRev),
  {{SL, SC}, {EL, EC}, _} = combine_range_meta(MetaStart, MetaEnd),
  CM = {{SL, SC}, {EL, EC}, Delim},
  Final = unescape_binary_parts(Parts),
  Tok = case Final of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    [] -> {kw_identifier, CM, ''};
    _ -> {kw_identifier_unsafe, CM, Final}
  end,
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [Tok | Out], Stack)
  end;
linear_to_legacy([{kw_identifier_safe_end, MetaEnd, Delim} | T], Out, [{Kind, MetaStart, _Delim2, PartsRev} | Stack]) when Kind =:= bin_string; Kind =:= list_string ->
  Parts = lists:reverse(PartsRev),
  {{SL, SC}, {EL, EC}, _} = combine_range_meta(MetaStart, MetaEnd),
  CM = {{SL, SC}, {EL, EC}, Delim},
  Final = unescape_binary_parts(Parts),
  Tok = case Final of
    [Bin] when is_binary(Bin) -> {kw_identifier, CM, binary_to_atom(Bin, utf8)};
    [] -> {kw_identifier, CM, ''};
    _ -> {kw_identifier_safe, CM, Final}
  end,
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [Tok | Out], Stack)
  end;
linear_to_legacy([{atom_unsafe_end, MetaEnd, Delim} | T], Out, [{atom_unsafe, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {{SL, SC}, {EL, EC}, _} = combine_range_meta(MetaStart, MetaEnd),
  CM = {{SL, SC}, {EL, EC}, Delim},
  Final = unescape_binary_parts(Parts),
  Tok = case Final of
    [Bin] when is_binary(Bin) -> {atom_quoted, CM, binary_to_atom(Bin, utf8)};
    [] -> {atom_quoted, CM, ''};
    _ -> {atom_unsafe, CM, Final}
  end,
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      % If inside interpolation, add the atom token to interpolation frame
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [Tok | Out], Stack)
  end;
linear_to_legacy([{atom_safe_end, MetaEnd, Delim} | T], Out, [{atom_safe, MetaStart, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {{SL, SC}, {EL, EC}, _} = combine_range_meta(MetaStart, MetaEnd),
  CM = {{SL, SC}, {EL, EC}, Delim},
  Final = unescape_binary_parts(Parts),
  Tok = case Final of
    [Bin] when is_binary(Bin) -> {atom_quoted, CM, binary_to_atom(Bin, utf8)};
    [] -> {atom_quoted, CM, ''};
    _ -> {atom_safe, CM, Final}
  end,
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      % If inside interpolation, add the atom token to interpolation frame
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [Tok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [Tok | Out], Stack)
  end;

linear_to_legacy([{quoted_identifier_end, EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      AtomVal = binary_to_atom(unescape_bin(Content), utf8),
      {{_, _}, {FEL, FEC}, _} = FragMeta,
      ContentEndPos = {FEL, FEC},
      {AtomVal, ContentEndPos};
    [] ->
      {EndPos, _, _} = EndMeta,
      {'', EndPos}
  end,
  {Line, Column} = ContentEnd,
  ClosingQuotePos = {Line, Column + 1},
  {{SL, SC}, _SEnd, _SX} = StartMeta,
  IdentifierMeta = {{SL, SC}, ClosingQuotePos, Delim},
  DoIdTok = {identifier, IdentifierMeta, Atom},
  %% Don't emit do token here - let normal tokenizer handle it to avoid duplicates
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [DoIdTok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [DoIdTok | Out], Stack)
  end;

linear_to_legacy([{quoted_paren_identifier_end, EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      AtomVal = binary_to_atom(unescape_bin(Content), utf8),
      {{_, _}, {FEL, FEC}, _} = FragMeta,
      ContentEndPos = {FEL, FEC},
      {AtomVal, ContentEndPos};
    [] ->
      {EndPos, _, _} = EndMeta,
      {'', EndPos}
  end,
  {Line, Column} = ContentEnd,
  ClosingQuotePos = {Line, Column + 1},
  {{SL, SC}, _SEnd, _SX} = StartMeta,
  IdentifierMeta = {{SL, SC}, ClosingQuotePos, Delim},
  DoIdTok = {paren_identifier, IdentifierMeta, Atom},
  %% Don't emit do token here - let normal tokenizer handle it to avoid duplicates
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [DoIdTok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [DoIdTok | Out], Stack)
  end;

linear_to_legacy([{quoted_bracket_identifier_end, EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      AtomVal = binary_to_atom(unescape_bin(Content), utf8),
      {{_, _}, {FEL, FEC}, _} = FragMeta,
      ContentEndPos = {FEL, FEC},
      {AtomVal, ContentEndPos};
    [] ->
      {EndPos, _, _} = EndMeta,
      {'', EndPos}
  end,
  {Line, Column} = ContentEnd,
  ClosingQuotePos = {Line, Column + 1},
  {{SL, SC}, _SEnd, _SX} = StartMeta,
  IdentifierMeta = {{SL, SC}, ClosingQuotePos, Delim},
  DoIdTok = {bracket_identifier, IdentifierMeta, Atom},
  %% Don't emit do token here - let normal tokenizer handle it to avoid duplicates
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [DoIdTok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [DoIdTok | Out], Stack)
  end;

linear_to_legacy([{quoted_do_identifier_end, EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      AtomVal = binary_to_atom(unescape_bin(Content), utf8),
      {{_, _}, {FEL, FEC}, _} = FragMeta,
      ContentEndPos = {FEL, FEC},
      {AtomVal, ContentEndPos};
    [] ->
      {EndPos, _, _} = EndMeta,
      {'', EndPos}
  end,
  {Line, Column} = ContentEnd,
  ClosingQuotePos = {Line, Column + 1},
  {{SL, SC}, _SEnd, _SX} = StartMeta,
  IdentifierMeta = {{SL, SC}, ClosingQuotePos, Delim},
  DoIdTok = {do_identifier, IdentifierMeta, Atom},
  %% Don't emit do token here - let normal tokenizer handle it to avoid duplicates
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [DoIdTok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [DoIdTok | Out], Stack)
  end;

linear_to_legacy([{quoted_op_identifier_end, EndMeta, Delim} | T], Out, [{quoted_identifier, StartMeta, _Delim2, PartsRev} | Stack]) ->
  Parts = lists:reverse(PartsRev),
  {Atom, ContentEnd} = case Parts of
    [{string_fragment, FragMeta, Content}] ->
      AtomVal = binary_to_atom(unescape_bin(Content), utf8),
      {{_, _}, {FEL, FEC}, _} = FragMeta,
      ContentEndPos = {FEL, FEC},
      {AtomVal, ContentEndPos};
    [] ->
      {EndPos, _, _} = EndMeta,
      {'', EndPos}
  end,
  {Line, Column} = ContentEnd,
  ClosingQuotePos = {Line, Column + 1},
  {{SL, SC}, _SEnd, _SX} = StartMeta,
  IdentifierMeta = {{SL, SC}, ClosingQuotePos, Delim},
  DoIdTok = {op_identifier, IdentifierMeta, Atom},
  %% Don't emit do token here - let normal tokenizer handle it to avoid duplicates
  case Stack of
    [{interpol, InterpMeta, InnerRev} | StackRest] ->
      linear_to_legacy(T, Out, [{interpol, InterpMeta, [DoIdTok | InnerRev]} | StackRest]);
    _ ->
      linear_to_legacy(T, [DoIdTok | Out], Stack)
  end;

%% Pass-through for non-linear tokens
linear_to_legacy([Tok | T], Out, Stack) ->
  linear_to_legacy(T, [Tok | Out], Stack);
linear_to_legacy([], Out, []) -> {Out, []}.

%% Combine range-shaped metas into a single span using the start of the first and end of the second.
combine_range_meta({{SL, SC}, _SEnd, _SX}, {_EStart, {EL, EC}, _EX}) -> {{SL, SC}, {EL, EC}, nil}.

%% Heredoc indentation stripping helpers

%% Strip indentation across parts while keeping track of line starts
strip_heredoc_indentation(Parts, Indent) ->
  {_AtLineStart, _SpacesLeft, OutRev} = strip_heredoc_indentation(Parts, Indent, true, Indent, []),
  lists:reverse(OutRev).

%% Walk the list of parts, maintaining whether we are at the start of a line
strip_heredoc_indentation([Part | Rest], Indent, AtLineStart, SpacesLeft, Acc) when is_binary(Part) ->
  {NewBin, NewAtLineStart, NewSpacesLeft} = strip_bin_indent(Part, Indent, AtLineStart, SpacesLeft),
  strip_heredoc_indentation(Rest, Indent, NewAtLineStart, NewSpacesLeft, [NewBin | Acc]);
strip_heredoc_indentation([{_SM, _EM, _Inner} = Interp | Rest], Indent, AtLineStart, _SpacesLeft, Acc) ->
  %% Interpolation counts as content on this line; do not trim spaces after it
  NewAtLineStart = case AtLineStart of true -> false; false -> false end,
  strip_heredoc_indentation(Rest, Indent, NewAtLineStart, 0, [Interp | Acc]);
strip_heredoc_indentation([], _Indent, AtLineStart, SpacesLeft, Acc) ->
  {AtLineStart, SpacesLeft, Acc}.

%% Process a binary fragment with indentation trimming aware of newlines
strip_bin_indent(Bin, Indent, AtLineStart, SpacesLeft) when is_binary(Bin) ->
  strip_bin_indent(binary_to_list(Bin), Indent, AtLineStart, SpacesLeft, []).

strip_bin_indent([$\n | Rest], Indent, _AtLineStart, _SpacesLeft, Acc) ->
  %% Newline resets indentation trimming for next characters
  strip_bin_indent(Rest, Indent, true, Indent, [$\n | Acc]);
strip_bin_indent([H | Rest], Indent, true, SpacesLeft, Acc) when SpacesLeft > 0, ?is_horizontal_space(H) ->
  %% Trim up to Indent horizontal spaces at start of line
  strip_bin_indent(Rest, Indent, true, SpacesLeft - 1, Acc);
strip_bin_indent([H | Rest], Indent, _AtLineStart, SpacesLeft, Acc) ->
  %% Regular character - keep and mark that we're no longer at line start
  strip_bin_indent(Rest, Indent, false, SpacesLeft, [H | Acc]);
strip_bin_indent([], _Indent, AtLineStart, SpacesLeft, Acc) ->
  {list_to_binary(lists:reverse(Acc)), AtLineStart, SpacesLeft}.

%% Helper: unescape only binary parts using the interpolation unescaper
unescape_binary_parts(Parts) ->
  Fun = fun(Part) when is_binary(Part) -> unescape_bin(Part);
           (Other) -> Other
        end,
  lists:map(Fun, Parts).

unescape_bin(Bin) ->
  case toxic_interpolation:unescape_tokens([Bin]) of
    {ok, [Un]} -> Un;
    _ -> Bin
  end.
