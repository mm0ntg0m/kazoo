%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz
%%% @doc
%%% User auth module
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cb_user_auth).

-export([init/0
         ,allowed_methods/0, allowed_methods/1 %% only accept 0 or 1 path token
         ,resource_exists/0, resource_exists/1
         ,authorize/1
         ,authenticate/1
         ,validate/1, validate/2
         ,put/1, put/2
         ,post/2
         ,cleanup_reset_ids/0
        ]).

-include("../crossbar.hrl").

-define(ACCT_MD5_LIST, <<"users/creds_by_md5">>).
-define(ACCT_SHA1_LIST, <<"users/creds_by_sha">>).
-define(LIST_BY_RESET_ID, <<"users/list_by_reset_id">>).
-define(LIST_BY_MTIME, <<"users/list_by_mtime">>).
-define(DEFAULT_LANGUAGE, <<"en-us">>).
-define(USER_AUTH_TOKENS, whapps_config:get_integer(?CONFIG_CAT, <<"user_auth_tokens">>, 35)).

-define(RECOVERY, <<"recovery">>).
-define(RESET_ID, <<"reset_id">>).
-define(RESET_ID_SIZE, 256).

%%%===================================================================
%%% API
%%%===================================================================
init() ->
    couch_mgr:db_create(?KZ_TOKEN_DB),
    _ = crossbar_bindings:bind(crossbar_cleanup:binding_day(), ?MODULE, 'cleanup_reset_ids'),

    _ = crossbar_bindings:bind(<<"*.authenticate">>, ?MODULE, 'authenticate'),
    _ = crossbar_bindings:bind(<<"*.authorize">>, ?MODULE, 'authorize'),
    _ = crossbar_bindings:bind(<<"*.allowed_methods.user_auth">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.user_auth">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.validate.user_auth">>, ?MODULE, 'validate'),
    _ = crossbar_bindings:bind(<<"*.execute.put.user_auth">>, ?MODULE, 'put'),
    _ = crossbar_bindings:bind(<<"*.execute.post.user_auth">>, ?MODULE, 'post').

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
-spec allowed_methods(path_token()) -> http_methods().
allowed_methods() -> [?HTTP_PUT].
allowed_methods(?RECOVERY) -> [?HTTP_PUT, ?HTTP_POST];
allowed_methods(_) -> [?HTTP_GET].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
-spec resource_exists(path_tokens()) -> boolean().
resource_exists() -> 'true'.
resource_exists(?RECOVERY) -> 'true';
resource_exists(_) -> 'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec authorize(cb_context:context()) -> boolean().
authorize(Context) ->
    authorize_nouns(cb_context:req_nouns(Context)).

authorize_nouns([{<<"user_auth">>, _}]) -> 'true';
authorize_nouns(_) -> 'false'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec authenticate(cb_context:context()) -> boolean().
authenticate(Context) ->
    authenticate_nouns(cb_context:req_nouns(Context)).

authenticate_nouns([{<<"user_auth">>, []}]) -> 'true';
authenticate_nouns([{<<"user_auth">>, [?RECOVERY]}]) -> 'true';
authenticate_nouns([{<<"user_auth">>, [?RECOVERY, _ResetId]}]) -> 'true';
authenticate_nouns(_Nouns) -> 'false'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
-spec validate(cb_context:context(), path_token()) -> cb_context:context().
validate(Context) ->
    Context1 = consume_tokens(Context),
    case cb_context:resp_status(Context1) of
        'success' ->
            cb_context:validate_request_data(<<"user_auth">>, Context, fun maybe_authenticate_user/1);
        _Status -> Context1
    end.

validate(Context, ?RECOVERY) ->
    case cb_context:req_verb(Context) of
        ?HTTP_PUT ->
            Schema = <<"user_auth_recovery">>,
            OnSuccess = fun maybe_load_user_doc_via_creds/1;
        ?HTTP_POST ->
            Schema = <<"user_auth_recovery_reset">>,
            OnSuccess = fun maybe_load_user_doc_via_reset_id/1
    end,
    cb_context:validate_request_data(Schema, Context, OnSuccess);

