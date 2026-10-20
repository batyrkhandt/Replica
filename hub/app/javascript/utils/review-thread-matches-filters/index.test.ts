import { describe, expect, it } from "vitest"

import type { ReviewThread } from "@utils/review-comment/types"

import { reviewThreadMatchesFilters } from "."

const THREAD: ReviewThread = {
  root: {
    id: 1,
    kind: "root",
    buildNumber: 2,
    buildPath: "/repositories/2001/prototypes/1?build=2",
    body: "Align the save button.",
    anchor: {
      schemaVersion: 1,
      kind: "element",
      route: { pathname: "/settings", search: "?tab=profile", hash: "" },
      selector: "#save",
      accessibleName: "Save",
      tagName: "button",
      selectedText: "",
      rect: { x: 20, y: 30, width: 100, height: 32 },
      viewport: { width: 1_280, height: 720, scrollX: 0, scrollY: 0 },
      elementOffset: { x: 0.5, y: 0.5 },
    },
    createdAt: "2026-09-14T12:00:00Z",
    updatedAt: "2026-09-14T12:00:00Z",
    editedAt: null,
    deletedAt: null,
    resolvedAt: null,
    resolvedBy: null,
    activityVersion: 1,
    viewerLastSeenActivityVersion: 1,
    author: { login: "octocat", name: "The Octocat", avatarUrl: null },
    viewerCanEdit: true,
    viewerCanDelete: true,
    reactions: [],
  },
  replies: [
    {
      id: 2,
      kind: "reply",
      rootId: 1,
      body: "Updated in the latest build.",
      createdAt: "2026-09-14T13:00:00Z",
      updatedAt: "2026-09-14T13:00:00Z",
      editedAt: null,
      deletedAt: null,
      author: { login: "mona", name: "Mona Lisa", avatarUrl: null },
      viewerCanEdit: false,
      viewerCanDelete: false,
      reactions: [],
    },
  ],
  participants: [
    { login: "octocat", name: "The Octocat", avatarUrl: null },
    { login: "mona", name: "Mona Lisa", avatarUrl: null },
  ],
  lastActivityAt: "2026-09-14T13:00:00Z",
  unread: false,
}

const DEFAULT_CONTEXT = {
  filters: {
    search: "",
    currentBuildOnly: false,
    currentPageOnly: false,
    showResolved: false,
    showRead: true,
    onlyMine: false,
    participant: null,
  },
  viewerLogin: "hubot",
  selectedBuildNumber: 2,
  route: { pathname: "/settings", search: "?tab=profile", hash: "" },
}

describe("reviewThreadMatchesFilters()", () => {
  it("keeps the selected draft revision visible after it is associated with a Build", () => {
    const context = {
      ...DEFAULT_CONTEXT,
      selectedBuildNumber: null,
      selectedDraftRevisionId: 11,
      filters: { ...DEFAULT_CONTEXT.filters, currentBuildOnly: true },
    }
    for (const buildNumber of [null, 2]) {
      expect(
        reviewThreadMatchesFilters(
          { ...THREAD, root: { ...THREAD.root, draftRevisionId: 11, buildNumber } },
          context,
        ),
      ).toBe(true)
    }
    expect(
      reviewThreadMatchesFilters(
        { ...THREAD, root: { ...THREAD.root, draftRevisionId: 12, buildNumber: null } },
        context,
      ),
    ).toBe(false)
    expect(reviewThreadMatchesFilters(THREAD, context)).toBe(false)
  })

  it("continues filtering published comments by the selected Build without a draft revision", () => {
    const context = {
      ...DEFAULT_CONTEXT,
      selectedDraftRevisionId: null,
      filters: { ...DEFAULT_CONTEXT.filters, currentBuildOnly: true },
    }
    expect(reviewThreadMatchesFilters(THREAD, context)).toBe(true)
    expect(
      reviewThreadMatchesFilters({ ...THREAD, root: { ...THREAD.root, buildNumber: 3 } }, context),
    ).toBe(false)
  })

  it("searches root comments, replies, authors, and saved anchor context", () => {
    for (const search of ["save", "latest", "mona", "button"]) {
      expect(
        reviewThreadMatchesFilters(THREAD, {
          ...DEFAULT_CONTEXT,
          filters: { ...DEFAULT_CONTEXT.filters, search },
        }),
      ).toBe(true)
    }
  })

  it("hides resolved threads until the reviewer includes them", () => {
    const resolved = {
      ...THREAD,
      root: {
        ...THREAD.root,
        resolvedAt: "2026-09-14T14:00:00Z",
        resolvedBy: THREAD.root.author,
      },
    }

    expect(reviewThreadMatchesFilters(resolved, DEFAULT_CONTEXT)).toBe(false)
    expect(
      reviewThreadMatchesFilters(resolved, {
        ...DEFAULT_CONTEXT,
        filters: { ...DEFAULT_CONTEXT.filters, showResolved: true },
      }),
    ).toBe(true)
  })

  it("matches any participant in the conversation", () => {
    expect(
      reviewThreadMatchesFilters(THREAD, {
        ...DEFAULT_CONTEXT,
        filters: { ...DEFAULT_CONTEXT.filters, participant: "mona" },
      }),
    ).toBe(true)
    expect(
      reviewThreadMatchesFilters(THREAD, {
        ...DEFAULT_CONTEXT,
        filters: { ...DEFAULT_CONTEXT.filters, participant: "hubot" },
      }),
    ).toBe(false)
  })

  it("shows only unread conversations when Show read is off", () => {
    const context = {
      ...DEFAULT_CONTEXT,
      filters: { ...DEFAULT_CONTEXT.filters, showRead: false },
    }
    expect(reviewThreadMatchesFilters(THREAD, context)).toBe(false)
    expect(reviewThreadMatchesFilters({ ...THREAD, unread: true }, context)).toBe(true)
  })

  it("includes threads the viewer started or replied to when Only your threads is on", () => {
    const context = {
      ...DEFAULT_CONTEXT,
      filters: { ...DEFAULT_CONTEXT.filters, onlyMine: true },
    }
    expect(reviewThreadMatchesFilters(THREAD, context)).toBe(false)
    expect(reviewThreadMatchesFilters(THREAD, { ...context, viewerLogin: "OCTOCAT" })).toBe(true)
    expect(reviewThreadMatchesFilters(THREAD, { ...context, viewerLogin: "mona" })).toBe(true)
  })
})
