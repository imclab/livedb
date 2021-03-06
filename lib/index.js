var Readable = require('stream').Readable;
var assert = require('assert');
var isError = require('util');
var async = require('async');
var redisLib = require('redis');
var EventEmitter = require('events').EventEmitter;
var bulkSubscribe = require('./bulksubscribe');

var SDC;
try {
  // If statsd isn't found, simply disable it.
  SDC = require('statsd-client');
} catch (e) {}

var ot = require('./ot');

// Export the memory store as livedb.memory
exports.memory = require('./memory');
exports.client = Livedb;

function doNothing() {};

// The client is created using either an options object or a database backend
// which is used as both oplog and snapshot.
//
// Eg:
//  var db = require('livedb-mongo')('localhost:27017/test?auto_reconnect', {safe:true});
//  var livedb = require('livedb').client(db);
//
// Or using an options object:
//
//  var db = require('livedb-mongo')('localhost:27017/test?auto_reconnect', {safe:true});
//  var livedb = require('livedb').client({db:db});
//
// If you want, you can use a different database for both snapshots and operations:
//
//  var snapshotdb = require('livedb-mongo')('localhost:27017/test?auto_reconnect', {safe:true});
//  var oplog = {writeOp:..., getVersion:..., getOps:...};
//  var livedb = require('livedb').client({snapshotDb:snapshotdb, oplog:oplog});
//
// Other options:
//
// - redis:<redis client>. This can be specified if there is any further
//     configuration of redis that you want to perform. The obvious examples of
//     this are when redis is running on a remote machine, redis requires
//     authentication or you want to use something other than redis db 0.
//
// - redisObserver:<redis client>. Livedb actually needs 2 redis connections,
//     because redis doesn't let you use a connection with pubsub subscriptions
//     to edit data. Livedb will automatically try to clone the first connection
//     to make the observer connection, but we can't copy some options. if you
//     want to do anything thats particularly fancy, you should make 2 redis
//     instances and provide livedb with both of them. Note that because redis
//     pubsub messages aren't constrained to the selected database, the
//     redisObserver doesn't need to select the db you have your data in.
//
// - extraDbs:{}  This is used to register extra database backends which will be
//     notified whenever operations are submitted. They can also be used in
//     queries.
//
// - statsd:{}  Options passed to node-statsd-client for statistics. If this is
//     missing, statsd-based logging is disabled.
function Livedb(options) {
  // Allow usage as
  //   var myClient = client(options);
  // or
  //   var myClient = new livedb.client(options);
  if (!(this instanceof Livedb)) return new Livedb(options);

  if (!options) throw new Error('livedb missing database options');

  // Database which stores the documents.
  this.snapshotDb = options.snapshotDb || options.db || options;

  if (!this.snapshotDb.getSnapshot || !this.snapshotDb.writeSnapshot) {
    throw new Error('Missing or invalid snapshot db');
  }

  // Database which stores the operations.
  this.oplog = options.oplog || options.db || options;

  if (!this.oplog.writeOp || !this.oplog.getVersion || !this.oplog.getOps) {
    throw new Error('Missing or invalid operation log');
  }

  this.driver = options.driver;

  // This contains any extra databases that can be queried & notified when documents change
  this.extraDbs = options.extraDbs || {};

  // Statsd client. Either accept a statsd client directly via options.statsd
  // or accept statsd options via options.statsd and create a statsd client
  // from them.
  if (options.sdc) {
    this.sdc = options.sdc;
  } else if (options.statsd) {
    if (!SDC) throw Error('statsd not found - `npm install statsd` for statsd support');
    this.sdc = new SDC(options.statsd);
    this.closeSdc = true;
  }

  // Some statsd gauges
  this.numStreams = 0;
  this.numSubscriptions = 0;


  // This is a set of all the outstanding streams that have been subscribed by
  // clients. We need this so we can clean up subscribers properly.
  this.streams = {};
  this.nextStreamId = 0;

  // Emitter for channel messages. Event is the prefixed channel name. Listener is
  // called with (prefixed channel, msg)
  this.subscribers = new EventEmitter();

  // We will be registering a lot of events. Surpress warnings.
  this.subscribers.setMaxListeners(0);

  // This will be rewritten when scaling support is added.
  // this.presenceVersion = {};
  // Map from cd -> {v:_, data:_}
  this.presenceCache = {};


  bulkSubscribe.mixinSnapshotFn(this.snapshotDb);
};


