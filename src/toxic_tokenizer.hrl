%% SPDX-License-Identifier: Apache-2.0
%% SPDX-FileCopyrightText: 2021 The Elixir Team

%% Driver state record for streaming tokenizer
%% Maintains single-token scanning state with position tracking
-record(toxic_driver, {
  source :: binary() | function(),  % input source
  offset = 0 :: non_neg_integer(),  % byte offset into source
  line = 1 :: pos_integer(),        % current line (exclusive end)  
  column = 1 :: pos_integer(),      % current column (exclusive end)
  scope :: #toxic_tokenizer{},      % tokenizer configuration and state
  mode = normal :: normal | {interp, atom(), atom(), atom(), term()}, % parsing mode stack
  error_mode = tolerant :: strict | tolerant, % error handling mode
  error_sync = [semicolon, newline, closer] :: [atom()], % sync points for error recovery
  lookahead_cache = [] :: [term()], % small buffer for multi-char ops and rewrites
  eof = false :: boolean()          % end of file reached
}).

%% Type definition for the driver record
-type toxic_driver() :: #toxic_driver{}.

%% Numbers
-define(is_hex(S), (?is_digit(S) orelse (S >= $A andalso S =< $F) orelse (S >= $a andalso S =< $f))).
-define(is_bin(S), (S >= $0 andalso S =< $1)).
-define(is_octal(S), (S >= $0 andalso S =< $7)).

%% Digits and letters
-define(is_digit(S), (S >= $0 andalso S =< $9)).
-define(is_upcase(S), (S >= $A andalso S =< $Z)).
-define(is_downcase(S), (S >= $a andalso S =< $z)).

%% Others
-define(is_quote(S), (S =:= $" orelse S =:= $')).
-define(is_sigil(S), (S =:= $/ orelse S =:= $< orelse S =:= $" orelse S =:= $' orelse
                      S =:= $[ orelse S =:= $( orelse S =:= ${ orelse S =:= $|)).
-define(LOC(Line, Column), [{line, Line}, {column, Column}]).

%% Spaces
-define(is_horizontal_space(S), (S =:= $\s orelse S =:= $\t)).
-define(is_vertical_space(S), (S =:= $\r orelse S =:= $\n)).
-define(is_space(S), (?is_horizontal_space(S) orelse ?is_vertical_space(S))).

%% Bidirectional control
%% Retrieved from https://trojansource.codes/trojan-source.pdf
-define(bidi(C), C =:= 16#202A;
                 C =:= 16#202B;
                 C =:= 16#202D;
                 C =:= 16#202E;
                 C =:= 16#2066;
                 C =:= 16#2067;
                 C =:= 16#2068;
                 C =:= 16#202C;
                 C =:= 16#2069).
