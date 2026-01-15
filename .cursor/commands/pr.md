Create a pull request for the current branch.

## Pre-flight checks

1. Run `git status` to check for uncommitted changes.
    If there are uncommitted changes, stop and ask the user to commit or stash them first
2. Run `git branch --show-current` to get the branch name
    Verify not on main/master - if so, stop and ask the user to create a branch first
3. Run the test suite (`bundle exec rake all_specs` and `bundle exec rubocop`)
    If any test suite failures, stop and prompt user to resolve first

## Gather context

4. Run `git log origin/main..HEAD --oneline` to see all commits on this branch
5. Run `git diff origin/main...HEAD --stat` to see changed files
6. If needed, read the diff for key files to understand the changes

## Generate PR content

7. Generate a PR title: a single line that summarizes the changes (imperative mood, e.g., "Add batch enqueueing support")
8. Generate a PR body with:
   - **Summary**: a handful of bullet points describing the key changes
   - **Details**: If sufficiently complex, include details of each notable change
   - **Usage Example**: If applicable, a brief code example demonstrating the new or changed feature/API

## Push and create PR

9. Push the branch: `git push -u origin HEAD`
10. Create the PR as a draft using gh:

gh pr create --draft --title "THE TITLE" --body "$(cat <<'EOF'
THE BODY HERE
EOF
)"

11. Report the PR URL to the user
