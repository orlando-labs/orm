package orm.pool

import orm

export ConnectionPoolError, ConnectionPoolClosedError
export ConnectionPoolTimeoutError, ConnectionPoolLeaseError
export ModelBindingError

class ConnectionPoolError < orm.OrmError:
  attr source

  def init(@message as Str, @source: null)

class ConnectionPoolClosedError < ConnectionPoolError
class ConnectionPoolTimeoutError < ConnectionPoolError
class ConnectionPoolLeaseError < ConnectionPoolError
class ModelBindingError < orm.OrmError
