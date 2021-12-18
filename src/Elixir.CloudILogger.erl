%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%% Automatically generated by ex2erl at 2021-12-18T01:34:23-08:00
%%% (Erlang/OTP 23.3.4.9, Elixir 1.13.0)
%%%
-file("lib/cloudi_core/priv/CloudILogger.ex", 39).

-module('Elixir.CloudILogger').

-compile([no_auto_import]).

-export(['MACRO-log'/4,
         'MACRO-log_apply'/4,
         'MACRO-log_apply'/5,
         'MACRO-log_debug'/3,
         'MACRO-log_debug_apply'/3,
         'MACRO-log_debug_apply'/4,
         'MACRO-log_debug_sync'/3,
         'MACRO-log_error'/3,
         'MACRO-log_error_apply'/3,
         'MACRO-log_error_apply'/4,
         'MACRO-log_error_sync'/3,
         'MACRO-log_fatal'/3,
         'MACRO-log_fatal_apply'/3,
         'MACRO-log_fatal_apply'/4,
         'MACRO-log_fatal_sync'/3,
         'MACRO-log_info'/3,
         'MACRO-log_info_apply'/3,
         'MACRO-log_info_apply'/4,
         'MACRO-log_info_sync'/3,
         'MACRO-log_metadata_get'/1,
         'MACRO-log_metadata_set'/2,
         'MACRO-log_sync'/4,
         'MACRO-log_trace'/3,
         'MACRO-log_trace_apply'/3,
         'MACRO-log_trace_apply'/4,
         'MACRO-log_trace_sync'/3,
         'MACRO-log_warn'/3,
         'MACRO-log_warn_apply'/3,
         'MACRO-log_warn_apply'/4,
         'MACRO-log_warn_sync'/3,
         '__info__'/1]).

-spec '__info__'(attributes |
                 compile |
                 functions |
                 macros |
                 md5 |
                 exports_md5 |
                 module |
                 deprecated) -> any().

'__info__'(module) -> 'Elixir.CloudILogger';
'__info__'(functions) -> [];
'__info__'(macros) ->
    [{log, 3},
     {log_apply, 3},
     {log_apply, 4},
     {log_debug, 2},
     {log_debug_apply, 2},
     {log_debug_apply, 3},
     {log_debug_sync, 2},
     {log_error, 2},
     {log_error_apply, 2},
     {log_error_apply, 3},
     {log_error_sync, 2},
     {log_fatal, 2},
     {log_fatal_apply, 2},
     {log_fatal_apply, 3},
     {log_fatal_sync, 2},
     {log_info, 2},
     {log_info_apply, 2},
     {log_info_apply, 3},
     {log_info_sync, 2},
     {log_metadata_get, 0},
     {log_metadata_set, 1},
     {log_sync, 3},
     {log_trace, 2},
     {log_trace_apply, 2},
     {log_trace_apply, 3},
     {log_trace_sync, 2},
     {log_warn, 2},
     {log_warn_apply, 2},
     {log_warn_apply, 3},
     {log_warn_sync, 2}];
'__info__'(exports_md5) ->
    <<"C\036\237\f\206°\024¬bªÁ£\n×'ð">>;
'__info__'(EKey = attributes) ->
    erlang:get_module_info('Elixir.CloudILogger', EKey);
'__info__'(EKey = compile) ->
    erlang:get_module_info('Elixir.CloudILogger', EKey);
'__info__'(EKey = md5) ->
    erlang:get_module_info('Elixir.CloudILogger', EKey);
'__info__'(deprecated) -> [].

'MACRO-log'(_E@CALLER, _Elevel@1, _Eformat@1,
            _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, log]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Elevel@1,
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_apply'(_E@CALLER, _Elevel@1, _Ef@1, _Ea@1) ->
    {{'.', [], [cloudi_core_i_logger_interface, log_apply]},
     [],
     [_Elevel@1, _Ef@1, _Ea@1]}.

'MACRO-log_apply'(_E@CALLER, _Elevel@1, _Em@1, _Ef@1,
                  _Ea@1) ->
    {{'.', [], [cloudi_core_i_logger_interface, log_apply]},
     [],
     [_Elevel@1, _Em@1, _Ef@1, _Ea@1]}.

'MACRO-log_debug'(_E@CALLER, _Eformat@1, _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, debug]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_debug_apply'(_E@CALLER, _Ef@1, _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, debug_apply]},
     [],
     [_Ef@1, _Ea@1]}.

'MACRO-log_debug_apply'(_E@CALLER, _Em@1, _Ef@1,
                        _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, debug_apply]},
     [],
     [_Em@1, _Ef@1, _Ea@1]}.

'MACRO-log_debug_sync'(_E@CALLER, _Eformat@1,
                       _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.',
        [],
        [cloudi_core_i_logger_interface, debug_sync]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_error'(_E@CALLER, _Eformat@1, _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, error]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_error_apply'(_E@CALLER, _Ef@1, _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, error_apply]},
     [],
     [_Ef@1, _Ea@1]}.

