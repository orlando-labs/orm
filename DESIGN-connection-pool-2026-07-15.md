# DESIGN: тонкий connection-pool слой для `amber-orm`

Date: 2026-07-15

Status: ORM substrate implemented; Ember integration remains a design proposal

Target: `amber-orm` и optional ORM integration будущего Ember framework

Related:

- [`amber-orm` public API design](../amber-lang/DESIGN-package-amber-orm-api-2026-07-09.md);
- [Ember web framework design](../amber-lang/DESIGN-web-framework-2026-07-13.md);
- [`sqlite3-amber`](../sqlite3-amber/README.md) и его реализованный `sqlite3.Pool`.

Этот документ расширяет P0-дизайн `amber-orm`, где connection pools были
оставлены за пределами scope. Он учитывает два сознательно разных execution
профиля Ember:

1. controller target `&People#show` имеет generated controller lifecycle;
2. bare target `&show` является обычной функцией и не получает неявный scope.

Различие принципиально. Controller action должен выглядеть как нормальный
ActiveRecord-shaped код и не знать о pool. Bare handler либо получает явную
инфраструктурную обёртку route/app middleware, либо помечается annotation macro,
либо сам открывает connection scope. Amber не подставляет скрытые bindings в
произвольную функцию — по той же причине bare handler не получает
receiver-local `status`, `header` и `render`.

---

## 0. Решение в одном экране

### 0.1. Startup

```amber
import orm
from orm.sqlite3 import pool as sqlite_pool

database = sqlite_pool("data/app.db",
  min_size: 1,
  max_size: 8,
  checkout_timeout: 0.25,
  busy_timeout: 2.0,
  pragmas: {
    foreign_keys: true,
    journal_mode: :wal
  },
  instrumentation: instrumentation)

# Один явный bind до запуска HTTP server. Модели получают shareable
# pool-backed executor, а не confined sqlite3.Database.
database.bind!(Person, EntityPath).or_raise
```

Optional Ember integration устанавливается один раз в application
configuration. Точный constructor hook принадлежит Ember; предлагаемый shape:

```amber
import ember
import ember.integrations.orm as ember_orm

app = ember.App(
  routes: routes,
  integrations: [ember_orm.pool(database)])
```

Интеграция автоматически оборачивает controller targets в scoped checkout,
добавляет pool в explicit request services для bare handlers и участвует в
graceful shutdown. Она не оборачивает bare functions скрыто.

### 0.2. Controller target: action ничего не знает о pool

```amber
routes = ember.routes:
  get "/people/:id", to: &People#show, params: {id: Int}

class People < ember.Controller:
  def show(id as Int):
    match Person.find(id):
      when Ok(person):
        render Views.people.show(person: person)
      when Err(error):
        render text: "not found", status: :not_found
```

Generated/integrated execution conceptually выглядит так:

```amber
database.with_connection:
  controller = People(request)
  controller.show(id)
```

Все `Person.find`, `EntityPath.where`, record `save` и raw adapter calls через
тот же bound pool автоматически повторно используют logical-task-local lease.

### 0.3. Bare target: scope явный

Без route middleware bare handler сам получает infrastructure dependency:

```amber
def show(request, id as Int):
  database = request.service(:database)

  database.with_connection:
    match Person.find(id):
      when Ok(person):
        ember.render json: person.attributes
      when Err(error):
        ember.render text: "not found", status: :not_found
```

Либо connection scope явно ставится на route:

```amber
db_request = ember_orm.connection(database)

routes = ember.routes:
  get "/people/:id",
    to: &show,
    params: {id: Int},
    before: [db_request]
```

После такой явной инфраструктурной подготовки тело функции тоже может вызывать
`Person.find(id)` без ручного checkout. Но это свойство route configuration, а
не неявная capability любой Amber function.

Если connection scope является intrinsic требованием самой функции, explicit
annotation переносит policy к declaration без boilerplate в body:

```amber
from ember.middleware import before

db_request = ember_orm.connection(database)

before db_request
def create(request):
  Person.create(name: request.query(:name))
```

