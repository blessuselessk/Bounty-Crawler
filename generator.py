import json
import re
from datetime import datetime

# Valid bounty statuses:
#   open = posted bounty, no attempts
#   triage = posted bounty, discussion, no attemps
#   active = posted bounty, has attempts
#   submitted = posted bounty, claimed via PR
#   smelly = posted bounty, has discussion w/ no attempts 
#   stinks = posted bounty, claimed via PR, >= 5 days with no merge or PR discussion
#   stale = posted bounty, attempts but no claims via PR
#   completed =  issue closed, PR merged

input_file = '/Users/lessuseless/Projects/Bounty-Crawler/bounties_grouped.json'
output_file = '/Users/lessuseless/Projects/Bounty-Crawler/bounties_template.json'

with open(input_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

current_time = "2026-03-02T22:48:59-06:00"

out = {
    "version": "1.0.0",
    "generated_datetime": current_time,
    "platform_ecosystem_name": "Algora",
    "platform_combined_bounties": 0,
    "platform_open_bounties": 0,
    "total_completed_bounties": 0,
    "total_rewards_value_usd": 0.0,
    "total_projects": len(data),
    "projects": {}
}

total_bounties = 0
total_rewards = 0.0

for org in data:
    org_name = org.get('org_name')
    org_handle = org.get('org_handle')
    bounties = org.get('bounties', [])
    org_open_bounties = len(bounties)
    
    org_rewards = 0.0
    repos = {}

    for b in bounties:
        reward_str = b.get('reward', '$0')
        reward_val_str = reward_str.replace('$', '').replace(',', '').strip()
        try:
            val = float(reward_val_str)
            org_rewards += val
        except ValueError:
            pass
            
        url = b.get('url') or ''
        # Extract repo name and issue id from url: https://github.com/org/repo/issues/123
        repo_name = "unknown"
        issue_id = 0
        if isinstance(url, str):
            match = re.search(r'github\.com/[^/]+/([^/]+)/issues/(\d+)', url)
            if match:
                repo_name = match.group(1)
                issue_id = int(match.group(2))
            
        if repo_name not in repos:
            repos[repo_name] = {
                "description": "Placeholder description for " + repo_name,
                "topics": ["placeholder-topic-1", "placeholder-topic-2"],
                "url": f"https://github.com/{org_handle}/{repo_name}",
                "maintainers": ["placeholder_maintainer"],
                "bounties": []
            }
            
        bounty_obj = {
            "reward": reward_str,
            "issue_id": issue_id,
            "deps": [],
            "title": b.get('title', ''),
            "url": url,
            "status": "open",
            "metrics": {
                "comments": 0,
                "attempts": 0
            }
        }
        repos[repo_name]["bounties"].append(bounty_obj)

    out['projects'][org_name] = {
        "org_handle": org_handle,
        "open_bounty_count": org_open_bounties,
        "open_bounties_total_value_usd": org_rewards,
        "last_updated": current_time,
        "repositories": {
            "total_project_repos": len(repos),
            "total_project_bounty_repos": len(repos),
            "repo_list": repos
        }
    }
    
    total_bounties += org_open_bounties
    total_rewards += org_rewards

out['platform_combined_bounties'] = total_bounties
out['platform_open_bounties'] = total_bounties
out['total_rewards_value_usd'] = total_rewards

with open(output_file, 'w', encoding='utf-8') as f:
    json.dump(out, f, indent=2)

print("Template updated successfully.")
