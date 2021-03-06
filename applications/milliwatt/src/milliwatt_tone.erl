%%%-------------------------------------------------------------------
%%% @copyright (C) 2013, VoIP, INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%% Peter Defebvre
%%%-------------------------------------------------------------------
-module(milliwatt_tone).

-export([exec/1]).

-include("milliwatt.hrl").

-define(FREQUENCIES, [<<"2600">>]).
-define(DURATION, 30000).

exec(Call) ->
    Tone = get_tone(),
    Duration = wh_json:get_integer_value(<<"Duration-ON">>, Tone, ?DURATION),
    lager:info("milliwatt execute action tone"),
    whapps_call_command:answer(Call),
    timer:sleep(500),
    whapps_call_command:tones([Tone], Call),
    timer:sleep(Duration),
    whapps_call_command:hangup(Call).

-spec get_tone() -> wh_json:object().
get_tone() ->
    JObj = whapps_config:get_non_empty(?CONFIG_CAT, <<"tone">>),
    Hz = wh_json:get_list_value(<<"frequencies">>, JObj, ?FREQUENCIES),
    Duration = wh_json:get_value(<<"duration">>, JObj, ?DURATION),

    wh_json:from_list(
      [{<<"Frequencies">>, Hz}
       ,{<<"Duration-ON">>, wh_util:to_binary(Duration)}
       ,{<<"Duration-OFF">>, <<"1000">>}
      ]
     ).
