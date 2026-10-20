import {
  closeSync,
  constants,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  statSync,
} from "node:fs"
import path from "node:path"
import { DatabaseSync } from "node:sqlite"
import { canonicalJson } from "../canonical-json.mjs"
import { LearningError, ProviderConflictError } from "../errors.mjs"
import {
  PROVIDER_CONTRACT,
  REDACT_CAPABILITY,
  REQUIRED_CAPABILITIES,
  STREAMS,
  assertQuery,
  assertStorable,
  assertStream,
  batchWrites,
  redactionProblem,
} from "../provider-contract.mjs"
import { PRODUCER, SCHEMA_VERSIONS } from "../records.mjs"
import { NO_FOLLOW, assertOwnPath, assertSameFile, openError } from "./files.mjs"

// The busy timeout comes first, so opening waits for another process instead of failing.
const SCHEMA = `
  pragma busy_timeout = 10000;
  pragma journal_mode = wal;
  pragma secure_delete = on;
  create table if not exists records (
    seq integer primary key autoincrement,
    stream text not null,
    id text not null,
    scope_key text not null,
    occurred_at text,
    episode_id text,
    digest text not null,
    body text not null,
    unique (stream, id)
  );
  create index if not exists records_by_scope on records (stream, scope_key, seq);
  create index if not exists records_by_operation
    on records (stream, scope_key, json_extract(body, '$.operation'), seq);
  create table if not exists memory_versions (
    seq integer primary key autoincrement,
    id text not null,
    version integer not null,
    scope_key text not null,
    updated_at text,
    digest text not null,
    body text not null,
    unique (id, version)
  );
  create index if not exists memory_versions_by_scope on memory_versions (scope_key, seq);
`

/**
 * Stores learning records in one SQLite file with the driver built into Node.js 24, so it
 * needs no service and no dependency. It is the default provider.
 *
 * The file is <directory>/learning.sqlite, created owner-only (0700 directory, 0600 file).
 * The provider refuses that file, or one SQLite keeps beside it, when it is a link or has a
 * second name, because SQLite would follow it out of the directory.
 * Each row keeps a record's exact JSON, so digests still verify, with its scope, time, and
 * episode copied into indexed columns. Every write runs in a BEGIN IMMEDIATE transaction,
 * which locks out other writers, including other processes, until it ends, and a change and its
 * audit entries share one transaction. Write-ahead logging lets readers continue during a
 * write. Reading a store nobody wrote creates nothing.
 *
 * @param {{ directory: string, file?: string }} options
 */
