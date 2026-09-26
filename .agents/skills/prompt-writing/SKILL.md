---
name: prompt-writing
description: Writes and reviews instructions for AI agents, such as AGENTS.md lines, SKILL.md files, and prompts that hand work to another agent or subagent. Use when writing or editing AGENTS.md, CLAUDE.md or a skill, or when briefing another agent.
---

# Prompt writing

The reader is a capable model that can read the repository. Write only what it can't work out from the code, and say each thing once.

## Give the outcome, the reason and the finish

- State the outcome, the scope and what done looks like. A clear done condition keeps the agent from stopping early.
- Give the reason behind each constraint. A model that knows why a rule exists applies it to cases the rule didn't name.
- Point exactly: the path, the symbol, the command, the README section. Whether the agent follows a pointer depends on its wording.
- Say what to do rather than what to avoid.
- Hand over what the agent can't discover: decisions already made and why, what was tried and failed, who owns which files, and what the user prefers.

## Keep instructions calm and consistent

- Write in a normal voice. Current Claude models follow instructions closely, and capitals, "CRITICAL" or "if in doubt, always" make them overapply a rule.
- Put each instruction in one place. Conflicting guidance across a skill, AGENTS.md and the prompt can make a model stop and block early. Where instructions can conflict, state the priority: the user's instructions win over a skill.
- Write the prompt in the form you want back. A prompt in prose tends to get prose, and one built from headings and bullets tends to get markdown.
- Call each thing by one name throughout.

## Keep context small

- Every line of AGENTS.md or CLAUDE.md loads into every session. Put material needed in one task out of ten behind a pointer to the file that holds it.
- Link every reference file directly from the entry file. A file reached through another reference may be read only in part.
- Leave out facts that expire, or put them where the current value lives and point there.

## Prune by behavior

- A line is a no-op if the agent acts the same without it. Delete the whole sentence, not a few of its words.
- Don't ask an agent to "shorten" or "streamline" a prompt. It optimizes for length and cuts instructions that mattered.
- Test by running it. Give a fresh agent a real task with only this prompt, watch where it goes wrong, and fix that failure rather than one you imagine.

## Writing a skill

- Write the description in the third person. Say what the skill does and when to use it, with the words a user would say. The description is all that loads before the skill is chosen.
- Keep SKILL.md under 500 lines. Move detail that only one branch of the task needs into a file SKILL.md links directly.

## Sources

- Anthropic, [Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices): give context and motivation, say what to do instead of what not to do, match prompt style to output, and dial back aggressive language on current models.
- Anthropic, [Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices): assume the model is capable, third-person descriptions, references one level deep, no time-sensitive facts, test with real tasks.
- OpenAI, [Prompting the latest model](https://developers.openai.com/api/docs/guides/latest-model): conflicting skill guidance can block work early, and the user's instructions should outrank a skill.
- Matt Pocock, [Writing skills for agents](https://aihero.dev/skills-writing-for-agents): pointer wording, done conditions, the no-op test, and testing by running the document.
