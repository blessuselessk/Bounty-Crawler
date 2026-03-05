# schema.ncl — Canonical executable spec for algora-bounties.json (v2.0.0)
# Formulas are defined as real Nickel functions and used inside contracts.
# Run: nickel check algora-bounties.json schema.ncl

# ─── Primitive helpers ───────────────────────────────────────────────────────

let clamp = fun lo hi x =>
  if x < lo then lo
  else if x > hi then hi
  else x
in

# ─── Bounty-level formulas ───────────────────────────────────────────────────

let competition_score = fun reward_val attempts =>
  reward_val / (1 + attempts)
in

let bounty_freshness = fun days_open =>
  if days_open < 14 then 1.0
  else if days_open < 60 then 0.7
  else if days_open < 180 then 0.4
  else 0.15
in

let assignee_penalty = fun assignee =>
  if assignee == null then 0.0 else -0.3
in

let monetizability_score = fun reward_val attempts days_open assignee =>
  clamp 0.0 1.0 (
    0.40 * (reward_val / 2000.0)
    + 0.35 * (1.0 / (1.0 + attempts))
    + 0.20 * (bounty_freshness days_open)
    + (assignee_penalty assignee)
  )
in

# ─── Repo-level formulas ─────────────────────────────────────────────────────

let repo_freshness = fun days_since_push =>
  if days_since_push < 30 then 1.0
  else if days_since_push < 90 then 0.6
  else if days_since_push < 365 then 0.2
  else 0.05
in

let repo_health_score = fun stars forks velocity days_since_push completion_rate =>
  clamp 0.0 1.0 (
    0.25 * (stars  / 5000.0)
    + 0.15 * (forks  / 1000.0)
    + 0.30 * (velocity / 200.0)
    + 0.15 * (repo_freshness days_since_push)
    + 0.15 * completion_rate
  )
in

let repo_monetizability_score = fun avg_bounty_mono open_bounty_count =>
  clamp 0.0 1.0 (
    0.70 * avg_bounty_mono
    + 0.30 * (open_bounty_count / 10.0)
  )
in

# ─── Maintainer-level formulas ───────────────────────────────────────────────

# activity_n    = clamp(recent_commits_90d / 30, 0, 1)
# merge_n       = clamp(merged_prs / 10, 0, 1)
# commit_share  = maintainer_total_commits / repo_total_commits  (bus factor proxy)
#
# maintainer_score = 0.40 * activity_n + 0.35 * merge_n + 0.25 * commit_share
# bus_factor_risk  = commit_share > 0.60

let maintainer_score = fun recent_commits merged_prs commit_share =>
  let activity_n = clamp 0.0 1.0 (recent_commits / 30.0) in
  let merge_n    = clamp 0.0 1.0 (merged_prs    / 10.0) in
  clamp 0.0 1.0 (
    0.40 * activity_n
    + 0.35 * merge_n
    + 0.25 * commit_share
  )
in

let bus_factor_risk = fun commit_share => commit_share > 0.60 in

# ─── Project-level formulas ──────────────────────────────────────────────────

let engagement_score = fun comments attempts total_bounties =>
  if total_bounties == 0 then 0.0
  else clamp 0.0 1.0 ((comments + attempts * 3) / (total_bounties * 13.0))
in

let project_health_score = fun completion_rate eng_score avg_repo_health =>
  clamp 0.0 1.0 (
    0.40 * completion_rate
    + 0.30 * eng_score
    + 0.30 * avg_repo_health
  )
in

# monetizability_rank = rank by (open_bounties_total_value_usd * health_score) desc
# Ranking is assigned externally (integer 1..N); validated below as a positive number.

# ─── Primitive contracts ─────────────────────────────────────────────────────

let BountyStatus = std.contract.from_predicate (fun s =>
  std.array.elem s ["open","triage","active","submitted","smelly","stinks","stale","completed"]
) in

let Fraction = std.contract.from_predicate (fun n =>
  std.is_number n && n >= 0.0 && n <= 1.0
) in

let PosInt = std.contract.from_predicate (fun n =>
  std.is_number n && n >= 1
) in

# ─── Bounty contract (validates stored scores against formulas) ──────────────

let BountyScores = fun label value =>
  let m = value.metrics in
  let expected_comp = competition_score value.reward_val m.attempts in
  let expected_mono = monetizability_score value.reward_val m.attempts m.days_open value.assignee in
  let ok_comp = std.number.is_finite (value.scores.competition_score - expected_comp) in
  let ok_mono = ((value.scores.monetizability_score - expected_mono) | std.number.abs) < 0.001 in
  if !ok_comp then
    std.contract.blame_with_message
      "scores.competition_score does not match reward_val / (1 + attempts)" label
  else if !ok_mono then
    std.contract.blame_with_message
      "scores.monetizability_score deviates from formula by >0.001" label
  else value
