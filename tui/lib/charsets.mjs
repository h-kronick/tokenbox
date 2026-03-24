// Character sets for the split-flap display — must match native app exactly.

export const DIGIT_SET = [' ', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
export const DOT_SET = [' ', '.'];
export const SUFFIX_SET = [' ', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'K', 'M', 'B', 'T'];
export const ALPHA_SET = [' ', ...Array.from({ length: 26 }, (_, i) => String.fromCharCode(65 + i))];

// Per-position character sets for the 7-module token display rows
export const TOKEN_POSITION_SETS = [
  DIGIT_SET,   // pos 0: digit
  DIGIT_SET,   // pos 1: digit
  DIGIT_SET,   // pos 2: digit
  DOT_SET,     // pos 3: space or decimal point
  DIGIT_SET,   // pos 4: digit
  DIGIT_SET,   // pos 5: digit
  SUFFIX_SET,  // pos 6: digit + K/M/B/T suffix
];

// For label rows (e-ink labels show text like "TODAY", "WEEK", friend names)
export const LABEL_POSITION_SETS = Array(7).fill(ALPHA_SET);
