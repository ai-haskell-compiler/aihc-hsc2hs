/* SPDX-License-Identifier: Unlicense */
struct Sample { char tag; int count; double value; };
struct Packed { char tag; int count; } __attribute__((packed));
typedef unsigned long Count;
#define SAMPLE_NUMBER 42
#define MODE_READ_WRITE 3
enum Colour { COLOUR_RED, COLOUR_GREEN, COLOUR_BLUE };
#define SAMPLE_TEXT "plain text"
#define ESCAPED_TEXT "a\"b\\c"
#define BINARY_TEXT "x\x01" "9y\x7f" "\xff\x80"
#define EMPTY_TEXT ""
#define TERMINATED_TEXT "ab\0cd"
