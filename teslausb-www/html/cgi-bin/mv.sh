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
  cat << EOF
HTTP/1.0 200 OK
Content-type: text/plain

FAILED
EOF
  exit 1
fi

cat << EOF
HTTP/1.0 200 OK
Content-type: text/plain

EOF
if mv "${urlargs[@]:1}"  &> /dev/null
then
  echo OK
else
  echo FAILED
fi
