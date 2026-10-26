package orm.atomicity_selftest

import orm
import sqlite3
import task
from orm.sqlite3 import pool as sqlite_pool, adapter as sqlite_adapter
from orm.sqlite3 import memory_pool
from orm.pool import ConnectionPoolTimeoutError, ConnectionPoolClosedError

export main

class Session:
  use orm.model(table: :sessions)

class Audit:
  use orm.model(table: :audits)

def check(value, message):
  raise ValueError("ORM atomicity: " + message) unless value

def count(token): Session.where({token: token}).all.or_raise.count

def return_from_transaction():
  Session.transaction:
    Session.create(token: "return", value: 1).or_raise
    return (:returned)
  :unreachable

def increment_locked(id, times):
  index = 0
  while index < times:
    Session.find_with_lock(id) |record|:
      value = record[:value]
      task.sleep(0.001)
      record[:value] = value + 1
      record.save.or_raise
    index += 1
  times

def create_once(token):
  Session.with_lock:
    found = Session.where({token: token}).first
    task.sleep(0.001)
    Session.create(token: token, value: 1).or_raise if found.err?
  true

def exercise(database):
  database.with_connection |db|:
    db.exec("create table sessions(id integer primary key, token text unique not null, value integer not null)")
    db.exec("create table audits(id integer primary key, label text not null)")
  database.bind!(Session, Audit).or_raise

  value = Session.transaction:
    Session.create(token: "normal", value: 1).or_raise
    :committed
  check(value == :committed and count("normal") == 1, "normal commit")
  result = Session.transaction:
    Session.create(token: "break", value: 2).or_raise
    break :accepted
  check(result == :accepted and count("break") == 1, "break commits and preserves its value")
  check(return_from_transaction() == :returned and count("return") == 1, "non-local return commits")

  result = Session.transaction:
    Session.create(token: "rollback-before", value: 1).or_raise
    Session.rollback
    Session.rollback
    Session.create(token: "rollback-after", value: 2).or_raise
    :continued
  check(result == :continued and count("rollback-before") == 0 and count("rollback-after") == 0,
    "rollback marks the transaction and does not exit the block")
  result = Session.transaction:
    Session.create(token: "rollback-break", value: 1).or_raise
    Session.rollback then break :declined
  check(result == :declined and count("rollback-break") == 0, "explicit rollback then break")

  error = orm.PersistenceError("abort")
  result = Session.transaction:
    Session.create(token: "err", value: 1).or_raise
    Err(error)
  check(result.err? and result.error == error and count("err") == 0, "Err rollback preserves Result")
  caught = false
  try:
    Session.transaction:
      Session.create(token: "raise", value: 1).or_raise
      raise ValueError("original failure")
  rescue ValueError |error|:
    caught = error.message == "original failure"
  check(caught and count("raise") == 0, "exception rolls back and propagates")

  Session.transaction(mode: :immediate):
    Session.create(token: "outer", value: 1).or_raise
    Audit.create(label: "same-connection").or_raise
    Session.transaction:
      Session.create(token: "inner", value: 1).or_raise
      Audit.rollback then break :inner_rollback
    Session.create(token: "outer-after", value: 1).or_raise
  check(count("outer") == 1 and count("outer-after") == 1 and count("inner") == 0,
    "cross-model rollback affects only the current savepoint")
  check(Audit.all.or_raise.count == 1, "models share transaction connection")
  Session.transaction:
    Session.create(token: "outer-abort", value: 1).or_raise
    Session.rollback
    Session.transaction:
      Session.create(token: "inner-commit", value: 1).or_raise
  check(count("outer-abort") == 0 and count("inner-commit") == 0, "inner commit cannot clear outer rollback")

  outside = false
  try:
    Session.rollback
  rescue orm.TransactionError:
    outside = true
  check(outside and database.stats[:leased] == 0, "rollback outside transaction fails without leaking a lease")
  Session.transaction:
    child = task.spawn:
      try:
        Session.rollback
        false
      rescue orm.TransactionError:
        true
    check(child.wait(), "child does not inherit rollback authority")
    Session.create(token: "parent", value: 1).or_raise
  check(count("parent") == 1, "child rollback cannot affect parent")

  ready = Channel.new(capacity: 1)
  child = task.async:
    Session.transaction:
      Session.create(token: "cancelled", value: 1).or_raise
      ready.send(true)
      task.sleep(30.0)
  ready.recv(timeout: 5.0)
  child.cancel()
  caught = false
  try:
    child.wait()
  rescue CancelledError:
    caught = true
  check(caught and count("cancelled") == 0 and database.stats[:leased] == 0, "cancellation rolls back and releases lease")

  record = Session.create(token: "counter", value: 0).or_raise
  missing_called = false
  missing = Session.where({token: "absent"}).find_with_lock |locked|:
    missing_called = true
  check(missing.err? and orm.NotFoundError === missing.error and not missing_called, "missing locked query returns NotFound")
  selected = Session.where |q|: q.field(:token) == "counter"
  result = selected.find_with_lock |locked|:
    locked[:value] = 1
    locked.save.or_raise
    :updated
  check(result == :updated and Session.find(record[:id]).or_raise[:value] == 1, "predicate find_with_lock")
  result = record.with_lock |locked|:
    check(locked == record and locked[:value] == 1, "instance lock reloads stale data")
    locked[:value] = 2
    locked.save.or_raise
    break :instance
  check(result == :instance and Session.find(record[:id]).or_raise[:value] == 2, "instance scoped break commits")
  record[:value] = 500
  dirty = record.with_lock: raise ValueError("must not run")
  check(dirty.err? and orm.LockingError === dirty.error and record[:value] == 500, "dirty record refuses reload")
  fresh = Session.new(token: "new", value: 0).with_lock: false
  check(fresh.err?, "new record refuses lock")

  upgraded = false
  ran = false
  Session.transaction:
    try:
      Session.with_lock:
        ran = true
    rescue orm.LockingError:
      upgraded = true
    Session.create(token: "after-upgrade-refusal", value: 1).or_raise
  check(upgraded and not ran and count("after-upgrade-refusal") == 1,
    "deferred transaction cannot silently upgrade to a write lock")
  nested = Session.with_lock:
    Audit.with_lock:
      database.with_lock: :nested
  check(nested == :nested, "nested writer lock reuses reserved connection")
  result = database.with_lock:
    Session.create(token: "pool-rollback", value: 1).or_raise
    database.rollback then break :pool
  check(result == :pool and count("pool-rollback") == 0, "pool rollback and scoped break")
  result = Session.with_lock:
    Session.create(token: "locked-err", value: 1).or_raise
    Err(orm.PersistenceError("abort locked changes"))
  check(result.err? and count("locked-err") == 0, "Err rolls back locked scope")

  # A different pool has no shared in-process mutex or lease. This proves the
  # reservation is a database lock taken before the user callback executes.
  path = database.with_connection |db|: db.filename()
  competitor = sqlite_pool(path, min_size: 1, max_size: 1, busy_timeout: 0)
  try:
    refused = false
    ran = false
    Session.with_lock:
      try:
        competitor.with_lock:
          ran = true
      rescue orm.LockingError |error|:
        refused = Sqlite3.BusyError === error.source
    check(refused and not ran and competitor.stats[:leased] == 0,
      "independent connection cannot enter a competing writer lock")
    check((competitor.with_lock: 42) == 42, "reservation released after successful scope")
  ensure:
    competitor.close!

  first = task.spawn: increment_locked(record[:id], 12)
  second = task.spawn: increment_locked(record[:id], 12)
  check(first.wait() + second.wait() == 24, "concurrent tasks finish")
  check(Session.find(record[:id]).or_raise[:value] == 26, "read-modify-write has no lost updates")
  first = task.spawn: create_once("created-once")
  second = task.spawn: create_once("created-once")
  check(first.wait() and second.wait() and count("created-once") == 1,
    "write lock protects absent-row check and creation")
  check(database.stats[:leased] == 0, "all lock scopes release their leases")

