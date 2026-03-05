#!/usr/bin/env nu

# Bounty-Crawler — v2.0 generator
# Produces an append-only algora-bounties.json with 3-tier health + monetizability metrics.
# Schema is canonically defined in schema.ncl at the project root.

# Valid bounty statuses (from schema.ncl):
#   open      = posted bounty, no activity
#   triage    = has comments, no attempts
#   active    = has attempts
#   submitted = has assignee (PR claimed)
#   smelly    = comments > 0, no attempts, open > 30 days
#   stinks    = (reserved for PR + stalled; not yet derivable from API alone)
#   stale     = attempts but no PR claim (same as active for now)
#   completed = issue closed + PR merged

const OUTPUT_FILE = "algora-bounties.json"

# ─── Auth check ─────────────────────────────────────────────────────────────

try {
  gh auth status
} catch {
  print -e "Error: gh auth is not configured. Run `gh auth login` first."
  exit 1
}

let current_time = (date now | format date "%Y-%m-%dT%H:%M:%S%:z")

# ─── Pure helpers: score formulas (match schema.ncl exactly) ────────────────

def clamp [val: float, lo: float, hi: float]: nothing -> float {
  if $val < $lo { $lo } else if $val > $hi { $hi } else { $val }
}

def compute-bounty-monetizability [
  reward_val: float,
  attempts: int,
  days_open: float,
  assignee: any
]: nothing -> float {
  let freshness = (
    if $days_open < 14 { 1.0 }
    else if $days_open < 60 { 0.7 }
    else if $days_open < 180 { 0.4 }
    else { 0.15 }
  )
  let assignee_penalty = (if $assignee != null { -0.3 } else { 0.0 })
  let base = (
    0.40 * ($reward_val / 2000.0)
    + 0.35 * (1.0 / (1.0 + $attempts))
    + 0.20 * $freshness
    + $assignee_penalty
  )
  clamp $base 0.0 1.0
}

def compute-repo-health [
  stars: int,
  forks: int,
  velocity: int,
  days_since_push: float,
  completion_rate: float
]: nothing -> float {
  let freshness_n = (
    if $days_since_push < 30 { 1.0 }
    else if $days_since_push < 90 { 0.6 }
    else if $days_since_push < 365 { 0.2 }
    else { 0.05 }
  )
  let raw = (
    0.25 * ($stars / 5000.0)
    + 0.15 * ($forks / 1000.0)
    + 0.30 * ($velocity / 200.0)
    + 0.15 * $freshness_n
    + 0.15 * $completion_rate
  )
  clamp $raw 0.0 1.0
}

def derive-status [
  assignee: any,
  attempts: int,
  comments: int,
  days_open: float
]: nothing -> string {
  if $assignee != null {
    "submitted"
  } else if $attempts >= 1 {
    "active"
  } else if ($comments > 0 and $attempts == 0 and $days_open > 30) {
    "smelly"
  } else if $comments > 0 {
    "triage"
  } else {
    "open"
  }
}

# ─── GitHub API fetchers ─────────────────────────────────────────────────────

def fetch-repo-meta [owner: string, repo: string]: nothing -> record {
  try {
    let d = (gh api $"repos/($owner)/($repo)" | from json)
    {
      description:        ($d | get description?    | default ""),
      topics:             ($d | get topics?         | default []),
      stars:              ($d | get stargazers_count? | default 0),
      forks:              ($d | get forks_count?    | default 0),
      watchers:           ($d | get subscribers_count? | default 0),
      open_issues_count:  ($d | get open_issues_count? | default 0),
      pushed_at:          ($d | get pushed_at?      | default ""),
      created_at:         ($d | get created_at?     | default ""),
      license:            ($d | get license.spdx_id? | default null),
    }
  } catch {
    { description: "", topics: [], stars: 0, forks: 0, watchers: 0,
      open_issues_count: 0, pushed_at: "", created_at: "", license: null }
  }
}

def fetch-repo-languages [owner: string, repo: string]: nothing -> list<string> {
  try {
    gh api $"repos/($owner)/($repo)/languages" | from json | columns
  } catch { [] }
}

def fetch-repo-maintainers [owner: string, repo: string]: nothing -> list<string> {
  try {
    gh api $"repos/($owner)/($repo)/contributors?per_page=5" | from json | get login
  } catch { [] }
}