// The ASCII unit separator!
var SEPARATOR = '\x1f';

// Rather than passing around 2 arguments (which results in extra objects in a
// bunch of cases), we're joining the collection & docname together using the
// ASCII unit separator.
Livedb.encodeCD = function(cName, docName) {
  return cName + SEPARATOR + docName;
};
// Returns [cName, docName]
Livedb.decodeCD = function(cd) {
  return cd.split(SEPARATOR);
};

function logEntryForData(opData) {
  // Only put the op itself and the op's id in redis's log. The version can be inferred via the version field.
  var entry = {};

  if (opData.src) entry.src = opData.src;
  if (opData.seq) entry.seq = opData.seq;
  if (opData.op) {
    entry.op = opData.op;
  } else if(opData.del) {
    entry.del = opData.del;
  } else if (opData.create) {
    entry.create = opData.create;
  }
  entry.m = opData.m; // Metadata.
  return entry;
};
Livedb.logEntryForData = logEntryForData;

Livedb.prototype._addStream = function(stream) {
  this.numStreams++;
  if (this.sdc) this.sdc.gauge('livedb.streams', this.numStreams);

  stream._id = this.nextStreamId++;
  this.streams[stream._id] = stream;
};

Livedb.prototype._removeStream = function(stream) {
  this.numStreams--;
  if (this.sdc) this.sdc.gauge('livedb.streams', this.numStreams);

  delete this.streams[stream._id];
};


// Non inclusive - gets ops from [from, to). Ie, all relevant ops. If to is
// not defined (null or undefined) then it returns all ops.
Livedb.prototype.getOps = function(cName, docName, from, to, callback) {
  // This function is basically just a fancy wrapper for driver.getOps(). Before
  // calling into the driver, it cleans up the input a little.

  // Make 'to' field optional.
  if (typeof to === 'function') {
    callback = to;
    to = null;
  }

  var self = this;

  if (from == null) return callback('Invalid from field in getOps');

  if (to != null && to >= 0 && from > to) return callback(null, []);

  var start = Date.now();
  // this._getOps(cName, docName, from, to, function(err, ops) {
  this.driver.getOps(cName, docName, from, to, function(err, ops) {
    if (self.sdc) self.sdc.timing('livedb.getOps', Date.now() - start);
    callback(err, ops);
  });
};


Livedb.prototype.publish = function(channel, data) {
  if (this.sdc) this.sdc.increment('livedb.redis.publish');

  if (data) data = JSON.stringify(data);
  this.redis.publish(this._prefixChannel(channel), data);
};