validate(Context, Token) ->
    Context1 = cb_context:set_account_db(Context, ?KZ_TOKEN_DB),
    maybe_get_auth_token(Context1, Token).

-spec put(cb_context:context()) -> cb_context:context().
-spec put(cb_context:context(), path_token()) -> cb_context:context().
put(Context) ->
    _ = cb_context:put_reqid(Context),
    crossbar_util:create_auth_token(Context, ?MODULE).

put(Context, ?RECOVERY) ->
    _ = cb_context:put_reqid(Context),
    save_reset_id_then_send_email(Context).

-spec post(cb_context:context(), path_token()) -> cb_context:context().
post(Context, ?RECOVERY) ->
    Context1 = crossbar_doc:save(Context),
    _ = cb_context:put_reqid(Context1),
    crossbar_util:create_auth_token(Context1, ?MODULE).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec maybe_get_auth_token(cb_context:context(), ne_binary()) -> cb_context:context().
maybe_get_auth_token(Context, Token) ->
    Context1 = crossbar_doc:load(Token, Context),
    case cb_context:resp_status(Context1) of
        'success' ->
            AuthAccountId = cb_context:auth_account_id(Context),
            AccountId = cb_context:account_id(Context),
            create_auth_resp(Context1, Token, AccountId, AuthAccountId);
        _ -> Context1
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create_auth_resp(cb_context:context(), ne_binary(), ne_binary(),  ne_binary()) ->
                              cb_context:context().
create_auth_resp(Context, Token, AccountId, AccountId) ->
    lager:debug("account ~s is same as auth account", [AccountId]),
    RespData = cb_context:resp_data(Context),
    crossbar_util:response(
      crossbar_util:response_auth(RespData)
      ,cb_context:set_auth_token(Context, Token)
     );
