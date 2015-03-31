#!/bin/bash

ABS_PATH=`realpath $0`
ABS_DIR=`dirname $ABS_PATH`
REQUEST=$ABS_DIR/request_mgmt/request

REQUEST_QUEUE=$1
$REQUEST fetch $REQUEST_QUEUE | sort | uniq | while read line; do
    IFS="|" read -a array <<< "$line"
    repo="${array[0]}"
    email="${array[1]}"
    is_public="${array[2]}"
    trusted="${array[3]}"

    # Trusted repos
    if [ "$trusted" = "1" ]; then
	echo "OK|$line"
	continue
    fi

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

$REQUEST archive-unique $REQUEST_QUEUE
