# accounts-auto.jq — the auto-switch engine (accounts.md, "Auto-switch").
#
# One pure function over one document: no I/O, no clock of its own, no idea
# which tool it is deciding for beyond the tool's name in the input. The
# script around it (files/scripts/accounts, cmd_auto) reads the roster, the
# usage cache and the engine state, runs this twice — pass "plan" to learn
# what to fetch, pass "decide" on the fresh document — then freshens and
# switches, writes the state back and logs the events.
#
# Input:
#   {pass: "plan"|"decide", tool, now (epoch s),
#    settings: {sessionThreshold, weekThreshold, modelThreshold, cooldownS,
#               hysteresisPct, unhealthyTicks, idleHoldS, strategy, modelWindows},
#    roster: {active: {tool: id}, accounts: {id: {tool, disabled, ...}}},
#    usage:  {entries: {id: {windows, fetchedAt, nextPollAt, backoffUntil}}, quarantine: {id: {...}}},
#    state:  {lastSwitchAt, lastSwitchTo, unhealthyTicks: {tool: n}, idleHoldSince: {tool: epoch}},
#    live:   {id: true}          entries running a profile session (never targets)
#    activeTokenExpired: bool    the live token is expired on disk and no session runs
#    liveUnmanaged: bool         a live login no entry carries}
#
# Output:
#   {fetch: [ids], decision: {action: "switch"|"none"|"blocked"|"fetch",
#            trigger, axis, reason, detail, candidates: [ids in order]},
#    events: [{event, ...}], state: {...}}
#
# The rules, in the order accounts.md gives them: no active entry; three bars,
# one per window class, the costliest window over its bar deciding; the
# trigger (proactive, at-limit, failover, with the idle hold); the cooldown,
# proactive only; the candidates and the two proactive gates; the order.

def counted($mw): if $mw == "all" then . else ($mw | split(",") | map(ascii_downcase)) as $w | select((.label | ascii_downcase) as $l | $w | index($l)) end;
def least(a; b): if a == null then b elif b == null then a elif b < a then b else a end;

