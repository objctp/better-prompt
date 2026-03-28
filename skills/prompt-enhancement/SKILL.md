---
name: prompt-enhancement
description: This skill should be used when the user asks to "enhance my prompt", "improve this prompt", "make this clearer", or when refining prompts for clarity and specificity. Provides guidance for reconstructing prompts to achieve better outcomes.
version: 0.1.0
---

# Prompt Enhancement

This skill provides guidance for refining and reconstructing prompts to achieve better outcomes from Claude. Focus on clarity and specificity improvements.

## Core Principles

**Clarity**: Remove ambiguity, use precise language, and eliminate unnecessary words.

**Specificity**: Include concrete details, context, and explicit requirements.

**Structure**: Organise information logically with clear sections or bullet points.

**@mentions**: Treat any token beginning with `@` (e.g. `@src/auth.ts`, `@README.md`) as an opaque file/folder reference. Reproduce it verbatim — do not rephrase, expand, or reposition it.

## Enhancement Process

To enhance a prompt, follow these steps:

1. **Identify the core request** - What is the user actually asking for?
2. **Add missing context** - What background information would help?
3. **Clarify constraints** - Are there limitations or requirements?
4. **Specify output format** - How should the response be structured?
5. **Remove redundancy** - Eliminate repetitive or unnecessary words

## Key Improvements

### Vague → Specific

**Vague:** "Fix the code"
**Specific:** "Fix the authentication bug in the login function where users with special characters in passwords cannot log in"

### Ambiguous → Clear

**Ambiguous:** "Make it faster"
**Clear:** "Reduce the API response time from 500ms to under 200ms by implementing caching"

### Missing Context → Context-Rich

**Missing context:** "Create a function"
**Context-rich:** "Create a Python function that validates email addresses using regex for a Django user registration form"

## Prompt Structure Template

Enhanced prompts typically follow this structure:

1. **Context** - Background information about the task
2. **Request** - Clear statement of what is needed
3. **Constraints** - Limitations, requirements, or preferences
4. **Output format** - Expected structure or style of response

## Common Enhancements

### Adding Context

- "For a React application..." → "For a React 18 application using TypeScript and Tailwind CSS..."
- "Write a function..." → "Write a function that processes user input from a web form..."

### Specifying Constraints

- "Create a layout..." → "Create a responsive layout that works on mobile (320px+) and desktop (1024px+)"
- "Optimize this code..." → "Optimize for O(n) time complexity and O(1) space complexity"

### Clarifying Output

- "Generate a report..." → "Generate a markdown report with sections for Overview, Analysis, and Recommendations"
- "Create documentation..." → "Create documentation including installation steps, usage examples, and API reference"

## Examples

### Before and After

**Original:** "make me a website"
**Enhanced:** "Create a responsive landing page for a SaaS product including a hero section, features grid, pricing table, and contact form. Use modern design principles and ensure mobile compatibility."

**Original:** "fix the bug"
**Enhanced:** "Investigate and fix the bug where the shopping cart total is not updating when items are removed. The issue occurs in the updateCart() function in cart.js."

**Original:** "write tests"
**Enhanced:** "Write unit tests for the user authentication module using Jest. Cover login, logout, password reset, and account creation scenarios. Include edge cases for invalid input."

**Original:** "refactor @src/auth.ts so it handles null inputs gracefully"
**Enhanced:** "Refactor @src/auth.ts to handle null and undefined inputs gracefully: add null guards at function entry points, return safe defaults rather than throwing, and add inline comments explaining each guard."

Note: `@src/auth.ts` is reproduced verbatim; only the request is expanded.

## Anti-Patterns to Avoid

- **Overly verbose**: Don't add fluff—every word should add meaning
- **Over-constraining**: Too many restrictions may limit creative solutions
- **Missing the goal**: Ensure the enhanced prompt still addresses the original intent
- **Changing meaning**: Enhancement should clarify, not alter what the user wants
- **Altering @mentions**: Never rephrase or expand `@mention` tokens; reproduce them exactly as written

## Quick Reference

| Issue               | Enhancement                         |
| ------------------- | ----------------------------------- |
| Ambiguous pronouns  | Replace with specific nouns         |
| Missing context     | Add relevant background information |
| Unclear constraints | Specify limitations explicitly      |
| Vague output        | Define expected format explicitly   |
| Redundant phrases   | Remove unnecessary repetition       |
