#!/bin/bash

# Find the digraph leaks part and chop it out by looking for a lowering
# in indentation relative to the head.
awk '
  !f && /^[ \t]*digraph leaks \{/ { f=1; match($0, /^[ \t]*/); ind=substr($0,1,RLENGTH) }
  f { print }
  f && $0 ~ "^" ind "\\}[ \t]*$" {exit}
' | dot -Tsvg
