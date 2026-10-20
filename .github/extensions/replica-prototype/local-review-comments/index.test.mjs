import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { writeFile } from "node:fs/promises"
import path from "node:path"
import { describe, it } from "node:test"

import { createLocalReviewComments } from "./index.mjs"
import { withContext } from "../test-support/with-context/index.mjs"

const scope = {
  hubOrigin: "https://hub.example.com",
  repository: "github/replica",
  branch: "prototype",
  viewerLogin: "octocat",
}

function git(context, ...args) {
  return execFileSync("git", args, { cwd: context.repositoryPath, encoding: "utf8" }).trim()
}

function revision(context) {
  const treeSha = git(context, "rev-parse", "HEAD^{tree}")
  return { id: Number.parseInt(treeSha.slice(0, 12), 16), treeSha }
}

function localComments(context) {
  return createLocalReviewComments(context, {
    directory: path.join(context.repositoryPath, ".git", "local-review-comments"),
  })
}

function build(context) {
  return {
    repositoryId: 5,
    prototypeId: 4,
    number: 7,
    commitSha: git(context, "rev-parse", "HEAD"),
    publishedAt: "2099-01-01T00:00:00Z",
  }
}

describe("local review comments", () => {
  it("persists editable roots and their captured selection across instances", async () => {
    await withContext(async (context) => {
      const captured = revision(context)
      const anchor = { schemaVersion: 1, kind: "element", selector: "#save" }
      const created = await localComments(context).create(scope, captured, {
        body: "Keep this selection",
        anchor,
      })
      assert.ok(Number.isSafeInteger(created.id) && created.id > 0)
      assert.equal(created.kind, "root")
      assert.equal(created.body, "Keep this selection")
      assert.equal(created.author.login, scope.viewerLogin)
      assert.equal(created.buildNumber, null)
      assert.equal(created.buildPath, null)
      assert.equal(created.draftRevisionId, captured.id)
      assert.equal(created.viewerCanEdit, true)
      assert.equal(created.viewerCanDelete, true)
      assert.deepEqual(created.anchor, anchor)
      assert.deepEqual(await localComments(context).list(scope), [created])

      await writeFile(path.join(context.repositoryPath, "edited.txt"), "Changed after selection")
      const updated = await localComments(context).update(scope, created.id, "Revised feedback")
      assert.equal(updated.body, "Revised feedback")
      assert.equal(updated.draftRevisionId, captured.id)
      assert.deepEqual(updated.anchor, anchor)
      assert.deepEqual(await localComments(context).list(scope), [updated])

      const removed = await localComments(context).remove(scope, created.id)
      assert.equal(removed.id, created.id)
      assert.ok(removed.deletedAt)
      assert.deepEqual(await localComments(context).list(scope), [])
    })
  })

  it("isolates comments by Hub, repository, branch and reviewer", async () => {
    await withContext(async (context) => {
      const comments = localComments(context)
      const captured = revision(context)
      const original = await comments.create(scope, captured, {
        body: "Original reviewer",
        anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
      })
      for (const changed of [
        { hubOrigin: "https://another-hub.example.com" },
        { repository: "github/another" },
        { branch: "another-branch" },
        { viewerLogin: "mona" },
      ]) {
        const isolated = { ...scope, ...changed }
        assert.deepEqual(await comments.list(isolated), [])
        const created = await comments.create(isolated, captured, {
          body: "Another scope",
          anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
        })
        assert.deepEqual(await localComments(context).list(isolated), [created])
        assert.deepEqual(await localComments(context).list(scope), [original])
      }
    })
  })

  it("uploads only matching source to an imported Build even when its commit differs", async () => {
    await withContext(async (context) => {
      const comments = localComments(context)
      const captured = revision(context)
      const originalCommit = git(context, "rev-parse", "HEAD")
      const anchor = { schemaVersion: 1, kind: "element", selector: "#original" }
      await comments.create(scope, captured, { body: "Matching source", anchor })
      await writeFile(path.join(context.repositoryPath, "new.txt"), "Different source")
      git(context, "add", "new.txt")
      const otherTree = git(context, "write-tree")
      const other = { id: Number.parseInt(otherTree.slice(0, 12), 16), treeSha: otherTree }
      const retained = await comments.create(scope, other, {
        body: "Not in this Build",
        anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
      })
      git(context, "reset", "--quiet")
      git(
        context,
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.com",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--allow-empty",
        "-qm",
        "Same source, different commit",
      )
      const imported = build(context)
      assert.notEqual(imported.commitSha, originalCommit)
      const requests = []
      await comments.sync(scope, imported, {
        async request(route, options) {
          requests.push({ route, options })
          return { comments: [{ id: 900, kind: "root", buildNumber: imported.number }] }
        },
      })
      assert.equal(requests.length, 1)
      assert.equal(requests[0].route, "/api/canvas/repositories/5/prototypes/4/review_comments")
      assert.equal(requests[0].options.method, "POST")
      assert.equal(requests[0].options.expectedTarget.repository, scope.repository)
      assert.equal(requests[0].options.expectedTarget.branch, scope.branch)
      assert.deepEqual(requests[0].options.body.review_comment, {
        body: "Matching source",
        anchor,
        build_number: imported.number,
      })
      assert.deepEqual(await localComments(context).list(scope), [retained])
      await comments.sync(scope, imported, {
        async request() {
          assert.fail("A synchronized comment must not be uploaded twice.")
        },
      })
    })
  })

  it("does not upload a draft when the Build source differs or cannot be resolved", async () => {
    await withContext(async (context) => {
      const comments = localComments(context)
      const imported = build(context)
      await writeFile(path.join(context.repositoryPath, "new.txt"), "Unpublished edits")
      git(context, "add", "new.txt")
      const treeSha = git(context, "write-tree")
      const draft = await comments.create(
        scope,
        { id: Number.parseInt(treeSha.slice(0, 12), 16), treeSha },
        {
          body: "Only this source",
          anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
        },
      )
      const hub = {
        async request() {
          assert.fail("An unrelated or unknown Build must not receive local feedback.")
        },
      }
      await comments.sync(scope, imported, hub)
      assert.deepEqual(await localComments(context).list(scope), [draft])
      await assert.rejects(comments.sync(scope, { ...imported, commitSha: "f".repeat(40) }, hub))
      assert.deepEqual(await localComments(context).list(scope), [draft])
    })
  })

  it("does not attach new feedback to an older Build with the same source tree", async () => {
    await withContext(async (context) => {
      const comments = localComments(context)
      const imported = build(context)
      const draft = await comments.create(scope, revision(context), {
        body: "Feedback captured after the old Build",
        anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
      })
      await comments.sync(
        scope,
        {
          ...imported,
          publishedAt: new Date(Date.parse(draft.createdAt) - 1).toISOString(),
        },
        {
          async request() {
            assert.fail("A Build published before the feedback must not claim it.")
          },
        },
      )
      assert.deepEqual(await localComments(context).list(scope), [draft])
      let uploads = 0
      await localComments(context).sync(
        scope,
        { ...imported, number: 8 },
        {
          async request(route, options) {
            uploads += 1
            assert.equal(options.body.review_comment.build_number, 8)
            return { comments: [{ id: 903, kind: "root", buildNumber: 8 }] }
          },
        },
      )
      assert.equal(uploads, 1)
      assert.deepEqual(await localComments(context).list(scope), [])
    })
  })

  it("retains rejected uploads for a later retry and propagates the Hub error", async () => {
    await withContext(async (context) => {
      const comments = localComments(context)
      const draft = await comments.create(scope, revision(context), {
        body: "Retry this feedback",
        anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
      })
      const failure = Object.assign(new Error("Hub denied the request"), { statusCode: 403 })
      await assert.rejects(
        comments.sync(scope, build(context), {
          async request() {
            throw failure
          },
        }),
        (error) => error === failure,
      )
      assert.deepEqual(await localComments(context).list(scope), [draft])
      let retries = 0
      await localComments(context).sync(scope, build(context), {
        async request() {
          retries += 1
          return { comments: [{ id: 901, kind: "root", buildNumber: 7 }] }
        },
      })
      assert.equal(retries, 1)
      assert.deepEqual(await localComments(context).list(scope), [])
    })
  })

  it("keeps previous Prototype feedback separate even when a new history has the same source", async () => {
    await withContext(async (context) => {
      const comments = localComments(context)
      const captured = revision(context)
      const previous = await comments.create(
        scope,
        { ...captured, prototypeId: 4 },
        {
          body: "Feedback for the previous history",
          anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
        },
      )
      await comments.create(
        scope,
        { ...captured, prototypeId: 9 },
        {
          body: "Feedback for the current history",
          anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
        },
      )
      const imported = { ...build(context), prototypeId: 9 }
      let uploads = 0
      await localComments(context).sync(scope, imported, {
        async request(route, options) {
          uploads += 1
          assert.equal(route, "/api/canvas/repositories/5/prototypes/9/review_comments")
          assert.equal(options.body.review_comment.body, "Feedback for the current history")
          return { comments: [{ id: 904, kind: "root", buildNumber: imported.number }] }
        },
      })
      assert.equal(uploads, 1)
      assert.deepEqual(await localComments(context).list(scope), [previous])
    })
  })

  it("reconciles an ambiguous upload to its original Build after a newer Build arrives", async () => {
    await withContext(async (context) => {
      const comments = localComments(context)
      const draft = await comments.create(scope, revision(context), {
        body: "Response was lost",
        anchor: { schemaVersion: 1, kind: "element", selector: "#save" },
      })
      const imported = build(context)
      const failure = new Error("Connection lost after sending")
      await assert.rejects(
        comments.sync(scope, imported, {
          async request() {
            throw failure
          },
        }),
        (error) => error === failure,
      )
      const pending = [{ ...draft, viewerCanEdit: false }]
      assert.deepEqual(await localComments(context).list(scope), pending)
      const newerBuild = { ...imported, number: imported.number + 1 }
      let reads = 0
      await assert.rejects(
        localComments(context).sync(scope, newerBuild, {
          async request(route, options) {
            assert.notEqual(options.method, "POST", "An uncertain save must never be replayed.")
            reads += 1
            return { comments: [], hasMore: false, nextCursor: null }
          },
        }),
        /could not be confirmed/,
      )
      assert.equal(reads, 1)
      assert.deepEqual(await localComments(context).list(scope), pending)
      await localComments(context).sync(scope, newerBuild, {
        async request(route, options) {
          assert.notEqual(options.method, "POST", "Reconciliation must not create another root.")
          return {
            comments: [
              {
                ...draft,
                id: 902,
                buildNumber: imported.number,
                createdAt: new Date().toISOString(),
              },
            ],
            hasMore: false,
            nextCursor: null,
          }
        },
      })
      assert.deepEqual(await localComments(context).list(scope), [])
    })
  })
})
