%%%-------------------------------------------------------------------
%%% @author Karl Anderson <karl@2600hz.org>
%%% @copyright (C) 2011, Karl Anderson
%%% @doc
%%%
%%% @end
%%% Created : 22 Feb 2011 by Karl Anderson <karl@2600hz.org>
%%%-------------------------------------------------------------------
-module(cf_voicemail).

-include("../callflow.hrl").

-export([handle/2]).

-define(FOLDER_NEW, <<"new">>).
-define(FOLDER_SAVED, <<"saved">>).
-define(FOLDER_DELETED, <<"deleted">>).

-define(UNAVAILABLE_GREETING, <<"unavailable_greeting.wav">>).
-define(NAME_RECORDING, <<"name_recording.wav">>).

-import(cf_call_command, [
                           answer/1, play/2, b_play/2, say/3, tones/2, b_record/2
                          ,store/3, b_play_and_collect_digits/6, noop/1, flush/1
                          ,wait_for_dtmf/1, wait_for_application_or_dtmf/2, audio_macro/2
                         ]).

-record(keys, {
          %% Compose Voicemail
           operator = <<"0">>
          ,login = <<"*">>

           %% Record Review
          ,listen = <<"1">>
          ,save = <<"2">>
          ,record = <<"3">>


          %% Main Menu
          ,hear_new = <<"1">>
          ,hear_saved = <<"2">>
          ,configure = <<"5">>
          ,exit = <<"#">>

          %% Config Menu
          ,rec_unavailable  = <<"1">>
          ,rec_name = <<"2">>
          ,set_pin = <<"3">>
          ,return_main = <<"0">>

          %% Post playbak
          ,replay = <<"1">>
          ,keep = <<"2">>
          ,delete = <<"3">>
         }).

-record(prompts, {
           person_at_exten = <<"/system_media/vm-person">>
          ,not_available = <<"/system_media/vm-not_available">>
          ,no_mailbox = <<"/system_media/vm-not_available_no_voicemail">>
          ,mailbox_full = <<"/system_media/vm-mailbox_full">>

          ,record_instructions = <<"/system_media/vm-record_message">>

          ,goodbye = <<"/system_media/vm-goodbye">>
          ,received = <<"/system_media/vm-received">>
          ,press = <<"/system_media/vm-press">>

          ,to_listen = <<"/system_media/vm-listen_to_recording">>
          ,to_save = <<"/system_media/vm-save_recording">>
          ,to_rerecord = <<"/system_media/vm-rerecord">>

          ,enter_mailbox = <<"/system_media/vm-enter_id">>
          ,enter_password = <<"/system_media/vm-enter_pass">>
          ,invalid_login = <<"/system_media/vm-fail_auth">>
          ,abort_login = <<"/system_media/vm-abort">>

          ,you_have = <<"/system_media/vm-you_have">>
          ,new = <<"/system_media/vm-new">>
          ,messages = <<"/system_media/vm-messages">>
          ,saved = <<"/system_media/vm-saved">>
          ,to_hear_new = <<"/system_media/vm-listen_new">>
          ,to_hear_saved = <<"/system_media/vm-listen_saved">>
          ,to_configure = <<"/system_media/vm-advanced">>
          ,to_exit = <<"/system_media/vm-to_exit">>

          ,to_change_pin = <<"/system_media/vm-change_password">>
          ,to_rec_name = <<"/system_media/vm-record_name2">>
          ,to_rec_unavailable = <<"/system_media/vm-to_record_greeting">>
          ,to_return_main = <<"/system_media/vm-main_menu">>

          ,to_replay = <<"/system_media/vm-listen_to_recording">>
          ,to_keep = <<"/system_media/vm-save_recording">>
          ,to_delete = <<"/system_media/vm-delete_recording">>

          ,message_saved = <<"/system_media/vm-saved">>
          ,message_deleted = <<"/system_media/vm-deleted">>

          ,record_name = <<"/system_media/vm-record_name1">>
          ,record_unavail_greeting = <<"/system_media/vm-record_greeting">>

          ,enter_new_pin = <<"shout://translate.google.com/translate_tts?tl=en&q=Enter+your+new+password+followed+by+the+pound+key.">>
          ,reenter_new_pin = <<"shout://translate.google.com/translate_tts?tl=en&q=Re-enter+your+new+password+followed+by+the+pound+key+to+confirm.">>

          ,tone_spec = [{struct, [{<<"Frequencies">>, [440]},{<<"Duration-ON">>, 500},{<<"Duration-OFF">>, 100}]}]
         }).

