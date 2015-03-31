#!/bin/bash

DIR=`realpath $0 | xargs dirname`
REPO=`pwd`

if [ ! -d "$REPO/.git" ]; then
    exit 1
fi

for project in $DIR/*; do
    if [ ! -d $project ]; then
	continue
    fi

    $project/update.sh $REPO
done
