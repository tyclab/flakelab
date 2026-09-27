# accounts-time.jq — one reset stamp into an epoch, shared by the adapters
# and the statusline ingest. The tools disagree on the shape: Claude's
# endpoint sends "2026-09-30T23:00:00.491236+00:00" (an offset, never Z),
# Codex an epoch in seconds, the statusline an epoch in seconds, a fixture
# "…Z". jq's fromdateiso8601 reads only the Z form, so the offset is applied
# by hand. null for anything else.

def stamp_epoch:
  if . == null then null
  elif type == "number" then (if . > 100000000000 then (. / 1000 | floor) else floor end)
  elif type == "string" then
    (sub("\\.[0-9]+"; "")) as $s
    | ([$s | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<tz>Z|[+-][0-9]{2}:[0-9]{2})?$")] | .[0]) as $c
    | if $c == null then ($s | tonumber? // null)
      else
        (try ($c.base + "Z" | fromdateiso8601) catch null) as $b
        | if $b == null then null
          elif ($c.tz // "Z") == "Z" then $b
          else ([$c.tz | capture("^(?<sign>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$")] | .[0]) as $o
            | $b - (if $o.sign == "+" then 1 else -1 end) * (($o.h | tonumber) * 3600 + ($o.m | tonumber) * 60)
          end
      end
  else null end;
