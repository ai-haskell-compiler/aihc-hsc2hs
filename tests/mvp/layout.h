/* SPDX-License-Identifier: Unlicense */
struct Sample { char tag; int count; double value; };
struct Packed { char tag; int count; } __attribute__((packed));
typedef unsigned long Count;
#define SAMPLE_NUMBER 42
#define MODE_READ_WRITE 3
enum Colour { COLOUR_RED, COLOUR_GREEN, COLOUR_BLUE };