def fetch-repo-velocity [owner: string, repo: string]: nothing -> int {
  try {
    let stats = (gh api $"repos/($owner)/($repo)/stats/participation" | from json)
    # "all" is weekly commit count for 52 weeks; take last 13 weeks ≈ 90 days
    let weekly = ($stats | get all? | default [])
    if ($weekly | length) >= 13 {
      $weekly | last 13 | math sum
    } else {
      $weekly | math sum
    }
  } catch { 0 }
}

def fetch-repo-latest-release [owner: string, repo: string]: nothing -> record {
  try {
    let r = (gh api $"repos/($owner)/($repo)/releases/latest" | from json)
    { tag: ($r | get tag_name? | default null), published_at: ($r | get published_at? | default null) }
  } catch {
    { tag: null, published_at: null }
  }
}

def fetch-closed-bounty-count [owner: string, repo: string]: nothing -> int {
  try {
    # 💎 Bounty label URL-encoded
    gh api $"repos/($owner)/($repo)/issues?state=closed&labels=%F0%9F%92%8E+Bounty&per_page=100" | from json | length
  } catch { 0 }
}

def fetch-issue-metrics [owner: string, repo: string, issue_id: int]: nothing -> record {
  if $issue_id == 0 {
    return {
      comments: 0, attempts: 0, created_at: "", updated_at: "",
      labels: [], assignee: null
    }
  }
  try {
    let issue = (gh api $"repos/($owner)/($repo)/issues/($issue_id)" | from json)
    let comments  = ($issue | get comments?  | default 0)
    let created   = ($issue | get created_at? | default "")
    let updated   = ($issue | get updated_at? | default "")
    let labels    = ($issue | get labels?    | default [] | each { |l| $l | get name? | default "" })
    let assignee  = ($issue | get assignee.login? | default null)
    let timeline  = (
      try { gh api $"repos/($owner)/($repo)/issues/($issue_id)/timeline?per_page=100" | from json }
      catch { [] }
    )
    let attempts  = ($timeline | where { |e| ($e | get event? | default "") == "cross-referenced" } | length)
    { comments: $comments, attempts: $attempts, created_at: $created,
      updated_at: $updated, labels: $labels, assignee: $assignee }
  } catch {
    { comments: 0, attempts: 0, created_at: "", updated_at: "", labels: [], assignee: null }
  }
}

# Days between two ISO-8601 datetime strings (returns float)
def days-between [from_dt: string, to_dt: string]: nothing -> float {
  if ($from_dt == "" or $to_dt == "") { return 0.0 }
  try {
    let t1 = ($from_dt | into datetime)
    let t2 = ($to_dt   | into datetime)
    (($t2 - $t1) | into int) / 1_000_000_000.0 / 86400.0
  } catch { 0.0 }
}

# ─── Fetch Algora bounties ───────────────────────────────────────────────────

print "Fetching bounties from Algora..."
let items = (
  http get "https://algora.io/api/trpc/bounty.list?batch=1&input={%220%22:{%22json%22:{%22status%22:%22open%22,%22limit%22:5000}}}"
  | get 0.result.data.json.items
)
print $"Fetched ($items | length) bounties."

let processed = ($items | each {|b|
  let url       = ($b.task.url | default "")
  let parsed    = ($url | parse -r 'github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/issues/(?P<issue>\d+)')
  let owner     = if ($parsed | length) > 0 { $parsed.0.owner } else { "" }
  let repo_name = if ($parsed | length) > 0 { $parsed.0.repo  } else { "unknown" }
  let issue_id  = if ($parsed | length) > 0 { $parsed.0.issue | into int } else { 0 }
  let reward_str = $b.reward_formatted
  let reward_val = ($reward_str | str replace '$' '' | str replace -a ',' '' | str trim | into float)
  {
    org_name: $b.org.name, org_handle: $b.org.handle,
    owner: $owner, repo_name: $repo_name,
    reward: $reward_str, reward_val: $reward_val,
    issue_id: $issue_id, title: $b.task.title, url: $url
  }
})

# ─── Build per-org summaries ─────────────────────────────────────────────────

print "Enriching from GitHub API (may take a while)..."