`before` здесь annotation macro, а `db_request` — runtime middleware value.
Macro не вычисляет его при expansion; он вставляет expression в generated
wrapper.

---

## 1. Главный design anchor: model API остаётся model API

Канонический persistence surface уже выбран в `amber-orm`:

```amber
Person.find(id)
Person.get(where: {slug: slug})
Person.where |query|:
  query.field(:age) >= 18

person.save
person.delete
```

Connection pooling не должен заменять его на:

```amber
session.repository(Person).find(id)
services.db.repository(Person).find(id)
Person.using(connection) |people|: people.find(id)
```

Такие формы протаскивают инфраструктурную деталь в каждый controller,
service и domain operation. Они противоречат ActiveRecord-shaped направлению
пакета и не являются тонкой обёрткой.

Правильное разделение:

```text
startup configuration
  binds ModelType -> shareable pool-backed executor once

execution infrastructure
  optionally establishes one scoped lease around dispatch

business/controller code
  calls Person.find / person.save
```

---

## 2. Фактическая низкоуровневая основа

На дату этого документа `sqlite3-amber` уже сообщает:

```amber
{
  pool: true,
  pool_wait: :cooperative,
  pool_affinity: :lease,
  pool_context: :task_local
}
```

Реализованы:

- `sqlite3.pool` и `sqlite3.memory_pool`;
- lazy growth от `min_size` до `max_size`;
- scoped `checkout`/`with_connection` и manual `acquire`;
- finite checkout timeout и cooperative waiting;
- exclusive lease ownership физического SQLite connection;
- non-inheritable logical-task-local current connection;
- сохранение binding через suspension и scheduler-worker migration;
- повторное использование lease вложенными Pool и ORM calls;
- отдельный lease для `task.spawn` child;
- transactions и nested savepoints;
- rollback/statement cleanup при release;
- `stats`, `prune!`, `disconnect!`, `drain!` и instrumentation.

Поэтому `amber-orm` не реализует собственные queue, semaphore, mutex, idle
timer, task local или lease generation. Он только связывает уже существующий
`sqlite3.Pool` с Model executor и предоставляет понятные lifecycle methods.

Документ Ember от 2026-07-13 всё ещё утверждает `pool: false`; это устаревшая
часть исходного substrate, которую нужно обновить.

---

## 3. Два execution profile

### 3.1. Controller profile

Controller target уже отличается от bare function на уровне generated wrapper:

```text
&People#show
  -> construct People(request)
  -> invoke People#show
  -> normalize controller response
```

Это естественная lifecycle seam для ORM integration:

```text
&People#show
  -> checkout pool lease
  -> install low-level non-inheritable task-local connection
  -> construct People(request)
  -> invoke People#show
  -> normalize response
  -> ensure release
```

Controller action не получает `pool`, `session`, `repository` или `connection`
argument. Так же как `status` и `header` работают благодаря controller receiver
и generated dispatch, DB lease работает благодаря controller target wrapper.

Это не process-global ambient connection. Public ORM API не имеет
`orm.current_connection`; executor явно bound в ModelType при startup, а
low-level pool лишь маршрутизирует calls в уже открытый lease текущей logical
task.

### 3.2. Bare function profile

Bare target остаётся обычным direct call:

```text
&show
  -> show(request, id)
```

Он не получает controller construction hook, receiver state или скрытый ORM
scope. Для web-кода допустимы три канонических варианта:

1. route/app middleware заранее оборачивает handler в connection scope;
2. `before db_request` annotation явно делает connection scope intrinsic
   policy самой функции;
3. handler получает pool через `request.service(:database)` и вызывает
   `with_connection`.

После startup `database.bind!(Models)` low-level executor технически умеет
сделать checkout/release вокруг одного изолированного model call. Это полезный
fallback для scripts, tests и однооперационных helpers, но не третий
bare-web profile: он не создаёт request scope, а две последовательные операции
могут выполняться на разных physical connections.

Никакая произвольная function автоматически не получает binding только потому,
что импортировала `orm`.

### 3.3. Сравнение

