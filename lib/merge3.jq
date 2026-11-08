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

# The shortest proper prefix of $p where the files disagree on object versus plain
# value: a plain value in live, or a place where the repo changed between the two.
# Whether a prefix counts doesn't depend on $p, so everything under it reports that same
# topmost path, and no such path is nested inside another.
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

# Apply a repo change to an untouched key. A removal also takes the parents it empties, or
# they'd stay as an empty object the repo doesn't have, and be listed as a local difference.
# A parent with anything else in it stays, and so does one the repo still has.
def apply_at($p; $w; $new):
  put_at($p; $w)
  | if ($w | length) == 1 then .
    else
      reduce range(($p | length) - 1; 0; -1) as $i (.;
        if at($p[:$i]) == [{}] and ($new | at($p[:$i])) == []
        then delpaths([$p[:$i]]) else . end)
    end;

def check_object($name):
  if length != 1 or (.[0] | type) != "object" then
    error("\($name) is not a single JSON object")
  else .[0] end;

($base   | check_object("repo copy")) as $base
| ($new    | check_object("new repo version")) as $new
| ($live   | check_object("live file")) as $live
| ($review | check_object("review copy")) as $review
| ([$base, $new | leaves] | unique) as $paths
| ([ $paths[] as $p | blocked_at($p; $base; $new; $live) ] | unique) as $tops
| ($paths | map(. as $p | select(any($tops[]; is_prefix(.; $p)) | not))) as $rest
# At a mismatch the whole values decide: repo unchanged keeps yours, and live already
# matching the repo updates records only, so neither is a conflict.
| ($tops | map(. as $t | select(($new | at($t)) != ($base | at($t))))) as $moved
| ($moved | map(. as $t | select(($live | at($t)) == ($new | at($t))))) as $agreed
| (($moved - $agreed)
   + [ $rest[] as $p
       | ($base | at($p)) as $b | ($new | at($p)) as $n | ($live | at($p)) as $l
       | select($n != $b and $l != $b and $l != $n)
       | $p
     ]
   | unique) as $conflicts
| ($conflicts | map(. as $c | $base | at($c) | [$c, .])) as $held
| (reduce $agreed[] as $t ($review; put_at($t; $new | at($t)))) as $review
| reduce ($rest[] as $p
          | select(any($conflicts[]; . == $p) | not)
          | $p) as $p
    ({live: $live, review: $review, applied: []};
     ($base | at($p)) as $b | ($new | at($p)) as $n | (.live | at($p)) as $l
     | if $n == $b then .
       elif $l == $b then
         .live |= apply_at($p; $n; $new)
         | .review |= apply_at($p; $n; $new)
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
