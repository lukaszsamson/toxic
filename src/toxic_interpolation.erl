%% SPDX-License-Identifier: Apache-2.0
%% SPDX-FileCopyrightText: 2021 The Elixir Team
%% SPDX-FileCopyrightText: 2012 Plataformatec

% Handle string and string-like interpolations.
-module(toxic_interpolation).
-export([extract/6, extract_stream_event/6, unescape_string/1, unescape_string/2,
unescape_tokens/1, unescape_map/1]).
-include("toxic.hrl").
-include("toxic_tokenizer.hrl").

%% Extract string interpolations

extract(Line, Column, Scope, Interpol, String, Last) when is_integer(Line), is_integer(Column) ->
  extract(String, [], [], Line, Column, Scope, Interpol, Last).

%% Original extract implementation - keep for compatibility
extract(String, Buffer, Output, Line, Column, Scope, Interpol, Last) ->
  extract_single(String, Buffer, Output, Line, Column, Scope, Interpol, Last).

%% Streaming interpolation API - emit events instead of collecting parts
%% Returns: {event_type(), EventData, Rest, NewLine, NewColumn, NewScope}
%% Event types:
%%   {fragment, Meta, Binary} - raw string content  
%%   {begin_interpolation, Meta, Kind} - start of #{...}
%%   {end_interpolation, Meta, Kind} - end of interpolation
%%   {done, Meta, Terminator} - string complete
%%   {done, Meta, Terminator, Indent} - heredoc complete (with indentation)
%%   {error, Meta, Reason} - parse error

extract_stream_event(Line, Column, Scope, Interpol, String, Last) when is_integer(Line), is_integer(Column) ->
  extract_stream_next(String, [], Line, Column, Line, Column, Scope, Interpol, Last).

% Terminators