| Свойство | Controller target | Bare target |
| --- | --- | --- |
| Generated lifecycle | да | нет |
| Pool lease вокруг dispatch | автоматически при установленной integration | только explicit middleware/scope |
| Action/handler вызывает `Person.find` | да | да после explicit bind |
| Action/handler знает о pool | нет | declaration или body явно знает, если scope не вынесен в route middleware |
| Один connection на весь dispatch | да | только с explicit scope/transaction |
| Raw connection | infrastructure escape hatch | через explicit pool scope |
| Hidden global binding | нет | нет |

---

## 4. Цели и не-цели

### 4.1. Цели

1. Сохранить `Person.find`/`person.save` как основной controller API.
2. Один раз bind models к shareable pool-backed executor до server startup.
3. Автоматически держать один lease вокруг controller dispatch.
4. Сохранить явность bare function handlers через route middleware, annotation
   или explicit request service.
5. Не дублировать pooling algorithms из `sqlite3-amber`.
6. Сохранить существующий `Result` persistence contract.
7. Дать model-level transaction API без обращения controller к pool.
8. Обеспечить bounded checkout, cancellation cleanup и graceful shutdown.
9. Оставить core Ember ORM-neutral; integration остаётся optional package
   layer.

### 4.2. Не-цели

Этот слой не добавляет:

- Repository/Session requirement для controller actions;
- dependency injection pool object в каждый controller;
- process-global `current_database`;
- runtime rebinding моделей на каждый request;
- собственный connection pool;
- automatic transaction на каждый request;
- inherited connection в child tasks;
- retry writes/transactions;
- read replicas, sharding или identity map;
- migrations или новый query algebra;
- скрытую ORM integration для любого `&handler`.

---

## 5. Public ORM API

### 5.1. Package shape

```amber
package orm.sqlite3

export adapter, pool, memory_pool
```

Текущий Amber bytecode emitter не поддерживает реэкспорт imported class
bindings из facade. Поэтому стабильный facade экспортирует constructors, а
типы и DB-neutral errors остаются в собственных модулях:

```amber
from orm.sqlite3.adapter import SqliteAdapter
from orm.sqlite3.pool import OrmSqlitePool
from orm.pool import ConnectionPoolTimeoutError, ModelBindingError
```

Core `orm` добавляет только model-level transaction forwarding и neutral
binding owner в `ModelConfig`. Он не получает `Session` и `Repository`
abstractions.

Implemented files:

```text
src/orm.am                   model transaction forwarding and binding owner
src/orm/pool.am              DB-neutral pool/binding errors
src/orm/sqlite3.am           public adapter/pool constructor facade
src/orm/sqlite3/adapter.am   SQLite executor and Result-aware transaction
src/orm/sqlite3/pool.am      thin wrapper over sqlite3.Pool
test/pool_selftest.am        ORM/controller-scope contract
```

Новый native code в `amber-orm` не появляется.

### 5.2. Constructor

`orm.sqlite3.pool` повторяет низкоуровневые options и добавляет ORM
instrumentation один раз на pool:

```amber
database = orm_sqlite.pool(path,
  mode: :create,
  uri: false,
  min_size: 0,
  max_size: 5,
  checkout_timeout: 5.0,
  idle_timeout: 60.0,
  max_lifetime: null,
  busy_timeout: null,
  pragmas: {},
  instrumentation: null)
```

Как другие Amber resources, он поддерживает handle-returning и block-scoped
формы. Handle-returning form передаёт ownership приложению; block form вызывает
`close!` в `ensure`.

`memory_pool` делегирует `sqlite3.memory_pool` и прежде всего нужен tests.

Wrapper не включает WAL, foreign keys или busy timeout неявно. Эти policies
остаются явными application options.

### 5.3. Pool surface

```amber
database.bind!(Person, EntityPath)
database.with_connection(timeout: null, &blk)
database.transaction(mode: :deferred, timeout: null, &blk)

database.stats()
database.prune!()
database.disconnect!()
database.close!()
database.closed?()
database.drain!(timeout: null)
```

`stats` и lifecycle methods делегируют underlying `sqlite3.Pool` без второго
состояния.

---

## 6. One-time model binding