let org_summaries = (
  $processed
  | group-by org_name
  | items {|org_name, org_bounties|
    let org_handle    = ($org_bounties | first | get org_handle)
    let open_count    = ($org_bounties | length)
    let open_val_usd  = ($org_bounties | get reward_val | math sum)

    let repo_list = (
      $org_bounties
      | group-by repo_name
      | items {|repo_name, repo_bounties|
        let owner        = ($repo_bounties | first | get owner)
        let open_b_count = ($repo_bounties | length)
        let total_b_val  = ($repo_bounties | get reward_val | math sum)

        print $"  ($owner)/($repo_name) ($open_b_count) bounties..."

        let meta        = (fetch-repo-meta       $owner $repo_name)
        let languages   = (fetch-repo-languages  $owner $repo_name)
        let maintainers = (fetch-repo-maintainers $owner $repo_name)
        let velocity    = (fetch-repo-velocity   $owner $repo_name)
        let release     = (fetch-repo-latest-release $owner $repo_name)
        let closed_b    = (fetch-closed-bounty-count $owner $repo_name)

        # Repo age / freshness
        let days_since_push = (days-between $meta.pushed_at $current_time)
        let repo_age_days   = (days-between $meta.created_at $current_time)
        let total_bounties_ever = ($open_b_count + $closed_b)
        let completion_rate = (
          if $total_bounties_ever > 0 {
            ($closed_b | into float) / ($total_bounties_ever | into float)
          } else { 0.0 }
        )

        let repo_health = (
          compute-repo-health $meta.stars $meta.forks $velocity $days_since_push $completion_rate
        )

        # Enrich bounties
        let enriched_bounties = ($repo_bounties | sort-by reward_val -r | each {|rb|
          let m         = (fetch-issue-metrics $owner $repo_name $rb.issue_id)
          let days_open = (days-between $m.created_at $current_time)
          let last_act  = (days-between $m.updated_at $current_time)
          let status    = (derive-status $m.assignee $m.attempts $m.comments $days_open)
          let comp_score = ($rb.reward_val / (1.0 + ($m.attempts | into float)))
          let mono_score = (
            compute-bounty-monetizability $rb.reward_val $m.attempts $days_open $m.assignee
          )
          {
            reward: $rb.reward, reward_val: $rb.reward_val,
            issue_id: $rb.issue_id, deps: [], title: $rb.title, url: $rb.url,
            status: $status, labels: $m.labels, assignee: $m.assignee,
            metrics: {
              comments:             $m.comments,
              attempts:             $m.attempts,
              days_open:            $days_open,
              created_at:           $m.created_at,
              updated_at:           $m.updated_at,
              last_activity_days_ago: $last_act,
            },
            scores: {
              competition_score:    $comp_score,
              monetizability_score: $mono_score,
            }
          }
        })

        let mono_scores = ($enriched_bounties | get scores.monetizability_score)
        let avg_mono = (if ($mono_scores | length) > 0 { $mono_scores | math avg } else { 0.0 })
        let repo_mono = (clamp (0.70 * $avg_mono + 0.30 * ($open_b_count / 10.0)) 0.0 1.0)

        let contributor_count = ($maintainers | length)

        {
          name: $repo_name,
          bounty_count: $open_b_count,
          data: {
            description: $meta.description,
            language:    $languages,
            topics:      $meta.topics,
            url:         $"https://github.com/($owner)/($repo_name)",
            maintainers: $maintainers,
            license:     $meta.license,
            metrics: {
              stars:                 $meta.stars,
              forks:                 $meta.forks,
              watchers:              $meta.watchers,
              open_issues_count:     $meta.open_issues_count,
              contributor_count:     $contributor_count,
              commit_velocity_90d:   $velocity,
              last_push_date:        $meta.pushed_at,
              repo_created_at:       $meta.created_at,
              repo_age_days:         $repo_age_days,
              last_release_tag:      $release.tag,
              last_release_date:     $release.published_at,
              open_bounty_count:     $open_b_count,
              closed_bounty_count:   $closed_b,
              bounty_completion_rate: $completion_rate,
              total_bounty_value_usd: $total_b_val,
            },
            scores: {
              repo_health_score:        $repo_health,
              repo_monetizability_score: $repo_mono,
            },
            bounties: $enriched_bounties,
          }
        }
      }
      | sort-by bounty_count -r
      | reduce -f {} {|it, acc| $acc | insert $it.name $it.data}
    )

    let num_repos = ($repo_list | columns | length)

    # Aggregate project-level metrics
    let all_repo_records = ($repo_list | values)

    let all_bounties_flat = (
      $all_repo_records | each { |r| $r.bounties } | flatten
    )
    let total_b = ($all_bounties_flat | length)
    let total_comments = ($all_bounties_flat | get metrics.comments | math sum)
    let total_attempts = ($all_bounties_flat | get metrics.attempts | math sum)

    # closed bounties estimated from repo-level data
    let total_closed = (
      $all_repo_records | each { |r| $r.metrics.closed_bounty_count } | math sum
    )
    let total_ever = ($total_b + $total_closed)
    let proj_completion_rate = (
      if $total_ever > 0 { ($total_closed | into float) / ($total_ever | into float) }
      else { 0.0 }
    )

    let engagement_score = (
      clamp (
        if $total_b > 0 {
          ($total_comments + $total_attempts * 3) / ($total_b * 13.0)
        } else { 0.0 }
      ) 0.0 1.0
    )

    let repo_health_list = ($all_repo_records | each { |r| $r.scores.repo_health_score })
    let avg_repo_health = (if ($repo_health_list | length) > 0 { $repo_health_list | math avg } else { 0.0 })

    let proj_health = (
      clamp (
        0.40 * $proj_completion_rate
        + 0.30 * $engagement_score
        + 0.30 * $avg_repo_health
      ) 0.0 1.0
    )

    {
      name: $org_name,
      open_bounty_count: $open_count,
      open_bounties_total_value_usd: $open_val_usd,
      health_score: $proj_health,
      project: {
        org_handle:  $org_handle,
        org_url:     $"https://github.com/($org_handle)",
        open_bounty_count: $open_count,
        open_bounties_total_value_usd: $open_val_usd,
        last_updated: $current_time,
        metrics: {
          bounty_completion_rate:           $proj_completion_rate,
          avg_resolution_days:              null,
          total_completed_bounties:         $total_closed,
          total_historical_bounty_value_usd: $open_val_usd,
          active_repos:                     $num_repos,
          engagement_score:                 $engagement_score,
        },
        scores: {
          health_score:       $proj_health,
          monetizability_rank: 0,  # filled in ranking pass below
        },
        repositories: {
          total_project_repos:        $num_repos,
          total_project_bounty_repos: $num_repos,
          repo_list: $repo_list,
        }
      }
    }
  }
  | sort-by open_bounty_count -r
)

