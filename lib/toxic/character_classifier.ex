defmodule Toxic.CharacterClassifier do
  # Digits and letters
  defguard is_digit(s) when s in ?0..?9
  defguard is_upcase(s) when s in ?A..?Z
  defguard is_downcase(s) when s in ?a..?z

  # Numbers
  defguard is_hex(s) when is_digit(s) or s in ?A..?F or s in ?a..?f
  defguard is_bin(s) when s in ?0..?1
  defguard is_octal(s) when s in ?0..?7

  # Others
  defguard is_quote(s) when s in [?", ?']
  defguard is_sigil(s) when s in [?/, ?<, ?", ?', ?[, ?(, ?{, ?|]

  # Spaces
  defguard is_horizontal_space(s) when s in [?\s, ?\t]
  defguard is_vertical_space(s) when s in [?\r, ?\n]
  defguard is_space(s) when is_horizontal_space(s) or is_vertical_space(s)

  # Bidirectional control
  # Retrieved from https://trojansource.codes/trojan-source.pdf
  defguard bidi(c)
           when c in [
                  0x202A,
                  0x202B,
                  0x202D,
                  0x202E,
                  0x2066,
                  0x2067,
                  0x2068,
                  0x202C,
                  0x2069
                ]

  # Unsupported newlines
  # https://www.unicode.org/reports/tr55/
  defguard break(c) when c in [0x000B, 0x000C, 0x0085, 0x2028, 0x2029]
end