// Submit an operation on the named collection/docname. opData should contain a
// {op:}, {create:} or {del:} field. It should probably contain a v: field (if
// it doesn't, it defaults to the current version).
//
// callback called with (err, version, ops, snapshot)
Livedb.prototype.submit = function(cName, docName, opData, options, callback) {
  // Options is optional.
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }

  var start = Date.now();
  
  if (!options) options = {};
  if (!callback) callback = doNothing;

  var err = ot.checkOpData(opData);
  if (err) return callback(err);

  ot.normalize(opData);

  var transformedOps = [];
  
  var self = this;

  function retry() {
    // First we'll get a doc snapshot. This wouldn't be necessary except that
    // we need to check that the operation is valid against the current
    // document before accepting it.
    self._lazyFetch(cName, docName, function(err, snapshot) {
      if (err) return callback(err);

      // Get all operations that might be relevant. We'll float the snapshot
      // and the operation up to the most recent version of the document, then
      // try submitting.
      var from = opData.v != null ? Math.min(snapshot.v, opData.v) : snapshot.v;
      self.driver.getOps(cName, docName, from, null, function(err, ops) {
        if (err) return callback(err);

        for (var i = 0; i < ops.length; i++) {
          var op = ops[i];

          if (opData.src && opData.src === op.src && opData.seq === op.seq) {
            // The op has already been submitted. There's a variety of ways
            // this can happen. Its important we don't transform it by itself
            // & submit again.
            return callback('Op already submitted');
          }

          // Bring both the op and the snapshot up to date. At least one of
          // these two conditionals should be true.
          if (snapshot.v === op.v) {
            err = ot.apply(snapshot, op);
            if (err) return callback(err);
          }
          if (opData.v === op.v) {
            transformedOps.push(op);
            err = ot.transform(snapshot.type, opData, op);
            if (err) return callback(err);
          }
        }

        // Setting the version here has ramifications if we have to retry -
        // we'll transform by any new operations which hit from this point on.
        // In reality, it shouldn't matter. But its important to know that even
        // if you pass a null version into submit, its still possible for
        // transform() to get called.
        if (opData.v == null)
          opData.v = snapshot.v;
        else if (opData.v !== snapshot.v)
          return callback('Invalid opData version');

        var type = snapshot.type;
        // Ok, now we can try to apply the op.
        err = ot.apply(snapshot, opData);
        if (err) {
          if (typeof err !== 'string' && !isError(err)) {
            console.warn('validation function must return falsy, string or an error object.');
            console.warn('Instead we got', err);
          }
          return callback(err);
        }

        // Great - now we're in the situation that we can actually submit the
        // operation to the database. If this method succeeds, it should
        // update any persistant oplogs before calling the callback to tell us
        // about the successful commit. I could make this API more
        // complicated, enabling the function to return actual operations and
        // whatnot, but its quite rare to actually need to transform data on
        // the server at this point.
        self.driver.atomicSubmit(cName, docName, opData, options, function(err, shouldRetry) {
          if (err) {
            if (shouldRetry)
              retry();
            else
              callback(err);
          } else {
            self._writeSnapshotAfterOp(cName, docName, snapshot, opData, options, function(err) {
              // What do we do if the snapshot write fails? We've already
              // committed the operation - its done and dusted. We probably
              // shouldn't re-run polling queries now. Really, no matter what
              // we do here things are going to be a little bit broken,
              // depending on the behaviour we trap in finish.

              // Its sort of too late to error out if the snapshotdb can't
              // take our op - the op has been commited.

              // postSubmit is for things like publishing the operation over
              // pubsub. We should probably make this asyncronous.

              // self._updateCursors(cName, docName, type, opData);
              if (self.driver.postSubmit) self.driver.postWriteSnapshot(cName, docName, opData, snapshot); 
              callback(err, snapshot.v - 1, transformedOps, snapshot);
            })
          }
        });
      });
    });
  }

  retry();
};

Livedb.prototype._writeSnapshotAfterOp = function(cName, docName, snapshot, opData, options, callback) {
  var self = this;

  this.snapshotDb.writeSnapshot(cName, docName, snapshot, function(err) {
    if (err) return callback(err);

    // For queries.
    for (var name in self.extraDbs) {
      var db = self.extraDbs[name];

      if (db.submit) {
        db.submit(cName, docName, opData, options, snapshot, self, function(err) {
          if (err) {
            console.warn("Error updating db " + name + " " +
              cName + "." + docName + " with new snapshot data: ", err);
          }
        });
      }
    }

    // It actually might make sense to hold calling the callback until after
    // all the database indexes have been updated. It might stop some race
    // conditions around external indexes.
    callback();
  });
};

// Subscribe to a redis pubsub channel and get a nodejs stream out
Livedb.prototype.subscribeChannels = function(channels, callback) {
  var stream = new Readable({objectMode: true});
  var self = this;

  // This function is for notifying us that the stream is empty and needs data.
  // For now, we'll just ignore the signal and assume the reader reads as fast
  // as we fill it. I could add a buffer in this function, but really I don't think
  // that is any better than the buffer implementation in nodejs streams themselves.
  stream._read = doNothing;

  var open = true;

  // Registered so we can clean up the stream if the livedb instance is destroyed.
  this._addStream(stream);

  var listener;

  if (Array.isArray(channels)) {
    listener = function(msgChannel, data) {
      // Unprefix the channel name
      msgChannel = msgChannel.slice(msgChannel.indexOf(' ') + 1);

      // We shouldn't get messages after unsubscribe, but it's happened.
      if (!open || channels.indexOf(msgChannel) === -1) return;

      // Unprefix database name from the channel and add it to the message.
      data.channel = msgChannel;
      stream.push(data);
    };
  } else {
    listener = function(msgChannel, data) {
      // console.log("listener", msgChannel, data);
      // We shouldn't get messages after unsubscribe, but it's happened.
      if (!open || msgChannel !== self._prefixChannel(channels)) return;

      stream.push(data);
    };
  }

  stream.destroy = function() {
    if (!open) return;

    open = false;
    stream.push(null);
    self._removeStream(stream);

    self._redisRemoveChannelListeners(channels, listener);
    stream.destroy = doNothing;

    stream.emit('close');
  };

  this._redisAddChannelListeners(channels, listener, function(err) {
    if (err) {
      stream.destroy();
      return callback(err);
    }

    callback(null, stream);
  });
};