### 6.1. `Pool#bind!`

```amber
database.bind!(Person, EntityPath, AuditEvent).or_raise
```

`bind!`:

1. использует один shared `SqliteAdapter` поверх underlying pool;
2. вызывает существующий model schema bind для каждой модели;
3. проверяет `expect_schema` или сохраняет inferred schema;
4. устанавливает один pool-backed executor в ModelConfig;
5. возвращает `Ok(database)` или первый structured ORM error.

Операция выполняется до запуска server. Per-request `Model.bind!` запрещён:
shared model config не должен меняться во время concurrent dispatch.

### 6.2. Почему global model executor здесь безопасен

Небезопасно:

```amber
User.bind!(sqlite_adapter(confined_database))
```

Безопасный startup shape:

```amber
User.bind!(sqlite_adapter(shareable_pool))
```

Model config хранит shareable executor, а не физический connection. Каждый call
через executor:

- повторно использует текущий lease, если infrastructure открыла scope;
- иначе кратковременно checkout/release собственный lease;
- никогда не отправляет один `Database` sibling task.

Это explicit application binding, не неявный language binding.

### 6.3. Binding ownership

Один ModelType в P0 имеет один executor. Его нельзя одновременно bind к двум
разным application pools. Типичный web deployment имеет один process/app pool;
tests с несколькими независимыми приложениями должны создавать отдельные
dynamic model types либо явно сбрасывать test fixture до concurrency.

Повторный bind к тому же Pool может быть idempotent. Bind к другому live Pool
после startup должен возвращать `ModelBindingError`, а не молча менять
executor.

---

## 7. Connection scope

### 7.1. `Pool#with_connection`

```amber
database.with_connection(timeout: 0.25) |connection|:
  Person.find(42)
  AuditEvent.create(message: "viewed")
```

Метод тонко делегирует `sqlite3.Pool#checkout`:

1. получает exclusive lease;
2. low-level Pool устанавливает non-inheritable logical-task-local connection;
3. вызывает block;
4. возвращает lease в `ensure`;
5. возвращает значение block без дополнительного Result wrapper.

`connection` предназначен для raw SQL infrastructure escape hatch; model code
не обязан его использовать.

### 7.2. Operation-local fallback

Если `Person` bound к Pool, но current execution не находится внутри
`with_connection`, существующий executor surface low-level Pool сам делает
scoped checkout вокруг отдельного call:

```amber
Person.find(42) # отдельный checkout/get/release
```

Это полезно для scripts и простых bare handlers, но не обещает один connection
на несколько statements. Temporary tables, connection-local pragmas и
request-wide consistency требуют explicit connection/transaction scope.

### 7.3. Records не держат lease

Hydrated record хранит attributes и ссылку на model type, не physical
connection. Поэтому record можно вернуть из controller action/service и позже
сохранить через model's pool-backed executor:

```amber
person = Person.find(42).or_raise
# controller checkout завершился
person[:name] = "Ada"
person.save # при необходимости получает новый lease
```

Это ActiveRecord behavior. `SessionClosedError` и session-affine record в этом
проекте не нужны.

---

## 8. Controller integration

### 8.1. Optional Ember integration object

Предлагаемый application surface:

```amber
integration = ember_orm.pool(database)

app = ember.App(
  routes: routes,
  integrations: [integration])
```

`integrations:` — proposed Ember composition hook. Если Ember выберет другой
spelling, семантический контракт остаётся тем же: integration получает seam
вокруг generated controller target, request services и app shutdown.

Integration:

- оборачивает каждый controller target в `database.with_connection`;
- не меняет action signature;
- добавляет `database` как explicit request service для bare handlers;
- преобразует checkout timeout до action в production-safe 503 boundary;
- вызывает `database.drain!` в согласованном shutdown lifecycle;
- не импортируется core router/request/response modules.

### 8.2. Generated controller wrapper

До integration:

```amber
controller = People(request)
result = controller.show(id)
normalize(result)
```

После composition:

```amber
database.with_connection:
  controller = People(request)
  result = controller.show(id)
  normalize(result)
```

