#[`cloudi_core` 1.3.0 (beta)](http://cloudi.org)

[![Build Status](https://secure.travis-ci.org/okeuday/CloudI.png?branch=develop)](http://travis-ci.org/okeuday/CloudI)

## LICENSE

[BSD License](https://github.com/okeuday/CloudI/blob/master/src/LICENSE)

## ABOUT

`cloudi_core` provides only the internal service support from the main
[CloudI](https://github.com/okeuday/CloudI/) repository.  For Erlang
development, this can help provide a limited set of dependencies.

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

