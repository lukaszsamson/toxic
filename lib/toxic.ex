defmodule Toxic do
  @moduledoc """
  Top-level API for the Toxic streaming lexer.

  Delegates directly to `Toxic.TokenStream` while keeping the implementation
  module private. This module exposes the familiar streaming operations needed
  by Pratt parsers, editor integrations, and tolerant mode consumers.
  """

  alias Toxic.TokenStream

  @doc "Create a new token stream (`Toxic.TokenStream.new/4`)."
  @spec new(TokenStream.source(), pos_integer(), pos_integer(), TokenStream.options()) ::
          TokenStream.t()
  defdelegate new(source, line \\ 1, column \\ 1, opts \\ []), to: TokenStream

  @doc "Return the next token from the stream (`Toxic.TokenStream.next/1`)."
  @spec next(TokenStream.t()) ::
          {:ok, TokenStream.token(), TokenStream.t()}
          | {:eof, TokenStream.t()}
          | {:error, Toxic.Error.t(), TokenStream.t()}
  defdelegate next(stream), to: TokenStream

  @doc "Peek at the next token without consuming it (`Toxic.TokenStream.peek/1`)."
  @spec peek(TokenStream.t()) ::
          {:ok, TokenStream.token(), TokenStream.t()}
          | {:eof, TokenStream.t()}
          | {:error, Toxic.Error.t(), TokenStream.t()}
  defdelegate peek(stream), to: TokenStream

  @doc "Peek at the next `n` tokens (`Toxic.TokenStream.peek_n/2`)."
  @spec peek_n(TokenStream.t(), pos_integer()) ::
          {:ok, [TokenStream.token()], TokenStream.t()}
          | {:eof, [TokenStream.token()], TokenStream.t()}
          | {:error, Toxic.Error.t(), [TokenStream.token()], TokenStream.t()}
  defdelegate peek_n(stream, n), to: TokenStream

  @doc "Push a token back onto the stream (`Toxic.TokenStream.pushback/2`)."
  @spec pushback(TokenStream.t(), TokenStream.token()) :: TokenStream.t()
  defdelegate pushback(stream, token), to: TokenStream

  @doc "Create a checkpoint for backtracking (`Toxic.TokenStream.checkpoint/1`)."
  @spec checkpoint(TokenStream.t()) :: {reference(), TokenStream.t()}
  defdelegate checkpoint(stream), to: TokenStream

  @doc "Rewind to a checkpoint (`Toxic.TokenStream.rewind_to/3`)."
  @spec rewind_to(TokenStream.t(), reference(), boolean()) :: TokenStream.t()
  defdelegate rewind_to(stream, ref, delete_checkpoint? \\ true), to: TokenStream

  @doc "Convert the stream into an Elixir `Stream` (`Toxic.TokenStream.to_stream/1`)."
  @spec to_stream(TokenStream.t()) :: Enumerable.t()
  defdelegate to_stream(stream), to: TokenStream

  @doc "Slice the source and create a fresh stream (`Toxic.TokenStream.slice/6`)."
  @spec slice(
          TokenStream.source(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          TokenStream.options()
        ) :: TokenStream.t()
  defdelegate slice(source, start_offset, end_offset, line_base, column_base, opts \\ []),
    to: TokenStream

  @doc "Get the current terminator stack (`Toxic.TokenStream.current_terminators/1`)."
  @spec current_terminators(TokenStream.t()) :: {TokenStream.terminator_stack(), TokenStream.t()}
  defdelegate current_terminators(stream), to: TokenStream

  @doc "Peek at the next missing terminator (`Toxic.TokenStream.peek_missing_terminator/1`)."
  @spec peek_missing_terminator(TokenStream.t()) :: {atom() | nil, TokenStream.t()}
  defdelegate peek_missing_terminator(stream), to: TokenStream

  @doc "Retrieve accumulated warnings (`Toxic.TokenStream.warnings/1`)."
  @spec warnings(TokenStream.t()) :: {[Toxic.Warning.t()], TokenStream.t()}
  defdelegate warnings(stream), to: TokenStream

  @doc "Collect emitted error tokens (`Toxic.TokenStream.errors/1`)."
  @spec errors(TokenStream.t()) ::
          {[{TokenStream.error_entry(), Toxic.Error.t()}], TokenStream.t()}
  defdelegate errors(stream), to: TokenStream

  @doc "Get the current absolute position (`Toxic.TokenStream.position/1`)."
  @spec position(TokenStream.t()) :: {{pos_integer(), pos_integer()}, TokenStream.t()}
  defdelegate position(stream), to: TokenStream
end
