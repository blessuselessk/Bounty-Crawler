# schema.ncl — Canonical data model for algora-bounties.json (v2.0.0)
# This file is the authoritative source of truth for types, contracts, and score formulas.
# The .nu generator script must implement formulas that match exactly.

# ─── Primitive contracts ────────────────────────────────────────────────────

let BountyStatus = std.contract.from_predicate (fun s =>
  std.array.elem s ["open", "triage", "active", "submitted", "smelly", "stinks", "stale", "completed"]
) in

let Fraction = std.contract.from_predicate (fun n =>
  std.is_number n && n >= 0 && n <= 1
) in

# ─── Score formulas (documented here, implemented in .nu) ──────────────────
#
# BOUNTY-LEVEL
#
#   competition_score  = reward_val / (1 + attempts)
#
#   monetizability_score (0–1):
#     base   = 0.40 * (reward_val / 2000)
#            + 0.35 * (1 / (1 + attempts))
#            + 0.20 * freshness
#            + assignee_penalty
#     where:
#       freshness:        days_open < 14  → 1.0
#                         days_open < 60  → 0.7
#                         days_open < 180 → 0.4
#                         else            → 0.15
#       assignee_penalty: assignee != null → -0.3, else 0
#     result = clamp(base, 0, 1)
#
# REPO-LEVEL
#
#   repo_health_score (0–1):
#     = 0.25 * (stars  / 5000)
#     + 0.15 * (forks  / 1000)
#     + 0.30 * (commit_velocity_90d / 200)
#     + 0.15 * freshness_n
#     + 0.15 * bounty_completion_rate
#     where:
#       freshness_n: days_since_push < 30  → 1.0
#                    days_since_push < 90  → 0.6
#                    days_since_push < 365 → 0.2
#                    else                  → 0.05
#
#   repo_monetizability_score (0–1):
#     = clamp(0.70 * avg_bounty_monetizability + 0.30 * (open_bounty_count / 10), 0, 1)
#
# PROJECT-LEVEL
#
#   health_score (0–1):
#     = 0.40 * bounty_completion_rate
#     + 0.30 * engagement_score
#     + 0.30 * avg_repo_health
#     where:
#       engagement_score = clamp((comments + attempts*3) / (total_bounties * 13), 0, 1)
#
#   monetizability_rank: integer rank by (open_bounties_total_value_usd * health_score) desc

# ─── Bounty ─────────────────────────────────────────────────────────────────

let BountyMetrics = {
  comments             | Number,
  attempts             | Number,
  days_open            | Number,
  created_at           | String,
  updated_at           | String,
  last_activity_days_ago | Number,
} in

let BountyScores = {
  competition_score    | Number,
  monetizability_score | Fraction,
} in

let Bounty = {
  reward       | String,
  reward_val   | Number,
  issue_id     | Number,
  deps         | Array String,
  title        | String,
  url          | String,
  status       | BountyStatus,
  labels       | Array String,
  assignee     | std.contract.any,
  metrics      | BountyMetrics,
  scores       | BountyScores,
} in

# ─── Repo ───────────────────────────────────────────────────────────────────

let RepoMetrics = {
  stars                   | Number,
  forks                   | Number,
  watchers                | Number,
  open_issues_count       | Number,
  contributor_count       | Number,
  commit_velocity_90d     | Number,
  last_push_date          | String,
  repo_created_at         | String,
  repo_age_days           | Number,
  last_release_tag        | std.contract.any,
  last_release_date       | std.contract.any,
  open_bounty_count       | Number,
  closed_bounty_count     | Number,
  bounty_completion_rate  | Fraction,
  total_bounty_value_usd  | Number,
} in

let RepoScores = {
  repo_health_score        | Fraction,
  repo_monetizability_score | Fraction,
} in

let Repo = {
  description  | String,
  language     | Array String,
  topics       | Array String,
  url          | String,
  maintainers  | Array String,
  license      | std.contract.any,
  metrics      | RepoMetrics,
  scores       | RepoScores,
  bounties     | Array Bounty,
} in

# ─── Project ────────────────────────────────────────────────────────────────

let ProjectMetrics = {
  bounty_completion_rate          | Fraction,
  avg_resolution_days             | std.contract.any,
  total_completed_bounties        | Number,
  total_historical_bounty_value_usd | Number,
  active_repos                    | Number,
  engagement_score                | Fraction,
} in

let ProjectScores = {
  health_score        | Fraction,
  monetizability_rank | Number,
} in

let Project = {
  org_handle                  | String,
  org_url                     | String,
  open_bounty_count           | Number,
  open_bounties_total_value_usd | Number,
  last_updated                | String,
  metrics                     | ProjectMetrics,
  scores                      | ProjectScores,
  repositories | {
    total_project_repos       | Number,
    total_project_bounty_repos | Number,
    repo_list                 | { _ | Repo },
  },
} in

# ─── Snapshot ───────────────────────────────────────────────────────────────

let SnapshotSummary = {
  total_bounties     | Number,
  open_bounties      | Number,
  completed_bounties | Number,
  total_rewards_usd  | Number,
  total_projects     | Number,
  total_repos        | Number,
} in

let Snapshot = {
  snapshot_id  | String,
  generated_at | String,
  platform     | String,
  summary      | SnapshotSummary,
  projects     | { _ | Project },
} in

# ─── Root ───────────────────────────────────────────────────────────────────

{
  schema_version | String,
  snapshots      | Array Snapshot,
}
