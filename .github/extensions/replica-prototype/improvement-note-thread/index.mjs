import { createHash } from "node:crypto"

export const maximumThreadBytes = 32_768
export const answerReserveBytes = 11_000
const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/
const workStatuses = new Set(["open", "sent", "ready", "blocked"])

export function checkThread(thread, localId) {
  function invalid() {
    throw Object.assign(new Error("Invalid improvement conversation."), {
      statusCode: 422,
    })
  }
  if (
    !thread ||
    ![1, 2].includes(thread.version) ||
    !workStatuses.has(thread.originalStatus) ||
    !Array.isArray(thread.messages) ||
    thread.messages.length > 100 ||
    Buffer.byteLength(JSON.stringify(thread)) > maximumThreadBytes ||
    Object.keys(thread).some(
      (key) =>
        ![
          "version",
          "originalStatus",
          "messages",
          ...(thread.version === 2 ? ["originalAuthor"] : []),
        ].includes(key),
    )
  )
    invalid()
  function checkAuthor(author) {
    if (
      !author ||
      !Number.isSafeInteger(author.id) ||
      author.id < 1 ||
      typeof author.login !== "string" ||
      !/^[a-z0-9][a-z0-9-]{0,38}$/i.test(author.login) ||
      Object.keys(author).sort().join(",") !== "avatarUrl,id,login" ||
      (author.avatarUrl !== null &&
        (typeof author.avatarUrl !== "string" ||
          author.avatarUrl.length > 2048 ||
          !URL.canParse(author.avatarUrl) ||
          new URL(author.avatarUrl).protocol !== "https:" ||
          new URL(author.avatarUrl).hostname !== "avatars.githubusercontent.com" ||
          new URL(author.avatarUrl).username ||
          new URL(author.avatarUrl).password ||
          new URL(author.avatarUrl).port))
    )
      invalid()
  }
  if (thread.originalAuthor !== undefined) checkAuthor(thread.originalAuthor)
  const ids = new Set([localId])
  const requests = new Set([localId])
  for (const message of thread.messages) {
    if (
      !message ||
      typeof message.id !== "string" ||
      !uuid.test(message.id) ||
      ids.has(message.id) ||
      typeof message.body !== "string" ||
      !message.body.trim()
    )
      invalid()
    ids.add(message.id)
    if (message.role === "author") {
      if (
        !workStatuses.has(message.status) ||
        Buffer.byteLength(message.body) > 10_000 ||
        Object.keys(message).some(
          (key) =>
            !["id", "role", "body", "status", ...(thread.version === 2 ? ["author"] : [])].includes(
              key,
            ),
        )
      )
        invalid()
      requests.add(message.id)
      if (message.author !== undefined) checkAuthor(message.author)
    } else if (message.role === "copilot") {
      if (
        !["ready", "blocked"].includes(message.status) ||
        message.body.length > 2000 ||
        !Array.isArray(message.requestIds) ||
        !message.requestIds.length ||
        new Set(message.requestIds).size !== message.requestIds.length ||
        message.requestIds.some((id) => !requests.has(id)) ||
        Object.keys(message).some(
          (key) => !["id", "role", "body", "status", "requestIds"].includes(key),
        )
      )
        invalid()
    } else invalid()
  }
  return thread
}

export function normalizeThread(note) {
  if (note.thread !== undefined && note.thread !== null)
    return checkThread(note.thread, note.localId)
  const originalStatus = note.status === "resolved" ? "ready" : note.status
  const messages = []
  if (note.result) {
    const hash = createHash("sha256").update(`${note.localId}:legacy-result`).digest("hex")
    messages.push({
      id: `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20, 32)}`,
      role: "copilot",
      body: note.result,
      status: note.status === "blocked" ? "blocked" : "ready",
      requestIds: [note.localId],
    })
  }
  return checkThread({ version: 1, originalStatus, messages }, note.localId)
}

export function requestIds(note, status) {
  return [
    ...(note.thread.originalStatus === status ? [note.localId] : []),
    ...note.thread.messages
      .filter((message) => message.role === "author" && message.status === status)
      .map((message) => message.id),
  ]
}

export function updateRequests(note, ids, status) {
  if (ids.includes(note.localId)) note.thread.originalStatus = status
  for (const message of note.thread.messages) {
    if (message.role === "author" && ids.includes(message.id)) message.status = status
  }
  note.status =
    ["open", "sent", "blocked"].find((value) => requestIds(note, value).length) ?? "ready"
}

export function requireAnswerRoom(note, answers = 1) {
  if (
    note.thread.messages.length + answers > 100 ||
    Buffer.byteLength(JSON.stringify(note.thread)) >
      maximumThreadBytes - answerReserveBytes * answers
  )
    throw Object.assign(
      new Error("This conversation is full. Add a new improvement to request further changes."),
      { statusCode: 422 },
    )
}