# The headroom of a usage entry on each axis, and whether it is trustworthy.
def headroom($now; $mw):
  (.fetchedAt // null) as $f
  | { session: ([.windows[]? | select(.class == "session") | .pct] | if length == 0 then null else (100 - max) end),
      week:    ([.windows[]? | select(.class == "week")    | .pct] | if length == 0 then null else (100 - max) end),
      model:   ([.windows[]? | select(.class == "model") | counted($mw) | .pct] | if length == 0 then null else (100 - max) end) }
  | .weekly = least(.week; .model)
  | .binding = least(.session; .weekly)
  | .age = (if $f == null then null else ($now - $f) end)
  | .known = (.binding != null and .age != null and .age <= 300);

# The earliest renewal among the weekly windows (week and counted model).
def weeklyReset($mw):
  [.windows[]? | select(.class == "week" or (.class == "model" and (counted($mw) | length > 0))) | .resetsAtEpoch | numbers] | if length == 0 then null else min end;

# The latest reset among the windows at their limit: when the entry is usable again.
def limitingReset:
  [.windows[]? | select(.pct >= 100) | .resetsAtEpoch | numbers] | if length == 0 then null else max end;

. as $in
| $in.settings as $s
| $in.now as $now
| ($in.roster.active[$in.tool] // null) as $active
| ($in.roster.accounts | to_entries | map(select(.value.tool == $in.tool)) | map({id: (.key | tonumber), key: .key, disabled: (.value.disabled // false)})) as $entries
| ($entries | map(select(.disabled | not) | select(.id != $active) | select(($in.usage.quarantine[.key] // null) == null) | select(($in.live[.key] // false) | not)) | map(.id)) as $candidateIds
| (if $active == null then {} else ($in.usage.entries[($active | tostring)] // {}) end) as $activeUsage
| ($activeUsage | headroom($now; $s.modelWindows)) as $ah
| {session: $s.sessionThreshold, week: $s.weekThreshold, model: $s.modelThreshold} as $bars
# The costliest axis at or over its bar, week first; null when none is.
| ( [ ["week", $ah.week], ["model", $ah.model], ["session", $ah.session] ]
    | map(select(.[1] != null) | select((100 - .[1]) >= $bars[.[0]])) | .[0][0] // null ) as $decidingAxis
| ( [ ["week", $ah.week], ["model", $ah.model], ["session", $ah.session] ]
    | map(select(.[1] != null) | select(.[1] <= 0)) | .[0][0] // null ) as $limitAxis
# The window closest to its own bar, for the below-threshold detail.
| ( [ ["session", $ah.session], ["week", $ah.week], ["model", $ah.model] ]
    | map(select(.[1] != null) | {axis: .[0], pct: (100 - .[1]), bar: $bars[.[0]], gap: ($bars[.[0]] - (100 - .[1]))})
    | sort_by(.gap) | .[0] // null ) as $closest
| (($in.state.unhealthyTicks // {})[$in.tool] // 0) as $unhealthy
| (($in.state.idleHoldSince // {})[$in.tool] // null) as $idleSince
| ($in.state.lastSwitchAt // null) as $lastSwitch
| {fetch: [], events: [], state: $in.state, decision: {action: "none", trigger: null, axis: null, reason: null, detail: null, candidates: []}}

# --- pass "plan": what to fetch before deciding -----------------------------
| if $in.pass == "plan" then
    if $active == null then .
    else
      # The active entry when due or never fetched; one due candidate; every
      # candidate when the active entry is unknown or within 15 points of a
      # bar on any axis (escalation), so a switch never rests on stale data.
      (($activeUsage.nextPollAt // 0) <= $now) as $activeDue
      | ( [ ["session", $ah.session], ["week", $ah.week], ["model", $ah.model] ]
          | map(select(.[1] != null) | select((100 - .[1]) >= $bars[.[0]] - 15)) | length > 0 ) as $near
      | ($ah.known | not) as $unknown
      | ($candidateIds | map(select((($in.usage.entries[(. | tostring)] // {}).nextPollAt // 0) <= $now))) as $dueCandidates
      | .fetch = ((if $activeDue then [$active] else [] end)
                  + (if ($unknown and ($in.activeTokenExpired | not)) or $near then $candidateIds else ($dueCandidates | .[0:1]) end))
      | .decision.action = "fetch"
    end

# --- pass "decide" --------------------------------------------------------------
  else
    if $active == null then
      .decision.reason = (if $in.liveUnmanaged then "unmanaged-active" else "no-active" end)
      | .decision.detail = ("run: flakelab accounts add " + $in.tool)
      | .events += [{event: "no-switch", reason: .decision.reason, detail: .decision.detail}]
    else
      .events += [{event: "poll", active: $active, headroom: {session: $ah.session, week: $ah.week, model: $ah.model}, known: $ah.known, bars: $bars}]
      # 1. The trigger.
      | ( if $ah.known then
            .state.unhealthyTicks[$in.tool] = 0 | .state.idleHoldSince[$in.tool] = null
            | if $limitAxis != null then .decision.trigger = "at-limit" | .decision.axis = $limitAxis
              elif $decidingAxis != null then .decision.trigger = "proactive" | .decision.axis = $decidingAxis
              else .decision.reason = "below-threshold"
                 | .decision.detail = (if $closest then "\($closest.axis) \($closest.pct | floor)% < \($closest.bar)%" else "no window reported" end)
              end
          elif $in.activeTokenExpired and ($idleSince == null or ($now - $idleSince) <= $s.idleHoldS) then
            .state.idleHoldSince[$in.tool] = ($idleSince // $now) | .state.unhealthyTicks[$in.tool] = 0
            | .decision.reason = "active-idle" | .decision.detail = "token expired while the tool is idle; resumes on next use"
          else
            .state.idleHoldSince[$in.tool] = null
            | ($unhealthy + 1) as $n
            | .state.unhealthyTicks[$in.tool] = $n
            | if $n < $s.unhealthyTicks then .decision.reason = "active-usage-unknown" | .decision.detail = "\($n)/\($s.unhealthyTicks) before failover"
              else .decision.trigger = "failover" | .decision.axis = null end
          end )
      | if .decision.trigger == null then
          .events += [{event: "no-switch", reason: .decision.reason, detail: .decision.detail}]
        # 2. The cooldown, proactive only.
        elif .decision.trigger == "proactive" and $lastSwitch != null and ($now - $lastSwitch) < $s.cooldownS then
          .decision.trigger = null | .decision.reason = "cooldown" | .decision.detail = "\($s.cooldownS - ($now - $lastSwitch))s left"
          | .events += [{event: "no-switch", reason: "cooldown", detail: .decision.detail}]
        else
          .decision.trigger as $trigger
          | .decision.axis as $axis
          # 3. The candidates: known usage, weekly budget left, and for a
          # proactive move the two gates on the deciding axis.
          | ($candidateIds | map(
                . as $id | ($in.usage.entries[($id | tostring)] // {}) as $u | ($u | headroom($now; $s.modelWindows)) as $h
                | {id: $id, h: $h, known: $h.known,
                   spent: ($h.weekly != null and $h.weekly <= 0),
                   weeklyReset: ($u | weeklyReset($s.modelWindows)),
                   usable: ($u | limitingReset)}
                | .qualifies = (
                    .known and (.spent | not)
                    and (if $trigger == "proactive" then
                           ($h[$axis] != null) and ((100 - $h[$axis]) < $bars[$axis]) and (($ah[$axis] != null) and ($h[$axis] - $ah[$axis] >= $s.hysteresisPct))
                         else true end)))) as $cands
          | ($cands | map(select(.qualifies))) as $qualifying
          | if ($candidateIds | length) == 0 then
              .decision.action = "blocked" | .decision.reason = "no-candidates" | .decision.detail = "no other enabled entry of \($in.tool) without a quarantine or a live session"
            elif ($cands | map(select(.known)) | length) == 0 then
              .decision.action = "blocked" | .decision.reason = "no-comparison" | .decision.detail = "no candidate has readable usage"
            elif ($qualifying | length) == 0 then
              if ($cands | map(select(.known)) | all(.spent)) then
                .decision.action = "blocked" | .decision.reason = "all-exhausted"
                | .decision.detail = (([$cands[] | select(.known) | .weeklyReset | numbers] | if length == 0 then null else min end) as $r | if $r then "earliest weekly renewal at \($r | todate)" else "no renewal time known" end)
                | .decision.earliestResetAt = ([$cands[] | select(.known) | .weeklyReset | numbers] | if length == 0 then null else min end)
              else
                .decision.action = "blocked" | .decision.reason = "no-qualifying-candidate"
                | .decision.detail = "no candidate is under the \($axis // "deciding") bar and better than the active entry by \($s.hysteresisPct) points, or its usage is unreadable this tick"
              end
            else
              # 4. The order: earliest weekly renewal, or most weekly headroom;
              # under soonest-reset an entry over a bar still goes after every
              # entry under it.
              .decision.action = "switch"
              | .decision.candidates = (
                  if $s.strategy == "best" then ($qualifying | sort_by(-(.h.weekly // .h.binding), .id) | map(.id))
                  else ($qualifying
                        | map(.over = (([ ["week", .h.week], ["model", .h.model], ["session", .h.session] ] | map(select(.[1] != null) | select((100 - .[1]) >= $bars[.[0]])) | length) > 0))
                        | sort_by((if .over then 1 else 0 end), (.weeklyReset // 9999999999), .id) | map(.id))
                  end)
            end
          | if .decision.action == "blocked" then .events += [{event: "blocked", reason: .decision.reason, detail: .decision.detail}] else . end
        end
    end
  end
