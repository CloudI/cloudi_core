#[`cloudi_core` 1.4.0](http://cloudi.org)

[![Build Status](https://secure.travis-ci.org/CloudI/cloudi_core.png?branch=master)](http://travis-ci.org/CloudI/cloudi_core)

## LICENSE

[BSD License](https://github.com/CloudI/CloudI/blob/master/src/LICENSE)

## ABOUT

`cloudi_core` provides only the internal service support from the main
[CloudI](https://github.com/CloudI/CloudI/) repository.  For Erlang or Elixir
development, this can help provide a limited set of dependencies.  If you
want external service support also, but with CloudI as a rebar dependency,
[look here for a local installation](https://github.com/CloudI/CloudI/tree/master/examples/hello_world3#readme) or
[look here for a system-wide installation](https://github.com/CloudI/CloudI/tree/develop/examples/hello_world5#readme).
Otherwise, just use the [main repository](https://github.com/CloudI/CloudI)
for external service support.

## BUILDING

    rebar get-deps
    rebar compile

## EXAMPLE

    $ erl -pz deps/*/ebin -pz ebin
    Erlang R16B02 (erts-5.10.3) [source] [64-bit] [smp:8:8] [async-threads:10] [kernel-poll:false]
    
    Eshell V5.10.3  (abort with ^G)
    1> reltool_util:application_start(cloudi_core, [{configuration, "cloudi.conf"}]).

## CONTACT

Michael Truog (mjtruog [at] gmail (dot) com)

