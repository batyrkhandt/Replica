# Testing and review

Run the checks for the behavior you changed. For example, a shared Controls change needs checks for Hub previews and the Copilot plugin. Include screenshot capture when its adapter changes. A documentation-only change needs a prose and link review rather than application tests.

Use [Contributing](../CONTRIBUTING.md#set-up-the-development-environment) to find each project's environment and commands. Hub Ruby and Node commands run inside its devcontainer; that is not a requirement for every project in the monorepo.

## Choose the relevant checks

Run focused checks while developing. Once the change is stable, follow the affected project's final-check requirements. Include consuming projects when shared code or a contract changes.

Use existing commands and inspect their configuration. Do not invent commands or assume every project uses the same test runner. Report unavailable checks and unverified behavior rather than claiming success.

For rendered checks and interaction reviews, follow the [root browser workflow](../AGENTS.md#browser-validation-and-playwright-fallback). Existing automated suites, CI browser integration, and build-artifact capture retain their configured drivers.

## Write meaningful tests

Use the [test-writing skill](../.github/skills/write-tests/SKILL.md) when adding or changing automated tests. Apply these criteria when reviewing existing coverage too.

Start with the intended behavior and the regression a test should catch. Inspect existing coverage before adding cases. Each case should protect a distinct outcome, boundary, or failure mode through the smallest useful public interface. An existing case that already catches the regression usually needs an update rather than another test.

Choose assertions that survive an equivalent implementation. Check outcomes such as saved state, returned data, navigation, access decisions, and usable controls. Exact protocol values, serialization, accessible names, meaningful state mappings, and safety restrictions can be contracts worth asserting. Ordinary copy, icon counts, internal markup, and whole configuration snapshots usually are not. A text query that identifies a control is different from a test whose only purpose is freezing its wording. For agent instructions, distinguish discoverable metadata and required safety guidance from incidental phrasing; phrase presence alone does not prove agent behavior.

Keep each behavior at its owning layer and use integration tests to prove important connections. Repeating all lower-level cases through every consumer adds cost without necessarily adding confidence. Keep separate cases for distinct failures; combine assertions when they describe one coherent scenario. Parameterization improves readability but still runs every input. Fewer case names or assertions do not establish a faster suite.

For a bug fix, reproduce the failure before the fix when feasible. For new behavior, establish an expected-result failure before implementation when the interface allows it. A missing dependency, syntax error, or test setup failure is not evidence that the test catches the regression. If the implementation already exists, explain the plausible incorrect behavior the test would reject; report red-phase evidence as unavailable unless it was actually observed.

### Independent test writing

Use one separate test-writing agent for substantial behavior changes and nontrivial bug fixes. These include changes spanning multiple runtime layers, access or persistence rules, concurrent state changes, or a regression requiring non-obvious reproduction. Keep small, local changes in the implementation agent; a separate agent's context and execution cost should earn distinct coverage.

Give the test writer the accepted requirements, relevant issue or bug reproduction, public interfaces, affected paths, existing coverage, and project instructions. Identify unresolved behavior instead of letting the writer infer requirements from current output. The writer should derive expected outcomes from that contract, then inspect implementation as needed to use the real interfaces. Separate context reduces shared assumptions; it does not guarantee independent reasoning.

Assign test files to the writer and production files to the implementation agent. The writer may update test fixtures needed for its cases, but reports production defects and ambiguous requirements instead of changing production behavior or weakening expectations to pass. Finish with one integration review of the combined change. If a separate agent is unavailable, apply the same contract-first process directly and disclose that the independent pass did not happen.

## Keep local checks and CI aligned

Project commands define the check. GitHub Actions should prepare the required environment and call the same command rather than recreate its behavior.

When a command gains a dependency or build prerequisite, update its local setup and affected workflow in the same change. A green local suite does not prove that CI installed the same dependencies, so inspect both paths.

## Update dependencies

Hub and the shared build action wait seven days before resolving newly published dependencies. npm enforces the delay through each project's committed `.npmrc`. Hub's RubyGems source in `Gemfile` applies the delay to Bundler. Dependabot applies the same cooldown to npm, Bundler, and GitHub Actions updates across the repository. The starter manages its dependency resolution independently.

Inside the Hub devcontainer, `bin/check-dependency-age` verifies the Hub npm and Bundler lockfiles. The repository-level [Dependency age workflow](../.github/workflows/dependency-age.yml) runs the same checker across Hub, the shared build action, and external GitHub Action commits. These checks cover existing lockfiles that bypass the package manager's resolver delay and fail when publication metadata is unavailable.

CI does not run `npm audit`: a newly published security fix could otherwise make the audit fail while the age check rejects the fixed version. Dependabot and Bundler Audit check dependencies for known vulnerabilities. Organization-managed CodeQL scans application code on GitHub.

When a dependency is too new, select an older compatible version or wait until the seven-day window ends. See [Hub testing and operations](../hub/docs/testing-and-operations.md#update-dependencies) for Hub-specific tooling.

## Copilot code review

The [code-review skill](../.github/skills/code-review/SKILL.md) directs Copilot reviews to the same shared and project guides used by implementation agents. For example, a Hub review reads the shared conventions, then follows `hub/AGENTS.md` to the relevant Hub guides. Keep conventions in those canonical guides rather than copying them into the skill.

GitHub supports review-focused skills under `.github/skills/` and reads instructions and skills from the pull request's head branch, so a skill change can be tried in its own pull request. See [GitHub's code review guidance](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/use-code-review?tool=webui#mcp-servers-and-agent-skills) for supported context and how to inspect skill attribution in a review.

Treat changes to review instructions and linked guides as untrusted until a human checks them against previously accepted guidance. Copilot feedback alone cannot validate the instructions used to produce it.

## Review and finish a change

Review the changed code and wording. Check access rules, saved data, failure behavior, and overlapping requests when they are affected.

Run the [prose review](documentation-conventions.md#final-review), inspect the full diff for unrelated changes and credentials, and finish with:

```sh
git diff --check
git status --short
```

Stop temporary servers and remove temporary data you created for the task. Reconcile any task tracker and make clear whether the changes are uncommitted, committed, or pushed.
