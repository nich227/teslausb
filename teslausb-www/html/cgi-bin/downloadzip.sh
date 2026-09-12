#!/bin/bash

declare -a urlargs
IFS='&' read -r -a urlargs <<<"$QUERY_STRING" 

declare -i len=${#urlargs[@]}
for ((i=0; i<len; i++ ))
do
  val="${urlargs[i]//+/ }"
  urlargs[i]="$(echo -e "${val//%/\\x}")"
done

if ! cd "$DOCUMENT_ROOT/${urlargs[0]}"
then
  echo "HTTP/1.0 200 OK"
  echo "Content-type: text/plain"
  echo
  echo "FAILED"
  exit 1
fi
echo "HTTP/1.0 200 OK"
echo "Content-type: application/zip"
echo
for i in "${urlargs[@]:1}"
do
  echo "$i"
done | zip -r -0 - -@ 2> /tmp/zipout.txt
