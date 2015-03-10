#!/bin/bash

OUT="env.txt"

function getversion
{
	printf "%-24s" "$1" >> $OUT
	"$1" --version 2>&1 |head -1 >> $OUT
}

function getversion1
{
	printf "%-24s" "$1" >> $OUT
	"$1" -version 2>&1 |head -1 >> $OUT
}


uname -s -o -m > $OUT
for i in bash make gcc arm-eabi-gcc qemu-system-x86_64 gdb arm-eabi-gdb python
do
	getversion "$i"
done

for i in java emulator-arm
do
	getversion1 "$i"
done

cat $OUT
