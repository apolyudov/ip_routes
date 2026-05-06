#!/bin/bash

awk -F'[./]' '{printf "%03d.%03d.%03d.%03d/%02d %s\n", $1, $2, $3, $4, $5, $0}' \
    | sort -u \
    | sed 's/^[^ ]* //'
