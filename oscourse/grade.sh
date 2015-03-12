#!/bin/bash

RESULT_DIR=$1
LAB=$2

ls -t $RESULT_DIR/*.yaml | while read f; do
    SCORE=`grep -E "^    - '$LAB Score: [0-9]+/[0-9]+'$" $f | grep -E -o "[0-9]+/[0-9]+"`
    if [ -n "$SCORE" ]; then
	echo "100*$SCORE" | bc
	exit 0
    fi
done
