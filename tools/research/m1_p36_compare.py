#!/usr/bin/env python3
"""P36 timed and null phase conservation checker."""
import argparse
import csv
from pathlib import Path


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('null',type=Path)
    parser.add_argument('timed',type=Path)
    parser.add_argument('--min-rounds',type=int,default=3)
    args=parser.parse_args()
    print('P36_COMPARE_PENDING')

if __name__=='__main__':
    main()
