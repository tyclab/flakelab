# accounts-headroom.jq — the headroom of one usage entry, shared by the
# engine (accounts-auto.jq) and the script (files/scripts/accounts, which
# `include`s it for --soonest/--best, the listing and the poll plan), so the
# two never disagree on what a window means or when an entry is known.
#
# An entry: {windows: [{label, class, pct, resetsAtEpoch}], fetchedAt, ...}.
# $mw is the model-window filter ("all" or a comma list of labels), $now the
# clock in epoch seconds.

# The model windows that count: all, or those whose label is listed.
def counted($mw): if $mw == "all" then . else ($mw | split(",") | map(ascii_downcase)) as $w | select((.label | ascii_downcase) as $l | $w | index($l)) end;
def least(a; b): if a == null then b elif b == null then a elif b < a then b else a end;

# The headroom on each axis (100 - the fullest window of the class), the
# weekly budget (week and counted model), the binding one, the age of the
# figure and whether it is trustworthy: fetched within five minutes with at
# least one window. A tool whose only window is a month (Kiro) is known and
# is never steered on, not unhealthy.
def headroom($now; $mw):
  (.fetchedAt // null) as $f
  | ([.windows[]?] | length) as $nw
  | { session: ([.windows[]? | select(.class == "session") | .pct] | if length == 0 then null else (100 - max) end),
      week:    ([.windows[]? | select(.class == "week")    | .pct] | if length == 0 then null else (100 - max) end),
      month:   ([.windows[]? | select(.class == "month")   | .pct] | if length == 0 then null else (100 - max) end),
      model:   ([.windows[]? | select(.class == "model") | counted($mw) | .pct] | if length == 0 then null else (100 - max) end) }
  | .weekly = least(.week; .model)
  | .binding = least(.session; .weekly)
  | .age = (if $f == null then null else ($now - $f) end)
  | .known = (.age != null and .age <= 300 and $nw > 0);

# The earliest renewal among the weekly windows (week and counted model).
def weeklyReset($mw):
  [.windows[]? | select(.class == "week" or (.class == "model" and (counted($mw) | length > 0))) | .resetsAtEpoch | numbers] | if length == 0 then null else min end;

# The latest reset among the windows at their limit: when the entry is usable again.
def limitingReset:
  [.windows[]? | select(.pct >= 100) | .resetsAtEpoch | numbers] | if length == 0 then null else max end;