'MACRO-log_error_apply'(_E@CALLER, _Em@1, _Ef@1,
                        _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, error_apply]},
     [],
     [_Em@1, _Ef@1, _Ea@1]}.

'MACRO-log_error_sync'(_E@CALLER, _Eformat@1,
                       _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.',
        [],
        [cloudi_core_i_logger_interface, error_sync]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_fatal'(_E@CALLER, _Eformat@1, _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, fatal]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_fatal_apply'(_E@CALLER, _Ef@1, _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, fatal_apply]},
     [],
     [_Ef@1, _Ea@1]}.

'MACRO-log_fatal_apply'(_E@CALLER, _Em@1, _Ef@1,
                        _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, fatal_apply]},
     [],
     [_Em@1, _Ef@1, _Ea@1]}.

'MACRO-log_fatal_sync'(_E@CALLER, _Eformat@1,
                       _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.',
        [],
        [cloudi_core_i_logger_interface, fatal_sync]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_info'(_E@CALLER, _Eformat@1, _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, info]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_info_apply'(_E@CALLER, _Ef@1, _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, info_apply]},
     [],
     [_Ef@1, _Ea@1]}.

'MACRO-log_info_apply'(_E@CALLER, _Em@1, _Ef@1,
                       _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, info_apply]},
     [],
     [_Em@1, _Ef@1, _Ea@1]}.

'MACRO-log_info_sync'(_E@CALLER, _Eformat@1,
                      _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, info_sync]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_metadata_get'(_E@CALLER) ->
    {{'.', [], [cloudi_core_i_logger, metadata_get]},
     [],
     []}.

'MACRO-log_metadata_set'(_E@CALLER, _El@1) ->
    {{'.', [], [cloudi_core_i_logger, metadata_set]},
     [],
     [_El@1]}.

'MACRO-log_sync'(_E@CALLER, _Elevel@1, _Eformat@1,
                 _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, log_sync]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Elevel@1,
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_trace'(_E@CALLER, _Eformat@1, _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, trace]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_trace_apply'(_E@CALLER, _Ef@1, _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, trace_apply]},
     [],
     [_Ef@1, _Ea@1]}.

'MACRO-log_trace_apply'(_E@CALLER, _Em@1, _Ef@1,
                        _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, trace_apply]},
     [],
     [_Em@1, _Ef@1, _Ea@1]}.

'MACRO-log_trace_sync'(_E@CALLER, _Eformat@1,
                       _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.',
        [],
        [cloudi_core_i_logger_interface, trace_sync]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_warn'(_E@CALLER, _Eformat@1, _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, warn]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.

'MACRO-log_warn_apply'(_E@CALLER, _Ef@1, _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, warn_apply]},
     [],
     [_Ef@1, _Ea@1]}.

'MACRO-log_warn_apply'(_E@CALLER, _Em@1, _Ef@1,
                       _Ea@1) ->
    {{'.',
      [],
      [cloudi_core_i_logger_interface, warn_apply]},
     [],
     [_Em@1, _Ef@1, _Ea@1]}.

'MACRO-log_warn_sync'(_E@CALLER, _Eformat@1,
                      _Eargs@1) ->
    {'__block__',
     [],
     [{'=',
       [],
       [{{function, [], 'Elixir.CloudILogger'},
         {arity, [], 'Elixir.CloudILogger'}},
        {'case',
         [],
         [{{'.',
            [],
            [{'__ENV__', [], 'Elixir.CloudILogger'}, function]},
           [{no_parens, true}],
           []},
          [{do,
            [{'->', [], [[nil], {undefined, undefined}]},
             {'->',
              [],
              [[{'=',
                 [],
                 [{{'_', [], 'Elixir.CloudILogger'},
                   {'_', [], 'Elixir.CloudILogger'}},
                  {function_arity, [], 'Elixir.CloudILogger'}]}],
               {function_arity, [], 'Elixir.CloudILogger'}]}]}]]}]},
      {'=',
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__aliases__', [{alias, false}], ['String']},
           to_charlist]},
         [],
         [{{'.',
            [],
            [{'__aliases__', [{alias, false}], ['Path']},
             basename]},
           [],
           [{{'.',
              [],
              [{'__ENV__', [], 'Elixir.CloudILogger'}, file]},
             [{no_parens, true}],
             []}]}]}]},
      {{'.', [], [cloudi_core_i_logger_interface, warn_sync]},
       [],
       [{file_name, [], 'Elixir.CloudILogger'},
        {{'.',
          [],
          [{'__ENV__', [], 'Elixir.CloudILogger'}, line]},
         [{no_parens, true}],
         []},
        {function, [], 'Elixir.CloudILogger'},
        {arity, [], 'Elixir.CloudILogger'},
        _Eformat@1,
        _Eargs@1]}]}.