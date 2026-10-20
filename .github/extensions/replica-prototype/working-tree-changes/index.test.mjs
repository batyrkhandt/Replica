import assert from "node:assert/strict"
import { it } from "node:test"

import { classifyWorkingTreeChanges, MAX_LISTED_CHANGES } from "./index.mjs"

it("treats only local agent skills as tooling and counts every other change", () => {
  const status = [
    "?? .github/skills/replica-publish-prototype/SKILL.md",
    " M .agents/skills/setup/SKILL.md",
    "A  .claude/skills/review/SKILL.md",
    " M src/App.tsx",
    "?? .github/workflows/replica.yml",
    "R  src/New.tsx",
    "src/Old.tsx",
    "R  .github/skills/moved/SKILL.md",
    "src/skill.md",
    "",
  ].join("\0")
  assert.deepEqual(classifyWorkingTreeChanges(status), {
    state: "changed",
    files: {
      paths: [
        "src/App.tsx",
        ".github/workflows/replica.yml",
        "src/New.tsx",
        ".github/skills/moved/SKILL.md",
      ],
      total: 4,
    },
    localSkills: {
      paths: [
        ".github/skills/replica-publish-prototype/SKILL.md",
        ".agents/skills/setup/SKILL.md",
        ".claude/skills/review/SKILL.md",
      ],
      total: 3,
    },
  })
})

it("reports a checkout with only local skill changes as clean", () => {
  assert.equal(classifyWorkingTreeChanges("?? .github/skills/a/SKILL.md\0").state, "clean")
  assert.equal(classifyWorkingTreeChanges("").state, "clean")
})

it("caps listed paths while keeping the full count", () => {
  const entries = Array.from({ length: MAX_LISTED_CHANGES + 5 }, (_, index) => ` M file-${index}`)
  const result = classifyWorkingTreeChanges(entries.join("\0"))
  assert.equal(result.files.paths.length, MAX_LISTED_CHANGES)
  assert.equal(result.files.total, MAX_LISTED_CHANGES + 5)
})
