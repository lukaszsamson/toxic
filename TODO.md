# Tokenizer Range Implementation - Current Status

## Implementation Approach ✅
- Added `produce_ranges` field to `#toxic_tokenizer{}` record
- Added `make_meta(Line, Column, EndLine, EndColumn, Extra, Scope)` function that conditionally produces ranges
- Added `make_meta_len(Line, Column, Len, Extra, Scope)` helper for simple length-based tokens  
- Added `tokenize_with_ranges/4` that forces `produce_ranges=true`
- Added `ranges_to_legacy/1` to convert range tokens back to legacy format

## Conversion Progress

### ✅ Already Converted (using make_meta_len)
- [x] Base integers (hex, binary, octal) - lines 219-232
- [x] Char literals (with and without escape) - lines 258-293  
- [x] Operator atoms (lines 316-341)
- [x] Three/two character operators (lines 344-378)
- [x] Association operator `=>` (line 374-377)
- [x] Identifier `..//` (line 380-387)  
- [x] Container tokens `,`, `<<`, `>>` (lines 420-430)
- [x] Map literal after `%` (line 432-437)
- [x] Parentheses, brackets, braces (lines 440-446)
- [x] Ternary operator `//` (lines 449-452)
- [x] Capture `&` operator (lines 454-506) 
- [x] Atom tokenization (lines 508-591)
- [x] Number tokenization (lines 595-634)
- [x] Semicolon (lines 644-648)
- [x] Map/struct tokens `%`, `%{}` (lines 681-686)
- [x] Dot operator (line 688-689)
- [x] Unary and regular operators (lines 893-938)

### ❌ TODO - Remaining Clauses to Convert
- [ ] **Line 212**: Version control marker `<<<<<<<` 
- [ ] **Line 236**: Comments `#`
- [ ] **Line 247**: Sigils `~`  
- [ ] **Line 297**: Heredocs `"""`
- [ ] **Line 301**: Heredocs `'''`
- [ ] **Line 307**: Strings `"`
- [ ] **Line 311**: Strings `'`
- [ ] **Line 650**: Backslash continuation `\`
- [ ] **Line 654**: Escaped newline `\\n` 
- [ ] **Line 657**: Escaped CRLF `\\r\\n`
- [ ] **Line 660**: Line continuation `\\n` + Rest
- [ ] **Line 663**: Line continuation `\\r\\n` + Rest  
- [ ] **Line 666**: Newline `\\n`
- [ ] **Line 669**: CRLF `\\r\\n`
- [ ] **Line 674**: Map parentheses `%(`
- [ ] **Line 678**: Map brackets `%[`
- [ ] **Lines 692-1542**: Main identifier/catch-all tokenization

### ❌ TODO - Helper Functions to Convert
- [ ] **tokenize_sigil**: Convert to use make_meta_len
- [ ] **handle_strings**: Convert to use make_meta_len  
- [ ] **handle_heredocs**: Convert to use make_meta_len
- [ ] **tokenize_dot**: Convert to use make_meta_len
- [ ] **handle_terminator**: Update to handle range metadata properly

## Next Steps
1. Convert the remaining simple tokenize clauses (version control, comments, etc.)
2. Update helper functions to use make_meta_len appropriately
3. Handle the complex identifier/catch-all tokenization
4. Run tests to verify all conversions work correctly
5. Update tests to use tokenize_with_ranges where needed

## Testing
- Update test helper to use `tokenize_with_ranges` and `ranges_to_legacy` for compatibility
- Verify all existing tests still pass 
- Add specific tests for range functionality