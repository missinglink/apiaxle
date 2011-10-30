_ = require "underscore"
{ Redis } = require "../redis"

class exports.ApiKey extends Redis
  @instantiateOnStartup = true
  @smallKeyName = "key"

  @structure =
    type: "object"
    properties:
      qpd:
        type: "integer"
        default: 1:  172800
      qps:
        type: "integer"
        default: 2
      forApi:
        type: "string"

  new: ( name, details, cb ) ->
    # if there isn't a forApi field then `super` will take care of
    # that
    if details.forApi
      @gatekeeper.model( "api" ).find details.forApi, ( err, apiDetails ) ->
        return cb err if err

        if not apiDetails
          return cb new ValidationError "API '#{ name }' doesn't exist."
    else
      super
