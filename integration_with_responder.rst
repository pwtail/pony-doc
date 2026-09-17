Integration with Responder
==========================

`Responder <https://github.com/kennethreitz/responder>`_ is an ASGI web framework built
on Starlette with a Flask-like API: every view receives ``req`` and ``resp``, and views
may be asynchronous. Pony works with it in :ref:`asynchronous mode <async-mode>` - a view
opens the session with ``async with db_session:`` and the queries are awaited.

The session can be turned into a *dependency* so that the views do not repeat the same
``async with db_session:`` in every handler. The provider is registered once with
``@api.dependency()``, and it is a generator: it opens the session, yields control to the
view, and closes the session (committing the transaction) after the view has returned:

.. code-block:: python

    import responder
    from pony.orm import *

    api = responder.API()

    db = Database('postgres_async', dsn='dbname=mydb user=postgres host=localhost')

    class Task(db.Entity):
        title = Required(str)
        done = Optional(bool, default=False)

    db.generate_mapping(create_tables=True)      # schema operations are synchronous


    @api.dependency(name='db_session')
    async def db_session_dep():
        """A dependency: opens a database session around the view.

        Registered under the name ``db_session``, so a view declares ``db_session``
        among its parameters. Control is yielded to the view, so the teardown - commit
        on session exit, or rollback if the view raised - runs after the response is
        ready. The value itself is not used: Pony keeps the session in contextvars.
        """
        async with db_session:
            yield


    @api.get('/tasks')
    async def list_tasks(req, resp, *, db_session):
        tasks = await select(t for t in Task).order_by(Task.title)
        resp.media = [{'id': t.id, 'title': t.title, 'done': t.done} for t in tasks]


    @api.get('/tasks/{task_id:int}')
    async def get_task(req, resp, *, task_id, db_session):
        try:
            task = await Task[task_id]
        except ObjectNotFound:
            resp.status_code = 404
            resp.media = {'error': 'task not found'}
            return
        resp.media = {'id': task.id, 'title': task.title, 'done': task.done}


    @api.delete('/tasks/{task_id:int}')
    async def delete_task(req, resp, *, task_id, db_session):
        try:
            task = await Task[task_id]
        except ObjectNotFound:
            resp.status_code = 404
            return
        task.delete()
        resp.status_code = 204


    @api.post('/tasks')                          # explicit session, see below
    async def create_task(req, resp):
        data = await req.media()                 # the body is read before the session
        async with db_session:                   # a pool connection is taken only here
            task = Task(title=data['title'])
            await flush()                        # the primary key is available here
            resp.status_code = 201
            resp.media = {'id': task.id, 'title': task.title, 'done': task.done}


    if __name__ == '__main__':
        api.run()

The provider is registered under the name ``db_session``, and a view gets it by declaring
a parameter with that name - Responder injects a registered dependency into any such
parameter automatically, so no ``Depends(...)`` is needed in the routes. The parameter
itself is a marker: Pony keeps the session in contextvars, so the value is not used, but
the declaration is what makes Responder run the dependency around the view:

.. code-block:: python

    @api.get('/tasks')
    async def list_tasks(req, resp, *, db_session):
        tasks = await select(t for t in Task).order_by(Task.title)      # session is open
        resp.media = [{'id': t.id, 'title': t.title, 'done': t.done} for t in tasks]

The same mechanism is used when a provider *returns* something the view needs - then the
value is used as well:

.. code-block:: python

    @api.dependency()
    async def current_user(req):
        return await req.api.state.auth.load_user(req.headers.get('Authorization'))

    @api.get('/me')
    async def me(req, resp, *, current_user):
        resp.media = {'user': current_user.name}

Two things about the last handler:

* ``create_task`` keeps the explicit ``async with db_session:``. The request body is read
  first, so a session (and a connection from the pool) is taken only for the part of the
  handler that works with the database.
* ``await flush()`` inside an explicit session sends the pending changes to the database,
  which is why the primary key of the new object can be used right away.

Error handling and transactions
-------------------------------

The two forms differ in how failures are handled, and it is worth knowing before choosing
one of them.

**Explicit session.** An exception raised inside the view reaches ``async with
db_session:``, so the transaction is rolled back:

.. code-block:: python

    @api.post('/tasks')
    async def create_task(req, resp):
        data = await req.media()
        async with db_session:
            Task(title=data['title'])
            raise ValueError('something went wrong')     # 500, changes are rolled back

**Session dependency.** Responder turns an exception raised by a view into an error
*response*, so the dependency's generator finishes normally and the session is committed -
even when the handler returned ``400`` or the framework produced ``500``. Such a
dependency is therefore best for read-only handlers (``list_tasks`` and ``get_task``
above), while a handler that writes should either open the session explicitly, or roll
back before returning an error:

.. code-block:: python

    @api.post('/tasks/import')
    async def import_tasks(req, resp, *, db_session):
        data = await req.media()
        if not data.get('items'):
            await rollback()                             # nothing should be written
            resp.status_code = 400
            resp.media = {'error': 'no items'}
            return
        for item in data['items']:
            Task(title=item['title'])
        resp.status_code = 201

The same is true for a "soft" error inside an explicit session: setting an error status
does not roll anything back, ``await rollback()`` does.

Other things to keep in mind in this example:

* ``resp.media``, ``resp.status_code`` and other response attributes may be assigned
  inside a session - they are not database operations.
* The transaction is committed on exit from ``async with db_session:``, so no explicit
  ``commit()`` is needed; ``await commit()``, ``await rollback()`` and ``await flush()``
  are available when a handler needs them.
* ``await Task[task_id]`` looks in the identity map of the session first and sends a query
  only if the object is not there yet; if the row does not exist, ``ObjectNotFound`` is
  raised.
* Collections require explicit loading, and collection elements come as seeds - see
  :ref:`async-mode` for the two rules of asynchronous sessions.
* ``delete_task`` writes as well, but its only failure path is a ``404`` which has not
  changed anything, so the dependency is safe there; a handler whose failure can leave a
  half-applied change should follow one of the two recipes above.

Synchronous views
-----------------

Synchronous providers work with Responder as well. A *synchronous* view of Responder is
executed in a thread pool (there is no event loop in that thread), so the usual
``with db_session:`` pattern applies and the queries are written without ``await``. Keep
the session *inside* the view here: a session opened elsewhere - in an asynchronous
dependency or in a middleware - belongs to the event-loop task and is not visible in the
thread pool, so such a view fails with ``TransactionError: db_session is required when
working with the database``:

.. code-block:: python

    db = Database('postgres', dsn='dbname=mydb user=postgres host=localhost')

    class Task(db.Entity):
        title = Required(str)

    db.generate_mapping(create_tables=True)

    @api.get('/tasks-sync')
    def list_tasks_sync(req, resp):
        with db_session:
            resp.media = [{'id': t.id, 'title': t.title} for t in select(t for t in Task)]

Do not mix the two styles inside one transaction: a synchronous ``with db_session:``
cannot be used inside an asynchronous view, and an asynchronous session requires an
asynchronous provider (``postgres_async`` or ``mariadb_async``).

The same approach works for other ASGI frameworks - see
:doc:`integration_with_fastapi`.
