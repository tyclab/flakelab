# Keep personal text byte-for-byte, including a missing final newline or
# an unfinished marker block. Only a complete flakelab block belongs to us.
{
  marker = $0
  sub(/\r$/, "", marker)
  if (marker == "<!-- BEGIN managed by flakelab -->") {
    printf "%s", pending
    pending = $0 RT
  } else if (pending != "") {
    if (marker == "<!-- END managed by flakelab -->") pending = ""
    else pending = pending $0 RT
  } else {
    printf "%s%s", $0, RT
  }
}
END { printf "%s", pending }