Connection scope должен покрывать controller construction, action и response
normalization/view materialization. Он завершается до возврата buffered
response server layer.

### 8.3. Controller example

```amber
class People < ember.Controller:
  def update(id as Int):
    person = Person.find(id).or_raise
    person[:name] = param(:name)

    match person.save:
      when Ok(saved):
        redirect routes.path(:person, id: saved[:id])
      when Err(error):
        render Views.people.edit(person: person, errors: error.errors),
          status: :unprocessable_entity
```

В action нет `database`, `pool`, `connection`, `session` или `repository`.

### 8.4. Controller scope не означает transaction

Default wrapper только удерживает connection. Он не начинает transaction.
Automatic transaction на каждый controller action ухудшает read concurrency и
скрывает atomicity boundaries.

Atomic business operation использует model-level transaction или explicit
route integration:

```amber
Person.transaction(mode: :immediate):
  person = Person.find(id).or_raise
  person[:slug] = next_slug
  person.save.and_then:
    EntityPath.create(person_id: id, slug: next_slug)
```

---

## 9. Bare handler integration

### 9.1. Explicit request service

```amber
def create(request):
  database = request.service(:database)

  database.transaction(mode: :immediate):
    Person.create(name: request.query(:name))
```

Handler явно знает, что ему нужен infrastructure scope. Это соответствует
function-handler profile Ember: request передаётся аргументом, response
создаётся через pure `ember.render`, state не возникает из hidden current
exchange.

### 9.2. Explicit route middleware

Если application хочет чистое function body, explicitness переносится в route
table:

```amber
db_request = ember_orm.connection(database)

routes = ember.routes:
  post "/people", to: &create, before: [db_request]
```

```amber
def create(request):
  Person.create(name: request.query(:name))
```

Здесь handler не pool-aware, потому что route декларативно pool-aware. Это не
автоматическое поведение всех `&handler`.

### 9.3. Annotation macro `before`

Function-intrinsic connection requirement можно выразить рядом с declaration:

```amber
from ember.middleware import before

db_request = ember_orm.connection(database)

before db_request
def create(request):
  Person.create(name: request.query(:name))
```

Amber macro system уже поддерживает этот surface: contiguous annotation-shaped
macro call непосредственно над declaration получает declaration `Ast` последним
аргументом и возвращает replacement declaration. Концептуальное expansion:

```amber
# В текущем macro.v1 annotation surface определяется по месту использования;
# отдельный modifier `annotation macro def` не нужен.
macro def before(middleware as Ast, declaration as Ast) -> Ast:
  # validate AstDefStmt, preserve signature, wrap its body
  ...
```

```amber
def create(request):
  db_request.call(request) |next_request|:
    Person.create(name: next_request.query(:name))
```

Точная generated `Next` форма должна совпадать с middleware ABI Ember. Macro
обязан сохранить public name, signature, typed/effect annotations, callable
reference `&create` и source mapping. Runtime middleware expression связывается
обычным binder после expansion; macro не ищет pool и не исполняет
`db_request` во время компиляции.

P0 rules:

- `before` принимает один middleware либо один ordered list;
- P0 поддерживает обычный `AstDefStmt`; clause/overload declarations требуют
  отдельного deterministic expansion;
- blank line между annotation и `def` запрещает attachment по общему правилу;
- annotation применяется при любом прямом вызове функции, не только через
  router;
- функция остаётся явно infrastructure-aware на уровне declaration.

Это не возвращает handler-local route annotations. `before` не объявляет HTTP
method/path/name и не регистрирует route. Разделение policy:

- middleware, зависящий от конкретного route, остаётся в central routes table;
- middleware, являющийся неизменным требованием самой функции, может быть
  annotation;
- если один handler используется routes с разной policy, annotation применять
  нельзя — policy объявляется на routes.

Одна annotation с ordered list предпочтительнее нескольких stacked `before`:
общая macro composition идёт source top-to-bottom, а runtime nesting легко
прочитать наоборот. Ordered list фиксирует outer-to-inner order явно:

```amber
before [request_id, authenticate, db_request]
def create(request):
  ...
```

### 9.4. Operation-local fallback — не request scope

