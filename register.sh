#!/bin/bash

REG_QUEUE=$1
if [ ! -f $REG_QUEUE ]; then
    exit 1
fi

RND=$RANDOM

mv $REG_QUEUE $REG_QUEUE.$RND

sort $REG_QUEUE.$RND | uniq | while read line; do
    IFS="|" read -a array <<< "$line"
    repo="${array[0]}"
    email="${array[1]}"

    # Do we have this repo already registered?
    if grep -q "$email:${repo##*/}" config.yaml; then
	echo "DUP|$line"
	continue
    fi

    # Does this mail still have tickets?
    if ! ticket_mgmt/ticket consume "$email"; then
	if ! ticket_mgmt/ticket user "$email"; then
	    echo "NOUSER|$line"
	else
	    echo "NOTICKET|$line"
	fi
	continue
    fi

    # Is the repo a valid one?
    rm -rf /tmp/.repo
    if ! timeout 3m git clone -q "$repo" /tmp/.repo; then
	echo "NOREPO|$line"
	ticket_mgmt/ticket free $email
	continue
    fi

    pushd /tmp/.repo > /dev/null
    head_email=`git show HEAD -s --pretty=format:%ce`
    if [ "$email" != "$head_email" ]; then
	echo "NOMAIL|$line"
	popd > /dev/null
	ticket_mgmt/ticket free $email
	continue
    fi
    popd > /dev/null

    echo "OK|$line"
done

rm $REG_QUEUE.$RND
