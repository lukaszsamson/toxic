defmodule Toxic.Unescape do
  def unescape_map(:newline), do: true
  def unescape_map(:unicode), do: true
  def unescape_map(:hex), do: true
  def unescape_map(?0), do: 0
  def unescape_map(?a), do: 7
  def unescape_map(?b), do: ?\b
  def unescape_map(?d), do: ?\d
  def unescape_map(?e), do: ?\e
  def unescape_map(?f), do: ?\f
  def unescape_map(?n), do: ?\n
  def unescape_map(?r), do: ?\r
  def unescape_map(?s), do: ?\s
  def unescape_map(?t), do: ?\t
  def unescape_map(?v), do: ?\v
  def unescape_map(other), do: other
end