%% Stream processing - accumulate buffer until we hit a significant event
extract_stream_next([], _Buffer, Line, Column, _StartLine, _StartColumn, #toxic_tokenizer{cursor_completion=false}, _Interpol, Last) ->
  {error, {string, Line, Column, io_lib:format("missing terminator: ~ts", [[Last]]), []}};

extract_stream_next([], Buffer, Line, Column, StartLine, StartColumn, Scope, _Interpol, _Last) ->
  % EOF reached - emit final fragment if any, then done
  case Buffer of
    [] -> {done, make_meta_range(Line, Column, Line, Column), [], [], Line, Column, Scope};
    _  -> {fragment, make_meta_range(StartLine, StartColumn, Line, Column), list_to_binary(lists:reverse(Buffer)), [], Line, Column, Scope}
  end;

extract_stream_next([H,H,H | Rest], [], Line, Column, _StartLine, _StartColumn, Scope, _Interpol, [H,H,H]) ->
  % Found heredoc terminator with no indentation - done
  {done, make_meta_range(Line, Column, Line, Column + 3), [], 0, Rest, Line, Column + 3, Scope};

extract_stream_next([$#, ${ | Rest], [], Line, Column, _StartLine, _StartColumn, Scope, true, [H,H,H]) ->
  % Found interpolation start in heredoc with empty buffer - emit begin_interpolation
  {begin_interpolation, make_meta_range(Line, Column, Line, Column + 2), string, Rest, Line, Column + 2, Scope};

extract_stream_next([Last | Rest], [], Line, Column, _StartLine, _StartColumn, Scope, _Interpol, Last) ->
  % Found terminator - emit fragment if any, then done
  {done, make_meta_range(Line, Column, Line, Column + 1), [], Rest, Line, Column + 1, Scope};

extract_stream_next([H,H,H | Rest], Buffer, Line, Column, StartLine, StartColumn, Scope, _Interpol, [H,H,H]) ->
  % Found heredoc terminator - emit final fragment, then done  
  Content = toxic_utils:characters_to_binary(lists:reverse(Buffer)),
  % {EndLine, EndColumn} = calculate_end_position(StartLine, StartColumn, Content),
  FragmentMeta = make_meta_range(StartLine, StartColumn, Line, Column),
  {fragment, FragmentMeta, Content, [H,H,H | Rest], Line, Column, Scope};

extract_stream_next([Last | Rest], Buffer, Line, Column, StartLine, StartColumn, Scope, _Interpol, Last) ->
  % Found terminator - emit final fragment, then done  
  Content = toxic_utils:characters_to_binary(lists:reverse(Buffer)),
  FragmentMeta = make_meta_range(StartLine, StartColumn, Line, Column),
  {fragment, FragmentMeta, Content, [Last | Rest], Line, Column, Scope};

% Interpolation

extract_stream_next([$#, ${ | Rest], Buffer, Line, Column, StartLine, StartColumn, Scope, true, _Last) ->
  % Found interpolation start - emit fragment if any, then begin_interpolation
  case Buffer of
    [] -> {begin_interpolation, make_meta_range(Line, Column, Line, Column + 2), string, Rest, Line, Column + 2, Scope};
    _  -> 
      % Calculate proper end position based on fragment content and use it for current position
      Content = list_to_binary(lists:reverse(Buffer)),
      % {EndLine, EndColumn} = calculate_end_position(StartLine, StartColumn, Content),
      {fragment, make_meta_range(StartLine, StartColumn, Line, Column), Content, [$#, ${ | Rest], Line, Column, Scope}
  end;

% Newlines

extract_stream_next([$\\, $\n | Rest], Buffer, Line, _Column, StartLine, StartColumn, Scope, Interpol, Last) ->
  extract_stream_next(Rest, [$\n, $\\ | Buffer], Line + 1, 1, StartLine, StartColumn, Scope, Interpol, Last);

extract_stream_next([$\\, $\r, $\n | Rest], Buffer, Line, _Column, StartLine, StartColumn, Scope, Interpol, Last) ->
  extract_stream_next(Rest, [$\n, $\r, $\\ | Buffer], Line + 1, 1, StartLine, StartColumn, Scope, Interpol, Last);

extract_stream_next([$\n | Rest], Buffer, Line, _Column, StartLine, StartColumn, Scope, Interpol, [H,H,H] = Last) ->
  % Special handling for heredocs - check if we have the closing delimiter after newline
  case strip_horizontal_space_stream(Rest, []) of
    {[H,H,H|NewRest], Spaces} ->
      Indent = length(Spaces),
      % Found closing heredoc delimiter - emit final fragment if any, then done
      case Buffer of
        [] -> {done, make_meta_range(Line + 1, Indent + 1, Line + 1, Indent + 4), [], Indent, NewRest, Line + 1, Indent + 4, Scope};
        _ ->
          % Emit the last fragment including this newline
          FragmentMeta = make_meta_range(StartLine, StartColumn, Line + 1, 1),
          {fragment, FragmentMeta, toxic_utils:characters_to_binary(lists:reverse([$\n | Buffer])), 
           lists:reverse(Spaces) ++ [H,H,H|NewRest], Line + 1, Indent + 1, Scope}
      end;
    {NewRest, Spaces} ->
      % Not closing delimiter, continue processing with newline
      extract_stream_next(NewRest, lists:reverse(Spaces) ++ [$\n | Buffer], Line + 1, length(Spaces) + 1, StartLine, StartColumn, Scope, Interpol, Last)
  end;
extract_stream_next([$\n | Rest], Buffer, Line, _Column, StartLine, StartColumn, Scope, Interpol, Last) ->
  extract_stream_next(Rest, [$\n | Buffer], Line + 1, 1, StartLine, StartColumn, Scope, Interpol, Last);

extract_stream_next([$\\, H, H, H | Rest], Buffer, Line, Column, StartLine, StartColumn, Scope, Interpol, [H, H, H]) ->
  % Handle escaped heredoc terminator
  extract_stream_next(Rest, [H, H, H, $\\ | Buffer], Line, Column + 4, StartLine, StartColumn, Scope, Interpol, [H, H, H]);

extract_stream_next([$\\, Last | Rest], Buffer, Line, Column, StartLine, StartColumn, Scope, Interpol, Last) ->
  % Handle escaped terminator
  extract_stream_next(Rest, [Last, $\\ | Buffer], Line, Column + 2, StartLine, StartColumn, Scope, Interpol, Last);

extract_stream_next([$\\, $#, ${ | Rest], Buffer, Line, Column, StartLine, StartColumn, Scope, true, Last) ->
  % Handle escaped interpolation start
  extract_stream_next(Rest, [${, $#, $\\ | Buffer], Line, Column + 3, StartLine, StartColumn, Scope, true, Last);

extract_stream_next(String, [], Line, Column, _StartLine, _StartColumn, Scope, _Interpol, [H,H,H] = Last) ->
  % Check for heredoc terminator with indentation
  % TODO: this is fucked up
  case strip_horizontal_space_stream(String, []) of
    {[H,H,H|NewRest], Spaces} ->
      % Found heredoc terminator with indentation
      Indent = length(Spaces),
      StartCol = Column + Indent,
      {done, make_meta_range(Line, StartCol, Line, StartCol + 3), [], Indent, NewRest, Line, StartCol + 3, Scope};
    _ ->
      % Not a heredoc terminator, process first character
      extract_stream_next(tl(String), [hd(String)], Line, Column + 1, Line, Column, Scope, true, Last)
  end;

extract_stream_next([Char | Rest], [], Line, Column, _StartLine, _StartColumn, Scope, Interpol, Last) ->
  % Starting buffer - track start position
  extract_stream_next(Rest, [Char], Line, Column + 1, Line, Column, Scope, Interpol, Last);

extract_stream_next([Char | Rest], Buffer, Line, Column, StartLine, StartColumn, Scope, Interpol, Last) ->
  % Regular character - add to buffer and continue
  extract_stream_next(Rest, [Char | Buffer], Line, Column + 1, StartLine, StartColumn, Scope, Interpol, Last).

%% Helper to create range metadata
make_meta_range(StartLine, StartColumn, EndLine, EndColumn) when StartLine >= 1, StartColumn >= 1, EndLine >= 1, EndColumn >= 1, StartLine < EndLine orelse (StartLine =:= EndLine andalso StartColumn =< EndColumn) ->
  {{StartLine, StartColumn}, {EndLine, EndColumn}, nil}.

%% Terminators

extract_single([], _Buffer, _Output, Line, Column, #toxic_tokenizer{cursor_completion=false}, _Interpol, Last) when is_integer(Line), is_integer(Column) ->
  {error, {string, Line, Column, io_lib:format("missing terminator: ~ts", [[Last]]), []}};

extract_single([], Buffer, Output, Line, Column, Scope, _Interpol, _Last) ->
  finish_extraction([], Buffer, Output, Line, Column, Scope);

extract_single([Last | Rest], Buffer, Output, Line, Column, Scope, _Interpol, Last) when is_integer(Line), is_integer(Column) ->
  finish_extraction(Rest, Buffer, Output, Line, Column + 1, Scope);

%% Going through the string

extract_single([$\\, $\r, $\n | Rest], Buffer, Output, Line, Column, Scope, Interpol, Last) when is_integer(Line), is_integer(Column) ->
  extract_nl(Rest, [$\n, $\r, $\\ | Buffer], Output, Line, Scope, Interpol, Last);

extract_single([$\\, $\n | Rest], Buffer, Output, Line, Column, Scope, Interpol, Last) when is_integer(Line), is_integer(Column) ->
  extract_nl(Rest, [$\n, $\\ | Buffer], Output, Line, Scope, Interpol, Last);

extract_single([$\n | Rest], Buffer, Output, Line, Column, Scope, Interpol, Last) when is_integer(Line), is_integer(Column) ->
  extract_nl(Rest, [$\n | Buffer], Output, Line, Scope, Interpol, Last);

extract_single([$\\, Last | Rest], Buffer, Output, Line, Column, Scope, Interpol, Last) when is_integer(Line), is_integer(Column) ->
  NewScope =
    %% TODO: Remove this on Elixir v2.0
    case Interpol of
      true ->
        Scope;
      false ->
        Msg = "using \\~ts to escape the closing of an uppercase sigil is deprecated, please use another delimiter or a lowercase sigil instead",
        prepend_warning(Line, Column, io_lib:format(Msg, [[Last]]), Scope)
    end,

  extract(Rest, [Last | Buffer], Output, Line, Column+2, NewScope, Interpol, Last);

extract_single([$\\, Last, Last, Last | Rest], Buffer, Output, Line, Column, Scope, Interpol, [Last, Last, Last] = All) when is_integer(Line), is_integer(Column) ->
  extract(Rest, [Last, Last, Last | Buffer], Output, Line, Column+4, Scope, Interpol, All);

extract_single([$\\, $#, ${ | Rest], Buffer, Output, Line, Column, Scope, true, Last) when is_integer(Line), is_integer(Column) ->
  extract(Rest, [${, $#, $\\ | Buffer], Output, Line, Column+3, Scope, true, Last);

extract_single([$#, ${ | Rest], Buffer, Output, Line, Column, Scope, true, Last) when is_integer(Line), is_integer(Column) ->
  %  TODO: yield here emitting string part and begin interpolation
  % push interpolation mode onto the stack
  % push opening terminator onto the stack
  Output1 = build_string(Buffer, Output),
  case toxic_tokenizer:tokenize(Rest, Line, Column + 2, Scope#toxic_tokenizer{terminators=[]}) of
    {error, {Location, _, "}"}, [$} | NewRest], Warnings, Tokens} ->
      NewScope = Scope#toxic_tokenizer{warnings=Warnings},
      {EndLine, EndColumn0} = location_end(Location),
      %% Store end meta at the closing '}' column (inclusive like Elixir),
      %% but resume scanning after it.
      ResumeColumn = EndColumn0 + 1,
      Output2 = build_interpol(Line, Column, EndLine, EndColumn0, lists:reverse(Tokens), Output1),
      extract(NewRest, [], Output2, EndLine, ResumeColumn, NewScope, true, Last);
    {error, Reason, _, _, _} ->
      {error, Reason};
    {ok, EndLine, EndColumn, Warnings, Tokens, Terminators} when Scope#toxic_tokenizer.cursor_completion /= false ->
      NewScope = Scope#toxic_tokenizer{warnings=Warnings, cursor_completion=noprune},
      {CursorTerminators, _} = cursor_complete(EndLine, EndColumn, Terminators),
      Output2 = build_interpol(Line, Column, EndLine, EndColumn, lists:reverse(Tokens, CursorTerminators), Output1),
      extract([], [], Output2, EndLine, EndColumn, NewScope, true, Last);
    {ok, _, _, _, _, _} ->
      {error, {string, Line, Column, "missing interpolation terminator: \"}\"", []}}
  end;

extract_single([$\\ | Rest], Buffer, Output, Line, Column, Scope, Interpol, Last) when is_integer(Line), is_integer(Column) ->
  extract_char(Rest, [$\\ | Buffer], Output, Line, Column + 1, Scope, Interpol, Last);

%% Catch all clause

extract_single([Char1, Char2 | Rest], Buffer, Output, Line, Column, Scope, Interpol, Last)
    when Char1 =< 255, Char2 =< 255, is_integer(Line), is_integer(Column) ->
  extract([Char2 | Rest], [Char1 | Buffer], Output, Line, Column + 1, Scope, Interpol, Last);

extract_single(Rest, Buffer, Output, Line, Column, Scope, Interpol, Last) when is_integer(Line), is_integer(Column) ->
  extract_char(Rest, Buffer, Output, Line, Column, Scope, Interpol, Last).

extract_char(Rest, Buffer, Output, Line, Column, Scope, Interpol, Last) ->
  case unicode_util:gc(Rest) of
    [Char | _] when ?bidi(Char) ->
      Token = io_lib:format("\\u~4.16.0B", [Char]),
      Pre = "invalid bidirectional formatting character in string: ",
      Pos = io_lib:format(". If you want to use such character, use it in its escaped ~ts form instead", [Token]),
      {error, {?LOC(Line, Column), {Pre, Pos}, Token}};

    [Char | NewRest] when is_list(Char) ->
      extract(NewRest, lists:reverse(Char, Buffer), Output, Line, Column + 1, Scope, Interpol, Last);

    [Char | NewRest] when is_integer(Char) ->
      extract(NewRest, [Char | Buffer], Output, Line, Column + 1, Scope, Interpol, Last);

    [] ->
      extract([], Buffer, Output, Line, Column, Scope, Interpol, Last)
  end.

%% Handle newlines. Heredocs require special attention

extract_nl(Rest, Buffer, Output, Line, Scope, Interpol, [H,H,H] = Last) ->
  case strip_horizontal_space(Rest, Buffer, 1) of
    {[H,H,H|NewRest], _NewBuffer, Column} ->
      finish_extraction(NewRest, Buffer, Output, Line + 1, Column + 3, Scope);
    {NewRest, NewBuffer, Column} ->
      extract(NewRest, NewBuffer, Output, Line + 1, Column, Scope, Interpol, Last)
  end;
extract_nl(Rest, Buffer, Output, Line, Scope, Interpol, Last) ->
  extract(Rest, Buffer, Output, Line + 1, Scope#toxic_tokenizer.column, Scope, Interpol, Last).

strip_horizontal_space([H | T], Buffer, Counter) when H =:= $\s; H =:= $\t ->
  strip_horizontal_space(T, [H | Buffer], Counter + 1);
strip_horizontal_space(T, Buffer, Counter) ->
  {T, Buffer, Counter}.

strip_horizontal_space_stream([H | T], Acc) when H =:= $\s; H =:= $\t ->
  strip_horizontal_space_stream(T, [H | Acc]);
strip_horizontal_space_stream(T, Acc) ->
  {T, Acc}.

cursor_complete(Line, Column, Terminators) ->
  lists:mapfoldl(
    fun({Start, _, _}, AccColumn) ->
      End = toxic_tokenizer:terminator(Start),
      {{End, {Line, AccColumn, nil}}, AccColumn + length(erlang:atom_to_list(End))}
    end,
    Column,
    Terminators
  ).

%% Unescape a series of tokens as returned by extract.

unescape_tokens(Tokens) ->
  try [unescape_token(Token, fun unescape_map/1) || Token <- Tokens] of
    Unescaped -> {ok, Unescaped}
  catch
    {error, _Reason, _Token} = Error -> Error
  end.

unescape_token(Token, Map) when is_list(Token) ->
  unescape_chars(toxic_utils:characters_to_binary(Token), Map);
unescape_token(Token, Map) when is_binary(Token) ->
  unescape_chars(Token, Map);
unescape_token(Other, _Map) ->
  Other.

% Unescape string. This is called by Elixir. Wrapped by convenience.

unescape_string(String) ->
  unescape_string(String, fun unescape_map/1).

unescape_string(String, Map) ->
  try
    unescape_chars(String, Map)
  catch
    {error, Reason, _} ->
      Message = toxic_utils:characters_to_binary(Reason),
      error('Elixir.ArgumentError':exception([{message, Message}]))
  end.

% Unescape chars. For instance, "\" "n" (two chars) needs to be converted to "\n" (one char).

unescape_chars(String, Map) ->
  unescape_chars(String, Map, <<>>).

unescape_chars(<<$\\, $x, Rest/binary>>, Map, Acc) ->
  case Map(hex) of
    true  -> unescape_hex(Rest, Map, Acc);
    false -> unescape_chars(Rest, Map, <<Acc/binary, $\\, $x>>)
  end;

unescape_chars(<<$\\, $u, Rest/binary>>, Map, Acc) ->
  case Map(unicode) of
    true  -> unescape_unicode(Rest, Map, Acc);
    false -> unescape_chars(Rest, Map, <<Acc/binary, $\\, $u>>)
  end;

unescape_chars(<<$\\, $\n, Rest/binary>>, Map, Acc) ->
  case Map(newline) of
    true  -> unescape_chars(Rest, Map, Acc);
    false -> unescape_chars(Rest, Map, <<Acc/binary, $\\, $\n>>)
  end;

unescape_chars(<<$\\, $\r, $\n, Rest/binary>>, Map, Acc) ->
  case Map(newline) of
    true  -> unescape_chars(Rest, Map, Acc);
    false -> unescape_chars(Rest, Map, <<Acc/binary, $\\, $\r, $\n>>)
  end;

unescape_chars(<<$\\, Escaped, Rest/binary>>, Map, Acc) ->
  case Map(Escaped) of
    false -> unescape_chars(Rest, Map, <<Acc/binary, $\\, Escaped>>);
    Other -> unescape_chars(Rest, Map, <<Acc/binary, Other>>)
  end;

unescape_chars(<<Char, Rest/binary>>, Map, Acc) ->
  unescape_chars(Rest, Map, <<Acc/binary, Char>>);

unescape_chars(<<>>, _Map, Acc) -> Acc.

% Unescape Helpers

unescape_hex(<<A, B, Rest/binary>>, Map, Acc) when ?is_hex(A), ?is_hex(B) ->
  Bytes = list_to_integer([A, B], 16),
  unescape_chars(Rest, Map, <<Acc/binary, Bytes>>);

unescape_hex(<<_/binary>>, _Map, _Acc) ->
  throw({error, "invalid hex escape character, expected \\xHH where H is a hexadecimal digit", "\\x"}).

%% Finish deprecated sequences

unescape_unicode(<<A, B, C, D, Rest/binary>>, Map, Acc) when ?is_hex(A), ?is_hex(B), ?is_hex(C), ?is_hex(D) ->
  append_codepoint(Rest, Map, [A, B, C, D], Acc, 16);

unescape_unicode(<<${, A, $}, Rest/binary>>, Map, Acc) when ?is_hex(A) ->
  append_codepoint(Rest, Map, [A], Acc, 16);

unescape_unicode(<<${, A, B, $}, Rest/binary>>, Map, Acc) when ?is_hex(A), ?is_hex(B) ->
  append_codepoint(Rest, Map, [A, B], Acc, 16);

unescape_unicode(<<${, A, B, C, $}, Rest/binary>>, Map, Acc) when ?is_hex(A), ?is_hex(B), ?is_hex(C) ->
  append_codepoint(Rest, Map, [A, B, C], Acc, 16);

unescape_unicode(<<${, A, B, C, D, $}, Rest/binary>>, Map, Acc) when ?is_hex(A), ?is_hex(B), ?is_hex(C), ?is_hex(D) ->
  append_codepoint(Rest, Map, [A, B, C, D], Acc, 16);

unescape_unicode(<<${, A, B, C, D, E, $}, Rest/binary>>, Map, Acc) when ?is_hex(A), ?is_hex(B), ?is_hex(C), ?is_hex(D), ?is_hex(E) ->
  append_codepoint(Rest, Map, [A, B, C, D, E], Acc, 16);

unescape_unicode(<<${, A, B, C, D, E, F, $}, Rest/binary>>, Map, Acc) when ?is_hex(A), ?is_hex(B), ?is_hex(C), ?is_hex(D), ?is_hex(E), ?is_hex(F) ->
  append_codepoint(Rest, Map, [A, B, C, D, E, F], Acc, 16);

unescape_unicode(<<_/binary>>, _Map, _Acc) ->
  throw({error, "invalid Unicode escape character, expected \\uHHHH or \\u{H*} where H is a hexadecimal digit", "\\u"}).

append_codepoint(Rest, Map, List, Acc, Base) ->
  Codepoint = list_to_integer(List, Base),
  try <<Acc/binary, Codepoint/utf8>> of
    Binary -> unescape_chars(Rest, Map, Binary)
  catch
    error:badarg ->
      throw({error, "invalid or reserved Unicode code point \\u{" ++ List ++ "}", "\\u"})
  end.

unescape_map(newline) -> true;
unescape_map(unicode) -> true;
unescape_map(hex) -> true;
unescape_map($0) -> 0;
unescape_map($a) -> 7;
unescape_map($b) -> $\b;
unescape_map($d) -> $\d;
unescape_map($e) -> $\e;
unescape_map($f) -> $\f;
unescape_map($n) -> $\n;
unescape_map($r) -> $\r;
unescape_map($s) -> $\s;
unescape_map($t) -> $\t;
unescape_map($v) -> $\v;
unescape_map(E)  -> E.

% Extract Helpers

finish_extraction(Remaining, Buffer, Output, Line, Column, Scope) ->
  Final = case build_string(Buffer, Output) of
    [] -> [[]];
    F  -> F
  end,

  {Line, Column, lists:reverse(Final), Remaining, Scope}.

build_string([], Output) -> Output;
build_string(Buffer, Output) -> [lists:reverse(Buffer) | Output].

build_interpol(Line, Column, EndLine, EndColumn, Buffer, Output) ->
  [{{Line, Column, nil}, {EndLine, EndColumn, nil}, Buffer} | Output].

location_end(Location) when is_list(Location) ->
  Line = proplists:get_value(line, Location),
  Col = proplists:get_value(column, Location),
  {Line, Col}.

prepend_warning(Line, Column, Msg, #toxic_tokenizer{warnings=Warnings} = Scope) ->
  Scope#toxic_tokenizer{warnings = [{{Line, Column}, Msg} | Warnings]}.
