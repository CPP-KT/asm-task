#!/usr/bin/env python3

import glob
import itertools

def check(filename: str):
    tabs = set()
    prev_no_backslash = False

    with open(filename) as file:
        for line_no, line in enumerate(file, 1):
            right_stripped = line.rstrip()

            trailing_spaces = len(line) - len(right_stripped)
            if line[-trailing_spaces:] != '\n':
                print(f'Extra trailing whitespaces in {filename} on line {line_no}: {repr(line[-trailing_spaces])}')
                exit(1)

            first_non_ws_pos = len(right_stripped) - len(right_stripped.lstrip())
            if first_non_ws_pos == 0:
                prev_no_backslash = True
                continue

            if prev_no_backslash:
                tabs.add(line[:first_non_ws_pos])
            prev_no_backslash = right_stripped[-1] != '\\'

    if len(tabs) > 1:
        print(f'Too many unique tabulation sequences in {filename}:')
        for tab in tabs:
            print(f'\t- {repr(tab)}')
        exit(1)

for filename in itertools.chain(glob.iglob('src/*.asm'), glob.iglob('include/*.inc')):
    check(filename)
