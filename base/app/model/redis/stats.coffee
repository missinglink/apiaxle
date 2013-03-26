# Store and access real time hits per second
async   = require "async"
_       = require "underscore"
{Redis} = require "../redis"

class exports.Stats extends Redis
  @instantiateOnStartup = true
  @smallKeyName         = "stats"

  @granularities =
    seconds:       # Available for 1 hour
      size:   3600 # Amount of values stored in each hash, used for ts rounding
      ttl:    7200 # Keys live twice as long to handle overlap
      factor: 1    # Granularity, in seconds of the ts used for hash keys

    minutes:         # Available for 24 hours
      size:   1440   # Amount of values stored in each hash, used for ts rounding
      ttl:    172800 # Keys live twice as long to handle overlap
      factor: 60     # Granularity, in seconds of the ts used for hash keys

  # Helper function to format timestamp in seconds
  # Defaults to curent time
  getSecondsTimestamp: ( ts=( new Date() ).getTime() ) ->
    return Math.floor( ts / 1000 )

  # Get a timestamp rounded to the supplied precision
  # Precision is typically the size of the key in question
  getRoundedTimestamp: ( ts=@getSecondsTimestamp(), precision=1 ) ->
    return Math.floor( ts / precision ) * precision

  getFactoredTimestamp: ( ts_seconds=@getSecondsTimestamp(), factor ) ->
    return Math.floor( ts_seconds / factor ) * factor

  getPossibleResponseTypes: ( db_key, cb ) ->
    return @smembers db_key.concat( "response-types" ), cb

  recordHit: ( [ db_key..., axle_type ], cb ) ->
    multi = @multi()
    multi.sadd db_key.concat( "response-types" ), axle_type

    for gran, properties of Stats.granularities
      tsround = @getRoundedTimestamp null, properties.size

      temp_key = db_key.concat axle_type
      temp_key.push gran
      temp_key.push tsround

      # hash keys are stored at second
      ts = @getFactoredTimestamp null, properties.factor
      multi.hincrby temp_key, ts, 1
      multi.expireat temp_key, tsround + properties.ttl

    multi.exec cb

  # Get all response codes for a particular stats entry
  getAll: ( db_key, gran, from, to, cb ) ->
    @getPossibleResponseTypes db_key, ( err, codes ) =>
      all = []
      _.each codes, ( code ) =>
        all.push ( cb ) =>
          temp_key = _.clone db_key
          temp_key.push code
          @get temp_key, gran, from, to, cb

      async.series all, ( err, res ) =>
        results = {}

        for code, idx in codes
          results[code] = res[idx]

        return cb err, results

  # Get a single response code for a key or api stat
  # from, to should be int, seconds
  get: ( db_key, gran, from, to, cb ) ->
    # TODO: fetch codes from redis
    properties = Stats.granularities[gran]

    if not properties
      return cb new Error "Invalid granularity"

    from = @getFactoredTimestamp( from, properties.factor )
    to   = @getFactoredTimestamp( to, properties.factor )

    # Check if in range
    if from > to or from < @getMinFrom gran
      return cb new Error "Invalid from time"

    multi = @multi()
    ts    = from

    while ts <= to
      tsround = @getRoundedTimestamp ts, properties.size

      temp_key = _.clone db_key
      temp_key.push gran
      temp_key.push tsround

      multi.hget temp_key, ts
      ts += properties.factor

    # we need to format the results into an object ts => hits
    # also 0 pads
    multi.exec ( err, results ) =>
      return cb err if err

      ts = from
      i  = 0
      data = {}
      while ts <= to
        res = ( results[i] or 0 )

        data[ts] = parseInt res
        ts += properties.factor
        i += 1

      return cb null, data

  getMinFrom: ( gran ) ->
    properties = Stats.granularities[gran]
    min = @getRoundedTimestamp null, properties.size

    # subtract size from the most recent rounded timestamp to allow
    # for overlap
    return ( min - properties.size )

  hit: ( api, key, cached, code, cb ) ->
    db_keys = [
      [ "api", api, cached, code ],
      [ "key", key, cached, code ],
      [ "key-api", key, api, cached, code ],
      [ "api-key", api, key, cached, code ],
    ]

    all = []
    for db_key in db_keys
      do( db_key ) =>
        all.push ( cb ) => @recordHit db_key, cb

    return async.parallel all, cb
