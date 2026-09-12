/* SPDX-License-Identifier: Unlicense */
struct Sample { char tag; int count; double value; };
struct Packed { char tag; int count; } __attribute__((packed));
typedef unsigned long Count;
#define SAMPLE_NUMBER 42