# ─── Monetizability ranking pass ─────────────────────────────────────────────

let ranked = (
  $org_summaries
  | sort-by { |it| $it.open_bounties_total_value_usd * $it.health_score } -r
  | enumerate
  | each {|it|
    let rank = ($it.index + 1)
    mut proj = $it.item.project
    $proj.scores.monetizability_rank = $rank
    { name: $it.item.name, project: $proj }
  }
)

let projects = (
  $ranked | reduce -f {} {|it, acc| $acc | insert $it.name $it.project}
)

# ─── Summary ─────────────────────────────────────────────────────────────────

let total_bounties    = ($processed | length)
let total_rewards     = ($processed | get reward_val | math sum)
let total_projects    = ($projects | columns | length)
let total_repos       = (
  $projects | values | each { |p| $p.repositories.repo_list | columns | length } | math sum
)

let snapshot_id = $"snap-($current_time | str replace -a ':' '' | str replace -a '+' '' | str replace -a '-' '' | str replace ' ' 'T')"

let new_snapshot = {
  snapshot_id:  $snapshot_id,
  generated_at: $current_time,
  platform:     "Algora",
  summary: {
    total_bounties:     $total_bounties,
    open_bounties:      $total_bounties,
    completed_bounties: 0,
    total_rewards_usd:  $total_rewards,
    total_projects:     $total_projects,
    total_repos:        $total_repos,
  },
  projects: $projects,
}

# ─── Append-mode write ───────────────────────────────────────────────────────

let existing = (
  if ($OUTPUT_FILE | path exists) {
    try {
      let parsed = (open $OUTPUT_FILE)
      # Accept only v2.0 files that already have the snapshots array
      if ($parsed | get snapshots? | default null) != null {
        $parsed
      } else {
        print "Existing file is v1.0 format — starting fresh v2.0 history."
        { schema_version: "2.0.0", snapshots: [] }
      }
    } catch {
      print "Could not parse existing file — starting fresh."
      { schema_version: "2.0.0", snapshots: [] }
    }
  } else {
    { schema_version: "2.0.0", snapshots: [] }
  }
)

{
  schema_version: "2.0.0",
  snapshots: ($existing.snapshots | append $new_snapshot),
}
| to json --indent 2
| save -f $OUTPUT_FILE

let snap_count = (open $OUTPUT_FILE | get snapshots | length)
print $"Done. ($total_bounties) bounties across ($total_projects) projects, $($total_rewards | into string) total value."
print $"Snapshot #($snap_count) appended to ($OUTPUT_FILE)."
