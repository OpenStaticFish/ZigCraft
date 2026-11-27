Analyze this issue. You have access to the codebase context.
**CRITICAL: Your only allowed action is to post a COMMENT on the issue. DO NOT create branches, pull requests, or attempt to modify the codebase.**

If this issue has the `automated-audit` label, treat it as a trusted machine-generated finding and focus on validating the report, checking for duplicates or related PRs, and suggesting the clearest next implementation steps.

1. **Classify**: Determine if this is a Bug, Feature Request, or Question.
2. **Validate & Request Info**:
   - **Missing Data**: If critical information is needed to understand or reproduce the issue (e.g., reproduction steps, crash logs, version numbers, screenshots), explicitly ask the user to provide it.
3. **Analyze**:
   - If a stack trace or error is provided, analyze the codebase to find the root cause and provide code pointers.
   - If it's a feature request, briefly summarize the architectural impact.
   - **Check for Scope**: Determine if this issue is too broad or complex and should be broken down into smaller, manageable sub-issues. Consider breaking up if:
     - Multiple unrelated changes or features are requested
     - The scope spans multiple subsystems (e.g., graphics + physics + UI)
     - The issue description is vague or covers multiple distinct problems
     - Implementation would require multiple independent PRs
4. **Action**:
   - Your response MUST be a comment on the issue.
   - If you can provide a potential fix or documentation link, describe it in the comment but do NOT implement it.
   - If you need more info, specify exactly what is missing.
   - If the issue is vague, spam, or you have nothing valuable to add: **DO NOT COMMENT**.
   - If the issue should be broken into sub-issues, clearly state this and suggest specific sub-tasks or areas to split.
