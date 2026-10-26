# Atomic ORM operations

The model layer defines transaction and locking boundaries without depending on
a session schema, `User`, or SQL dialect. Only the SQLite adapter is currently
implemented. Other databases implement the same executor hooks in their own
adapters; this does not introduce database-specific session packages.

## Public surface

| API | Behavior |
| --- | --- |
| `Model.transaction:` | Run on one connection; return the block result. |
| `Model.rollback` | Mark the innermost managed boundary rollback-only; return Null. |
| `Model.with_lock:` | Reserve a write boundary before the callback, including absent-row checks. |
| `Model.find_with_lock(id) \|record\|:` | Find by primary key under the reservation. |
| `Model.where(...).find_with_lock \|record\|:` | Find the first matching record under the reservation. |
| `record.with_lock \|record\|:` | Reload a clean persisted record under the reservation. |
| `database.transaction:` / `database.with_lock:` / `database.rollback` | The same boundaries on the ORM pool facade. |

Locked lookups return `Err(NotFoundError)` without calling the block when the
record is missing. A new or dirty instance returns `Err(LockingError)` without
reloading or invoking the block. Tableless executors reject transactions and
locking. All lock/transaction block arguments are mandatory. Reads without a
block never claim to hold a lock after an operation-local connection is released.

Normal completion, `break` and non-local `return` commit. Explicit `rollback`,
exceptions and cancellation roll back. A normally returned `Err` rolls back and
is returned intact. A control-flow exit bypasses inspection of the callback's
return value, so use `Model.rollback then break value` to abort explicitly.

`rollback` is not control flow: statements after it still run inside the same
transaction and their database writes are rolled back too. Repeating it is
idempotent. A nested rollback discards only its savepoint; an inner commit does
not clear an outer rollback request. Rollback through another model bound to
the same pool affects that same current boundary. Outside a managed boundary,
it raises `orm.TransactionError` without acquiring a new connection.

Rollback concerns database state. It does not undo network calls, filesystem
writes or mutations of in-memory model objects, including generated IDs and
dirty flags. Discard/reload records used by aborted transactions before reuse.

## Adapter contract

Executors retain the existing CRUD API and provide:

```sputnik
transaction(mode: :deferred, &blk)
rollback()
with_lock(model = null, &blk)
find_with_lock(model, id, &blk)
first_with_lock(model, where: null, &blk)
```

`find_with_lock` and `first_with_lock` receive model/predicate metadata so an
adapter can use the database's locking-read primitives. Core ORM does not append
`FOR UPDATE` or choose connection/transaction modes. `with_lock` guarantees its
write boundary covers the full callback and never invokes it before the lock is
acquired. Adapter implementations must state their lock granularity and
isolation guarantees, especially for absent rows. Do not emulate this with a
process-local mutex or by locking after the first read.

Failures to acquire the database reservation and unsafe upgrades raise
`orm.LockingError`, with the original driver error in `source`. Transaction
driver failures raise `orm.TransactionError`. Pool timeout/closed/lease errors
retain the DB-neutral `orm.pool` classes, preserving Orbit's 503 handling.
User exceptions propagate. Commit or rollback failure is surfaced; it is never
reported as a successful transaction. Callbacks are not retried automatically,
because they may have side effects outside the database.

## SQLite

`with_lock` uses `BEGIN IMMEDIATE` before the first read, reserving the single
writer across connections and processes. WAL readers can continue. Nested lock
scopes inside immediate/exclusive transactions use savepoints on the same
connection. A deferred transaction or unmanaged `begin!` cannot be upgraded
through a savepoint and is rejected before the callback. Start the outer scope
with `with_lock` or `transaction(mode: :immediate)` when it needs locked reads.

The pool's non-inheritable logical-task connection binding carries the complete
scope across suspension. Child tasks obtain separate leases and do not inherit
rollback authority. A bare `sqlite3.Database`/direct adapter is for one logical
task at a time; use the pool when handling concurrent requests. Keep reservations
short and avoid unrelated network waits while holding SQLite's writer.

## Use by a session store

An ORM-backed session store can lock, re-read the current payload/version,
validate expiry/revocation, mutate and save in one callback. For creation or
rotation, `Model.with_lock` also covers a missing-row check and inserts/deletes
across models on the same pool. Schema, unique token constraints and policy for
expiry/conflicts stay in the session package/application. Plain `find` followed
by `save` outside such a boundary is not an atomic read–modify–write operation.

Development graphs load the working `orm` and sibling `sqlite3` sources directly.
Internal SQLite modules use `_adapter`/`_pool`, matching published module names,
so they cannot shadow public `orm.sqlite3.adapter`/`pool` factories. No package
archive generation, version bump, commit or publication is part of this work.