export function createSqliteMemoryProvider({ directory, file = "learning.sqlite" } = {}) {
  if (typeof directory !== "string" || !directory)
    throw new LearningError("invalid_input", "The SQLite provider needs a directory.")
  if (typeof file !== "string" || path.basename(file) !== file || file.startsWith("."))
    throw new LearningError("invalid_input", "file must be a plain file name in the directory.")
  const root = path.resolve(directory)
  const target = path.join(root, file)
  let db = null
  let statements = null

  /**
   * Refuse the database, or a file SQLite keeps beside it, unless it is this provider's own.
   * SQLite follows links, so a link in their place would send reads and writes elsewhere.
   */
  function assertOwnFiles() {
    for (const name of [file, `${file}-wal`, `${file}-shm`, `${file}-journal`]) {
      const candidate = path.join(root, name)
      const info = lstatSync(candidate, { throwIfNoEntry: false })
      if (info) assertOwnPath(root, candidate, info)
    }
  }

  /** The open database, or null when nobody wrote one and this call only reads. */
  function connect({ create }) {
    if (db) return db
    if (existsSync(root)) assertOwnFiles()
    if (!create && !lstatSync(target, { throwIfNoEntry: false })) return null
    mkdirSync(root, { recursive: true, mode: 0o700 })
    assertPrivate(root)
    let checked
    try {
      const descriptor = openSync(target, constants.O_WRONLY | constants.O_CREAT | NO_FOLLOW, 0o600)
      try {
        checked = fstatSync(descriptor)
      } finally {
        closeSync(descriptor)
      }
    } catch (error) {
      throw openError(root, target, error)
    }
    assertPrivate(target)
    // node:sqlite opens the path again by name and follows links, so check that it opened the
    // file checked above, and that the files SQLite keeps beside it are this provider's own.
    const opened = new DatabaseSync(target)
    try {
      assertSameFile(root, target, checked)
      opened.exec(SCHEMA)
      assertOwnFiles()
    } catch (error) {
      opened.close()
      throw error
    }
    db = opened
    statements = {
      insertRecord: db.prepare(`
        insert into records (stream, id, scope_key, occurred_at, episode_id, digest, body)
        values (?, ?, ?, ?, ?, ?, ?) on conflict (stream, id) do nothing`),
      storedDigest: db.prepare("select digest from records where stream = ? and id = ?"),
      storedEvent: db.prepare("select body from records where stream = 'events' and id = ?"),
      replaceEvent: db.prepare("update records set body = ? where stream = 'events' and id = ?"),
      latestVersion: db.prepare(
        "select version, digest from memory_versions where id = ? order by version desc limit 1",
      ),
      insertVersion: db.prepare(`
        insert into memory_versions (id, version, scope_key, updated_at, digest, body)
        values (?, ?, ?, ?, ?, ?)`),
    }
    return db
  }

  /** Run work in one write transaction, which also locks out other processes until it ends. */
  function transaction(work) {
    const database = connect({ create: true })
    database.exec("begin immediate")
    try {
      const result = work()
      database.exec("commit")
      return result
    } catch (error) {
      database.exec("rollback")
      throw error
    }
  }

  /** Insert records into a stream inside a transaction, skipping those already stored. */
  function insert(stream, records) {
    let appended = 0
    let existing = 0
    for (const record of records) {
      const { changes } = statements.insertRecord.run(
        stream,
        record.id,
        canonicalJson(record.scope),
        text(record[STREAMS[stream]]),
        text(stream === "episodes" ? record.id : record.episodeId),
        record.digest,
        JSON.stringify(record),
      )
      if (changes) {
        appended++
        continue
      }
      if (statements.storedDigest.get(stream, record.id)?.digest !== record.digest)
        throw new ProviderConflictError(
          `${stream} already holds a different record with ID ${record.id}.`,
          { stream, id: record.id },
        )
      existing++
    }
    return { appended, existing }
  }

  /** Append to several streams in one transaction. */
  function write(batch, { audit = [] } = {}) {
    const writes = batchWrites(batch, audit)
    return transaction(() => {
      const counts = {}
      for (const [stream, records] of writes) {
        const result = insert(stream, records)
        if (Object.hasOwn(batch, stream)) counts[stream] = result
      }
      return counts
    })
  }

  return {
    manifest() {
      return {
        schemaVersion: SCHEMA_VERSIONS.providerManifest,
        id: "sqlite",
        name: "SQLite file",
        version: PRODUCER.version,
        contract: { name: PROVIDER_CONTRACT.name, versions: [PROVIDER_CONTRACT.version] },
        capabilities: [...REQUIRED_CAPABILITIES, REDACT_CAPABILITY],
        storage: { kind: "local", location: target },
        externalCalls: [],
        dataRetention:
          "Records stay in the file until someone deletes it. Nothing leaves the machine. Redaction overwrites removed text in the file, but backups and copies keep their own.",
      }
    },

    async health() {
      try {
        const missing = { ok: true, detail: `Not created yet; the first write creates ${target}.` }
        if (!existsSync(root)) return missing
        assertPrivate(root)
        assertOwnFiles()
        if (!existsSync(target)) return missing
        assertPrivate(target)
        const { version } = connect({ create: false })
          .prepare("select sqlite_version() as version")
          .get()
        return { ok: true, detail: `SQLite ${version} at ${target}` }
      } catch (error) {
        return { ok: false, detail: error.message }
      }
    },

    async appendRecords(stream, records, options) {
      assertStream(stream)
      return write({ [stream]: records }, options)[stream]
    },

    async appendBatch(batch, options) {
      return write(batch, options)
    },

    async readRecords(stream, query) {
      assertStream(stream)
      assertQuery(query)
      const database = connect({ create: false })
      if (!database) return []
      return select(database, query, {
        table: "records",
        stream,
        time: "occurred_at",
        episode: "episode_id",
      })
    },

    async appendMemoryVersion(record, { expectedPreviousDigest = null, audit = [] } = {}) {
      assertStorable([record])
      assertStorable(audit)
      if (!Number.isSafeInteger(record.version) || record.version < 1)
        throw new LearningError("invalid_input", "A memory version needs a positive version.")
      try {
        transaction(() => {
          const latest = statements.latestVersion.get(record.id)
          if ((latest?.digest ?? null) !== expectedPreviousDigest)
            throw new ProviderConflictError(`Memory ${record.id} changed since it was read.`, {
              id: record.id,
            })
          if (record.version !== (latest?.version ?? 0) + 1)
            throw new ProviderConflictError(
              `Memory ${record.id} version must follow ${latest?.version ?? 0}.`,
              { id: record.id },
            )
          statements.insertVersion.run(
            record.id,
            record.version,
            canonicalJson(record.scope),
            text(record.updatedAt),
            record.digest,
            JSON.stringify(record),
          )
          insert("audit", audit)
        })
      } catch (error) {
        if (/UNIQUE constraint failed/.test(error.message))
          throw new ProviderConflictError(`Memory ${record.id} changed since it was read.`, {
            id: record.id,
          })
        throw error
      }
    },

    async readMemoryVersions(query) {
      assertQuery(query)
      const database = connect({ create: false })
      if (!database) return []
      return select(database, query, { table: "memory_versions", time: "updated_at" })
    },

    /**
     * Replace one event with its redacted copy. secure_delete overwrites the old text in the
     * database pages, and the checkpoint empties the write-ahead log, unless a reader in another
     * process holds those pages, in which case the next checkpoint does.
     */
    async redactRecord(stream, record) {
      if (stream !== "events")
        throw new LearningError("invalid_input", "Only events can be redacted.")
      const result = transaction(() => {
        const row = statements.storedEvent.get(record?.id)
        const stored = row ? JSON.parse(row.body) : undefined
        const problem = redactionProblem(stored, record)
        if (problem) throw problem
        if (stored.payload === undefined) return { redacted: false }
        statements.replaceEvent.run(JSON.stringify(record), record.id)
        return { redacted: true }
      })
      if (result.redacted) db.exec("pragma wal_checkpoint(truncate)")
      return result
    },

    async close() {
      db?.close()
      db = null
      statements = null
    },
  }
}

