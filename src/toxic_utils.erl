%% SPDX-License-Identifier: Apache-2.0
%% SPDX-FileCopyrightText: 2021 The Elixir Team
%% SPDX-FileCopyrightText: 2012 Plataformatec

%% Convenience functions used throughout elixir source code
%% for ast manipulation and querying.
-module(toxic_utils).
-export([characters_to_binary/1]).
% -include("toxic.hrl").

characters_to_binary(Data) when is_binary(Data) ->
  Data;
characters_to_binary(Data) ->
  case unicode:characters_to_binary(Data) of
    Result when is_binary(Result) -> Result;
    {error, Encoded, Rest} -> conversion_error(invalid, Encoded, Rest);
    {incomplete, Encoded, Rest} -> conversion_error(incomplete, Encoded, Rest)
  end.

conversion_error(Kind, Encoded, Rest) ->
  error('Elixir.UnicodeConversionError':exception([{encoded, Encoded}, {rest, Rest}, {kind, Kind}])).
