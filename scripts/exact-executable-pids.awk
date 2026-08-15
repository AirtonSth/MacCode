{
  pid = $1
  sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
  if ($0 == executable || index($0, executable " ") == 1) print pid
}