После explicit startup bind допустим минимальный вариант:

```amber
def show(request, id as Int):
  Person.find(id).map |person|:
    ember.render json: person.attributes
```

Он делает operation-local checkout благодаря явному startup bind. Для одного
изолированного query это технически корректно, но не является канонической
web-интеграцией bare route. Несколько связанных calls должны использовать
middleware, `with_connection` или transaction.

### 9.5. Без подготовки

Если model не bound и route/handler не получил database dependency:

```amber
Person.find(id)
```

возвращает существующий `Err(PersistenceError("model is not bound to an
executor"))`. Framework не ищет pool по имени package, process global или
current task.

---

## 10. Model-level transactions

### 10.1. API

Model macro получает class forwarding:

```amber
Person.transaction(mode: :deferred, &blk)
```

`ModelType#transaction` делегирует bound executor. `SqliteAdapter#transaction`
делегирует underlying `Database` или `Pool`. Если controller wrapper уже держит
lease, transaction использует этот connection. Другие models, bound к тому же
Pool, автоматически участвуют в transaction через low-level task-local route.

### 10.2. Result-aware rule

ORM persistence возвращает `Result`, поэтому model/pool transaction использует:

| Block outcome | Outcome |
| --- | --- |
| `Ok(value)` | commit, вернуть тот же `Ok` |
| `Err(error)` | rollback, вернуть тот же `Err` |
| обычное значение | commit, вернуть значение |
| exception | rollback, re-raise |
| cancellation | rollback, продолжить cancellation |

Implementation может использовать private rollback sentinel поверх уже
проверенного low-level transaction cleanup. Raw
`connection.transaction` сохраняет commit-on-normal-return semantics
`sqlite3-amber`.

Если block проигнорировал ранний `Err` и вернул `Ok`, ORM не может угадать
намерение пользователя.

### 10.3. Multiple pools

`Person.transaction` атомарна только для models, bound к тому же underlying
Pool/connection. Вызов model из другого database внутри block создаёт отдельную
transaction boundary и не является distributed transaction.

---

## 11. Concurrency и child tasks

1. ORM `Pool` и pool-backed model executor shareable.
2. Physical `Database`, statement и lease confined.
3. Controller integration держит один lease на logical request task.
4. Suspension не меняет connection.
5. `task.spawn` child не наследует parent lease.
6. `Person.find` в child получает отдельный lease через shareable Pool.
7. Parent release происходит на return, exception и cancellation.
8. ORM не создаёт process-global `task_id -> connection` map.

Важный sizing edge:

```amber
class Reports < ember.Controller:
  def show():
    child = task.spawn:
      Person.find(42)
    child.wait()
```

Parent controller уже держит lease, child должен получить второй. При
`max_size: 1` parent, ожидающий child, приведёт к checkout timeout. Framework
documentation должна рекомендовать не ждать DB-using child внутри held request
scope либо sizing не меньше ожидаемой nested concurrency.

Raw connection нельзя передавать child task.

---

## 12. Errors и HTTP boundary

DB-neutral outer-scope errors:

```text
orm.pool.ConnectionPoolError < orm.OrmError
orm.pool.ConnectionPoolClosedError < orm.pool.ConnectionPoolError
orm.pool.ConnectionPoolTimeoutError < orm.pool.ConnectionPoolError
orm.pool.ConnectionPoolLeaseError < orm.pool.ConnectionPoolError
orm.pool.ModelBindingError < orm.OrmError
```

`ConnectionPoolError#source` хранит исходную adapter/native error для
diagnostics.

Правила:

- checkout failure в controller wrapper происходит до action и превращается
  integration layer в production-safe 503;
- bare explicit `with_connection` может rescue
  `orm.pool.ConnectionPoolTimeoutError`;
- operation-local checkout failure внутри `Person.find` возвращает
  `Err(ConnectionPoolTimeoutError)` через adapter API;
- bind к другому live Pool возвращает `Err(ModelBindingError)`;
- native message не попадает напрямую в HTTP response.

Core Ember не импортирует эти ошибки. Optional `ember.integrations.orm` делает
mapping.