in

let Bounty = {
  reward               | String,
  reward_val           | Number,
  issue_id             | Number,
  deps                 | Array String,
  title                | String,
  url                  | String,
  status               | BountyStatus,
  labels               | Array String,
  assignee             | std.contract.any,
  metrics = {
    comments               | Number,
    attempts               | Number,
    days_open              | Number,
    created_at             | String,
    updated_at             | String,
    last_activity_days_ago | Number,
  },
  scores               | BountyScores,
} in

# ─── Repo contract ───────────────────────────────────────────────────────────

let RepoScores = fun label value =>
  let m = value.metrics in
  # Recompute days_since_push from last_push_date is not possible without a
  # current timestamp in Nickel, so we only range-check here.
  let ok_health = value.scores.repo_health_score >= 0.0 && value.scores.repo_health_score <= 1.0 in
  let ok_mono   = value.scores.repo_monetizability_score >= 0.0 && value.scores.repo_monetizability_score <= 1.0 in
  if !ok_health then
    std.contract.blame_with_message "repo_health_score out of [0,1]" label
  else if !ok_mono then
    std.contract.blame_with_message "repo_monetizability_score out of [0,1]" label
  else value
in

let MaintainerMetrics = {
  total_commits      | Number,
  recent_commits_90d | Number,
  merged_prs         | Number,
  commit_share       | Fraction,
} in

let MaintainerScores = fun label value =>
  let expected = maintainer_score
    value.metrics.recent_commits_90d
    value.metrics.merged_prs
    value.metrics.commit_share
  in
  let ok = ((value.scores.maintainer_score - expected) | std.number.abs) < 0.001 in
  if !ok then
    std.contract.blame_with_message "maintainer_score deviates from formula by >0.001" label
  else value
in

let Maintainer = {
  metrics | MaintainerMetrics,
  scores  | MaintainerScores,
} in

let Repo = {
  description  | String,
  language     | Array String,
  topics       | Array String,
  url          | String,
  maintainers  | { _ | Maintainer },
  license      | std.contract.any,
  metrics = {
    stars                  | Number,
    forks                  | Number,
    watchers               | Number,
    open_issues_count      | Number,
    contributor_count      | Number,
    commit_velocity_90d    | Number,
    last_push_date         | String,
    repo_created_at        | String,
    repo_age_days          | Number,
    last_release_tag       | std.contract.any,
    last_release_date      | std.contract.any,
    open_bounty_count      | Number,
    closed_bounty_count    | Number,
    bounty_completion_rate | Fraction,
    total_bounty_value_usd | Number,
  },
  scores       | RepoScores,
  bounties     | Array Bounty,
} in

# ─── Project contract ────────────────────────────────────────────────────────

let ProjectScores = fun label value =>
  let ok_health = value.scores.health_score >= 0.0 && value.scores.health_score <= 1.0 in
  let ok_rank   = value.scores.monetizability_rank >= 1 in
  if !ok_health then
    std.contract.blame_with_message "health_score out of [0,1]" label
  else if !ok_rank then
    std.contract.blame_with_message "monetizability_rank must be >= 1" label
  else value
in

let Project = {
  org_handle                    | String,
  org_url                       | String,
  open_bounty_count             | Number,
  open_bounties_total_value_usd | Number,
  last_updated                  | String,
  metrics = {
    bounty_completion_rate            | Fraction,
    avg_resolution_days               | std.contract.any,
    total_completed_bounties          | Number,
    total_historical_bounty_value_usd | Number,
    active_repos                      | Number,
    engagement_score                  | Fraction,
  },
  scores                        | ProjectScores,
  repositories = {
    total_project_repos        | Number,
    total_project_bounty_repos | Number,
    repo_list                  | { _ | Repo },
  },
} in

# ─── Snapshot + root ─────────────────────────────────────────────────────────

let Snapshot = {
  snapshot_id  | String,
  generated_at | String,
  platform     | String,
  summary = {
    total_bounties     | Number,
    open_bounties      | Number,
    completed_bounties | Number,
    total_rewards_usd  | Number,
    total_projects     | Number,
    total_repos        | Number,
  },
  projects | { _ | Project },
} in

{
  schema_version | String,
  snapshots      | Array Snapshot,
}