def direct_adapter():
  sqlite3.memory() |db|:
    db.exec("create table entries(id integer primary key, value integer)")
    Entry = orm.model(name: :Entry, table: :entries)
    Entry.bind!(sqlite_adapter(db)).or_raise
    record = Entry.create(value: 1).or_raise
    result = Entry.find_with_lock(record[:id]) |locked|:
      locked[:value] = 2
      locked.save.or_raise
      break :direct
    check(result == :direct and Entry.find(record[:id]).or_raise[:value] == 2, "factory model and direct adapter lock")
    Entry.with_lock:
      Entry.find_with_lock(record[:id]) |locked|:
        locked[:value] = 3
        locked.save.or_raise
        Entry.rollback then break
    check(Entry.find(record[:id]).or_raise[:value] == 2, "nested direct-adapter rollback")
    expected = orm.TransactionError("business failure")
    caught = false
    try:
      Entry.with_lock: raise expected
    rescue orm.TransactionError |error|:
      caught = error == expected
    check(caught, "lock preserves user transaction exceptions")
    db.pragma!(:foreign_keys, true)
    db.exec("create table parent(id integer primary key)")
    db.exec("create table child(parent_id integer references parent(id) deferrable initially deferred)")
    caught = false
    try:
      Entry.with_lock:
        db.execute("insert into child values (999)")
    rescue orm.TransactionError |error|:
      caught = not (orm.LockingError === error) and Sqlite3.ConstraintError === error.source
    check(caught and db.scalar("select count(*) from child") == 0 and not db.in_transaction?(),
      "commit failure rolls back and retains transaction error type")

def pool_errors():
  database = memory_pool(name: "atomicity_pool_errors", max_size: 1, checkout_timeout: 0)
  try:
    database.with_connection:
      child = task.spawn:
        try:
          database.with_lock: false
          false
        rescue ConnectionPoolTimeoutError:
          true
      check(child.wait(), "lock preserves DB-neutral pool timeout for web 503 mapping")
  ensure:
    database.close!
  caught = false
  try:
    database.with_lock: false
  rescue ConnectionPoolClosedError:
    caught = true
  check(caught, "lock preserves DB-neutral closed-pool error")

def main():
  path = "/tmp/sputnik-orm-atomicity-" + SecureRandom.hex(8) + ".sqlite"
  database = sqlite_pool(path, min_size: 1, max_size: 4, busy_timeout: 5.0,
    pragmas: {journal_mode: :wal, foreign_keys: true})
  try:
    exercise(database)
    direct_adapter()
    pool_errors()
  ensure:
    database.close!
    for suffix in ["", "-wal", "-shm"]:
      fs.remove(path + suffix) if fs.exists?(path + suffix)
  print "PASS orm atomicity"
  0
