# [`cloudi_core` 1.7.1](http://cloudi.org)

[![Build Status](https://secure.travis-ci.org/CloudI/cloudi_core.png?branch=master)](http://travis-ci.org/CloudI/cloudi_core)
[![hex.pm version](https://img.shields.io/hexpm/v/cloudi_core.svg)](https://hex.pm/packages/cloudi_core)

## LICENSE

[MIT License](https://github.com/CloudI/CloudI/blob/master/src/LICENSE)

## ABOUT

`cloudi_core` provides only the internal service support from the main
[CloudI](https://github.com/CloudI/CloudI/) repository.  For Erlang or Elixir
development, this can help provide a limited set of dependencies.  If you
want external service support also, but with CloudI as a rebar dependency,
refer to the [`hello_world_embedded` local installation example](https://github.com/CloudI/CloudI/tree/develop/examples/hello_world_embedded#readme).
Otherwise, just use the [main repository](https://github.com/CloudI/CloudI)
for external service support.

## BUILDING

    rebar get-deps
    rebar compile

## EXAMPLE

    $ erl -pz deps/*/ebin -pz ebin
    
    1> reltool_util:application_start(cloudi_core, [{configuration, "cloudi.conf"}]).

## CONTACT

Michael Truog (mjtruog [at] gmail (dot) com)

