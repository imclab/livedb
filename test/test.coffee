# This used to be the whole set of tests - now some of the ancillary parts of
# livedb have been pulled out. These tests should probably be split out into
# multiple files.

redisLib = require 'redis'
livedb = require '../lib'
assert = require 'assert'

otTypes = require 'ottypes'
{createClient, setup, teardown} = require './util'

stripTs = (ops) ->
  if Array.isArray ops
    for op in ops
      delete op.m.ts if op.m
  else
    delete ops.m.ts if ops.m
  ops

# Snapshots we get back from livedb will have a timestamp with a
# m:{ctime:, mtime:} with the current time. We'll check the time is sometime
# between when the module is loaded and 10 seconds later. This is a bit
# brittle. It also copies functionality in ot.coffee.
checkAndStripMetadata = do ->
  before = Date.now()
  after = before + 10 * 1000
  (snapshot) ->
    assert.ok snapshot.m
    assert.ok before <= snapshot.m.ctime < after if snapshot.m.ctime
    assert.ok before <= snapshot.m.mtime < after
    delete snapshot.m.ctime
    delete snapshot.m.mtime
    snapshot


describe 'livedb', ->
  beforeEach setup

  beforeEach ->
    @cName = '_test'
    @cName2 = '_test2'
    @cName3 = '_test3'

  afterEach teardown

  describe 'submit', ->
    it 'creates a doc', (done) ->
      @collection.submit @docName, {v:0, create:{type:'text'}}, (err) ->
        throw new Error err if err
        done()

    it 'allows create ops with a null version', (done) ->
      @collection.submit @docName, {v:null, create:{type:'text'}}, (err) ->
        throw new Error err if err
        done()

    it 'errors if you dont specify a type', (done) ->
      @collection.submit @docName, {v:0, create:{}}, (err) ->
        assert.ok err
        done()

    it 'can modify a document', (done) -> @create =>
      @collection.submit @docName, v:1, op:['hi'], (err, v) =>
        throw new Error err if err
        @collection.fetch @docName, (err, {v, data}) =>
          throw new Error err if err
          assert.deepEqual data, 'hi'
          done()

    it 'transforms operations', (done) -> @create =>
      @collection.submit @docName, v:1, op:['a'], src:'abc', seq:123, (err, v, ops) =>
        throw new Error err if err
        assert.deepEqual ops, []
        @collection.submit @docName, v:1, op:['b'], (err, v, ops) =>
          throw new Error err if err
          assert.deepEqual stripTs(ops), [{v:1, op:['a'], src:'abc', seq:123, m:{}}]
          done()

    it 'allows ops with a null version', (done) -> @create =>
      @collection.submit @docName, v:null, op:['hi'], (err, v) =>
        throw new Error err if err
        @collection.fetch @docName, (err, {v, data}) =>
          throw new Error err if err
          assert.deepEqual data, 'hi'
          done()

    it 'removes a doc', (done) -> @create =>
      @collection.submit @docName, v:1, del:true, (err, v) =>
        throw new Error err if err
        @collection.fetch @docName, (err, data) =>
          throw new Error err if err
          assert.equal data.data, null
          assert.equal data.type, null
          done()

    it 'removes a doc and allows creation of a new one', (done) ->
      @collection.submit @docName, {create: {type: 'text', data: 'world'}}, (err) =>
        throw new Error err if err
        @collection.submit @docName, v:1, del:true, (err, v) =>
          throw new Error err if err
          @collection.fetch @docName, (err, data) =>
            throw new Error err if err
            assert.equal data.data, null
            assert.equal data.type, null
            @collection.submit @docName, {create: {type: 'text', data: 'hello'}}, (err) =>
              throw new Error err if err
              @collection.fetch @docName, (err, data) =>
                throw new Error err if err
                assert.equal data.data, 'hello'
                assert.equal data.type, 'http://sharejs.org/types/textv1'
                done()

    it 'passes an error back to fetch if fetching returns a document with no version'

    it 'does not execute repeated operations', (done) -> @create =>
      @collection.submit @docName, v:1, op:['hi'], (err, v) =>
        throw new Error err if err
        op = [2, ' there']
        @collection.submit @docName, v:2, src:'abc', seq:123, op:op, (err, v) =>
          throw new Error err if err
          @collection.submit @docName, v:2, src:'abc', seq:123, op:op, (err, v) =>
            assert.strictEqual err, 'Op already submitted'
            done()

    it 'will execute concurrent operations', (done) -> @create =>
      count = 0

      callback = (err, v) =>
        assert.equal err, null
        count++
        done() if count is 2

      @collection.submit @docName, v:1, src:'abc', seq:1, op:['client 1'], callback
      @collection.submit @docName, v:1, src:'def', seq:1, op:['client 2'], callback

    it 'sends operations to the persistant oplog', (done) -> @create =>
      @db.getVersion @cName, @docName, (err, v) =>
        throw Error err if err
        assert.strictEqual v, 1
        @db.getOps @cName, @docName, 0, null, (err, ops) ->
          throw Error err if err
          assert.strictEqual ops.length, 1
          done()

    it 'repopulates the persistant oplog if data is missing', (done) ->
      @redis.set "#{@cName}.#{@docName} v", 2
      @redis.rpush "#{@cName}.#{@docName} ops",
        JSON.stringify({create:{type:otTypes.text.uri}}),
        JSON.stringify({op:['hi']}),
        (err) =>
          throw Error err if err
          @collection.submit @docName, v:2, op:['yo'], (err, v, ops, snapshot) =>
            throw Error err if err
            assert.strictEqual v, 2
            assert.deepEqual ops, []
            checkAndStripMetadata snapshot
            assert.deepEqual snapshot, {v:3, data:'yohi', type:otTypes.text.uri, m:{}}

            # And now the actual test - does the persistant oplog have our data?
            @db.getVersion @cName, @docName, (err, v) =>
              throw Error err if err
              assert.strictEqual v, 3
              @db.getOps @cName, @docName, 0, null, (err, ops) =>
                throw Error err if err
                assert.strictEqual ops.length, 3
                done()

    it 'sends operations to any extra db backends', (done) ->
      @testWrapper.submit = (cName, docName, opData, options, snapshot, callback) =>
        assert.equal cName, @cName
        assert.equal docName, @docName
        assert.deepEqual stripTs(opData), {v:0, create:{type:otTypes.text.uri, data:''}, m:{}}
        checkAndStripMetadata snapshot
        assert.deepEqual snapshot, {v:1, data:"", type:otTypes.text.uri, m:{}}
        done()

      @create()

    it 'works if the data in redis is missing', (done) -> @create =>
      @redis.flushdb =>
        @collection.submit @docName, v:1, op:['hi'], (err, v) =>
          throw new Error err if err
          @collection.fetch @docName, (err, {v, data}) =>
            throw new Error err if err
            assert.deepEqual data, 'hi'
            done()

    it 'ignores redis operations if the version isnt set', (done) -> @create =>
      @redis.del "#{@cName}.#{@docName} v", (err, result) =>
        throw Error err if err
        # If the key format ever changes, this test should fail instead of becoming silently ineffective
        assert.equal result, 1

        @redis.lset "#{@cName}.#{@docName} ops", 0, "junk that will crash livedb", (err) =>

          @collection.submit @docName, v:1, op:['hi'], (err, v) =>
            throw new Error err if err
            @collection.fetch @docName, (err, {v, data}) =>
              throw new Error err if err
              assert.deepEqual data, 'hi'
              done()

    it 'works if data in the oplog is missing', (done) ->
      # This test depends on the actual format in redis. Try to avoid adding
      # too many tests like this - its brittle.
      @redis.set "#{@cName}.#{@docName} v", 2
      @redis.rpush "#{@cName}.#{@docName} ops", JSON.stringify({create:{type:otTypes.text.uri}}), JSON.stringify({op:['hi']}), (err) =>
        throw Error err if err

        @collection.fetch @docName, (err, snapshot) ->
          throw Error err if err

          checkAndStripMetadata snapshot
          assert.deepEqual snapshot, {v:2, data:'hi', type:otTypes.text.uri, m:{}}
          done()


    describe 'pre validate', ->
      it 'runs a supplied pre validate function on the data', (done) ->
        validationRun = no
        preValidate = (opData, snapshot) ->
          assert.deepEqual snapshot, {v:0}
          validationRun = yes
          return

        @collection.submit @docName, {v:0, create:{type:'text'}, preValidate}, (err) ->
          assert.ok validationRun
          done()

      it 'does not submit if pre validation fails', (done) -> @create =>
        preValidate = (opData, snapshot) ->
          assert.deepEqual opData.op, ['hi']
          return 'no you!'

        @collection.submit @docName, {v:1, op:['hi'], preValidate}, (err) =>
          assert.equal err, 'no you!'

          @collection.fetch @docName, (err, {v, data}) =>
            throw new Error err if err
            assert.deepEqual data, ''
            done()

      it 'calls prevalidate on each component in turn, and applies them incrementally'


    describe 'validate', ->
      it 'runs a supplied validation function on the data', (done) ->
        validationRun = no
        validate = (opData, snapshot, callback) ->
          checkAndStripMetadata snapshot
          assert.deepEqual snapshot, {v:1, data:'', type:otTypes.text.uri, m:{}}
          validationRun = yes
          return

        @collection.submit @docName, {v:0, create:{type:'text'}, validate}, (err) ->
          assert.ok validationRun
          done()

      it 'does not submit if validation fails', (done) -> @create =>
        validate = (opData, snapshot, callback) ->
          assert.deepEqual opData.op, ['hi']
          return 'no you!'

        @collection.submit @docName, {v:1, op:['hi'], validate}, (err) =>
          assert.equal err, 'no you!'

          @collection.fetch @docName, (err, {v, data}) =>
            throw new Error err if err
            assert.deepEqual data, ''
            done()

      it 'calls validate on each component in turn, and applies them incrementally'

  describe 'fetch', ->
    it 'can fetch created documents', (done) -> @create 'hi', =>
      @collection.fetch @docName, (err, {v, data}) ->
        throw new Error err if err
        assert.deepEqual data, 'hi'
        assert.strictEqual v, 1
        done()

  describe 'bulk fetch', ->
    it 'can fetch created documents', (done) -> @create 'hi', =>
      request = {}
      request[@cName] = [@docName]
      @client.bulkFetch request, (err, data) =>
        throw new Error err if err
        expected = {} # Urgh javascript :(
        expected[@cName] = {}
        expected[@cName][@docName] = {data:'hi', v:1, type:otTypes.text.uri, m:{}}

        for cName, docs of data
          for docName, snapshot of docs
            checkAndStripMetadata snapshot

        assert.deepEqual data, expected
        done()

    # creating anyway here just 'cos.
    it 'doesnt return anything for missing documents', (done) -> @create 'hi', =>
      request = {}
      request[@cName] = ['doesNotExist']
      @client.bulkFetch request, (err, data) =>
        throw new Error err if err
        expected = {}
        expected[@cName] = {doesNotExist:{v:0}}
        assert.deepEqual data, expected
        done()

    it 'works with multiple collections', (done) -> @create 'hi', =>
      # This test fetches a bunch of documents that don't exist, but whatever.
      request =
        aaaaa: []
        bbbbb: ['a', 'b', 'c']

      request[@cName] = [@docName]
      # Adding this afterwards to make sure @cName doesn't come last in native iteration order
      request.zzzzz = ['d', 'e', 'f']

      @client.bulkFetch request, (err, data) =>
        throw new Error err if err
        expected =
          aaaaa: {}
          bbbbb: {a:{v:0}, b:{v:0}, c:{v:0}}
          zzzzz: {d:{v:0}, e:{v:0}, f:{v:0}}
        expected[@cName] = {}
        expected[@cName][@docName] = {data:'hi', v:1, type:otTypes.text.uri, m:{}}

        checkAndStripMetadata data[@cName][@docName]

        assert.deepEqual data, expected
        done()


  describe 'getOps', ->
    it 'returns an empty list for nonexistant documents', (done) ->
      @collection.getOps @docName, 0, -1, (err, ops) ->
        throw new Error err if err
        assert.deepEqual ops, []
        done()

    it 'returns ops that have been submitted to a document', (done) -> @create =>
      @collection.submit @docName, v:1, op:['hi'], (err, v) =>
        @collection.getOps @docName, 0, 1, (err, ops) =>
          throw new Error err if err
          assert.deepEqual stripTs(ops), [create:{type:otTypes.text.uri, data:''}, v:0, m:{}]

          @collection.getOps @docName, 1, 2, (err, ops) ->
            throw new Error err if err
            assert.deepEqual stripTs(ops), [op:['hi'], v:1, m:{}]
            done()

    it 'puts a decent timestamp in ops', (done) ->
      # TS should be between start and end.
      start = Date.now()
      @create =>
        end = Date.now()
        @collection.getOps @docName, 0, (err, ops) ->
          throw Error(err) if err
          assert.equal ops.length, 1
          assert ops[0].m.ts >= start
          assert ops[0].m.ts <= end
          done()

    it 'puts a decent timestamp in ops which already have a m:{} field', (done) ->
      # TS should be between start and end.
      start = Date.now()
      @collection.submit @docName, {v:0, create:{type:'text'}, m:{}}, (err) =>
        throw Error(err) if err
        @collection.submit @docName, {v:1, op:['hi there'], m:{ts:123}}, (err) =>
          throw Error(err) if err

          end = Date.now()
          @collection.getOps @docName, 0, (err, ops) ->
            throw Error(err) if err
            assert.equal ops.length, 2
            for op in ops
              assert op.m.ts >= start
              assert op.m.ts <= end
            done()

    it 'returns all ops if to is not defined', (done) -> @create =>
      @collection.getOps @docName, 0, (err, ops) =>
        throw new Error err if err
        assert.deepEqual stripTs(ops), [create:{type:otTypes.text.uri, data:''}, v:0, m:{}]

        @collection.submit @docName, v:1, op:['hi'], (err, v) =>
          @collection.getOps @docName, 0, (err, ops) ->
            throw new Error err if err
            assert.deepEqual stripTs(ops), [{create:{type:otTypes.text.uri, data:''}, v:0, m:{}}, {op:['hi'], v:1, m:{}}]
            done()

    it 'works if redis has no data', (done) -> @create =>
      @redis.flushdb =>
        @collection.getOps @docName, 0, (err, ops) =>
          throw new Error err if err
          assert.deepEqual stripTs(ops), [create:{type:otTypes.text.uri, data:''}, v:0, m:{}]
          done()

    it 'ignores redis operations if the version isnt set', (done) -> @create =>
      @redis.del "#{@cName}.#{@docName} v", (err, result) =>
        throw Error err if err
        # If the key format ever changes, this test should fail instead of becoming silently ineffective
        assert.equal result, 1

        @redis.lset "#{@cName}.#{@docName} ops", 0, "junk that will crash livedb", (err) =>

          @collection.getOps @docName, 0, (err, ops) =>
            throw new Error err if err
            assert.deepEqual stripTs(ops), [create:{type:otTypes.text.uri, data:''}, v:0, m:{}]
            done()

    it 'removes junk in the redis oplog on submit', (done) -> @create =>
      @redis.del "#{@cName}.#{@docName} v", (err, result) =>
        throw Error err if err
        # If the key format ever changes, this test should fail instead of becoming silently ineffective
        assert.equal result, 1

        @redis.lset "#{@cName}.#{@docName} ops", 0, "junk that will crash livedb", (err) =>

          @collection.submit @docName, v:1, op:['hi'], (err, v) =>
            throw new Error err if err

            @collection.getOps @docName, 0, (err, ops) =>
              throw new Error err if err
              assert.deepEqual stripTs(ops), [{create:{type:otTypes.text.uri, data:''}, v:0, m:{}}, {op:['hi'], v:1, m:{}}]
              done()

    describe 'does not hit the database if the version is current in redis', ->
      beforeEach (done) -> @create =>
        @db.getVersion = -> throw Error 'getVersion should not be called'
        @db.getOps = -> throw Error 'getOps should not be called'
        done()

      it 'from previous version', (done) ->
        # This one operation is in redis. It should be fetched.
        @collection.getOps @docName, 0, (err, ops) =>
          throw new Error err if err
          assert.strictEqual ops.length, 1
          done()

      it 'from current version', (done) ->
        # Redis knows that the document is at version 1, so we should return [] here.
        @collection.getOps @docName, 1, (err, ops) ->
          throw new Error err if err
          assert.deepEqual ops, []
          done()

    it 'caches the version in redis', (done) ->
      @create => @redis.flushdb =>
        @collection.getOps @docName, 0, (err, ops) =>
          throw new Error err if err

          @redis.get "#{@cName}.#{@docName} v", (err, result) ->
            throw new Error err if err
            assert.equal result, 1
            done()



    it 'errors if ops are missing from the snapshotdb and oplogs'

  describe 'bulkGetOpsSince', ->
    # This isn't really an external API, but there is a tricky edge case which
    # can come up that its hard to recreate using bulkSubscribe directly.
    it 'handles multiple gets which are missing from redis correctly', (done) -> # regression
      # Nothing in redis, but the data of two documents are in the database.
      @db.writeOp 'test', 'one', {v:0, create:{type:otTypes.text.uri}}, =>
      @db.writeOp 'test', 'two', {v:0, create:{type:otTypes.text.uri}}, =>

        @client.bulkGetOpsSince {test:{one:0, two:0}}, (err, result) ->
          throw Error err if err
          assert.deepEqual result,
            test:
              one: [{v:0, create:{type:otTypes.text.uri}}]
              two: [{v:0, create:{type:otTypes.text.uri}}]
            done()

  describe 'subscribe', ->
    for subType in ['single', 'bulk'] then do (subType) -> describe subType, ->
      beforeEach ->
        @subscribe = if subType is 'single'
          @collection.subscribe
        else
          (docName, v, callback) =>
            request = {}
            request[@cName] = {}
            request[@cName][docName] = v
            @client.bulkSubscribe request, (err, streams) =>
              callback err, if streams then streams[@cName]?[docName]

      it 'observes local changes', (done) -> @create =>
        @subscribe @docName, 1, (err, stream) =>
          throw new Error err if err

          stream.on 'data', (op) ->
            try
              assert.deepEqual stripTs(op), {v:1, op:['hi'], src:'abc', seq:123, m:{}}
              stream.destroy()
              done()
            catch e
              console.error e.stack
              throw e

          @collection.submit @docName, v:1, op:['hi'], src:'abc', seq:123

      it 'sees ops when you observe an old version', (done) -> @create =>
        # The document has version 1
        @subscribe @docName, 0, (err, stream) =>
            #stream.once 'readable', =>
            assert.deepEqual stripTs(stream.read()), {v:0, create:{type:otTypes.text.uri, data:''}, m:{}}
            # And we still get ops that come in now.
            @collection.submit @docName, v:1, op:['hi'], src:'abc', seq:123,
            stream.once 'readable', ->
              assert.deepEqual stripTs(stream.read()), {v:1, op:['hi'], src:'abc', seq:123, m:{}}
              stream.destroy()
              done()

      it 'can observe a document that doesnt exist yet', (done) ->
        @subscribe @docName, 0, (err, stream) =>
          stream.on 'readable', ->
            assert.deepEqual stripTs(stream.read()), {v:0, create:{type:otTypes.text.uri, data:''}, m:{}}
            stream.destroy()
            done()

          @create()

      it 'does not throw when you double stream.destroy', (done) ->
        @subscribe @docName, 1, (err, stream) =>
          stream.destroy()
          stream.destroy()
          done()

      it 'has no dangling listeners after subscribing and unsubscribing', (done) ->
        @subscribe @docName, 0, (err, stream) =>
          stream.destroy()

          redis = redisLib.createClient()
          # I want to count the number of subscribed channels. Redis 2.8 adds
          # the 'pubsub' command, which does this. However, I can't rely on
          # pubsub existing so I'll use a dodgy method.
          #redis.send_command 'pubsub', ['CHANNELS'], (err, channels) ->
          redis.publish "15 #{@cName}.#{@docName}", '{}', (err, numSubscribers) ->
            assert.equal numSubscribers, 0
            redis.quit()
            done()

    it 'does not throw when you double stream.destroy', (done) ->
      @collection.subscribe @docName, 1, (err, stream) =>
        stream.destroy()
        stream.destroy()
        done()


    it 'works with separate clients', (done) -> @create =>
      numClients = 10 # You can go way higher, but it gets slow.

      # We have to share the database here because these tests are written
      # against the memory API, which doesn't share data between instances.
      clients = (createClient @db for [0...numClients])

      for c, i in clients
        c.client.submit @cName, @docName, v:1, op:["client #{i} "], (err) ->
          throw new Error err if err

      @collection.subscribe @docName, 1, (err, stream) =>
        throw new Error err if err
        # We should get numClients ops on the stream, in order.
        seq = 1
        stream.on 'readable', tryRead = =>
          data = stream.read()
          return unless data
          #console.log 'read', data
          delete data.op
          assert.deepEqual stripTs(data), {v:seq, m:{}} #, op:{op:'ins', p:['x', -1]}}

          if seq is numClients
            #console.log 'destroy stream'
            stream.destroy()

            for c, i in clients
              c.redis.quit()
              c.db.close()
            done()

            # Uncomment to see the actually submitted data
            #@collection.fetch @docName, (err, {v, data}) =>
            #  console.log data
          else
            seq++

          tryRead()

  it 'Fails to apply an operation to a document that was deleted and recreated'

  it 'correctly namespaces pubsub operations so other collections dont get confused'

  describe 'cleanup', ->
    it 'does not leak streams when clients subscribe & unsubscribe from documents', (done) -> @create =>
      assert.strictEqual 0, @client.numStreams
      @collection.subscribe @docName, 1, (err, stream) =>
        throw new Error err if err
        assert.strictEqual 1, @client.numStreams
        stream.destroy()
        assert.strictEqual 0, @client.numStreams
        done()

    it 'does not leak streams from bulkSubscribe', (done) -> @create2 'x', => @create2 'y', =>
      assert.strictEqual 0, @client.numStreams
      bs = {}
      bs[@cName] = {x:1, y:1}
      @client.bulkSubscribe bs, (err, streams) =>
        throw new Error err if err
        assert.strictEqual 2, @client.numStreams
        streams[@cName].x.destroy()
        streams[@cName].y.destroy()
        assert.strictEqual 0, @client.numStreams
        assert.strictEqual 0, Object.keys(@client.streams).length
        done()


  describe.skip 'listeners', ->
    it 'listens from the current version if v is not passed to add', (done) ->
      listener.on 'data', (opData) =>
        assert.deepEqual stripTs(opData),
          cName: @cName
          docName: @docName
          v: 0
          create:{type:otTypes.text.uri, data:''}
          m:{}
        done()

      listener = @client.listener().add @cName, @docName, (err, v) =>
        throw Error err if err
        @create()

    it 'listens from the specified version if its the present version', (done) ->
      listener.on 'data', (opData) =>
        assert.deepEqual stripTs(opData),
          cName: @cName
          docName: @docName
          v: 0
          create:{type:otTypes.text.uri, data:''}
          m:{}
        done()

      listener = @client.listener().add @cName, @docName, 0, (err, v) =>
        throw Error err if err
        @create()

    it 'listens from the specified version if its a past version', (done) -> @create =>
      listener.on 'data', (opData) =>
        assert.deepEqual stripTs(opData),
          cName: @cName
          docName: @docName
          v: 0
          create:{type:otTypes.text.uri, data:''}
          m:{}
        done()

      listener = @client.listener().add @cName, @docName, 0, (err, v) =>
        throw Error err if err





