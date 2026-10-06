package orm.sqlite3.pool

import orm
import sqlite3
from orm.pool import ConnectionPoolClosedError
from orm.pool import ConnectionPoolLeaseError
from orm.pool import ConnectionPoolTimeoutError
from orm.pool import ModelBindingError
from orm.sqlite3.adapter import SqliteAdapter
from sync import Atomic

export OrmSqlitePool, wrap

POOL_SEQUENCE = Atomic.new(0)

def wrap(native_pool):
  binding_id = POOL_SEQUENCE.update: _1 + 1
  OrmSqlitePool(native_pool, binding_id)

class OrmSqlitePool:
  def init(@native_pool, @binding_id as Int):
    @adapter = SqliteAdapter(@native_pool)

  # Models are configured once during application boot. Rebinding an already
  # configured model to another pool is almost always a deployment bug.
  def bind!(*models):
    model_types = models.map |model|: _model_type(model)
    conflict = model_types.find |model|:
      model.bound? and model.config.binding_owner != @binding_id
    if conflict:
      message = "model #{conflict.name} is already bound to another executor"
      return Err(ModelBindingError(message))
    binding = Ok(self)
    model_types.each |model|:
      if binding.ok? and not model.bound?:
        binding = model.bind!(@adapter, binding_owner: @binding_id)
    binding

  def with_connection(
    timeout as (Float | Int | TimePeriod)?: null,
    &blk
  ):
    raise ArgumentError("with_connection requires a block") unless blk
    _translate_pool_error:
      @native_pool.with_connection(timeout: timeout) |connection|:
        blk(connection)

  def transaction(
    mode as Symbol: :deferred,
    timeout as (Float | Int | TimePeriod)?: null,
    &blk
  ):
    raise ArgumentError("transaction requires a block") unless blk
    with_connection(timeout: timeout) |_connection|:
      @adapter.transaction(mode: mode):
        blk()

  def instrument_queries!(instrumenter):
    @native_pool.instrument_queries!(instrumenter)
    self

  def query_instrumenter():
    @native_pool.query_instrumenter

  def features():
    @native_pool.features

  def stats():
    @native_pool.stats

  def prune!():
    _translate_pool_error:
      @native_pool.prune!

  def disconnect!():
    _translate_pool_error:
      @native_pool.disconnect!

  def drain!(timeout as (Float | Int | TimePeriod)?: null):
    _translate_pool_error:
      @native_pool.drain!(timeout: timeout)

  def close!():
    @native_pool.close!

  def destroy!():
    self.close!

  def closed?():
    @native_pool.closed?

def _model_type(model):
  case model:
    when orm.ModelType:
      model
    else:
      model.model

def _translate_pool_error(&blk):
  try:
    blk()
  rescue Sqlite3.PoolTimeoutError |error|:
    raise ConnectionPoolTimeoutError(error.message, source: error)
  rescue Sqlite3.PoolClosedError |error|:
    raise ConnectionPoolClosedError(error.message, source: error)
  rescue Sqlite3.PoolLeaseError |error|:
    raise ConnectionPoolLeaseError(error.message, source: error)