create_auth_resp(Context, _AccountId, _Token, _AuthAccountId) ->
    lager:debug("forbidding token for account ~s and auth account ~s"
                ,[_AccountId, _AuthAccountId]),
    cb_context:add_system_error('forbidden', Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalize the account name by converting the name to lower case
%% and then removing all non-alphanumeric characters.
%%
%% This can possibly return an empty binary.
%% @end
%%--------------------------------------------------------------------
-spec normalize_account_name(api_binary()) -> api_binary().
normalize_account_name(AccountName) ->
    wh_util:normalize_account_name(AccountName).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the credentials are valid based on the
%% provided hash method
%%
%% Attempt to lookup and compare the user creds in the provided accounts.
%%
%% Failure here returns 401
%% @end
%%--------------------------------------------------------------------
-spec maybe_authenticate_user(cb_context:context()) -> cb_context:context().
-spec maybe_authenticate_user(cb_context:context(), ne_binary(), ne_binary(), ne_binary() | ne_binaries()) ->
                                     cb_context:context().
maybe_authenticate_user(Context) ->
    JObj = cb_context:doc(Context),
    Credentials = wh_json:get_value(<<"credentials">>, JObj),
    Method = wh_json:get_value(<<"method">>, JObj, <<"md5">>),
    AccountName = normalize_account_name(wh_json:get_value(<<"account_name">>, JObj)),
    PhoneNumber = wh_json:get_ne_value(<<"phone_number">>, JObj),
    AccountRealm = wh_json:get_first_defined([<<"account_realm">>, <<"realm">>], JObj),
    case find_account(PhoneNumber, AccountRealm, AccountName, Context) of
        {'error', _} ->
            lager:debug("failed to find account DB from realm ~s", [AccountRealm]),
            cb_context:add_system_error('invalid_credentials', Context);
        {'ok', <<_/binary>> = Account} ->
            maybe_auth_account(Context, Credentials, Method, Account);
        {'ok', Accounts} ->
            maybe_auth_accounts(Context, Credentials, Method, Accounts)
    end.

maybe_authenticate_user(Context, Credentials, <<"md5">>, <<_/binary>> = Account) ->
    AccountDb = wh_util:format_account_id(Account, 'encoded'),

    Context1 = crossbar_doc:load_view(?ACCT_MD5_LIST
                                      ,[{'key', Credentials}]
                                      ,cb_context:set_account_db(Context, AccountDb)
                                     ),
    case cb_context:resp_status(Context1) of
        'success' -> load_md5_results(Context1, cb_context:doc(Context1));
        _Status ->
            lager:debug("credentials do not belong to any user: ~s: ~p"
                        ,[_Status, cb_context:doc(Context1)]),
            cb_context:add_system_error('invalid_credentials', Context1)
    end;
maybe_authenticate_user(Context, Credentials, <<"sha">>, <<_/binary>> = Account) ->
    AccountDb = wh_util:format_account_id(Account, 'encoded'),
    Context1 = crossbar_doc:load_view(?ACCT_SHA1_LIST
                                      ,[{'key', Credentials}]
                                      ,cb_context:set_account_db(Context, AccountDb)
                                     ),
    case cb_context:resp_status(Context1) of
        'success' -> load_sha1_results(Context1, cb_context:doc(Context1));
        _Status ->
            lager:debug("credentials do not belong to any user"),
            cb_context:add_system_error('invalid_credentials', Context)
    end;
maybe_authenticate_user(Context, _Creds, _Method, _Account) ->
    lager:debug("invalid creds by method ~s", [_Method]),
    cb_context:add_system_error('invalid_credentials', Context).

-spec maybe_auth_account(cb_context:context(), ne_binary(), ne_binary(), ne_binary()) ->
                                     cb_context:context().
maybe_auth_account(Context, Credentials, Method, Account) ->
    Context1 = maybe_authenticate_user(Context, Credentials, Method, Account),
    case cb_context:resp_status(Context1) of
        'success' ->
            maybe_account_is_expired(Context1, Account);
        _Status -> Context1
    end.

-spec maybe_auth_accounts(cb_context:context(), ne_binary(), ne_binary(), ne_binaries()) ->
                                     cb_context:context().
maybe_auth_accounts(Context, _, _, []) ->
    lager:debug("no account(s) specified"),
    cb_context:add_system_error('invalid_credentials', Context);
maybe_auth_accounts(Context, Credentials, Method, [Account|Accounts]) ->
    Context1 = maybe_authenticate_user(Context, Credentials, Method, Account),
    case cb_context:resp_status(Context1) of
        'success' ->
            maybe_account_is_expired(Context1, Account);
        _Status ->
            maybe_auth_accounts(Context, Credentials, Method, Accounts)
    end.

-spec maybe_account_is_expired(cb_context:context(), ne_binary()) -> cb_context:context().
maybe_account_is_expired(Context, Account) ->
    case wh_util:is_account_expired(Account) of
        'false' -> maybe_account_is_enabled(Context, Account);
        {'true', Expired} ->
            _ = wh_util:spawn(fun() -> wh_util:maybe_disable_account(Account) end),
            Cause =
                wh_json:from_list(
                  [{<<"message">>, <<"account expired">>}
                   ,{<<"cause">>, Expired}
                  ]
                 ),
            cb_context:add_validation_error(<<"account">>, <<"expired">>, Cause, Context)
    end.

-spec maybe_account_is_enabled(cb_context:context(), ne_binary()) -> cb_context:context().
maybe_account_is_enabled(Context, Account) ->
    case wh_util:is_account_enabled(Account) of
        'true' -> Context;
        'false' ->
            lager:debug("account ~p is disabled", [Account]),
            Cause =
                wh_json:from_list(
                  [{<<"message">>, <<"account disabled">>}]
                 ),
            cb_context:add_validation_error(<<"account">>, <<"disabled">>, Cause, Context)
    end.

-spec load_sha1_results(cb_context:context(), wh_json:objects() | wh_json:object()) ->
                               cb_context:context().
load_sha1_results(Context, [JObj|_]) ->
    lager:debug("found more that one user with SHA1 creds, using ~s", [wh_doc:id(JObj)]),
    cb_context:set_doc(Context, wh_json:get_value(<<"value">>, JObj));
load_sha1_results(Context, []) ->
    cb_context:add_system_error('invalid_credentials', Context);
load_sha1_results(Context, JObj) ->
    lager:debug("found SHA1 credentials belong to user ~s", [wh_doc:id(JObj)]),
    cb_context:set_doc(Context, wh_json:get_value(<<"value">>, JObj)).

-spec load_md5_results(cb_context:context(), wh_json:objects() | wh_json:object()) ->
                              cb_context:context().
load_md5_results(Context, [JObj|_]) ->
    lager:debug("found more that one user with MD5 creds, using ~s", [wh_doc:id(JObj)]),
    cb_context:set_doc(Context, wh_json:get_value(<<"value">>, JObj));
load_md5_results(Context, []) ->
    lager:debug("failed to find a user with MD5 creds"),
    cb_context:add_system_error('invalid_credentials', Context);
load_md5_results(Context, JObj) ->
    lager:debug("found MD5 credentials belong to user ~s", [wh_doc:id(JObj)]),
    cb_context:set_doc(Context, wh_json:get_value(<<"value">>, JObj)).


%% @public
-spec cleanup_reset_ids() -> 'ok'.
cleanup_reset_ids() ->
    CreatedBefore = wh_util:current_tstamp() - 2 * ?SECONDS_IN_DAY,
    ViewOptions = [{'startkey', 0}
                   ,{'endkey', CreatedBefore}
                   %% TODO: find a limit that matches the number of pwd resets per day
                   ,{'limit', couch_util:max_bulk_insert()}
                   ,'include_docs'
                  ],
    case couch_mgr:get_results(?WH_ACCOUNTS_DB, ?LIST_BY_MTIME, ViewOptions) of
        {'error', _E} ->
            lager:debug("failed to lookup expired reset_ids: ~p", [_E]);
        {'ok', []} ->
            lager:debug("no expired reset_ids found");
        {'ok', UserDocs} ->
            lager:debug("checking ~b user documents", [length(UserDocs)]),
            couch_mgr:suppress_change_notice(),
            ensure_reset_id_deleted(UserDocs),
            couch_mgr:enable_change_notice(),
            lager:debug("removed yesterday's expired reset_ids")
    end.

-spec ensure_reset_id_deleted(wh_json:objects()) -> 'ok'.
ensure_reset_id_deleted([Doc|Docs]) ->
    {'ok', _} =
        case wh_json:get_ne_binary_value(?RESET_ID, Doc) of
            'undefined' -> {'ok', 'undefined'};
            _Defined ->
                couch_mgr:save_doc(wh_doc:account_db(Doc)
                                   ,wh_json:delete_key(?RESET_ID, Doc))
        end,
    ensure_reset_id_deleted(Docs);
ensure_reset_id_deleted([]) -> 'ok'.


%% @private
-spec maybe_load_user_doc_via_creds(cb_context:context()) -> cb_context:context().
maybe_load_user_doc_via_creds(Context) ->
    JObj = cb_context:doc(Context),
    AccountName = normalize_account_name(wh_json:get_value(<<"account_name">>, JObj)),
    PhoneNumber = wh_json:get_ne_value(<<"phone_number">>, JObj),
    AccountRealm = wh_json:get_first_defined([<<"account_realm">>, <<"realm">>], JObj),
    case find_account(PhoneNumber, AccountRealm, AccountName, Context) of
        {'error', C} -> C;
        {'ok', [Account|_]} -> maybe_load_user_doc_by_username(Account, Context);
        {'ok', Account} ->     maybe_load_user_doc_by_username(Account, Context)
    end.

%% @private
-spec maybe_load_user_doc_by_username(ne_binary(), cb_context:context()) -> cb_context:context().
maybe_load_user_doc_by_username(Account, Context) ->
    JObj = cb_context:doc(Context),
    AccountDb = wh_util:format_account_id(Account, 'encoded'),
    lager:debug("attempting to lookup user name in db: ~s", [AccountDb]),
    Username = wh_json:get_value(<<"username">>, JObj),
    ViewOptions = [{'key', Username}
                   ,'include_docs'
                  ],
    case couch_mgr:get_results(AccountDb, ?LIST_BY_USERNAME, ViewOptions) of
        {'ok', [User]} ->
            case wh_json:is_false([<<"doc">>, <<"enabled">>], JObj) of
                'false' ->
                    lager:debug("user name '~s' was found and is not disabled, continue", [Username]),
                    Doc = wh_json:get_value(<<"doc">>, User),
                    cb_context:setters(Context, [{fun cb_context:set_account_db/2, Account}
                                                 ,{fun cb_context:set_doc/2, Doc}
                                                 ,{fun cb_context:set_resp_status/2, 'success'}
                                                ]);
                'true' ->
                    lager:debug("user name '~s' was found but is disabled", [Username]),
                    cb_context:add_validation_error(
                      <<"username">>
                      ,<<"forbidden">>
                      ,wh_json:from_list(
                         [{<<"message">>, <<"The provided user name is disabled">>}
                          ,{<<"cause">>, Username}
                         ])
                      ,Context
                     )
            end;
        _ ->
            cb_context:add_validation_error(
              <<"username">>
              ,<<"not_found">>
              ,wh_json:from_list(
                 [{<<"message">>, <<"The provided user name was not found">>}
                  ,{<<"cause">>, Username}
                 ])
              ,Context
             )
    end.

%% @private
-spec save_reset_id_then_send_email(cb_context:context()) -> cb_context:context().
save_reset_id_then_send_email(Context) ->
    ResetId = reset_id(cb_context:account_db(Context)),
    UserDoc = wh_json:set_value(?RESET_ID, ResetId, cb_context:doc(Context)),
    Context1 = crossbar_doc:save(cb_context:set_doc(Context, UserDoc)),
    case cb_context:resp_status(Context1) of
        'success' ->
            Email = wh_json:get_ne_binary_value(<<"email">>, UserDoc),
            lager:debug("created recovery id, sending email to '~s'", [Email]),
            ReqData = cb_context:req_data(Context),
            UIURL = wh_json:get_ne_binary_value(<<"ui_url">>, ReqData),
            Link = reset_link(UIURL, ResetId),
            lager:debug("created password reset link: ~s", [Link]),
            Notify = [{<<"Email">>, Email}
                      ,{<<"First-Name">>, wh_json:get_value(<<"first_name">>, UserDoc)}
                      ,{<<"Last-Name">>,  wh_json:get_value(<<"last_name">>, UserDoc)}
                      ,{<<"Password-Reset-Link">>, Link}
                      ,{<<"Account-ID">>, wh_doc:account_id(UserDoc)}
                      ,{<<"Account-DB">>, wh_doc:account_db(UserDoc)}
                      ,{<<"Request">>, wh_json:delete_key(<<"username">>, ReqData)}
                      | wh_api:default_headers(?APP_VERSION, ?APP_NAME)
                     ],
            'ok' = wapi_notifications:publish_pwd_recovery(Notify),
            Msg = <<"Request for password reset handled, email sent to: ", Email/binary>>,
            crossbar_util:response(Msg, Context1);
        _Status ->
            Context1
    end.


%% @private
-spec maybe_load_user_doc_via_reset_id(cb_context:context()) -> cb_context:context().
maybe_load_user_doc_via_reset_id(Context) ->
    ResetId = wh_json:get_ne_binary_value(?RESET_ID, cb_context:req_data(Context)),
    AccountDb = reset_id(ResetId),
    lager:debug("attempting to lookup user doc using reset_id: ~s", [ResetId]),
    ViewOptions = [{'key', ResetId}
                   ,'include_docs'
                  ],
    case couch_mgr:get_results(AccountDb, ?LIST_BY_RESET_ID, ViewOptions) of
        {'ok', [User]} ->
            lager:debug("user was found"),
            Doc = wh_json:delete_key(?RESET_ID, User),
            cb_context:setters(Context, [{fun cb_context:set_account_db/2, AccountDb}
                                         ,{fun cb_context:set_doc/2, Doc}
                                         ,{fun cb_context:set_resp_status/2, 'success'}
                                        ]);
        _ ->
            Msg = wh_json:from_list(
                    [{<<"message">>, <<"The provided reset_id did not resolve to any user">>}
                     ,{<<"cause">>, ResetId}
                    ]),
            cb_context:add_validation_error(<<"user">>, <<"not_found">>, Msg, Context)
    end.


%% @private
-spec reset_id(ne_binary()) -> ne_binary().
reset_id(?MATCH_ACCOUNT_ENCODED(A,B,Rest)) ->
    Noise = wh_util:rand_hex_binary((?RESET_ID_SIZE - 32) / 2),
    <<(?MATCH_ACCOUNT_RAW(A,B,Rest))/binary, Noise/binary>>;
reset_id(<<ResetId:?RESET_ID_SIZE/binary>>) ->
    <<Account:32/binary, _Noise/binary>> = ResetId,
    wh_util:format_account_db(wh_util:to_lower_binary(Account)).

%% @private
-spec reset_link(wh_json:object(), ne_binary()) -> ne_binary().
reset_link(UIURL, ResetId) ->
    Url = hd(binary:split(UIURL, <<"#">>)),
    <<Url/binary, "/#/", (?RECOVERY)/binary, ":", ResetId/binary>>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec find_account(api_binary(), api_binary(), api_binary(), cb_context:context()) ->
                          {'ok', ne_binary() | ne_binaries()} |
                          {'error', cb_context:context()}.
find_account('undefined', 'undefined', 'undefined', Context) ->
    {'error', Context};
find_account('undefined', 'undefined', AccountName, Context) ->
    case whapps_util:get_accounts_by_name(AccountName) of
        {'ok', AccountDb} ->
            lager:debug("found account by name '~s': ~s", [AccountName, AccountDb]),
            {'ok', AccountDb};
        {'multiples', AccountDbs} ->
            lager:debug("the account name returned multiple results"),
            {'ok', AccountDbs};
        {'error', _} ->
            C = cb_context:add_validation_error(
                  <<"account_name">>
                  ,<<"not_found">>
                  ,wh_json:from_list(
                     [{<<"message">>, <<"The provided account name could not be found">>}
                      ,{<<"cause">>, AccountName}
                     ])
                  ,Context
                 ),
            find_account('undefined', 'undefined', 'undefined', C)
    end;
find_account('undefined', AccountRealm, AccountName, Context) ->
    case whapps_util:get_account_by_realm(AccountRealm) of
        {'ok', 'undefined'} ->
            lager:debug("failed to find account ~s by name", [AccountName]),
            C = cb_context:add_validation_error(
                  <<"account_name">>
                  ,<<"not_found">>
                  ,wh_json:from_list(
                     [{<<"message">>, <<"The provided account name could not be found">>}
                      ,{<<"cause">>, AccountName}
                     ])
                  ,Context
                 ),
            find_account('undefined', 'undefined', 'undefined', C);
        {'ok', AccountDb} ->
            lager:debug("found account by realm '~s': ~s", [AccountRealm, AccountDb]),
            {'ok', AccountDb};
        {'multiples', AccountDbs} ->
            lager:debug("the account realm returned multiple results"),
            {'ok', AccountDbs};
        {'error', _} ->
            C = cb_context:add_validation_error(
                  <<"account_realm">>
                  ,<<"not_found">>
                  ,wh_json:from_list(
                     [{<<"message">>, <<"The provided account realm could not be found">>}
                      ,{<<"cause">>, AccountRealm}
                     ])
                  ,Context
                 ),
            find_account('undefined', 'undefined', AccountName, C)
    end;
find_account(PhoneNumber, AccountRealm, AccountName, Context) ->
    case wh_number_manager:lookup_account_by_number(PhoneNumber) of
        {'ok', AccountId, _} ->
            AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
            lager:debug("found account by phone number '~s': ~s", [PhoneNumber, AccountDb]),
            {'ok', AccountDb};
        {'error', _} ->
            C = cb_context:add_validation_error(
                  <<"phone_number">>
                  ,<<"not_found">>
                  ,wh_json:from_list(
                     [{<<"message">>, <<"The provided phone number could not be found">>}
                      ,{<<"cause">>, PhoneNumber}
                     ])
                  ,Context
                 ),
            find_account('undefined', AccountRealm, AccountName, C)
    end.

-spec consume_tokens(cb_context:context()) -> cb_context:context().
consume_tokens(Context) ->
    case kz_buckets:consume_tokens_until(?APP_NAME
                                         ,cb_modules_util:bucket_name(Context)
                                         ,cb_modules_util:token_cost(Context, ?USER_AUTH_TOKENS)
                                        )
    of
        'true' -> cb_context:set_resp_status(Context, 'success');
        'false' ->
            cb_context:add_system_error('too_many_requests', Context)
    end.