-record(mailbox, {
           has_unavailable_greeting = false
          ,mailbox_id = undefined
          ,exists = false
          ,skip_instructions = <<"false">>
          ,skip_greeting = <<"false">>
          ,pin = <<>>
          ,timezone = <<"America/Los_Angeles">>
          ,max_login_attempts = 3
          ,keys = #keys{}
          ,prompts = #prompts{}
         }).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Entry point for this module, based on the payload will either
%% connect a caller to check_voicemail or compose_voicemail.
%% @end
%%--------------------------------------------------------------------
-spec(handle/2 :: (Data :: json_object(), Call :: #cf_call{}) -> no_return()).
handle(Data, #cf_call{cf_pid=CFPid}=Call) ->
    case whapps_json:get_value(<<"action">>, Data) of
        <<"compose">> ->
            answer(Call),
            _ = compose_voicemail(get_mailbox_profile(Data, Call), Call),
            CFPid ! {stop};
        <<"check">> ->
            answer(Call),
            _ = case whapps_json:get_value(<<"id">>, Data) of
		    undefined ->
			find_mailbox(Call);
		    _ ->
			check_mailbox(get_mailbox_profile(Data, Call), Call)
		end,
            CFPid ! {stop};
        _ ->
            CFPid ! {continue}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(check_mailbox/2 :: (Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
-spec(check_mailbox/3 :: (Box :: #mailbox{}, Call :: #cf_call{}, Loop :: non_neg_integer()) -> no_return()).

check_mailbox(#mailbox{prompts=Prompts, pin = <<>>}, Call) ->
    b_play(Prompts#prompts.goodbye, Call);
check_mailbox(Box, Call) ->
    check_mailbox(Box, Call, 1).

check_mailbox(#mailbox{max_login_attempts=MaxLoginAttempts
		       ,prompts=#prompts{abort_login=AbortLogin, enter_password=EnterPass, invalid_login=InvalidLogin}
		       ,pin=Pin}=Box, Call, Loop) ->
    try
        {ok, Pin} = b_play_and_collect_digits(<<"1">>, <<"6">>, EnterPass, <<"1">>, <<"8000">>, Call),
        main_menu(Box, Call)
    catch
        _:_ ->
            _ = b_play(InvalidLogin, Call),
            case Loop < MaxLoginAttempts of
		true -> check_mailbox(Box, Call, Loop+1);
                false -> b_play(AbortLogin, Call)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(find_mailbox/1 :: (Call :: #cf_call{}) -> no_return()).
-spec(find_mailbox/2 :: (Call :: #cf_call{}, Loop :: non_neg_integer()) -> no_return()).

find_mailbox(Call) ->
    find_mailbox(Call, 1).

find_mailbox(#cf_call{account_db=Db}=Call, Loop) ->
    Prompts = #prompts{},
    try
        {ok, Mailbox} = b_play_and_collect_digits(<<"1">>, <<"6">>, Prompts#prompts.enter_mailbox, <<"1">>, <<"8000">>, Call),
        {ok, Pin} = b_play_and_collect_digits(<<"1">>, <<"6">>, Prompts#prompts.enter_password, <<"1">>, <<"8000">>, Call),
        {ok, [JObj]} = couch_mgr:get_results(Db, {<<"vmboxes">>, <<"listing_by_mailbox">>}, [{<<"key">>, Mailbox}]),
        Box = get_mailbox_profile({struct, [{<<"id">>, whapps_json:get_value(<<"id">>, JObj)}]}, Call ),
        Pin = Box#mailbox.pin,
        main_menu(Box, Call)
    catch
        _:_=E ->
            logger:format_log(info, "ERROR: ~p", [E]),
            B = #mailbox{},
            _ = b_play(Prompts#prompts.invalid_login, Call),
            if
                Loop < B#mailbox.max_login_attempts ->
                    find_mailbox(Call, Loop+1);
                true ->
                    b_play(Prompts#prompts.abort_login, Call)
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(compose_voicemail/2 :: (Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
compose_voicemail(#mailbox{exists=false, prompts=#prompts{no_mailbox=NoMailbox}}, Call) ->
    b_play(NoMailbox, Call);
compose_voicemail(#mailbox{skip_greeting=SkipGreeting, skip_instructions=SkipInstructions
			   ,prompts=#prompts{record_instructions=RecordInstructions}
			   ,keys=#keys{login=Login}}=Box, Call) ->

    not whistle_util:is_true(SkipGreeting) andalso play_greeting(Box, Call),
    not whistle_util:is_true(SkipInstructions) andalso play(RecordInstructions, Call),

    noop(Call),

    case wait_for_application_or_dtmf(<<"noop">>, 25000) of
        {ok, _} ->
            record_voicemail(tmp_file(), Box, Call);
        {dtmf, Digit} ->
            _ = flush(Call),
            case Digit of
                Login ->
                    find_mailbox(Call);
                _ ->
                    record_voicemail(tmp_file(), Box, Call)
            end;
        {error, _} ->
            ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(play_greeting/2 :: (Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
play_greeting(#mailbox{prompts=#prompts{person_at_exten=PersonAtExten, not_available=NotAvailable}
		       ,has_unavailable_greeting=false}, #cf_call{to_number=Exten} = Call) ->
    audio_macro([
                  {play, PersonAtExten}
                 ,{say,  Exten}
                 ,{play, NotAvailable}
                ], Call);
play_greeting(#mailbox{mailbox_id=Id, has_unavailable_greeting=true}, #cf_call{account_db=Db}=Call) ->
    play(<<$/, Db/binary, $/, Id/binary, $/, "unavailable_greeting.wav">>, Call).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(record_voicemail/3 :: (MediaName :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
record_voicemail(MediaName, #mailbox{prompts=#prompts{tone_spec=ToneSpec}}=Box, Call) ->
    tones(ToneSpec, Call),
    case b_record(MediaName, Call) of
        {ok, _Msg} ->
            case review_recording(MediaName, Box, Call) of
                {ok, record} ->
                    record_voicemail(MediaName, Box, Call);
                _Else ->
                    new_message(MediaName, Box, Call)
            end;
        _Else ->
            new_message(MediaName, Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(main_menu/2 :: (Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
main_menu(#mailbox{prompts=#prompts{you_have=YouHave, new=New, messages=PromptMessages, saved=Saved, to_hear_new=ToHearNew
				    ,press=Press, to_hear_saved=ToHearSaved, to_configure=ToConfigure, to_exit=ToExit}
		   ,keys=#keys{hear_new=HearNew, hear_saved=HearSaved, configure=Configure, exit=Exit}}=Box, Call) ->
    Messages = get_messages(Box, Call),
    audio_macro([
                  {play, YouHave}
                 ,{say,  whistle_util:to_binary(count_messages(Messages, ?FOLDER_NEW))}
                 ,{play, New}
                 ,{play, PromptMessages}

                 ,{play, YouHave}
                 ,{say,  whistle_util:to_binary(count_messages(Messages, ?FOLDER_SAVED))}
                 ,{play, Saved}
                 ,{play, PromptMessages}

                 ,{play, ToHearNew}
                 ,{play, Press}
                 ,{say,  HearNew}

                 ,{play, ToHearSaved}
                 ,{play, Press}
                 ,{say,  HearSaved}

                 ,{play, ToConfigure}
                 ,{play, Press}
                 ,{say,  Configure}

                 ,{play, ToExit}
                 ,{play, Press}
                 ,{say,  Exit}
                ], Call),
    {ok, Digit} = wait_for_dtmf(30000),
    _ = flush(Call),
    case Digit of
	HearNew ->
	    play_messages(get_folder(Messages, ?FOLDER_NEW), Box, Call),
	    main_menu(Box, Call);
	HearSaved ->
	    play_messages(get_folder(Messages, ?FOLDER_SAVED), Box, Call),
	    main_menu(Box, Call);
	Configure ->
	    config_menu(Box, Call);
	Exit ->
	    ok;
	_ ->
	    main_menu(Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(play_messages/3 :: (Messages :: json_objects(), Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
play_messages([], _, _) -> ok;
play_messages([{struct, _}=H|T]=Messages, #mailbox{timezone=Timezone
			      ,prompts=#prompts{received=Received, to_replay=ToReplay, press=Press, to_keep=ToKeep
						,to_delete=ToDelete, to_return_main=ToReturnMain
						,message_saved=MessageSaved, message_deleted=MessageDeleted}
			      ,keys=#keys{replay=Replay, keep=Keep, delete=Delete, return_main=ReturnMain}}=Box, Call) ->
    Message = get_message(H, Box, Call),
    audio_macro([
                  {play, Received}
                 ,{say,  get_unix_epoch(whapps_json:get_value(<<"timestamp">>, H), Timezone), <<"current_date_time">>}
                 ,{play, Message}

                 ,{play, ToReplay}
                 ,{play, Press}
                 ,{say,  Replay}

                 ,{play, ToKeep}
                 ,{play, Press}
                 ,{say,  Keep}

                 ,{play, ToDelete}
                 ,{play, Press}
                 ,{say,  Delete}

                 ,{play, ToReturnMain}
                 ,{play, Press}
                 ,{say,  ReturnMain}
                ], Call),
    {ok, Digit} = wait_for_dtmf(30000),
    _ = flush(Call),
    case Digit of
	Keep ->
	    play(MessageSaved, Call),
	    set_folder(?FOLDER_SAVED, H, Box, Call),
	    play_messages(T, Box, Call);
	Delete ->
	    play(MessageDeleted, Call),
	    set_folder(?FOLDER_DELETED, H, Box, Call),
	    play_messages(T, Box, Call);
	ReturnMain ->
	    play(MessageSaved, Call),
	    set_folder(?FOLDER_SAVED, H, Box, Call);
	Replay ->
	    play_messages(Messages, Box, Call);
	_ ->
	    play(MessageSaved, Call),
	    set_folder(?FOLDER_SAVED, H, Box, Call),
	    play_messages(T, Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(config_menu/2 :: (Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
config_menu(#mailbox{prompts=#prompts{to_rec_unavailable=ToRecUnavailable, press=Press, to_rec_name=ToRecName
				     ,to_change_pin=ToChangePin, to_return_main=ToReturnMain}
		     ,keys=#keys{rec_unavailable=RecUnavailable, rec_name=RecName, set_pin=SetPin, return_main=ReturnMain}}=Box, Call) ->
    audio_macro([
                  {play, ToRecUnavailable}
                 ,{play, Press}
                 ,{say,  RecUnavailable}

                 ,{play, ToRecName}
                 ,{play, Press}
                 ,{say,  RecName}

                 ,{play, ToChangePin}
                 ,{play, Press}
                 ,{say,  SetPin}

                 ,{play, ToReturnMain}
                 ,{play, Press}
                 ,{say,  ReturnMain}
                ], Call),
    {ok, Digit} =  wait_for_dtmf(30000),
    _ = flush(Call),
    case Digit of
	RecUnavailable ->
	    record_unavailable_greeting(tmp_file(), Box, Call),
	    config_menu(Box, Call);
	RecName ->
	    record_name(tmp_file(), Box, Call),
	    config_menu(Box, Call);
	SetPin ->
	    change_pin(Box, Call),
	    config_menu(Box, Call);
	ReturnMain ->
	    main_menu(Box, Call);
	%% Bulk delete -> delete all voicemails
	%% Reset -> delete all voicemails, greetings, name, and reset pin
	_ ->
	    config_menu(Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(record_unavailable_greeting/3 :: (MediaName :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
record_unavailable_greeting(MediaName, #mailbox{prompts=#prompts{record_unavail_greeting=RecordUnavailGreeting, tone_spec=ToneSpec}}=Box, Call) ->
    audio_macro([
                  {play,  RecordUnavailGreeting}
                 ,{tones, ToneSpec}
                ], Call),
    {ok, _} = b_record(MediaName, Call),
    case review_recording(MediaName, Box, Call) of
	{ok, record} ->
	    record_unavailable_greeting(MediaName, Box, Call);
	{ok, save} ->
	    store_recording(MediaName, ?UNAVAILABLE_GREETING, Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(new_message/3 :: (MediaName :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
new_message(MediaName, #mailbox{mailbox_id=Id}=Box, #cf_call{route_request=RR, account_db=Db}=Call) ->
    store_recording(MediaName, Box, Call),
    receive after 5000 -> ok end,
    {ok, JObj} = couch_mgr:open_doc(Db, Id),
    NewMessages=[{struct, [
			   {<<"timestamp">>, new_timestamp()}
			   ,{<<"from">>, whapps_json:get_value(<<"From">>, RR)}
			   ,{<<"to">>, whapps_json:get_value(<<"To">>, RR)}
			   ,{<<"caller-id-number">>, whapps_json:get_value(<<"Caller-ID-Number">>, RR)}
			   ,{<<"caller-id-name">>, whapps_json:get_value(<<"Caller-ID-Name">>, RR)}
			   ,{<<"call-id">>, whapps_json:get_value(<<"Call-ID">>, RR)}
			   ,{<<"folder">>, ?FOLDER_NEW}
			   ,{<<"attachment">>, MediaName}
			  ]
		 }] ++ whapps_json:get_value([<<"messages">>], JObj, []),
    couch_mgr:save_doc(Db, whapps_json:set_value([<<"messages">>], NewMessages, JObj)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(record_name/3 :: (MediaName :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> ok).
record_name(MediaName, #mailbox{prompts=#prompts{record_name=RecordName, tone_spec=ToneSpec}}=Box, Call) ->
    audio_macro([
                  {play,  RecordName}
                 ,{tones, ToneSpec}
                ], Call),
    {ok, _} = b_record(MediaName, Call),
    case review_recording(MediaName, Box, Call) of
	{ok, record} ->
	    record_name(MediaName, Box, Call);
	{ok, save} ->
	    store_recording(MediaName, ?NAME_RECORDING, Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(change_pin/2 :: (Box :: #mailbox{}, Call :: #cf_call{}) -> stop | continue).
change_pin(#mailbox{prompts=#prompts{enter_new_pin=EnterNewPin, reenter_new_pin=ReenterNewPin}
		    ,mailbox_id=Id}=Box, #cf_call{account_db=Db}=Call) ->
    try
        {ok, Pin} = b_play_and_collect_digits(<<"1">>, <<"6">>, EnterNewPin, <<"1">>, <<"8000">>, Call),
        {ok, Pin} = b_play_and_collect_digits(<<"1">>, <<"6">>, ReenterNewPin, <<"1">>, <<"8000">>, Call),
        if byte_size(Pin) == 0 -> throw(pin_empty); true -> ok end,
        {ok, JObj} = couch_mgr:open_doc(Db, Id),
        couch_mgr:save_doc(Db, whapps_json:set_value(<<"pin">>, Pin, JObj))
    catch
        _:_ ->
            change_pin(Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Fetches the mailbox parameters from the datastore and loads the
%% mailbox record
%% @end
%%--------------------------------------------------------------------
-spec(get_mailbox_profile/2 :: (Data :: json_object(), Call :: #cf_call{}) -> #mailbox{}).
get_mailbox_profile(Data, #cf_call{account_db=Db}) ->
    Id = whapps_json:get_value(<<"id">>, Data),
    case couch_mgr:open_doc(Db, Id) of
        {ok, JObj} ->
            Default=#mailbox{},
            #mailbox{
                       mailbox_id = Id
                      ,skip_instructions = whapps_json:get_value(<<"skip-instructions">>, JObj, Default#mailbox.skip_instructions)
                      ,skip_greeting = whapps_json:get_value(<<"skip-greeting">>, JObj, Default#mailbox.skip_greeting)
                      ,has_unavailable_greeting = whapps_json:get_value([<<"_attachments">>, ?UNAVAILABLE_GREETING], JObj) =/= undefined
                      ,pin = whapps_json:get_value(<<"pin">>, JObj, <<>>)
                      ,timezone = whapps_json:get_value(<<"timezone">>, JObj, Default#mailbox.timezone)
                      ,exists=true
                    };
        _ ->
            #mailbox{}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(review_recording/3 :: (MediaName :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> tuple(ok, record | save)).
review_recording(MediaName, #mailbox{prompts=#prompts{press=Press, to_listen=ToListen, to_save=ToSave, to_rerecord=ToRerecord}
				     ,keys=#keys{listen=Listen, save=Save, record=Record}}=Box, Call) ->
    audio_macro([
                  {play, Press}
                 ,{say,  Listen}
                 ,{play, ToListen}

                 ,{play, Press}
                 ,{say,  Save}
                 ,{play, ToSave}

                 ,{play, Press}
                 ,{say,  Record}
                 ,{play, ToRerecord}
                ], Call),
    {ok, Digit} = wait_for_dtmf(5000),

    _ = flush(Call),
    case Digit of
	Listen ->
	    _ = b_play(MediaName, Call),
	    review_recording(MediaName, Box, Call);
	Record ->
	    {ok, record};
	Save ->
	    {ok, save};
	_ ->
	    review_recording(MediaName, Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(store_recording/3 :: (MediaName :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
-spec(store_recording/4 :: (MediaName :: binary(), DestName :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
store_recording(MediaName, Box, Call) ->
    store_recording(MediaName, MediaName, Box, Call).
store_recording(MediaName, DestName, Box, Call) ->
    store(MediaName, get_attachment_path(DestName, Box, Call), Call).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(get_attachment_path/3 :: (MediaName :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> binary()).
get_attachment_path(MediaName, #mailbox{mailbox_id=Id}, #cf_call{account_db=Db}) ->
    <<(couch_mgr:get_url())/binary
      ,Db/binary
      ,$/, Id/binary
      ,$/, MediaName/binary
      ,"?rev=", (lookup_doc_rev(Db, Id))/binary>>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(lookup_doc_rev/2 :: (Db :: binary(), Id :: binary()) -> binary()).
lookup_doc_rev(Db, Id) ->
    {ok, Rev} = couch_mgr:lookup_doc_rev(Db, Id),
    Rev.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(get_messages/2 :: (Mailbox :: #mailbox{}, Call :: #cf_call{}) -> json_objects()).
get_messages(#mailbox{mailbox_id=Id}, #cf_call{account_db=Db}) ->
    case couch_mgr:open_doc(Db, Id) of
        {ok, JObj} ->
            whapps_json:get_value(<<"messages">>, JObj, []);
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(get_message/3 :: (Message :: json_object(), Mailbox :: #mailbox{}, Call :: #cf_call{}) -> binary()).
get_message(Message, #mailbox{mailbox_id=Id}, #cf_call{account_db=Db}) ->
    <<$/, Db/binary, $/, Id/binary, $/, (whapps_json:get_value(<<"attachment">>, Message))/binary>>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(count_messages/2 :: (Message :: json_objects(), Folder :: binary()) -> integer()).
count_messages(Messages, Folder) ->
    lists:foldr(fun(Message, Count) ->
                       case whapps_json:get_value(<<"folder">>, Message) of
                           Folder ->
                               Count + 1;
                           _ ->
                               Count
                       end
               end, 0, Messages).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(get_folder/2 :: (Messages :: json_objects(), Folder :: binary()) -> json_objects()).
get_folder(Messages, Folder) ->
    lists:foldr(fun(Message, Acc) ->
                       case whapps_json:get_value(<<"folder">>, Message) of
                           Folder ->
                               [Message|Acc];
                           _ ->
                               Acc
                       end
               end, [], Messages).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(set_folder/4 :: (Folder :: binary(), Message :: json_object(), Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
set_folder(Folder, Message, Box, Call) ->
    not (whapps_json:get_value(<<"folder">>, Message) =:= Folder) andalso
	update_folder(Folder, whapps_json:get_value(<<"attachment">>, Message), Box, Call).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec(update_folder/4 :: (Folder :: binary(), Attachment :: binary(), Box :: #mailbox{}, Call :: #cf_call{}) -> no_return()).
update_folder(_, undefined, _, _) ->
    {error, attachment_undefined};
update_folder(Folder, Attachment, #mailbox{mailbox_id=Id}, #cf_call{account_db=Db}) ->
    case couch_mgr:open_doc(Db, Id) of
        {ok, JObj} ->
            Messages = [ update_folder1(Message, Folder, Attachment, whapps_json:get_value(<<"attachment">>, Message))
			 || Message <- whapps_json:get_value(<<"messages">>, JObj, []) ],
            couch_mgr:save_doc(Db, whapps_json:set_value(<<"messages">>, Messages, JObj));
        {error, _}=E ->
            E
    end.

update_folder1(Message, Folder, Attachment, Attachment) ->
    whapps_json:set_value(<<"folder">>, Folder, Message);
update_folder1(Message, _, _, _) ->
    Message.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec(tmp_file/0 :: () -> binary()).
tmp_file() ->
     <<(list_to_binary(whistle_util:to_hex(crypto:rand_bytes(16))))/binary, ".wav">>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns the Universal Coordinated Time (UTC) reported by the
%% underlying operating system (local time is used if universal
%% time is not available) as number of gregorian seconds starting
%% with year 0.
%% @end
%%--------------------------------------------------------------------
-spec(new_timestamp/0 :: () -> binary()).
new_timestamp() ->
    whistle_util:to_binary(whistle_util:current_tstamp()).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Accepts Universal Coordinated Time (UTC) and convert it to binary
%% encoded Unix epoch in the provided timezone
%% @end
%%--------------------------------------------------------------------
-spec(get_unix_epoch/2 :: (Epoch :: binary(), Timezone :: binary()) -> binary()).
get_unix_epoch(Epoch, Timezone) ->
    UtcDateTime = calendar:gregorian_seconds_to_datetime(whistle_util:to_integer(Epoch)),
    LocalDateTime = localtime:utc_to_local(UtcDateTime, whistle_util:to_list(Timezone)),
    whistle_util:to_binary(calendar:datetime_to_gregorian_seconds(LocalDateTime) - 62167219200).