/**
 * Records in one table that match the contract's filters exactly: the same scope, any of the
 * IDs, any of the episodes or audit operations, since inclusive and until exclusive, in the
 * order appended. Times are UTC text with six fractional digits, so text order is time order.
 */
function select(db, query, { table, stream, time, episode }) {
  const values = []
  const conditions = []
  function add(sql, value) {
    conditions.push(sql)
    values.push(value)
  }
  if (stream) add("stream = ?", stream)
  add("scope_key = ?", canonicalJson(query.scope))
  if (query.ids) add("id in (select value from json_each(?))", JSON.stringify(query.ids))
  if (query.operations?.length === 1)
    add("json_extract(body, '$.operation') = ?", query.operations[0])
  else if (query.operations)
    add(
      "json_extract(body, '$.operation') in (select value from json_each(?))",
      JSON.stringify(query.operations),
    )
  if (query.episodeIds) {
    if (!episode) return []
    add(`${episode} in (select value from json_each(?))`, JSON.stringify(query.episodeIds))
  }
  if (query.since) add(`${time} >= ?`, query.since)
  if (query.until) add(`${time} < ?`, query.until)
  return db
    .prepare(`select body from ${table} where ${conditions.join(" and ")} order by seq`)
    .all(...values)
    .map((row) => JSON.parse(row.body))
}

function text(value) {
  return typeof value === "string" ? value : null
}

function assertPrivate(target) {
  if (process.platform === "win32") return
  if ((statSync(target).mode & 0o077) !== 0)
    throw new LearningError(
      "storage_corrupt",
      `${target} is readable by other users. Run chmod ${statSync(target).isDirectory() ? 700 : 600} on it.`,
    )
}
