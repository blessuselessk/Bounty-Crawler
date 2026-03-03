#!/usr/bin/env nu

# Valid bounty statuses:
#   open = posted bounty, no attempts
#   triage = posted bounty, discussion, no attempts
#   active = posted bounty, has attempts
#   submitted = posted bounty, claimed via PR
#   smelly = posted bounty, has discussion w/ no attempts
#   stinks = posted bounty, claimed via PR, >= 5 days with no merge or PR discussion
#   stale = posted bounty, attempts but no claims via PR
#   completed = issue closed, PR merged

let current_time = (date now | format date "%Y-%m-%dT%H:%M:%S%:z")

# Fetch all open bounties from Algora API
let items = (
  http get "https://algora.io/api/trpc/bounty.list?batch=1&input={%220%22:{%22json%22:{%22status%22:%22open%22,%22limit%22:5000}}}"
  | get 0.result.data.json.items
)

# Process each bounty into a flat row
let processed = ($items | each {|b|
  let url = ($b.task.url | default '')
  let parsed = ($url | parse -r 'github\.com/[^/]+/(?P<repo>[^/]+)/issues/(?P<issue>\d+)')
  let repo_name = if ($parsed | length) > 0 { $parsed.0.repo } else { "unknown" }
  let issue_id = if ($parsed | length) > 0 { $parsed.0.issue | into int } else { 0 }
  let reward_str = $b.reward_formatted
  let reward_val = ($reward_str | str replace '$' '' | str replace -a ',' '' | str trim | into float)

  {
    org_name: $b.org.name,
    org_handle: $b.org.handle,
    repo_name: $repo_name,
    reward: $reward_str,
    reward_val: $reward_val,
    issue_id: $issue_id,
    title: $b.task.title,
    url: $url
  }
})

# Build per-org summaries, sorted by bounty count descending
let org_summaries = (
  $processed
  | group-by org_name
  | items {|org_name, org_bounties|
    let org_handle = ($org_bounties | first | get org_handle)
    let open_bounty_count = ($org_bounties | length)
    let org_rewards = ($org_bounties | get reward_val | math sum)

    # Group bounties by repo, sort repos by bounty count desc
    let repo_list = (
      $org_bounties
      | group-by repo_name
      | items {|repo_name, repo_bounties|
        let sorted_bounties = ($repo_bounties | sort-by reward_val -r)
        {
          name: $repo_name,
          bounty_count: ($repo_bounties | length),
          data: {
            description: $"Placeholder description for ($repo_name)",
            topics: [placeholder-topic-1, placeholder-topic-2],
            url: $"https://github.com/($org_handle)/($repo_name)",
            maintainers: [placeholder_maintainer],
            bounties: ($sorted_bounties | each {|rb| {
              reward: $rb.reward,
              issue_id: $rb.issue_id,
              deps: [],
              title: $rb.title,
              url: $rb.url,
              status: open,
              metrics: {
                comments: 0,
                attempts: 0
              }
            }})
          }
        }
      }
      | sort-by bounty_count -r
      | reduce -f {} {|it, acc| $acc | insert $it.name $it.data}
    )

    let num_repos = ($repo_list | columns | length)

    {
      name: $org_name,
      open_bounty_count: $open_bounty_count,
      project: {
        org_handle: $org_handle,
        open_bounty_count: $open_bounty_count,
        open_bounties_total_value_usd: $org_rewards,
        last_updated: $current_time,
        repositories: {
          total_project_repos: $num_repos,
          total_project_bounty_repos: $num_repos,
          repo_list: $repo_list
        }
      }
    }
  }
  | sort-by open_bounty_count -r
)

# Fold sorted list into a record keyed by org name
let projects = (
  $org_summaries
  | reduce -f {} {|it, acc| $acc | insert $it.name $it.project}
)

let total_bounties = ($processed | length)
let total_rewards = ($processed | get reward_val | math sum)
let total_projects = ($projects | columns | length)

# Assemble final output
let output = {
  version: "1.0.0",
  generated_datetime: $current_time,
  platform_ecosystem_name: Algora,
  platform_combined_bounties: $total_bounties,
  platform_open_bounties: $total_bounties,
  total_completed_bounties: 0,
  total_rewards_value_usd: $total_rewards,
  total_projects: $total_projects,
  projects: $projects
}

$output | to json --indent 2 | save -f algora-bounties.json

print $"Template updated successfully. ($total_bounties) bounties across ($total_projects) projects, $($total_rewards) total value."
