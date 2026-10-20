import assert from "node:assert/strict"
import { createServer } from "node:http"
import path from "node:path"
import { readFile, writeFile } from "node:fs/promises"

import { chromium } from "../../actions/build/node_modules/playwright/index.mjs"
import { startCanvasServer } from "../../.github/extensions/replica-prototype/start-canvas-server/index.mjs"
import { withContext } from "../../.github/extensions/replica-prototype/test-support/with-context/index.mjs"
import { createCanvasContext } from "../../.github/extensions/replica-prototype/create-canvas-context/index.mjs"
import { createImprovementNotes } from "../../.github/extensions/replica-prototype/improvement-notes/index.mjs"

const prototype = createServer((request, response) => {
  if (request.url === "/controls.replica.json") {
    response.writeHead(404)
    response.end()
    return
  }
  response.writeHead(200, { "Content-Type": "text/html" })
  response.end(
    '<!doctype html><html><head><title>Projects</title></head><body style="margin:0;padding:80px"><button id="save" style="width:120px;height:40px">Save project</button></body></html>',
  )
})
await new Promise((resolve) => prototype.listen(0, "127.0.0.1", resolve))
const address = prototype.address()
assert.ok(address && typeof address === "object")

const browser = await chromium.launch({
  executablePath: "/usr/bin/chromium",
  args: ["--no-sandbox"],
})
const branchDiscoveryNotice = "Notes are saved locally until Hub discovers this branch."
const toolbarBranch = "prototype/refine-project-navigation-and-review-workflow"
const fixtureAuthor = {
  id: 7,
  login: "mona",
  avatarUrl: "https://avatars.githubusercontent.com/u/7",
}
const modes = process.argv.length > 2 ? process.argv.slice(2) : ["sample", "real", "comments"]
assert.ok(modes.every((mode) => ["sample", "real", "comments"].includes(mode)))
const fixtureComment = {
  id: 1,
  kind: "root",
  buildNumber: 1,
  buildPath: "/repositories/1/prototypes/1?build=1",
  body: "Please align this control with the content above it.",
  anchor: {
    schemaVersion: 1,
    kind: "element",
    route: { pathname: "/projects", search: "?view=active", hash: "#list" },
    selector: "#save",
    accessibleName: "Save project",
    tagName: "button",
    selectedText: "",
    rect: { x: 80, y: 80, width: 120, height: 40 },
    viewport: { width: 1280, height: 900, scrollX: 0, scrollY: 0 },
    elementOffset: { x: 0.5, y: 0.5 },
  },
  createdAt: "2026-09-14T12:00:00Z",
  updatedAt: "2026-09-14T12:00:00Z",
  editedAt: null,
  deletedAt: null,
  resolvedAt: null,
  resolvedBy: null,
  activityVersion: 2,
  viewerLastSeenActivityVersion: 2,
  author: { ...fixtureAuthor, name: null },
  viewerCanEdit: true,
  viewerCanDelete: true,
  reactions: [
    { content: "heart", count: 1, viewerHasReacted: true },
    { content: "rocket", count: 2, viewerHasReacted: false },
  ],
}

