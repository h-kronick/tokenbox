// Character sets for the split-flap display — must match native app exactly.

export const DIGIT_SET = [' ', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
export const DOT_SET = [' ', '.'];
export const SUFFIX_SET = [' ', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'K', 'M', 'B', 'T'];
export const ALPHA_SET = [' ', ...Array.from({ length: 26 }, (_, i) => String.fromCharCode(65 + i))];

// Per-position character sets for the 6-module token display rows.
// Adaptive precision means dot can appear at position 2 or 3.
export const TOKEN_POSITION_SETS = [
  DIGIT_SET,   // pos 0: digit
  DIGIT_SET,   // pos 1: digit
  [...DIGIT_SET, '.'],  // pos 2: digit or dot (2-decimal: " 1.00K")
  [...DIGIT_SET, '.'],  // pos 3: digit or dot (1-decimal: "100.0K")
  DIGIT_SET,   // pos 4: digit
  SUFFIX_SET,  // pos 5: digit + K/M/B/T suffix
];

// For label rows (e-ink labels show text like "TODAY", "WEEK", friend names)
export const LABEL_POSITION_SETS = Array(6).fill(ALPHA_SET);
