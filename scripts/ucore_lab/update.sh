#!/bin/bash

DIR=`realpath $0 | xargs dirname`
REPO=$1

update_file() {
    file=$1

    if ! diff "$DIR/$file" "$REPO/$file" > /dev/null 2>&1; then
	cp $DIR/$file $REPO/$file
    fi
}

# sanity checks
if [ ! -d "$REPO/labcodes" ] ||
    [ ! -d "$REPO/labcodes_answer" ] ||
    [ ! -d "$REPO/related_info" ] ; then
    exit 0
fi

for f in `find $DIR -type f`; do
    relname=${f#$DIR/}
    if [ "$relname" == "update.sh" ]; then
	continue
    fi
    update_file "$relname"
done
