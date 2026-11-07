# merge3.jq - per-key three-way decision for a merged JSON file.
#
# Run by records_merge3 with $base, $new, $live and $review from --slurpfile: the repo
# copy, the repo now, the live file and the review copy. Prints
#   {live, repo, review, conflicts, applied}
# where conflicts and applied are arrays of path arrays.
#
# A leaf is any non-object value, arrays included, so an array is one value. Empty
# objects manage nothing. Paths are arrays, so a key "a.b" and a -> b stay distinct.
#
# Values are compared wrapped: [] is absent and [x] is x, because a key holding null,
# false or 0 is not the same as no key. jq's == ignores object key order.

# The wrapped value at path $p, going through objects only
def at($p):
  if ($p | length) == 0 then [.]
  elif type == "object" and has($p[0]) then .[$p[0]] | at($p[1:])
  else [] end;

# Every leaf path
def leaves:
  def walk_from($p):
    if type == "object" then
      to_entries[] | .key as $k | .value | walk_from($p + [$k])
    else $p end;
  walk_from([]);

def plain_at($p): at($p) | length == 1 and (.[0] | type) != "object";

def is_prefix($a; $b): $b[:($a | length)] == $a;

# The shortest proper prefix of $p that blocks it: a plain value in live, or a place
# where the repo changed between a plain value and an object. Whether a prefix blocks
# doesn't depend on $p, so everything under it reports that same topmost path, and no
# conflict is ever nested inside another.
def blocked_at($p; $base; $new; $live):
  first(
    range(1; $p | length) as $i
    | $p[:$i] as $q
    | select(
        ($live | plain_at($q))
        or (($new | plain_at($q)) != ($base | plain_at($q)))
      )
    | $q
  );

# Set a value, replacing anything plain in the way: only the review copy can have that,
# since a plain value in live blocks the path.
def set_at($p; $x):
  if ($p | length) == 0 then $x
  else
    (if type == "object" then . else {} end)
    | .[$p[0]] |= set_at($p[1:]; $x)
  end;

def delete_at($p):
  if (at($p) | length) == 1 then delpaths([$p]) else . end;

# Apply a wrapped value: [x] sets, [] deletes
def put_at($p; $w):
  if ($w | length) == 1 then set_at($p; $w[0]) else delete_at($p) end;

def check_object($name):
  if length != 1 or (.[0] | type) != "object" then
    error("\($name) is not a single JSON object")
  else .[0] end;

($base   | check_object("repo copy")) as $base
| ($new    | check_object("new repo version")) as $new
| ($live   | check_object("live file")) as $live
| ($review | check_object("review copy")) as $review
| ([$base, $new | leaves] | unique) as $paths
| ([ $paths[] as $p
     | ($base | at($p)) as $b | ($new | at($p)) as $n | ($live | at($p)) as $l
     | blocked_at($p; $base; $new; $live) // (if $n != $b and $l != $b and $l != $n then $p else empty end)
   ] | unique) as $conflicts
| ($conflicts | map(. as $c | $base | at($c) | [$c, .])) as $held
| reduce ($paths[] as $p
          | select(any($conflicts[]; is_prefix(.; $p)) | not)
          | $p) as $p
    ({live: $live, review: $review, applied: []};
     ($base | at($p)) as $b | ($new | at($p)) as $n | (.live | at($p)) as $l
     | if $n == $b then .
       elif $l == $b then
         .live |= put_at($p; $n)
         | .review |= put_at($p; $n)
         | .applied += [$p]
       elif $l == $n then
         .review |= put_at($p; $n)
       else . end)
| {
    live: .live,
    repo: (reduce $held[] as $h ($new; put_at($h[0]; $h[1]))),
    review: .review,
    conflicts: $conflicts,
    applied: .applied
  }
