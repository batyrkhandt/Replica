import assert from "node:assert/strict"
import { createServer } from "node:http"
import path from "node:path"

import { chromium } from "../../actions/build/node_modules/playwright/index.mjs"
import { startCanvasServer } from "../../.github/extensions/replica-prototype/start-canvas-server/index.mjs"
import { withContext } from "../../.github/extensions/replica-prototype/test-support/with-context/index.mjs"
import { createCanvasContext } from "../../.github/extensions/replica-prototype/create-canvas-context/index.mjs"
import { createImprovementNotes } from "../../.github/extensions/replica-prototype/improvement-notes/index.mjs"

function sanitize(message) {
  return String(message).replace(/https?:\/\/\S+/g, "[local resource]")
}
const prototype = createServer((request, response) => {
  if (request.url === "/controls.replica.json") {
    response.writeHead(404).end()
    return
  }
  response.writeHead(200, { "Content-Type": "text/html" })
  response.end(
    '<!doctype html><html><head><title>Projects</title></head><body><button id="save">Save project</button></body></html>',
  )
})
let browser
let phase = "startup"
const errors = []
const failedAssets = []

try {
  await new Promise((resolve) => prototype.listen(0, "127.0.0.1", resolve))
  const address = prototype.address()
  assert.ok(address && typeof address === "object")
  browser = await chromium.launch({
    executablePath: "/usr/bin/chromium",
    args: ["--no-sandbox"],
  })
  await withContext(async (fixture) => {
    const context = await createCanvasContext({
      prototypeUrl: `http://127.0.0.1:${address.port}/projects?view=active#list`,
      name: "Renderer smoke",
      sessionId: "renderer-smoke",
      repository: fixture.target.repository,
      repositoryPath: fixture.repositoryPath,
      sessionWorkspacePath: fixture.sessionWorkspacePath,
    })
    const dispatched = []
    const session = { send: async (message) => dispatched.push(message) }
    const directory = path.join(context.sessionWorkspacePath, "notes")
    const store = createImprovementNotes(
      () => context,
      session,
      async () => null,
      { directory },
    )
    const canvas = await startCanvasServer(context, session, {
      improvementNotesDirectory: directory,
      hubOptions: { directory: path.join(context.sessionWorkspacePath, "credentials") },
    })
    let page
    try {
      page = await browser.newPage()
      page.on("pageerror", (error) => errors.push(sanitize(error.message)))
      page.on("response", (response) => {
        const url = new URL(response.url())
        if (url.pathname.startsWith("/assets/") && response.status() !== 200)
          failedAssets.push({ asset: path.basename(url.pathname), status: response.status() })
      })
      page.on("requestfailed", (request) => {
        const url = new URL(request.url())
        if (url.pathname.startsWith("/assets/"))
          failedAssets.push({ asset: path.basename(url.pathname), error: "request failed" })
      })
      await page.route("**/api/**", async (route) => {
        const pathname = new URL(route.request().url()).pathname
        // Keep notes, source capture, and batch persistence on the real disk API.
        if (pathname.startsWith("/api/improvement-notes")) return route.continue()
        if (pathname === "/api/state" || pathname === "/api/refresh")
          return route.fulfill({
            json: {
              name: "Renderer smoke",
              stats: { branch: "prototype", commitSha: "a".repeat(40), workingTree: "clean" },
              publishRequest: { state: "idle", requestedAt: null },
            },
          })
        if (pathname === "/api/agent/next") return route.fulfill({ json: { command: null } })
        return route.fulfill({ json: { state: "unconfigured" } })
      })
      const cards = page.getByRole("button", { name: /^Open improvement:/ })
      const dialog = page.getByRole("dialog", { name: "Improvement", exact: true })
      function fix(count) {
        return page.getByRole("button", {
          name: `Fix all, ${count} pending ${count === 1 ? "request" : "requests"}`,
          exact: true,
        })
      }
      async function filter(name) {
        await page.getByRole("button", { name: /^Filter improvement notes:/ }).click()
        await page.getByRole("menuitemradio", { name, exact: true }).click()
      }
      async function answer(batch, message) {
        await store.results({
          batchId: batch.id,
          results: [
            {
              localId: batch.notes[0].localId,
              revision: batch.notes[0].revision,
              status: "ready",
              message,
            },
          ],
        })
      }

      phase = "select preview target and save locally"
      await page.goto(canvas.url)
      const picker = page.getByRole("button", { name: "Pick & polish", exact: true })
      await picker.click()
      assert.ok(await fix(0).isDisabled())
      const preview = page.frameLocator('iframe[title="Renderer smoke prototype"]')
      await preview.locator("[data-replica-canvas-bridge]").first().waitFor()
      // The bridge's selection surface receives this real pointer click over the target.
      await preview
        .getByRole("button", { name: "Save project", exact: true })
        .click({ force: true })
      const composer = page.getByRole("dialog", { name: "Add improvement note", exact: true })
      await composer
        .getByRole("textbox", { name: "What should change?", exact: true })
        .fill("Make the save action clearer.")
      await composer.getByRole("button", { name: "Save note", exact: true }).click()
      await cards.first().waitFor()
      assert.equal(await cards.count(), 1)
      let state = await store.load()
      assert.equal(state.notes.length, 1)
      assert.equal(state.notes[0].body, "Make the save action clearer.")
      assert.equal(state.notes[0].anchor.selector, "#save")
      assert.deepEqual(state.notes[0].anchor.route, {
        pathname: "/projects",
        search: "?view=active",
        hash: "#list",
      })
      assert.equal(state.notes[0].status, "open")
      assert.equal(dispatched.length, 0)

      phase = "explicit first batch"
      await fix(1).click()
      await page.getByText("In progress", { exact: true }).waitFor()
      state = await store.load()
      const first = await store.batch({ batchId: state.activeBatch })
      assert.equal(dispatched.length, 1)
      assert.deepEqual(first.notes[0].requestIds, [state.notes[0].localId])
      assert.ok(await fix(0).isDisabled())

      phase = "follow-up while the captured batch is pending"
      await cards.first().click()
      await dialog
        .getByRole("textbox", { name: "Follow-up", exact: true })
        .fill("Keep the existing shortcut.")
      const followUpSaved = page.waitForResponse(
        (response) =>
          new URL(response.url()).pathname === "/api/improvement-notes" &&
          response.request().method() === "POST" &&
          response.request().postDataJSON()?.operation === "follow-up" &&
          response.ok(),
      )
      await dialog.getByRole("button", { name: "Add follow-up", exact: true }).click()
      await followUpSaved
      await dialog.getByText("Keep the existing shortcut.", { exact: true }).waitFor()
      state = await store.load()
      const followUp = state.notes[0].thread.messages.find((message) => message.role === "author")
      assert.ok(followUp)
      assert.equal(dispatched.length, 1)
      assert.deepEqual(await store.batch({ batchId: first.id }), first)
      await answer(first, "The save action is clearer.")
      await dialog.getByText("The save action is clearer.", { exact: true }).waitFor()
      state = await store.load()
      assert.equal(state.notes[0].status, "open")
      assert.equal(dispatched.length, 1)
      assert.ok(await fix(1).isEnabled())
      await dialog.getByRole("button", { name: "Close improvement", exact: true }).click()
      await filter("Ready to review")
      assert.equal(await cards.count(), 0)
      await filter("Active notes")
      await cards.first().waitFor()

      phase = "explicit subsequent batch answers only the follow-up"
      await fix(1).click()
      await page.getByText("In progress", { exact: true }).waitFor()
      state = await store.load()
      const second = await store.batch({ batchId: state.activeBatch })
      assert.notEqual(second.id, first.id)
      assert.deepEqual(second.notes[0].requestIds, [followUp.id])
      assert.equal(dispatched.length, 2)
      await answer(second, "The existing shortcut is preserved.")
      await page.getByText("Ready to review", { exact: true }).waitFor()
      assert.equal((await store.load()).notes[0].status, "ready")
      await cards.first().click()
      await dialog.getByText("The existing shortcut is preserved.", { exact: true }).waitFor()
      if (process.env.REPLICA_CANVAS_SCREENSHOT)
        await page.screenshot({ path: process.env.REPLICA_CANVAS_SCREENSHOT, fullPage: true })
      await dialog.getByRole("button", { name: "Close improvement", exact: true }).click()

      phase = "resolve and filter"
      await page.getByRole("button", { name: "Improvement actions: 1", exact: true }).click()
      await page.getByRole("menuitem", { name: "Mark as resolved", exact: true }).click()
      await cards.first().waitFor({ state: "hidden" })
      await filter("Resolved")
      await cards.first().waitFor()
      const saved = (await store.load()).notes
      assert.equal(saved[0].status, "resolved")
      assert.equal(saved[0].body, "Make the save action clearer.")
      assert.deepEqual(
        saved[0].thread.messages.map(({ role, body }) => ({ role, body })),
        [
          { role: "author", body: "Keep the existing shortcut." },
          { role: "copilot", body: "The save action is clearer." },
          { role: "copilot", body: "The existing shortcut is preserved." },
        ],
      )

      phase = "reload retains local history"
      await page.reload()
      await filter("Resolved")
      await cards.first().click()
      for (const body of [
        saved[0].body,
        ...saved[0].thread.messages.map((message) => message.body),
      ])
        await dialog.getByText(body, { exact: true }).waitFor()
      const reloaded = createImprovementNotes(
        () => context,
        session,
        async () => null,
        { directory },
      )
      assert.deepEqual((await reloaded.load()).notes, saved)
      assert.equal(dispatched.length, 2)

      phase = "confirmed deletion"
      await dialog.getByRole("button", { name: "Close improvement", exact: true }).click()
      await page.getByRole("button", { name: "Improvement actions: 1", exact: true }).click()
      await page.getByRole("menuitem", { name: "Delete improvement", exact: true }).click()
      const deletion = page.getByRole("dialog", { name: "Delete this improvement?", exact: true })
      await deletion.waitFor()
      assert.equal((await store.load()).notes.length, 1)
      await deletion.getByRole("button", { name: "Delete improvement", exact: true }).click()
      await deletion.waitFor({ state: "hidden" })
      await cards.first().waitFor({ state: "hidden" })
      assert.equal((await reloaded.load()).notes.length, 0)
      assert.equal(dispatched.length, 2)
      assert.deepEqual(errors, [])
      assert.deepEqual(failedAssets, [])
      console.log(
        "Packaged renderer smoke passed: local notes, explicit batches, and persisted history.",
      )
    } finally {
      await page?.close()
      await canvas.close()
    }
  })
} catch (error) {
  console.error(
    JSON.stringify({
      phase,
      reason: sanitize(error.message.split("\n")[0]),
      source: error.stack?.match(/check-prototype-canvas-renderer\.mjs:\d+:\d+/)?.[0],
      runtimeErrors: errors,
      failedAssets,
    }),
  )
  // eslint-disable-next-line preserve-caught-error -- Playwright errors may include private capability URLs.
  throw new Error("Packaged renderer smoke failed; see sanitized diagnostics above.")
} finally {
  await browser?.close()
  if (prototype.listening)
    await new Promise((resolve, reject) =>
      prototype.close((error) => (error ? reject(error) : resolve())),
    )
}