try {
  await withContext(async (fixtureContext) => {
    const context = await createCanvasContext({
      prototypeUrl: `http://127.0.0.1:${address.port}/projects?view=active#list`,
      name: "Renderer smoke",
      sessionId: "renderer-smoke",
      repository: fixtureContext.target.repository,
      repositoryPath: fixtureContext.repositoryPath,
      sessionWorkspacePath: fixtureContext.sessionWorkspacePath,
    })
    for (const mode of modes) {
      const sample = mode === "sample"
      const ordinary = mode === "comments"
      const dispatched = []
      const session = { send: async (message) => dispatched.push(message) }
      const notesDirectory = path.join(context.sessionWorkspacePath, "notes")
      const store = createImprovementNotes(
        () => context,
        session,
        async () => null,
        { directory: notesDirectory },
      )
      const canvas = await startCanvasServer(
        { ...context, improvementThreadsSample: sample },
        session,
        {
          improvementNotesDirectory: path.join(context.sessionWorkspacePath, "notes"),
          hubOptions: { directory: path.join(context.sessionWorkspacePath, "credentials") },
        },
      )
      const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
      if (ordinary)
        await page.route(canvas.url, async (route) => {
          const response = await route.fetch()
          await route.fulfill({
            response,
            body: (await response.text()).replace('"pickAndPolish":true', '"pickAndPolish":false'),
          })
        })
      const errors = []
      const failedAssets = []
      const noteRequests = []
      let holdSync = false
      let releaseSync
      let syncHeld
      let holdDelete = false
      let releaseDelete
      let deleteHeld
      let deletionRequests = 0
      let failNextDelete = false
      let phase = "document"
      let sharedDialogStyle
      async function rowPresentation(row, state) {
        const evidence = []
        for (const width of [1280, 390]) {
          await page.setViewportSize({ width, height: 900 })
          for (const appearance of ["dark", "light"]) {
            phase = `${state} row ${appearance} at ${width}`
            await page
              .getByRole("button", {
                name: `${appearance === "dark" ? "Dark" : "Light"} appearance`,
              })
              .click()
            await row.hover()
            await page.mouse.move(0, 0)
            const before = await row.locator(".review-comment-row__body").boundingBox()
            await row.hover()
            const style = await row.evaluate((element) => {
              const sidebar = element.closest(".hub-sidebar")
              const sidebarBox = sidebar.getBoundingClientRect()
              const sidebarStyle = getComputedStyle(sidebar)
              const box = element.getBoundingClientRect()
              const highlight = getComputedStyle(element, "::before")
              const hit = getComputedStyle(
                element.querySelector(".review-comment-row__button"),
                "::after",
              )
              const author = getComputedStyle(element.querySelector(".review-comment-row__author"))
              const body = getComputedStyle(element.querySelector(".review-comment-row__body"))
              const probe = document.createElement("span")
              element.append(probe)
              function token(name) {
                probe.style.color = `var(${name})`
                return getComputedStyle(probe).color
              }
              const foreground = token("--hub-fg-default")
              const muted = token("--hub-fg-muted")
              probe.style.backgroundColor = "var(--brand-color-border-muted)"
              const background = getComputedStyle(probe).backgroundColor
              probe.remove()
              return {
                author: author.color,
                weight: author.fontWeight,
                body: body.color,
                foreground,
                muted,
                background: highlight.backgroundColor,
                expectedBackground: background,
                gutters: [
                  box.left +
                    parseFloat(highlight.left) -
                    sidebarBox.left -
                    parseFloat(sidebarStyle.borderLeftWidth),
                  sidebarBox.right -
                    box.right +
                    parseFloat(highlight.right) -
                    parseFloat(sidebarStyle.borderRightWidth),
                ],
                hitContainsHighlight:
                  parseFloat(hit.left) <= parseFloat(highlight.left) &&
                  parseFloat(hit.right) <= parseFloat(highlight.right),
                unread: element.classList.contains("review-comment-row--unread"),
              }
            })
            assert.equal(style.author, state === "active" ? style.foreground : style.muted)
            assert.equal(style.body, state === "active" ? style.foreground : style.muted)
            assert.equal(style.weight, state === "active" ? "600" : "400")
            assert.equal(style.unread, false)
            assert.equal(style.background, style.expectedBackground)
            assert.deepEqual(style.gutters.map(Math.round), [8, 12])
            assert.ok(style.hitContainsHighlight)
            const after = await row.locator(".review-comment-row__body").boundingBox()
            assert.equal(after.x, before.x)
            evidence.push({ width, appearance, state, ...style })
          }
        }
        await page.setViewportSize({ width: 1280, height: 900 })
        console.log(JSON.stringify({ rowPresentation: evidence }))
      }
      async function dialogStyle(dialog) {
        return dialog.evaluate((element) => {
          const shell = getComputedStyle(element)
          const header = getComputedStyle(element.querySelector(".canvas-dialog-header"))
          const close = element.querySelector(".canvas-dialog-header .hub-icon-button")
          return {
            width: shell.width,
            padding: shell.padding,
            border: shell.border,
            borderRadius: shell.borderRadius,
            background: shell.backgroundColor,
            headerGap: header.gap,
            headerMargin: header.marginBottom,
            closeClass: close.className,
            closeBackground: getComputedStyle(close).backgroundColor,
          }
        })
      }
      async function fixButton(count) {
        const button = page.getByRole("button", {
          name: `Fix all, ${count} pending ${count === 1 ? "request" : "requests"}`,
          exact: true,
        })
        const counter = button.locator(".hub-counter")
        await counter.waitFor({ state: "visible" })
        assert.equal(await counter.textContent(), String(count))
        assert.doesNotMatch(await button.textContent(), /[()]/)
        assert.equal(await counter.getAttribute("aria-hidden"), "true")
        const geometry = await button.evaluate((element) => {
          const label = element.querySelector(".thread-sample__fix-label")
          const badge = element.querySelector(".hub-counter").getBoundingClientRect()
          const box = element.getBoundingClientRect()
          return {
            slot: Boolean(label?.contains(element.querySelector(".hub-counter"))),
            inside:
              badge.width > 0 &&
              badge.height > 0 &&
              badge.left >= box.left &&
              badge.right <= box.right,
          }
        })
        assert.ok(geometry.slot && geometry.inside)
        return button
      }
      async function counterColors(button, enabled) {
        const colors = await button.evaluate((element) => {
          const canvas = document.createElement("canvas")
          canvas.width = canvas.height = 1
          const context = canvas.getContext("2d")
          function rgba(color) {
            context.clearRect(0, 0, 1, 1)
            context.fillStyle = color
            context.fillRect(0, 0, 1, 1)
            return Array.from(context.getImageData(0, 0, 1, 1).data)
          }
          const counter = element.querySelector(".hub-counter")
          const badge = getComputedStyle(counter)
          return {
            button: rgba(getComputedStyle(element).backgroundColor),
            background: rgba(badge.backgroundColor),
            foreground: rgba(badge.color),
            buttonForeground: rgba(getComputedStyle(element).color),
            parentForeground: rgba(getComputedStyle(counter.parentElement).color),
            labelForeground: element.querySelector(".thread-sample__fix-label")
              ? rgba(getComputedStyle(element.querySelector(".thread-sample__fix-label")).color)
              : null,
            neutral: rgba(badge.getPropertyValue("--hub-fg-default")),
            opacity: badge.opacity,
            appearance: element.closest("[data-color-mode]")?.getAttribute("data-color-mode"),
          }
        })
        if (colors.labelForeground)
          assert.deepEqual(colors.foreground, colors.labelForeground, JSON.stringify(colors))
        else if (enabled)
          assert.deepEqual(colors.foreground, colors.parentForeground, JSON.stringify(colors))
        assert.equal(colors.opacity, "1")
        assert.ok(Math.abs(colors.background[3] / 255 - 0.1) < 0.005, JSON.stringify(colors))
        assert.deepEqual(
          colors.background.slice(0, 3),
          colors.neutral.slice(0, 3),
          JSON.stringify(colors),
        )
        const neutral = colors.neutral.slice(0, 3).reduce((sum, value) => sum + value, 0) / 3
        assert.ok(
          colors.appearance === "dark" ? neutral > 192 : neutral < 64,
          JSON.stringify(colors),
        )
        assert.equal(await button.isEnabled(), enabled)
        return colors
      }
      async function counterStates(button) {
        const enabled = await button.isEnabled()
        const rest = await counterColors(button, enabled)
        const count = await button.locator(".hub-counter").textContent()
        const bounds = await button.locator(".hub-counter").boundingBox()
        const states = { rest: rest.background }
        const foregroundStates = { rest: rest.foreground }
        if (enabled) {
          await button.hover()
          const hover = await counterColors(button, true)
          states.hover = hover.background
          foregroundStates.hover = hover.foreground
          await page.mouse.down()
          const pressed = await counterColors(button, true)
          states.pressed = pressed.background
          foregroundStates.pressed = pressed.foreground
          await page.mouse.move(0, 0)
          await page.mouse.up()
          for (const attribute of ["disabled", "aria-disabled"]) {
            await button.evaluate((element, name) => element.setAttribute(name, "true"), attribute)
            const disabled = await counterColors(button, false)
            states[attribute] = disabled.background
            foregroundStates[attribute] = disabled.foreground
            await button.evaluate((element, name) => element.removeAttribute(name), attribute)
          }
        }
        const after = await button.locator(".hub-counter").boundingBox()
        assert.equal(after.width, bounds.width)
        assert.equal(after.height, bounds.height)
        assert.equal(await button.locator(".hub-counter").textContent(), count)
        return {
          name: await button.getAttribute("aria-label"),
          count,
          background: rest.background,
          foreground: rest.foreground,
          appearance: rest.appearance,
          enabled,
          states,
          foregroundStates,
        }
      }
      async function copilotAvatars(dialog) {
        for (const appearance of ["dark", "light"]) {
          await page
            .getByRole("button", {
              name: `${appearance === "dark" ? "Dark" : "Light"} appearance`,
              exact: true,
            })
            .click()
          const avatars = await dialog
            .locator(".thread-sample__copilot-avatar")
            .evaluateAll(async (elements) =>
              Promise.all(
                elements.map(async (element) => {
                  const image = element.querySelector("img")
                  await image.decode()
                  const style = getComputedStyle(element)
                  const bounds = element.getBoundingClientRect()
                  const canvas = document.createElement("canvas")
                  canvas.width = canvas.height = 16
                  const context = canvas.getContext("2d")
                  context.fillStyle = style.getPropertyValue(
                    element.closest("[data-color-mode]")?.getAttribute("data-color-mode") === "dark"
                      ? "--hub-success-emphasis"
                      : "--hub-fg-success",
                  )
                  context.fillRect(0, 0, 1, 1)
                  const expected = Array.from(context.getImageData(0, 0, 1, 1).data)
                  context.fillStyle = style.backgroundColor
                  context.fillRect(0, 0, 1, 1)
                  const background = Array.from(context.getImageData(0, 0, 1, 1).data)
                  context.clearRect(0, 0, 16, 16)
                  context.drawImage(image, 0, 0, 16, 16)
                  const pixels = context.getImageData(0, 0, 16, 16).data
                  let opaque = 0
                  let white = true
                  for (let index = 0; index < pixels.length; index += 4) {
                    if (!pixels[index + 3]) continue
                    opaque++
                    white &&=
                      pixels[index] === 255 &&
                      pixels[index + 1] === 255 &&
                      pixels[index + 2] === 255
                  }
                  return {
                    width: bounds.width,
                    height: bounds.height,
                    radius: style.borderRadius,
                    padding: getComputedStyle(image).padding,
                    alt: image.alt,
                    background,
                    expected,
                    opaque,
                    white,
                  }
                }),
              ),
            )
          assert.ok(avatars.length > 0)
          for (const avatar of avatars) {
            assert.equal(avatar.width, 28)
            assert.equal(avatar.height, 28)
            assert.ok(
              avatar.radius === "50%" || parseFloat(avatar.radius) >= avatar.width / 2,
              JSON.stringify(avatar),
            )
            assert.equal(avatar.padding, "6px")
            assert.equal(avatar.alt, "")
            assert.deepEqual(avatar.background, avatar.expected)
            assert.ok(avatar.background[1] > avatar.background[0])
            assert.ok(avatar.background[1] > avatar.background[2])
            assert.ok(avatar.opaque > 0 && avatar.white)
            const linear = avatar.background.slice(0, 3).map((channel) => {
              const value = channel / 255
              return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
            })
            const luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
            assert.ok(1.05 / (luminance + 0.05) >= 3, JSON.stringify(avatar))
          }
        }
      }
      async function deleteGeometry(dialog) {
        await page.mouse.move(0, 0)
        assert.deepEqual(await dialogStyle(dialog), sharedDialogStyle)
        const geometry = await dialog.evaluate((element) => {
          const quote = element.querySelector("blockquote").getBoundingClientRect()
          const actions = element
            .querySelector(".thread-sample__delete-actions")
            .getBoundingClientRect()
          const buttons = element.querySelectorAll(".thread-sample__delete-actions button")
          const cancel = buttons[0].getBoundingClientRect()
          const confirm = buttons[1].getBoundingClientRect()
          return {
            gap: actions.top - quote.bottom,
            adjacent: confirm.left - cancel.right,
            right: actions.right - confirm.right,
            ordered: cancel.right <= confirm.left,
          }
        })
        assert.equal(geometry.gap, 16)
        assert.equal(geometry.adjacent, 8)
        assert.ok(Math.abs(geometry.right) < 1 && geometry.ordered)
        assert.equal(
          await dialog
            .getByText("This improvement and its follow-ups will be removed.", { exact: true })
            .count(),
          0,
        )
        const close = dialog.locator(".canvas-dialog-header .hub-icon-button")
        assert.equal(
          await close.evaluate((element) =>
            element.classList.contains("hub-icon-button--invisible"),
          ),
          false,
        )
        for (const hovered of [false, true]) {
          if (hovered) await close.hover()
          else await page.mouse.move(0, 0)
          assert.notEqual(
            await close.evaluate((element) => getComputedStyle(element).backgroundColor),
            "rgba(0, 0, 0, 0)",
          )
        }
      }
      async function deleteCursor() {
        const item = page.getByRole("menuitem", { name: "Delete improvement", exact: true })
        await item.hover()
        assert.equal(await item.getAttribute("aria-disabled"), "false")
        assert.equal(await item.evaluate((element) => getComputedStyle(element).cursor), "default")
      }
      async function toolbarPalette() {
        const evidence = []
        const controls = page.locator(".canvas-toolbar .canvas-controls-toggle")
        async function colors() {
          return controls.evaluate((button) => {
            const style = getComputedStyle(button)
            function resolve(token) {
              const probe = document.createElement("span")
              probe.style.backgroundColor = `var(${token})`
              button.closest(".canvas-toolbar").append(probe)
              const value = getComputedStyle(probe).backgroundColor
              probe.remove()
              return value
            }
            return {
              background: style.backgroundColor,
              rest: resolve("--brand-button-secondary-bgColor-rest"),
              hover: resolve("--brand-button-secondary-bgColor-hover"),
              pressed: resolve("--brand-button-secondary-bgColor-active"),
            }
          })
        }
        for (const appearance of ["dark", "light"]) {
          await page
            .getByRole("button", {
              name: `${appearance === "dark" ? "Dark" : "Light"} appearance`,
              exact: true,
            })
            .click()
          await page.mouse.move(0, 0)
          await page.waitForTimeout(250)
          const originalPublish = await page
            .locator(".canvas-publish-button")
            .evaluate((button) => getComputedStyle(button).backgroundColor)
          const rest = await colors()
          assert.equal(rest.background, rest.rest)
          assert.equal(
            rest.rest,
            appearance === "dark" ? "rgba(255, 255, 255, 0.12)" : "rgba(0, 0, 0, 0.06)",
          )
          const neutral = await page
            .locator(".canvas-toolbar button:not(.canvas-title,.canvas-publish-button)")
            .evaluateAll((buttons) =>
              buttons.map((button) => ({
                name: button.getAttribute("aria-label"),
                disabled: button.disabled || button.getAttribute("aria-disabled") === "true",
                selected:
                  button.getAttribute("aria-pressed") === "true" ||
                  button.getAttribute("aria-expanded") === "true",
                background: getComputedStyle(button).backgroundColor,
              })),
            )
          for (const button of neutral)
            assert.equal(
              button.background,
              button.selected && !button.disabled ? rest.hover : rest.rest,
              JSON.stringify(button),
            )
          await controls.hover()
          await page.waitForTimeout(250)
          assert.equal((await colors()).background, rest.hover)
          await controls.click()
          assert.equal(await controls.getAttribute("aria-expanded"), "true")
          await page.mouse.move(0, 0)
          await page.waitForTimeout(250)
          assert.equal((await colors()).background, rest.hover)
          await controls.hover()
          await page.waitForTimeout(250)
          assert.equal((await colors()).background, rest.pressed)
          await page.mouse.move(0, 0)
          for (const attribute of ["disabled", "aria-disabled"]) {
            await controls.evaluate((button, name) => button.setAttribute(name, "true"), attribute)
            await page.waitForTimeout(250)
            assert.equal((await colors()).background, rest.pressed)
            await controls.hover()
            await page.waitForTimeout(250)
            assert.equal((await colors()).background, rest.pressed)
            await controls.evaluate((button, name) => button.removeAttribute(name), attribute)
            await page.mouse.move(0, 0)
          }
          const panel = page.getByRole("complementary", { name: "Controls", exact: true })
          const link = panel.getByRole("link", { name: "Learn more", exact: true })
          await link.waitFor({ state: "visible" })
          assert.equal(
            await link.getAttribute("href"),
            "https://github.com/github/replica/blob/main/starter/README.md#prototype-controls",
          )
          assert.equal(await link.getAttribute("target"), "_blank")
          assert.equal(await link.getAttribute("rel"), "noopener noreferrer")
          const footer = await link.evaluate((element) => {
            const bar = element.closest(".canvas-controls-footer")
            const box = element.getBoundingClientRect()
            const bounds = bar.getBoundingClientRect()
            const barStyle = getComputedStyle(bar)
            const style = getComputedStyle(element)
            const icon = element.querySelector("svg.octicon-link-external")
            const range = document.createRange()
            range.selectNodeContents(element.firstChild)
            const text = range.getBoundingClientRect()
            const probe = document.createElement("span")
            probe.style.color = "var(--hub-fg-success)"
            element.append(probe)
            const green = getComputedStyle(probe).color
            probe.remove()
            return {
              bottom: box.bottom,
              messageBottom: element
                .closest(".canvas-controls-panel")
                .querySelector('[role="status"]')
                .getBoundingClientRect().bottom,
              leftInset: box.left - bounds.left,
              footerPadding:
                parseFloat(barStyle.paddingLeft) + parseFloat(barStyle.borderLeftWidth),
              verticalOffset: (box.top + box.bottom - bounds.top - bounds.bottom) / 2,
              color: style.color,
              green,
              decoration: style.textDecorationLine,
              iconColor: getComputedStyle(icon).color,
              iconGap: icon.getBoundingClientRect().left - text.right,
              decorativeIcon: icon.getAttribute("aria-hidden") === "true",
            }
          })
          assert.ok(footer.bottom > footer.messageBottom)
          assert.ok(Math.abs(footer.leftInset - footer.footerPadding) < 1, JSON.stringify(footer))
          assert.ok(Math.abs(footer.verticalOffset) < 1, JSON.stringify(footer))
          assert.equal(footer.color, footer.green)
          assert.equal(footer.iconColor, footer.green)
          assert.equal(footer.decoration, "none")
          assert.ok(footer.iconGap >= 3 && footer.iconGap <= 5, JSON.stringify(footer))
          assert.ok(footer.decorativeIcon)
          await link.hover()
          assert.deepEqual(
            await link.evaluate((element) => ({
              color: getComputedStyle(element).color,
              decoration: getComputedStyle(element).textDecorationLine,
            })),
            { color: footer.green, decoration: "none" },
          )
          await link.focus()
          await page.keyboard.press("Shift+Tab")
          await page.keyboard.press("Tab")
          assert.ok(
            await link.evaluate(
              (element) =>
                element.matches(":focus-visible") &&
                parseFloat(getComputedStyle(element).outlineWidth) > 0,
            ),
          )
          await controls.hover()
          await page.mouse.down()
          await page.waitForTimeout(250)
          assert.equal((await colors()).background, rest.pressed)
          await page.mouse.up()
          assert.equal(await controls.getAttribute("aria-expanded"), "false")
          await page.mouse.move(0, 0)
          await controls.focus()
          await page.keyboard.press("Shift+Tab")
          await page.keyboard.press("Tab")
          assert.ok(
            await controls.evaluate(
              (button) =>
                button.matches(":focus-visible") &&
                parseFloat(getComputedStyle(button).outlineWidth) > 0,
            ),
          )
          await controls.evaluate((button) => {
            button.disabled = true
          })
          await page.waitForTimeout(250)
          assert.equal((await colors()).background, rest.rest)
          await controls.evaluate((button) => {
            button.disabled = false
          })
          await page.mouse.move(0, 0)
          const publish = await page
            .locator(".canvas-publish-button")
            .evaluate((button) => getComputedStyle(button).backgroundColor)
          assert.equal(publish, originalPublish)
          const counters = []
          for (const button of await page.locator("button:has(.hub-counter)").all())
            if (await button.isVisible()) counters.push(await counterStates(button))
          evidence.push({
            appearance,
            rest: rest.rest,
            expanded: rest.hover,
            selectedHover: rest.pressed,
            selectedDisabled: rest.pressed,
            hover: rest.hover,
            pressed: rest.pressed,
            emptyControlsLink: footer,
            counters,
          })
        }
        console.log(JSON.stringify({ sample, toolbarPalette: evidence, emptyControlsReadme: true }))
      }
      page.on("pageerror", (error) =>
        errors.push(error.message.replace(/https?:\/\/\S+/g, "[local asset]")),
      )
      page.on("response", (response) => {
        const url = new URL(response.url())
        if (url.pathname.startsWith("/assets/") && response.status() !== 200)
          failedAssets.push({ asset: path.basename(url.pathname), status: response.status() })
      })
      await page.route(fixtureAuthor.avatarUrl, (route) =>
        route.fulfill({
          contentType: "image/svg+xml",
          body: '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="12" fill="#8250df"/></svg>',
        }),
      )
      await page.route("**/api/**", async (route) => {
        const pathname = new URL(route.request().url()).pathname
        let data = { state: "unconfigured" }
        if (pathname === "/api/agent/next") data = { command: null }
        else if (pathname === "/api/state" || pathname === "/api/refresh")
          data = {
            name: "Renderer smoke",
            stats: { branch: toolbarBranch, commitSha: "a".repeat(40), workingTree: "clean" },
            publishRequest: { state: "idle", requestedAt: null },
          }
        else if (ordinary && pathname === "/api/hub/status")
          data = {
            state: "connected",
            repository: context.target.repository,
            branch: toolbarBranch,
            commitSha: "a".repeat(40),
            hubOrigin: "https://hub.example.com",
            canPublish: false,
            prototype: {
              id: 1,
              repositoryId: 1,
              branch: toolbarBranch,
              name: "Projects",
              description: null,
              viewerLogin: fixtureAuthor.login,
              registered: true,
              published: true,
              canEdit: true,
              canRegister: false,
              buildState: "successful",
              versionCount: 1,
              currentBuild: { commitSha: "a".repeat(40), state: "successful" },
              build: {
                commitSha: "a".repeat(40),
                number: 1,
                publishedAt: "2026-09-28T10:00:00Z",
                url: "https://hub.example.com/prototypes/1",
                author: { ...fixtureAuthor, name: null },
              },
            },
          }
        else if (ordinary && pathname === "/api/hub/comments")
          data = { comments: [fixtureComment], nextCursor: null, hasMore: false }
        else if (pathname.startsWith("/api/improvement-notes")) {
          noteRequests.push(pathname)
          if (!sample) {
            if (
              failNextDelete &&
              pathname === "/api/improvement-notes" &&
              route.request().method() === "POST" &&
              route.request().postDataJSON().operation === "delete"
            ) {
              failNextDelete = false
              return route.fulfill({
                status: 409,
                json: { error: "The improvement could not be deleted." },
              })
            }
            if (holdSync && pathname.endsWith("/sync"))
              await new Promise((resolve) => {
                releaseSync = resolve
                syncHeld?.()
              })
            if (
              holdDelete &&
              pathname === "/api/improvement-notes" &&
              route.request().method() === "POST" &&
              route.request().postDataJSON().operation === "delete"
            ) {
              deletionRequests++
              await new Promise((resolve) => {
                releaseDelete = resolve
                deleteHeld?.()
              })
            }
            const response = await route.fetch()
            const data = await response.json()
            if (
              route.request().method() === "POST" &&
              route.request().postDataJSON().operation === "create" &&
              data.notes?.length === 1
            ) {
              const file = path.join(notesDirectory, `${data.identity}.json`)
              const fixture = JSON.parse(await readFile(file, "utf8"))
              fixture.owner = {
                origin: "https://hub.example.com",
                id: fixtureAuthor.id,
                login: fixtureAuthor.login,
              }
              fixture.notes[0].author = fixtureAuthor.login
              fixture.notes[0].thread = {
                ...fixture.notes[0].thread,
                version: 2,
                originalAuthor: fixtureAuthor,
              }
              await writeFile(file, JSON.stringify(fixture), { mode: 0o600 })
              data.notes[0] = {
                ...data.notes[0],
                author: fixtureAuthor.login,
                thread: fixture.notes[0].thread,
              }
            }
            return route.fulfill({
              response,
              json: { ...data, syncError: branchDiscoveryNotice },
            })
          }
          data = {
            identity: "isolated",
            revision: 0,
            notes: [],
            activeBatch: null,
            syncError: null,
          }
        }
        return route.fulfill({ json: data })
      })
      try {
        await page.goto(canvas.url)
        await page.locator("#root > *").first().waitFor({ state: "visible", timeout: 10_000 })
        await page.getByRole("button", { name: toolbarBranch, exact: true }).waitFor()
        if (!ordinary) await toolbarPalette()
        if (ordinary) {
          phase = "ordinary comment counters"
          const evidence = []
          const toggle = page.locator(".canvas-comments-toggle")
          await toggle.waitFor()
          await counterColors(toggle, true)
          await toggle.click()
          const sidebar = page.getByRole("complementary", { name: "Comments", exact: true })
          await sidebar.locator(".review-comment-row__button").waitFor()
          await rowPresentation(sidebar.locator(".review-comment-row").first(), "read")
          await sidebar.locator(".review-comment-row__button").click()
          await page.locator(".review-comment-reactions .hub-counter").first().waitFor()
          for (const appearance of ["dark", "light"]) {
            phase = `ordinary comment counters ${appearance}`
            await page
              .getByRole("button", {
                name: `${appearance === "dark" ? "Dark" : "Light"} appearance`,
                exact: true,
              })
              .click()
            await page.mouse.move(0, 0)
            await page.waitForTimeout(250)
            const toolbar = await counterColors(toggle, true)
            assert.equal(await toggle.getAttribute("aria-expanded"), "true")
            const selectedColors = await toggle.evaluate((button) => {
              const probe = document.createElement("span")
              button.closest(".canvas-toolbar").append(probe)
              probe.style.backgroundColor = "var(--brand-button-secondary-bgColor-hover)"
              const selected = getComputedStyle(probe).backgroundColor
              probe.style.backgroundColor = "var(--brand-button-secondary-bgColor-active)"
              const hover = getComputedStyle(probe).backgroundColor
              probe.remove()
              return { selected, hover, background: getComputedStyle(button).backgroundColor }
            })
            assert.equal(selectedColors.background, selectedColors.selected)
            await toggle.hover()
            await page.waitForTimeout(250)
            assert.equal(
              await toggle.evaluate((button) => getComputedStyle(button).backgroundColor),
              selectedColors.hover,
            )
            await page.mouse.move(0, 0)
            await counterColors(sidebar.locator(".hub-counter").locator(".."), true)
            const reactions = []
            for (const button of await page
              .locator(".review-comment-reactions > button:has(.hub-counter)")
              .all()) {
              await button.waitFor({ state: "visible" })
              reactions.push({
                ...(await counterStates(button)),
                selected: await button.getAttribute("aria-pressed"),
              })
            }
            assert.equal(reactions.length, 2)
            assert.deepEqual(
              reactions.map(({ count }) => count),
              ["1", "2"],
            )
            evidence.push({ appearance, toolbar, selectedColors, reactions })
          }
          assert.deepEqual(errors, [])
          assert.deepEqual(failedAssets, [])
          assert.deepEqual(dispatched, [])
          console.log(JSON.stringify({ ordinaryCommentCounters: evidence }))
          console.log("ordinary comments packaged renderer: counters verified, no runtime errors")
          continue
        }
        const toolbarSizes = []
        for (const width of [
          1600, 1280, 1100, 1024, 1023, 900, 700, 600, 480, 390, 389, 388, 387, 345, 344, 343, 342,
          320, 280, 240, 1600,
        ]) {
          await page.setViewportSize({ width, height: 900 })
          const size = await page.locator(".canvas-toolbar").evaluate((toolbar) => {
            const title = toolbar.querySelector(".canvas-title")
            const text = title.querySelector(":scope > span")
            const box = toolbar.getBoundingClientRect()
            const titleBox = title.getBoundingClientRect()
            const actions = Array.from(toolbar.querySelectorAll("button"))
              .filter((button) => button !== title && button.getBoundingClientRect().width)
              .map((button) => button.getBoundingClientRect())
            const centers = actions.map((rect) => rect.top + rect.height / 2)
            return {
              width: box.width,
              overflow: toolbar.scrollWidth > toolbar.clientWidth,
              sameRow: Math.max(...centers) - Math.min(...centers) < 1,
              titleWidth: titleBox.width,
              clipped: text.scrollWidth > text.clientWidth,
              ellipsis: getComputedStyle(text).textOverflow,
              fullTitle: title.textContent,
              hoverTitle: title.title,
              right: box.right - Math.max(...actions.map((rect) => rect.right)),
              overlap: actions.some(
                (rect) =>
                  rect.left < titleBox.right &&
                  rect.right > titleBox.left &&
                  rect.top < titleBox.bottom &&
                  rect.bottom > titleBox.top,
              ),
            }
          })
          assert.equal(size.overflow, false, JSON.stringify(size))
          assert.equal(size.overlap, false, JSON.stringify(size))
          assert.equal(size.fullTitle, toolbarBranch)
          assert.ok(size.hoverTitle.includes(toolbarBranch))
          assert.equal(size.ellipsis, "ellipsis")
          assert.ok(Math.abs(size.right - (width <= 480 ? 10 : 8)) < 1, JSON.stringify(size))
          assert.equal(size.sameRow, width >= (sample ? 343 : 388), JSON.stringify(size))
          if (width === 1600) assert.equal(size.clipped, false, JSON.stringify(size))
          if (width === 600) assert.equal(size.clipped, true, JSON.stringify(size))
          toolbarSizes.push({
            width,
            titleWidth: size.titleWidth,
            clipped: size.clipped,
            sameRow: size.sameRow,
          })
        }
        console.log(JSON.stringify({ sample, toolbarSizes }))
        await page.locator(".canvas-toolbar").evaluate((toolbar) => {
          toolbar.style.width = "600px"
        })
        const contained = await page.locator(".canvas-toolbar").evaluate((toolbar) => {
          const title = toolbar.querySelector(".canvas-title > span")
          const centers = Array.from(toolbar.querySelectorAll("button:not(.canvas-title)"))
            .map((button) => button.getBoundingClientRect())
            .filter((rect) => rect.width)
            .map((rect) => rect.top + rect.height / 2)
          return {
            width: toolbar.getBoundingClientRect().width,
            clipped: title.scrollWidth > title.clientWidth,
            sameRow: Math.max(...centers) - Math.min(...centers) < 1,
            overflow: toolbar.scrollWidth > toolbar.clientWidth,
          }
        })
        assert.equal(contained.width, 600)
        assert.ok(
          contained.clipped && contained.sameRow && !contained.overflow,
          JSON.stringify(contained),
        )
        await page.locator(".canvas-toolbar").evaluate((toolbar) => {
          toolbar.style.removeProperty("width")
        })
        await page.setViewportSize({ width: 1280, height: 900 })
        await page.getByRole("button", { name: toolbarBranch, exact: true }).click()
        const details = page.getByRole("dialog", { name: "Build details", exact: true })
        await details.waitFor({ state: "visible" })
        await page.mouse.move(0, 0)
        sharedDialogStyle = await dialogStyle(details)
        await details.getByRole("button", { name: "Close build details", exact: true }).click()
        if (sample) {
          await page
            .getByRole("button", { name: "Open improvements", exact: true })
            .waitFor({ state: "visible" })
          async function realisticCopy() {
            const text = await page
              .locator(
                ".thread-sample, .thread-sample__surface, [role='status'], dialog.canvas-dialog",
              )
              .evaluateAll((elements) =>
                elements
                  .map(
                    (element) =>
                      `${element.textContent} ${Array.from(
                        element.querySelectorAll("[aria-label], [title], [placeholder]"),
                      )
                        .map((node) =>
                          [
                            node.getAttribute("aria-label"),
                            node.getAttribute("title"),
                            node.getAttribute("placeholder"),
                          ].join(" "),
                        )
                        .join(" ")}`,
                  )
                  .join(" "),
              )
            assert.doesNotMatch(text, /\b(sample|demo|simulat\w*|experiment)\b/i)
          }
          await realisticCopy()
          const cards = page.getByRole("button", { name: /^Open improvement:/ })
          assert.equal(await cards.count(), 3)
          await rowPresentation(page.locator(".thread-sample__card").first(), "active")
          await rowPresentation(page.locator(".thread-sample__card").last(), "active")
          const avatar = await cards.first().locator(".hub-user-avatar").boundingBox()
          assert.equal(avatar.width, 20)
          assert.equal(avatar.height, 20)
          const alignment = await page
            .locator(".thread-sample__card")
            .nth(1)
            .evaluate((card) => ({
              body: card.querySelector(".review-comment-row__body").getBoundingClientRect().left,
              metadata: card.querySelector(".thread-sample__metadata").getBoundingClientRect().left,
              followUps: card.querySelector(".thread-sample__follow-ups").getBoundingClientRect()
                .left,
            }))
          assert.equal(alignment.metadata, alignment.body)
          assert.equal(alignment.followUps, alignment.body)
          const ready = page.locator(".thread-sample__status--ready").first()
          const badge = await ready.evaluate((element) => {
            const style = getComputedStyle(element)
            const card = element.closest(".thread-sample__card")
            const body = card.querySelector(".review-comment-row__body").getBoundingClientRect()
            const author = card.querySelector(".review-comment-row__author").getBoundingClientRect()
            const badge = element.getBoundingClientRect()
            return {
              border: style.borderTopStyle,
              width: parseFloat(style.borderTopWidth),
              color: style.borderTopColor,
              background: style.backgroundColor,
              beside:
                author.right <= badge.left &&
                badge.top < author.bottom &&
                author.top < badge.bottom,
              above: badge.bottom <= body.top,
              metadataGap:
                card.querySelector(".thread-sample__metadata").getBoundingClientRect().top -
                body.bottom,
            }
          })
          assert.equal(badge.border, "solid")
          assert.ok(badge.width >= 1)
          assert.equal(badge.background, "rgba(0, 0, 0, 0)")
          assert.ok(badge.above)
          assert.ok(badge.beside)
          assert.ok(Math.abs(badge.metadataGap - 4) < 0.1)
          const green = badge.color.match(/\d+/g).map(Number)
          assert.ok(green[1] > green[0] && green[1] > green[2])
          assert.equal(await cards.last().locator(".thread-sample__status").count(), 0)
          assert.equal(await cards.last().getByText("Open", { exact: true }).count(), 0)
          const summary = page.locator(".thread-sample__follow-ups")
          const summaryStyle = await summary.evaluate((element) => {
            const probe = document.createElement("span")
            probe.style.color = "var(--hub-fg-default)"
            element.append(probe)
            const defaultColor = getComputedStyle(probe).color
            probe.remove()
            return {
              color: getComputedStyle(element).color,
              defaultColor,
              icon: element
                .querySelector('svg.octicon-reply[aria-hidden="true"] path')
                ?.getAttribute("d"),
              interactive: Boolean(element.closest("button, a")),
              iconSize: element.querySelector("svg").getBoundingClientRect().width,
            }
          })
          assert.equal(summaryStyle.color, summaryStyle.defaultColor)
          assert.ok(summaryStyle.icon)
          assert.equal(summaryStyle.interactive, false)
          assert.equal(summaryStyle.iconSize, 12)
          await page.setViewportSize({ width: 520, height: 900 })
          const headingFits = await ready.evaluate((element) => {
            const heading = element.parentElement.getBoundingClientRect()
            const badge = element.getBoundingClientRect()
            return (
              badge.left >= heading.left &&
              badge.right <= heading.right &&
              badge.bottom <= heading.bottom
            )
          })
          assert.ok(headingFits)
          await page.setViewportSize({ width: 1280, height: 900 })
          const fix = await fixButton(1)
          for (const appearance of ["dark", "light"]) {
            await page
              .getByRole("button", {
                name: `${appearance === "dark" ? "Dark" : "Light"} appearance`,
                exact: true,
              })
              .click()
            await page.mouse.move(0, 0)
            console.log(JSON.stringify({ fixAllCounter: await counterStates(fix) }))
          }
          assert.equal(await fix.count(), 1)
          assert.ok(
            await fix.evaluate((element) => Boolean(element.closest(".thread-sample__filters"))),
          )
          const menuTrigger = page.getByRole("button", {
            name: "Improvement actions: 1",
            exact: true,
          })
          await page.mouse.move(0, 0)
          const ghost = await menuTrigger.evaluate((element) => {
            const style = getComputedStyle(element)
            return { background: style.backgroundColor, border: style.borderTopColor }
          })
          assert.equal(ghost.background, "rgba(0, 0, 0, 0)")
          assert.equal(ghost.border, "rgba(0, 0, 0, 0)")
          await menuTrigger.click()
          const markResolved = page.getByRole("menuitem", { name: "Mark as resolved", exact: true })
          assert.equal(
            await page.getByRole("menuitem", { name: "Add follow-up", exact: true }).count(),
            0,
          )
          const resolveIcon = await markResolved.locator("svg path").getAttribute("d")
          assert.ok(
            await markResolved
              .locator("svg")
              .evaluate((icon) => icon.classList.contains("octicon-check-circle")),
          )
          assert.equal(
            await markResolved
              .locator("svg")
              .evaluate((icon) => icon.getBoundingClientRect().width),
            16,
          )
          const menuSpacing = await markResolved.evaluate((element) => ({
            gap: parseFloat(getComputedStyle(element).columnGap),
            separation: parseFloat(getComputedStyle(element.nextElementSibling).marginBlockStart),
          }))
          assert.ok(menuSpacing.gap >= 8)
          assert.ok(menuSpacing.separation >= 4)
          await page.keyboard.press("Escape")
          async function choose(label) {
            await page.getByRole("button", { name: /^Filter improvement notes:/ }).click()
            await page.getByRole("menuitemradio", { name: label, exact: true }).click()
          }
          await choose("Ready to review")
          assert.equal(await cards.count(), 2)
          assert.equal(await page.getByRole("button", { name: /Fix all/ }).count(), 0)
          await choose("Resolved")
          assert.equal(await cards.count(), 0)
          await realisticCopy()
          await page
            .getByText("No improvements in this view.", { exact: true })
            .waitFor({ state: "visible" })
          await choose("Active notes")
          assert.equal(await cards.count(), 3)
          await page
            .getByRole("button", { name: /^Open improvement:/ })
            .first()
            .click()
          await page.getByText("Copilot", { exact: true }).waitFor({ state: "visible" })
          const dialog = page.getByRole("dialog", { name: "Improvement", exact: true })
          await copilotAvatars(dialog)
          assert.equal(await cards.count(), 3)
          assert.equal(await dialog.locator("xpath=ancestor::aside").count(), 0)
          async function constrainedToPreview() {
            await page.waitForFunction(() => {
              const dialog = document.querySelector(".thread-sample__conversation")
              const surface = document.querySelector(".thread-sample__surface")
              const sidebar = document.querySelector("aside.thread-sample")
              if (!dialog || !surface || !sidebar) return false
              const box = dialog.getBoundingClientRect()
              const bounds = surface.getBoundingClientRect()
              return (
                box.width > 0 &&
                box.height > 0 &&
                box.left >= bounds.left - 1 &&
                box.top >= bounds.top - 1 &&
                box.right <= bounds.right + 1 &&
                box.bottom <= bounds.bottom + 1
              )
            })
          }
          await constrainedToPreview()
          async function headerAligned() {
            const alignment = await dialog.evaluate((element) => {
              const header = element.querySelector(".review-thread-conversation__header")
              const edge =
                header.getBoundingClientRect().right -
                parseFloat(getComputedStyle(header).paddingRight)
              const close = element.querySelector(".thread-sample__close").getBoundingClientRect()
              const resolve = element
                .querySelector(".thread-sample__resolve")
                .getBoundingClientRect()
              const title = header.querySelector("h3").getBoundingClientRect()
              return {
                close: Math.abs(close.right - edge),
                actionBeforeClose: resolve.right <= close.left,
                titleRow: close.top < title.bottom && title.top < close.bottom,
                actionRow: resolve.top < close.bottom && close.top < resolve.bottom,
                titleBeforeAction: title.right <= resolve.left,
              }
            })
            assert.ok(alignment.close <= 1)
            assert.ok(alignment.actionBeforeClose)
            assert.ok(alignment.titleBeforeAction)
            assert.ok(alignment.titleRow)
            assert.ok(alignment.actionRow)
          }
          await headerAligned()
          assert.equal(
            await dialog.locator(".thread-sample__resolve svg path").getAttribute("d"),
            resolveIcon,
          )
          await realisticCopy()
          const firstPosition = await dialog.boundingBox()
          const firstMarker = await page
            .getByRole("button", { name: "Open improvement 1", exact: true })
            .boundingBox()
          assert.ok(Math.abs(firstPosition.x - (firstMarker.x + firstMarker.height + 12)) <= 1)
          await page.setViewportSize({ width: 1100, height: 720 })
          await constrainedToPreview()
          await headerAligned()
          await page.setViewportSize({ width: 1280, height: 900 })
          await constrainedToPreview()
          await page.keyboard.press("Escape")
          assert.equal(await dialog.count(), 0)
          assert.ok(await cards.first().evaluate((element) => document.activeElement === element))
          for (const width of [900, 600]) {
            await page.setViewportSize({ width, height: 900 })
            const coveredPin = page.getByRole("button", { name: "Open improvement 2", exact: true })
            assert.equal(
              await coveredPin.evaluate((pin) => {
                const avatar = pin.querySelector(".review-participant-stack__avatar")
                const rect = avatar.getBoundingClientRect()
                return Boolean(
                  document
                    .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
                    ?.closest("aside.thread-sample"),
                )
              }),
              true,
            )
            await cards.nth(1).click()
            await constrainedToPreview()
            assert.equal(
              await dialog.evaluate((element) => {
                const sidebar = document
                  .querySelector("aside.thread-sample")
                  .getBoundingClientRect()
                const box = element.getBoundingClientRect()
                const x = Math.max(box.left, sidebar.left) + 4
                const y = Math.max(box.top, sidebar.top) + 4
                return (
                  x < box.right &&
                  y < box.bottom &&
                  element.contains(document.elementFromPoint(x, y))
                )
              }),
              true,
            )
            await page.keyboard.press("Escape")
          }
          await page.setViewportSize({ width: 1280, height: 900 })
          const secondPoint = page.getByRole("button", { name: "Open improvement 2", exact: true })
          await secondPoint.click()
          await constrainedToPreview()
          const secondPosition = await dialog.boundingBox()
          assert.notEqual(secondPosition.x, firstPosition.x)
          assert.equal(await dialog.getByText("Copilot", { exact: true }).count(), 3)
          await page.keyboard.press("Escape")
          assert.ok(await secondPoint.evaluate((element) => document.activeElement === element))
          await cards.first().click()
          await constrainedToPreview()
          const conversationAvatar = await page
            .locator(".thread-sample__conversation .hub-user-avatar")
            .first()
            .boundingBox()
          assert.equal(conversationAvatar.width, 28)
          assert.equal(conversationAvatar.height, 28)
          await page
            .getByRole("textbox", { name: "Follow-up", exact: true })
            .getAttribute("placeholder")
            .then((value) => assert.equal(value, "Request a follow-up change"))
          await page
            .getByRole("textbox", { name: "Follow-up", exact: true })
            .fill("Keep the stronger label")
          assert.ok(
            await page
              .getByRole("button", { name: "Improvement actions: 1", exact: true })
              .isDisabled(),
          )
          const retainedAnchor = await page
            .getByRole("button", { name: "Open improvement 1", exact: true })
            .boundingBox()
          for (const [label, count] of [
            ["Ready to review", 2],
            ["Resolved", 0],
            ["Active notes", 3],
          ]) {
            assert.ok(
              await page.getByRole("button", { name: /^Filter improvement notes:/ }).isEnabled(),
            )
            await choose(label)
            assert.equal(await cards.count(), count)
            assert.equal(await dialog.count(), 1)
            assert.equal(
              await dialog.getByRole("textbox", { name: "Follow-up", exact: true }).inputValue(),
              "Keep the stronger label",
            )
            assert.deepEqual(
              await page
                .getByRole("button", { name: "Open improvement 1", exact: true })
                .boundingBox(),
              retainedAnchor,
            )
          }
          assert.ok(await (await fixButton(1)).isDisabled())
          await page.keyboard.press("Escape")
          await page
            .getByText("Your unsaved follow-up will be lost.", { exact: true })
            .waitFor({ state: "visible" })
          await page.keyboard.press("Escape")
          assert.equal(
            await page.getByRole("textbox", { name: "Follow-up", exact: true }).inputValue(),
            "Keep the stronger label",
          )
          await page.getByRole("button", { name: "Add follow-up", exact: true }).click()
          await page
            .getByText("Keep the stronger label", { exact: true })
            .waitFor({ state: "visible" })
          await page.getByRole("button", { name: "Close improvement", exact: true }).click()
          await (await fixButton(2)).click()
          await realisticCopy()
          assert.ok(await (await fixButton(0)).isDisabled())
          for (const appearance of ["dark", "light"]) {
            await page
              .getByRole("button", {
                name: `${appearance === "dark" ? "Dark" : "Light"} appearance`,
                exact: true,
              })
              .click()
            await counterColors(await fixButton(0), false)
          }
          await choose("Ready to review")
          assert.equal(await cards.count(), 3)
          await cards.first().click()
          await realisticCopy()
          await page.getByRole("button", { name: "Resolved", exact: true }).click()
          await page.getByRole("button", { name: "Close improvement", exact: true }).click()
          assert.equal(await cards.count(), 2)
          await choose("Resolved")
          assert.equal(await cards.count(), 1)
          await cards.first().click()
          await dialog
            .getByRole("textbox", { name: "Follow-up", exact: true })
            .fill("Retain this filtered draft")
          await choose("Active notes")
          await dialog.getByRole("button", { name: "Close improvement", exact: true }).click()
          await page
            .getByText("Your unsaved follow-up will be lost.", { exact: true })
            .waitFor({ state: "visible" })
          await page.getByRole("button", { name: "Discard", exact: true }).click()
          assert.equal(await dialog.count(), 0)
          assert.ok(
            await page
              .getByRole("button", { name: "Open improvements", exact: true })
              .evaluate((element) => document.activeElement === element),
          )
          await choose("Resolved")
          await page.getByRole("button", { name: "Improvement actions: 1", exact: true }).click()
          await deleteCursor()
          await page.getByRole("menuitem", { name: "Delete improvement", exact: true }).click()
          await page
            .getByRole("dialog", { name: "Delete this improvement?", exact: true })
            .waitFor({ state: "visible" })
          await deleteGeometry(
            page.getByRole("dialog", { name: "Delete this improvement?", exact: true }),
          )
          await realisticCopy()
          await page
            .getByRole("dialog", { name: "Delete this improvement?", exact: true })
            .getByRole("button", { name: "Cancel", exact: true })
            .last()
            .click()
          await cards.first().click()
          await page.getByRole("button", { name: "Improvement actions: 1", exact: true }).click()
          await deleteCursor()
          await page.getByRole("menuitem", { name: "Delete improvement", exact: true }).click()
          const fixtureDelete = page.getByRole("dialog", {
            name: "Delete this improvement?",
            exact: true,
          })
          await fixtureDelete
            .getByRole("button", { name: "Delete improvement", exact: true })
            .click()
          await fixtureDelete.waitFor({ state: "hidden" })
          assert.equal(await dialog.count(), 0)
          assert.equal(await page.locator('[data-improvement-thread-id="1"]').count(), 0)
          assert.ok(
            await page
              .getByRole("button", { name: "Open improvements", exact: true })
              .evaluate((element) => document.activeElement === element),
          )
          assert.deepEqual(noteRequests, [])
          assert.equal(dispatched.length, 0)
        } else {
          phase = "picker readiness"
          const picker = page.getByRole("button", { name: "Pick & polish", exact: true })
          await picker.waitFor({ state: "visible" })
          await page.waitForFunction(
            () => !document.querySelector(".improvement-demo__split button")?.disabled,
          )
          assert.ok(await (await fixButton(0)).isDisabled())
          assert.equal(await page.getByText(branchDiscoveryNotice, { exact: true }).count(), 0)
          assert.equal(await page.locator(".thread-sample__error").count(), 0)
          await picker.click()
          phase = "capture target"
          const target = page
            .frameLocator('iframe[title="Renderer smoke prototype"]')
            .getByRole("button", { name: "Save project", exact: true })
          await page
            .frameLocator('iframe[title="Renderer smoke prototype"]')
            .locator('[data-replica-canvas-bridge][style*="crosshair"]')
            .waitFor({ state: "visible" })
          const selectedBox = await target.boundingBox()
          await page.mouse.click(
            selectedBox.x + selectedBox.width / 2,
            selectedBox.y + selectedBox.height / 2,
          )
          phase = "save original"
          const composer = page.getByRole("dialog", { name: "Add improvement note", exact: true })
          assert.equal(await page.getByText(branchDiscoveryNotice, { exact: true }).count(), 0)
          await composer
            .getByRole("textbox", { name: "What should change?", exact: true })
            .fill("Make the save action clearer.")
          await composer.getByRole("button", { name: "Save note", exact: true }).click()
          const cards = page.getByRole("button", { name: /^Open improvement:/ })
          await cards.first().waitFor({ state: "visible" })
          assert.equal(await cards.count(), 1)
          await rowPresentation(page.locator(".thread-sample__card").first(), "active")
          let state = await store.load()
          phase = "saved anchor"
          assert.equal(state.notes[0].body, "Make the save action clearer.")
          assert.equal(state.notes[0].anchor.selector, "#save")
          assert.deepEqual(state.notes[0].anchor.route, {
            pathname: "/projects",
            search: "?view=active",
            hash: "#list",
          })
          const marker = page.getByRole("button", { name: "Open improvement 1", exact: true })
          await marker.waitFor({ state: "visible" })
          const controlBox = await target.boundingBox()
          const markerBox = await marker.locator(".review-participant-stack__avatar").boundingBox()
          assert.equal(await marker.locator("img").getAttribute("src"), fixtureAuthor.avatarUrl)
          assert.equal(
            await marker
              .locator(".review-participant-stack__avatar")
              .evaluate((element) => getComputedStyle(element).borderRadius),
            "50%",
          )
          assert.equal(
            await marker.evaluate((element) => getComputedStyle(element).backgroundColor),
            "rgba(0, 0, 0, 0)",
          )
          assert.equal(
            await cards.first().locator("img").getAttribute("src"),
            fixtureAuthor.avatarUrl,
          )
          assert.equal(await cards.first().getByText("@mona", { exact: true }).count(), 1)
          phase = "saved pins without sidebar"
          await picker.click()
          await picker.click()
          await marker.waitFor({ state: "visible" })
          assert.equal(await picker.getAttribute("aria-pressed"), "true")
          assert.equal(await page.getByRole("complementary", { name: "Pick & polish" }).count(), 0)
          await marker.click()
          const closedSidebarConversation = page.getByRole("dialog", {
            name: "Improvement",
            exact: true,
          })
          await closedSidebarConversation.waitFor({ state: "visible" })
          assert.equal(await page.getByRole("complementary", { name: "Pick & polish" }).count(), 0)
          const closedSidebarInput = closedSidebarConversation.getByRole("textbox", {
            name: "Follow-up",
            exact: true,
          })
          await closedSidebarInput.fill("Preserve this closed-sidebar draft")
          await closedSidebarInput.press("Escape")
          await page
            .getByText("Your unsaved follow-up will be lost.", { exact: true })
            .waitFor({ state: "visible" })
          assert.equal(await picker.getAttribute("aria-pressed"), "true")
          await closedSidebarConversation.getByRole("button", { name: "Keep", exact: true }).click()
          assert.equal(await closedSidebarInput.inputValue(), "Preserve this closed-sidebar draft")
          await closedSidebarInput.fill("")
          await closedSidebarConversation
            .getByRole("button", { name: "Close improvement", exact: true })
            .click()
          assert.ok(await marker.evaluate((element) => document.activeElement === element))
          await picker.click()
          await marker.waitFor({ state: "hidden" })
          await picker.click()
          await marker.waitFor({ state: "visible" })
          await page
            .getByRole("button", { name: "Open improvement notes (1)", exact: true })
            .click()
          await cards.first().waitFor({ state: "visible" })
          phase = "true marker position"
          assert.ok(
            Math.abs(markerBox.x + markerBox.width / 2 - controlBox.x - controlBox.width / 2) <= 2,
          )
          assert.ok(
            Math.abs(markerBox.y + markerBox.height / 2 - controlBox.y - controlBox.height / 2) <=
              2,
          )
          phase = "background sync controls"
          const actionTrigger = page.getByRole("button", {
            name: "Improvement actions: 1",
            exact: true,
          })
          await actionTrigger.hover()
          await page.waitForTimeout(150)
          assert.equal(
            await actionTrigger.evaluate((element) => {
              const label = document.getElementById(element.getAttribute("aria-labelledby"))
              return label && getComputedStyle(label).visibility
            }),
            "hidden",
          )
          assert.equal(await actionTrigger.getAttribute("title"), null)
          await actionTrigger.click()
          assert.equal(
            await page.getByRole("menuitem", { name: "Mark as resolved", exact: true }).count(),
            0,
          )
          await page.getByRole("menuitem", { name: "Delete improvement", exact: true }).click()
          const deletion = page.getByRole("dialog", {
            name: "Delete this improvement?",
            exact: true,
          })
          await deleteGeometry(deletion)
          await page.evaluate(() => {
            window.__improvementDisabled = []
            window.__improvementObserver = new MutationObserver((records) => {
              for (const record of records) {
                if (record.target.disabled)
                  window.__improvementDisabled.push(record.target.className)
              }
            })
            for (const button of document.querySelectorAll(
              ".thread-sample__fix-all, .thread-sample__delete-confirm",
            ))
              window.__improvementObserver.observe(button, {
                attributes: true,
                attributeFilter: ["disabled"],
              })
          })
          await page.clock.install()
          holdSync = true
          const periodicSync = new Promise((resolve) => {
            syncHeld = resolve
          })
          await page.clock.fastForward(18_000)
          await periodicSync
          await page.clock.runFor(2_000)
          assert.ok(
            await deletion
              .getByRole("button", { name: "Delete improvement", exact: true })
              .isEnabled(),
          )
          assert.equal(await page.locator(".thread-sample__fix-all").isDisabled(), false)
          assert.deepEqual(await page.evaluate(() => window.__improvementDisabled), [])
          await page.evaluate(() => window.__improvementObserver.disconnect())
          await page.clock.resume()
          await deletion.getByRole("button", { name: "Cancel", exact: true }).last().click()
          const firstFix = await fixButton(1)
          await firstFix.click()
          assert.ok(await firstFix.isDisabled())
          await firstFix.evaluate((button) => button.click())
          assert.equal(dispatched.length, 0)
          await page.getByRole("button", { name: "Improvement actions: 1", exact: true }).click()
          await page.clock.runFor(300)
          const disabledDelete = page.getByRole("menuitem", {
            name: "Delete improvement",
            exact: true,
          })
          await disabledDelete.hover()
          assert.equal(await disabledDelete.getAttribute("aria-disabled"), "true")
          assert.equal(
            await disabledDelete.evaluate((element) => getComputedStyle(element).cursor),
            "not-allowed",
          )
          await page.keyboard.press("Escape")
          holdSync = false
          assert.ok(releaseSync)
          releaseSync()
          phase = "first batch"
          await page.getByText("In progress", { exact: true }).waitFor({ state: "visible" })
          assert.equal(dispatched.length, 1)
          state = await store.load()
          const first = await store.batch({ batchId: state.activeBatch })
          assert.deepEqual(first.notes[0].requestIds, [state.notes[0].localId])
          await cards.first().click()
          phase = "floating follow-up"
          const dialog = page.getByRole("dialog", { name: "Improvement", exact: true })
          assert.equal(await page.getByText(branchDiscoveryNotice, { exact: true }).count(), 0)
          assert.equal(await page.locator(".thread-sample__error").count(), 0)
          assert.equal(await cards.count(), 1)
          assert.equal(await dialog.locator("xpath=ancestor::aside").count(), 0)
          phase = "preview Escape closes saved conversation"
          await target.press("Escape")
          await dialog.waitFor({ state: "hidden" })
          await cards.first().click()
          await dialog
            .getByRole("textbox", { name: "Follow-up", exact: true })
            .fill("Keep the existing shortcut.")
          assert.ok(await cards.first().isDisabled())
          assert.equal(
            await cards.first().evaluate((element) => getComputedStyle(element).opacity),
            "0.6",
          )
          phase = "preview Escape protects follow-up draft"
          await target.press("Escape")
          await dialog
            .getByText("Your unsaved follow-up will be lost.", { exact: true })
            .waitFor({ state: "visible" })
          await dialog.getByRole("button", { name: "Keep", exact: true }).click()
          assert.equal(
            await dialog.getByRole("textbox", { name: "Follow-up", exact: true }).inputValue(),
            "Keep the existing shortcut.",
          )
          const realAnchor = await marker.boundingBox()
          for (const [label, count] of [
            ["Ready to review", 0],
            ["Resolved", 0],
            ["Active notes", 1],
          ]) {
            const filter = page.getByRole("button", { name: /^Filter improvement notes:/ })
            assert.ok(await filter.isEnabled())
            await filter.click()
            await page.getByRole("menuitemradio", { name: label, exact: true }).click()
            assert.equal(await cards.count(), count)
            assert.equal(await dialog.count(), 1)
            assert.equal(
              await dialog.getByRole("textbox", { name: "Follow-up", exact: true }).inputValue(),
              "Keep the existing shortcut.",
            )
            const filteredAnchor = await marker.boundingBox()
            assert.ok(
              Math.abs(filteredAnchor.x - realAnchor.x) <= 1 &&
                Math.abs(filteredAnchor.y - realAnchor.y) <= 1,
              `Selected anchor changed: ${JSON.stringify({ before: realAnchor, after: filteredAnchor })}`,
            )
            assert.equal(dispatched.length, 1)
          }
          await dialog.getByRole("button", { name: "Add follow-up", exact: true }).click()
          await dialog
            .locator(".review-thread-message__body")
            .filter({ hasText: "Keep the existing shortcut." })
            .waitFor({ state: "visible" })
          state = await store.load()
          const followUpId = state.notes[0].thread.messages[0].id
          assert.equal(dispatched.length, 1)
          assert.equal(
            (await store.batch({ batchId: first.id })).notes[0].thread.messages.length,
            0,
          )
          await store.results({
            batchId: first.id,
            results: [
              {
                localId: first.notes[0].localId,
                revision: first.notes[0].revision,
                status: "ready",
                message: "The save action is clearer.",
              },
            ],
          })
          phase = "first result roundtrip"
          await dialog
            .getByText("The save action is clearer.", { exact: true })
            .waitFor({ state: "visible" })
          await copilotAvatars(dialog)
          assert.equal(
            await page.locator(".thread-sample__follow-ups").textContent(),
            "1 follow-up",
          )
          assert.ok(await (await fixButton(1)).isEnabled())
          await dialog.getByRole("button", { name: "Close improvement", exact: true }).click()
          phase = "second batch"
          await (await fixButton(1)).click()
          await page.getByText("In progress", { exact: true }).waitFor({ state: "visible" })
          state = await store.load()
          const second = await store.batch({ batchId: state.activeBatch })
          assert.deepEqual(second.notes[0].requestIds, [followUpId])
          assert.equal(second.notes[0].thread.messages[1].body, "The save action is clearer.")
          assert.equal(dispatched.length, 2)
          await store.results({
            batchId: second.id,
            results: [
              {
                localId: second.notes[0].localId,
                revision: second.notes[0].revision,
                status: "ready",
                message: "The existing shortcut is preserved.",
              },
            ],
          })
          phase = "ready result roundtrip"
          await page.getByText("Ready to review", { exact: true }).waitFor({ state: "visible" })
          await cards.first().click()
          await dialog
            .getByText("The existing shortcut is preserved.", { exact: true })
            .waitFor({ state: "visible" })
          const geometry = await dialog.evaluate((element) => {
            const box = element.getBoundingClientRect()
            const surface = element.parentElement.getBoundingClientRect()
            const header = element.querySelector("header")
            const title = header.querySelector("h3").getBoundingClientRect()
            const resolve = element.querySelector(".thread-sample__resolve").getBoundingClientRect()
            const close = element.querySelector(".thread-sample__close").getBoundingClientRect()
            return {
              bounded:
                box.left >= surface.left &&
                box.top >= surface.top &&
                box.right <= surface.right + 1 &&
                box.bottom <= surface.bottom + 1,
              row:
                title.top < resolve.bottom &&
                resolve.top < title.bottom &&
                resolve.top < close.bottom &&
                close.top < resolve.bottom,
              ordered: title.right <= resolve.left && resolve.right <= close.left,
            }
          })
          phase = "ready header geometry"
          assert.ok(geometry.bounded && geometry.row && geometry.ordered)
          phase = "resolve and filter"
          const realResolveIcon = await dialog
            .locator(".thread-sample__resolve svg path")
            .getAttribute("d")
          await dialog.getByRole("button", { name: "Close improvement", exact: true }).click()
          await page.getByRole("button", { name: "Improvement actions: 1", exact: true }).click()
          const sidebarResolve = page.getByRole("menuitem", {
            name: "Mark as resolved",
            exact: true,
          })
          assert.equal(await sidebarResolve.locator("svg path").getAttribute("d"), realResolveIcon)
          await sidebarResolve.click()
          await cards.first().waitFor({ state: "hidden" })
          await page.getByRole("button", { name: /^Filter improvement notes:/ }).click()
          await page.getByRole("menuitemradio", { name: "Resolved", exact: true }).click()
          await cards.first().waitFor({ state: "visible" })
          state = await store.load()
          assert.equal(state.notes[0].status, "resolved")
          await rowPresentation(page.locator(".thread-sample__card").first(), "resolved")
          assert.equal(state.notes[0].body, "Make the save action clearer.")
          assert.equal(
            state.notes[0].thread.messages.filter((entry) => entry.role === "author").length,
            1,
          )
          assert.equal(
            state.notes[0].thread.messages.filter((entry) => entry.role === "copilot").length,
            2,
          )
          assert.deepEqual(
            (
              await createImprovementNotes(
                () => context,
                session,
                async () => null,
                { directory: notesDirectory },
              ).load()
            ).notes,
            state.notes,
          )
          await page.reload()
          phase = "persistent reload"
          await page.getByRole("button", { name: /^Filter improvement notes:/ }).click()
          await page.getByRole("menuitemradio", { name: "Resolved", exact: true }).click()
          await cards.first().waitFor({ state: "visible" })
          await cards.first().click()
          await dialog
            .getByText("The existing shortcut is preserved.", { exact: true })
            .waitFor({ state: "visible" })
          assert.equal(dispatched.length, 2)
          phase = "foreground deletion"
          await page.getByRole("button", { name: "Improvement actions: 1", exact: true }).click()
          await deleteCursor()
          assert.equal(
            await page.getByRole("menuitem", { name: "Mark as resolved", exact: true }).count(),
            0,
          )
          await page.getByRole("menuitem", { name: "Delete improvement", exact: true }).click()
          await deleteGeometry(deletion)
          failNextDelete = true
          await deletion.getByRole("button", { name: "Delete improvement", exact: true }).click()
          await deletion
            .getByText("The improvement could not be deleted.", { exact: true })
            .waitFor({ state: "visible" })
          const alerts = await page.getByRole("alert").evaluateAll((elements) =>
            elements.map((element) => {
              const style = getComputedStyle(element)
              return {
                padding: [
                  style.paddingTop,
                  style.paddingRight,
                  style.paddingBottom,
                  style.paddingLeft,
                ],
                visible: element.getBoundingClientRect().height > 0,
              }
            }),
          )
          assert.equal(alerts.length, 3)
          for (const alert of alerts) {
            assert.deepEqual(alert.padding, ["8px", "8px", "8px", "8px"])
            assert.ok(alert.visible)
          }
          console.log(JSON.stringify({ improvementErrorInsets: alerts }))
          assert.equal(await dialog.count(), 1)
          assert.equal((await store.load()).notes.length, 1)
          holdDelete = true
          const deletionStarted = new Promise((resolve) => {
            deleteHeld = resolve
          })
          const deleteConfirm = deletion.getByRole("button", {
            name: "Delete improvement",
            exact: true,
          })
          await deleteConfirm.click()
          await deletionStarted
          assert.ok(await deleteConfirm.isDisabled())
          await deleteConfirm.evaluate((button) => button.click())
          assert.equal(deletionRequests, 1)
          assert.ok(releaseDelete)
          releaseDelete()
          await deletion.waitFor({ state: "hidden" })
          assert.equal((await store.load()).notes.length, 0)
          assert.equal(await dialog.count(), 0)
          assert.equal(await page.locator('[data-improvement-thread-id="1"]').count(), 0)
          assert.ok(
            await page
              .getByRole("button", { name: /^Open improvement notes/ })
              .evaluate((element) => document.activeElement === element),
          )
          assert.equal(dispatched.length, 2)
        }
        assert.deepEqual(errors, [])
        assert.deepEqual(failedAssets, [])
        console.log(`${sample ? "sample" : "real"} packaged renderer: visible, no runtime errors`)
      } catch (error) {
        console.error(
          JSON.stringify({
            sample,
            phase,
            reason: error.message.split("\n")[0].replace(/https?:\/\/\S+/g, "[local resource]"),
            source: error.stack?.match(/check-prototype-canvas-renderer\.mjs:\d+:\d+/)?.[0],
            runtimeErrors: errors,
            failedAssets,
            rootChildren: await page.locator("#root").evaluate((root) => root.childElementCount),
            ordinaryState: ordinary
              ? await page.evaluate(() => ({
                  expanded: document
                    .querySelector(".canvas-comments-toggle")
                    ?.getAttribute("aria-expanded"),
                  sidebars: Array.from(document.querySelectorAll(".hub-sidebar")).map(
                    (element) => ({
                      label: element.getAttribute("aria-label"),
                      open: element.getAttribute("data-open"),
                    }),
                  ),
                  rows: document.querySelectorAll(".review-comment-row").length,
                }))
              : undefined,
          }),
        )
        // eslint-disable-next-line preserve-caught-error -- Playwright call logs can contain the private bootstrap capability.
        throw new Error("Packaged renderer smoke failed; see sanitized diagnostics above.")
      } finally {
        await page.close()
        await canvas.close()
      }
    }
  })
} finally {
  await browser.close()
  await new Promise((resolve, reject) =>
    prototype.close((error) => (error ? reject(error) : resolve())),
  )
}
