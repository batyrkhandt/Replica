import assert from "node:assert/strict"
import { randomUUID } from "node:crypto"
import { it } from "node:test"

import { checkThread, requireAnswerRoom } from "./index.mjs"

for (const statuses of [["open"], ["sent", "open"]]) {
  it(`reserves exactly the serialized worst-case answer for ${statuses.join(" and ")} work`, () => {
    const localId = randomUUID()
    const note = {
      localId,
      thread: {
        version: 1,
        originalStatus: statuses[0],
        messages: Array.from({ length: 4 }, (_, index) => ({
          id: randomUUID(),
          role: "author",
          status: statuses[index % statuses.length],
          body: "x",
        })),
      },
    }
    function answeredThread() {
      const thread = structuredClone(note.thread)
      const groups = statuses.map((status) => [
        ...(thread.originalStatus === status ? [localId] : []),
        ...thread.messages.filter((message) => message.status === status).map(({ id }) => id),
      ])
      thread.originalStatus = "blocked"
      for (const message of thread.messages) message.status = "blocked"
      for (const requestIds of groups) {
        thread.messages.push({
          id: randomUUID(),
          role: "copilot",
          body: "\0".repeat(2000),
          status: "blocked",
          requestIds,
        })
      }
      return thread
    }
    let remaining = 32_768 - Buffer.byteLength(JSON.stringify(answeredThread()))
    for (const message of note.thread.messages) {
      const added = Math.min(remaining, 9999)
      message.body += "x".repeat(added)
      remaining -= added
    }
    assert.equal(remaining, 0)
    assert.equal(Buffer.byteLength(JSON.stringify(answeredThread())), 32_768)
    checkThread(note.thread, localId)
    assert.doesNotThrow(() => requireAnswerRoom(note))
    checkThread(answeredThread(), localId)
    note.thread.messages.at(-1).body += "x"
    assert.throws(
      () => requireAnswerRoom(note),
      (error) => error.statusCode === 422 && /conversation is full/.test(error.message),
    )
  })
}