---

## 13. Instrumentation и pool policy

`instrumentation:` устанавливается один раз на underlying `sqlite3.Pool`.
Checked-out databases наследуют instrumenter; existing `orm.Instrumentation`,
`ExecutionEvent` и `QueryLogger` продолжают видеть каждый SQL execution один
раз.

Pool metrics читаются без ORM-копии:

```amber
database.stats()[:open]
database.stats()[:leased]
database.stats()[:waiting]
```

Wrapper не выбирает автоматически:

- `max_size`;
- WAL;
- `busy_timeout`;
- read/write transaction mode;
- checkout timeout;
- retry policy.

Для SQLite web deployment документация должна объяснять, что увеличение pool
не превращает SQLite в multi-writer database. WAL помогает concurrent reads,
а writers всё равно сериализуются SQLite locking rules.

---

## 14. Response и shutdown lifetime

Текущий server возвращает buffered response. Controller lease освобождается
после action и response/view materialization, до передачи готового response
низкоуровневому server.

Если Ember позже добавит streaming, integration должна явно выбрать:

- materialize DB data до выхода из scope; либо
- удерживать lease до завершения stream с отдельным timeout/backpressure
  policy.

Lazy DB query после release недопустим, но обычный hydrated record не держит
connection и безопасен для rendering.

Graceful shutdown:

```text
1. перестать принимать новые HTTP requests;
2. дождаться/отменить in-flight controller/handler tasks;
3. database.drain!(timeout: ...);
4. завершить scheduler/process.
```

`drain!` запрещает новые checkout и ждёт outstanding leases.

---

## 15. Rejected alternatives

### 15.1. Repository/Session в каждом controller

```amber
def show(id):
  people = services.db.repository(Person)
  people.find(id)
```

Отклонено: infrastructure boilerplate попадает в business/controller logic и
ломает выбранный `Person.find` API.

### 15.2. Per-request model bind

```amber
User.bind!(sqlite_adapter(request_connection))
```

Отклонено: concurrent requests гоняются за shared ModelConfig, а executor
указывает на confined connection.

### 15.3. Передавать pool в controller constructor

Отклонено как обязательная форма. Controller request services могут содержать
другие business dependencies, но обычный ORM call не требует pool injection.

### 15.4. Universal hidden scope для bare handlers

Отклонено: стирает сознательную границу между `&handler` и
`&Controller#action`. Bare function получает только явно объявленные arguments
и middleware/service configuration. Явная `before` annotation допустима:
она является частью declaration, а не hidden framework behavior.

### 15.5. Public `orm.current_connection`

Отклонено: создаёт ambient capability. Внутренний task-local lease routing
инкапсулирован в `sqlite3.Pool` и не является public lookup API.

### 15.6. ORM реализует второй pool

Отклонено: дублирует уже проверенные waiting, affinity, cancellation, cleanup и
maintenance semantics `sqlite3-amber`.

### 15.7. Automatic transaction на controller action

Отклонено как default. Connection scope автоматический; transaction boundary
остаётся явной business semantics.

### 15.8. Commit возвращённого `Err`

Отклонено на ORM transaction layer, потому что persistence failures являются
Result values, а не обязательно exceptions.

---

## 16. Согласование с Ember design

В `DESIGN-web-framework-2026-07-13.md` нужно изменить:

1. **Grounded substrate:** `sqlite3-amber` уже имеет `pool: true`, lease
   affinity и non-inheritable task-local connection context.
2. **Request-scoped state:** connection lease остаётся request-scoped, но
   controller action не обязан получать repository/session object.
3. **Target normalization:** optional integrations могут декорировать
   controller target wrapper, сохраняя direct statically visible action call.
4. **Controller construction:** ORM connection scope охватывает construction,
   action и response normalization.
5. **Bare handler:** никакого автоматического controller ORM scope; explicit
   route middleware, `before` annotation, request service или ограниченный
   operation-local bound model call.
6. **ORM 13.2:** небезопасен bind к confined `Database`, но one-time bind к
   shareable Pool является каноническим web shape.