// Callback called with (err, op stream). v must be in the past or present. Behaviour
// with a future v is undefined. (Don't do that.)
Livedb.prototype.subscribe = function(cName, docName, v, options, callback) {
  // Support old option-less subscribe semantics
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }

  if (this.sdc) {
    this.sdc.increment('livedb.subscribe');
    this.sdc.increment('livedb.subscribe.raw');
  }

  var opChannel = Livedb.getDocOpChannel(cName, docName);
  var self = this;

  // Subscribe redis to the stream first so we don't miss out on any operations
  // while we're getting the history
  this.subscribeChannels(opChannel, function(err, stream) {
    if (err) callback(err);

    // From here on, we need to call stream.destroy() if there are errors.
    self.getOps(cName, docName, v, function(err, ops) {
      if (err) {
        stream.destroy();
        return callback(err);
      }
      self._packOpStream(v, stream, ops);

      // Better to call fetchPresence here
      var presence;
      if (options.wantPresence) {
        var cd = Livedb.encodeCD(cName, docName);
        presence = self.presenceCache[cd] || {};
      }
      callback(null, stream, presence);
    });
  });
};

// This is a fetch that doesn't check the oplog to see if the snapshot is out
// of date. It will be higher performance, but in some error conditions it may
// return an outdated snapshot.
Livedb.prototype._lazyFetch = function(cName, docName, callback) {
  var self = this;
  var start = Date.now();

  this.snapshotDb.getSnapshot(cName, docName, function(err, snapshot) {
    if (err) return callback(err);

    snapshot = snapshot || {v:0};
    if (snapshot.v == null) return callback('Invalid snapshot data');
    if (self.sdc) self.sdc.timing('livedb.lazyFetch', Date.now() - start);

    callback(null, snapshot);
  });
};

// Callback called with (err, {v, data})
Livedb.prototype.fetch = function(cName, docName, callback) {
  var self = this;
  this._lazyFetch(cName, docName, function(err, data) {
    if (err) return callback(err);

    self.getOps(cName, docName, data.v, function(err, results) {
      if (err) return callback(err);

      err = ot.applyAll(data, results);
      callback(err, err ? null : data);

      // Note that this does NOT cache the new version in redis, unlike the old version.
    });
  });
};

Livedb.prototype.fetchAndSubscribe = function(cName, docName, callback) {
  var self = this;
  this.fetch(cName, docName, function(err, data) {
    if (err) return callback(err);
    self.subscribe(cName, docName, data.v, function(err, stream) {
      callback(err, data, stream);
    });
  });
};

Livedb.prototype.collection = function(cName) {
  return {
    submit: this.submit.bind(this, cName),
    subscribe: this.subscribe.bind(this, cName),
    getOps: this.getOps.bind(this, cName),
    fetch: this.fetch.bind(this, cName),
    //fetchAndObserve: this.fetchAndObserve.bind(this, cName),
    queryFetch: this.queryFetch.bind(this, cName),
    query: this.query.bind(this, cName),
  };
};

Livedb.prototype.destroy = function() {
  // ... and close any remaining subscription streams.
  for (var id in this.streams) {
    this.streams[id].destroy();
  }

  if (this.closeSdc) this.sdc.close();
};




// Helper for subscribe & bulkSubscribe to repack the start of a stream given
// potential operations which happened while the listeners were getting
// established
Livedb.prototype._packOpStream = function(v, stream, ops) {
  // Ok, so if there's anything in the stream right now, it might overlap with the
  // historical operations. We'll pump the reader and (probably!) prefix it with the
  // getOps result.
  var d;
  var queue = [];
  while (d = stream.read()) {
    queue.push(d);
  }

  // First send all the operations between v and when we called getOps
  for (var i = 0; i < ops.length; i++) {
    d = ops[i];
    assert.equal(d.v, v);
    v++;
    stream.push(d);
  }
  // Then all the ops between then and now..
  for (i = 0; i < queue.length; i++) {
    d = queue[i];
    if (d.v >= v) {
      assert.equal(d.v, v);
      v++;
      stream.push(d);
    }
  }
};

// Mixin external modules
require('./livedb-redis')(Livedb);
require('./queries')(Livedb);
require('./presence')(Livedb);
bulkSubscribe.mixin(Livedb);