7. **ORM 13.3:** заменить repository-first пример на `Person.find` внутри
   controller и явный pool scope для bare handler.
8. **ORM 13.4:** убрать временный SQLite gate; оставить sizing, busy timeout,
   WAL, cancellation и shutdown caveats.
9. **Security:** «no ambient database connection» уточнить до «no public
   ambient connection lookup»; internal non-inheritable lease routing допустим.
10. **Phase 6:** low-level pool/affinity выполнены; остаются ORM facade,
    controller integration и end-to-end tests.

---

## 17. Implementation plan

### Phase 1 — thin ORM Pool facade — implemented

- реализовать `orm.sqlite3.pool`/`memory_pool`;
- хранить один shared `SqliteAdapter` поверх low-level Pool;
- реализовать multi-model `bind!` и binding guard;
- делегировать `with_connection`, stats и lifecycle;
- нормализовать outer pool errors;
- сохранить direct `adapter(db)` API.

### Phase 2 — model transaction surface — implemented

- добавить `ModelType#transaction`;
- сгенерировать class forwarding в `use orm.model`;
- добавить `SqliteAdapter#transaction`;
- реализовать Result-aware rollback;
- `find_by(**attributes)` отложен как необязательный ActiveRecord-shaped sugar
  над `get(where:)`; pool/transaction contract от него не зависит.

### Phase 3 — Ember integration

- определить optional `ember.integrations.orm` package;
- добавить composition seam вокруг controller target wrappers;
- не менять action signatures;
- добавить pool как explicit request service;
- предоставить explicit `connection(database)` middleware для bare routes;
- предоставить generic `before` annotation macro над middleware ABI;
- добавить pool timeout mapping и shutdown hook.

### Phase 4 — conformance

- controller action вызывает только `Person.find` и использует один lease;
- несколько models в action используют тот же connection;
- bare handler без binding получает unbound Result error;
- bare handler с operation-local bound call checkout/release на operation;
- bare handler middleware держит один lease;
- bare handler `before db_request` сохраняет signature/`&handler` и держит один
  lease;
- concurrent controllers получают exclusive leases;
- suspension сохраняет lease;
- child task получает новый lease;
- timeout/cancellation всегда release/rollback;
- transaction commit на `Ok`, rollback на `Err`/raise/cancel;
- instrumentation не дублируется;
- drain ждёт in-flight controller scope.

---

## 18. Acceptance criteria

1. В controller action нет pool/session/repository boilerplate.
2. `Person.find` автоматически использует controller's checked-out lease.
3. Model bind выполняется один раз к shareable Pool до concurrent serving.
4. Bare function не получает скрытый controller scope.
5. Bare function может выбрать explicit route middleware, `before` annotation,
   request service или ограниченный operation-local model call.
6. Несколько ORM calls controller dispatch используют один connection.
7. Records не держат lease и сохраняются через pool-backed model executor.
8. Child task не наследует parent connection.
9. Model-level `transaction` включает другие models того же Pool.
10. `Err` из ORM transaction вызывает rollback.
11. ORM не содержит собственного pooling algorithm/task local.
12. Core Ember остаётся ORM-neutral.
13. Legacy `Model.bind!(adapter(db))` и direct adapters не ломаются.
14. Timeout, cancellation, instrumentation и shutdown покрыты tests.

---

## 19. Зафиксированные решения

1. Основной controller API — `Person.find`, `Person.where`, `person.save`.
2. Application один раз bind models к shareable pool-backed executor.
3. Controller integration автоматически устанавливает lease вокруг generated
   controller dispatch.
4. Controller action не является pool-aware.
5. Bare function не получает этот scope неявно.
6. Explicit route middleware может сделать bare route pool-scoped.
7. `before` annotation может сделать scope intrinsic policy bare function.
8. Bound model вне scope использует operation-local checkout.
9. Pooling полностью принадлежит `sqlite3-amber`.
10. Public ambient current connection отсутствует.
11. Internal non-inheritable task-local lease routing допустим и
    инкапсулирован.
12. Transaction остаётся явной business boundary и доступна через Model.
13. Repository/Session layer не является частью connection-pool проекта.
