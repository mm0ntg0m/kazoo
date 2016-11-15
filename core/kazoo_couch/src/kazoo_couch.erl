-module(kazoo_couch).
-behaviour(kz_data).

-include("kz_couch.hrl").

%% Driver callbacks
-export([new_connection/1
        ,format_error/1
        ]).

%% Server callbacks
-export([server_info/1
        ,server_url/1
        ,get_db/2
        ,db_url/2
        ]).


%% DB operations
-export([db_create/3
        ,db_delete/2
        ,db_view_cleanup/2
        ,db_info/1, db_info/2
        ,db_exists/2
        ,db_archive/3
        ,db_list/2
        ]).

%% Document operations
-export([open_doc/4
        ,lookup_doc_rev/3
        ,save_doc/4
        ,save_docs/4
        ,del_doc/4
        ,del_docs/4
        ,ensure_saved/4
        ,copy_doc/3
        ,move_doc/3
        ]).

%% Attachment-related
-export([fetch_attachment/4
        ,stream_attachment/5
        ,put_attachment/6
        ,delete_attachment/5
        ,attachment_url/5
        ]).

%% View-related
-export([design_info/3
        ,all_design_docs/3
        ,get_results/4
        ,get_results_count/4
        ,all_docs/3
        ]).

%% Server operations
-spec new_connection(map()) -> kz_data:connection() |
                               {'error', 'timeout' | 'ehostunreach' | _}.
new_connection(Map) ->
    kz_couch_util:new_connection(Map).

-spec format_error(any()) -> any().
format_error(Error) ->
    kz_couch_util:format_error(Error).

%% Connection operations
-spec get_db(kz_data:connection(), ne_binary()) -> any().
get_db(Server, DbName) ->
    kz_couch_util:get_db(Server, DbName).

-spec server_url(kz_data:connection()) -> ne_binary().
server_url(Server) ->
    kz_couch_util:server_url(Server).

-spec db_url(kz_data:connection(), ne_binary()) -> ne_binary().
db_url(Server, DbName) ->
    kz_couch_util:db_url(Server, DbName).

-spec server_info(kz_data:connection()) -> any().
server_info(Server) ->
    kz_couch_util:server_info(Server).

%% DB operations
-spec db_create(kz_data:connection(), ne_binary(), kz_data:options()) -> any().
db_create(Server, DbName, Options) ->
    kz_couch_db:db_create(Server, DbName, Options).

-spec db_delete(kz_data:connection(), ne_binary()) -> any().
db_delete(Server, DbName) ->
    kz_couch_db:db_delete(Server, DbName).

-spec db_view_cleanup(kz_data:connection(), ne_binary()) -> any().
db_view_cleanup(Server, DbName) ->
    kz_couch_db:db_view_cleanup(Server, DbName).

-spec db_info(kz_data:connection()) -> any().
db_info(Server) ->
    kz_couch_db:db_info(Server).

-spec db_info(kz_data:connection(), ne_binary()) -> any().
db_info(Server, DbName) ->
    kz_couch_db:db_info(Server, DbName).

-spec db_exists(kz_data:connection(), ne_binary()) -> boolean().
db_exists(Server, DbName) ->
    kz_couch_db:db_exists(Server, DbName).

-spec db_archive(kz_data:connection(), ne_binary(), ne_binary()) -> any().
db_archive(Server, DbName, Filename) ->
    kz_couch_db:db_archive(Server, DbName, Filename).

-spec db_list(kz_data:connection(), kz_data:options()) -> any().
db_list(Server, Options) ->
    db_list(version(Server), Server, Options).

%%
%% db specific
%%
db_list('couchdb_2', Server, Options) ->
    kz_couch_db:db_list(Server, Options);
db_list('bigcouch', Server, Options) ->
    {'ok', Results} = kz_couch_view:all_docs(Server, <<"dbs">>, Options),
    {'ok', [ kz_doc:id(Db) || Db <- Results]};
db_list('couchdb_1_6', Server, Options) ->
    {'ok', List} = kz_couch_db:db_list(Server, Options),
    {'ok', db_local_filter(List, Options)}.

%% Document operations
-spec open_doc(kz_data:connection(), ne_binary(), ne_binary(), kz_data:options()) -> any().
open_doc(Server, DbName, DocId, Options) ->
    kz_couch_doc:open_doc(Server, DbName, DocId, Options).

-spec lookup_doc_rev(kz_data:connection(), ne_binary(), ne_binary()) -> any().
lookup_doc_rev(Server, DbName, DocId) ->
    kz_couch_doc:lookup_doc_rev(Server, DbName, DocId).

-spec save_doc(kz_data:connection(), ne_binary(), kz_data:document(), kz_data:options()) -> any().
save_doc(Server, DbName, Doc, Options) ->
    kz_couch_doc:save_doc(Server, DbName, Doc, Options).

-spec save_docs(kz_data:connection(), ne_binary(), kz_data:documents(), kz_data:options()) -> any().
save_docs(Server, DbName, Docs, Options) ->
    kz_couch_doc:save_docs(Server, DbName, Docs, Options).

-spec del_doc(kz_data:connection(), ne_binary(), kz_data:documents(), kz_data:options()) -> any().
del_doc(Server, DbName, Doc, Options) ->
    kz_couch_doc:del_doc(Server, DbName, Doc, Options).

-spec del_docs(kz_data:connection(), ne_binary(), kz_data:documents(), kz_data:options()) -> any().
del_docs(Server, DbName, Docs, Options) ->
    kz_couch_doc:del_docs(Server, DbName, Docs, Options).

-spec ensure_saved(kz_data:connection(), ne_binary(), kz_data:document(), kz_data:options()) -> any().
ensure_saved(Server, DbName, DocId, Options) ->
    kz_couch_doc:ensure_saved(Server, DbName, DocId, Options).

-spec copy_doc(kz_data:connection(), copy_doc(), kz_data:options()) -> any().
copy_doc(Server, CopySpec, Options) ->
    kz_couch_doc:copy_doc(Server, CopySpec, Options).

-spec move_doc(kz_data:connection(), copy_doc(), kz_data:options()) -> any().
move_doc(Server, CopySpec, Options) ->
    kz_couch_doc:move_doc(Server, CopySpec, Options).

%% Attachment-related
-spec fetch_attachment(kz_data:connection(), ne_binary(), ne_binary(), ne_binary()) -> any().
fetch_attachment(Server, DbName, DocId, AName) ->
    kz_couch_attachments:fetch_attachment(Server, DbName, DocId, AName).

-spec stream_attachment(kz_data:connection(), ne_binary(), ne_binary(), ne_binary(), pid()) -> any().
stream_attachment(Server, DbName, DocId, AName, Caller) ->
    kz_couch_attachments:stream_attachment(Server, DbName, DocId, AName, Caller).

-spec put_attachment(kz_data:connection(), ne_binary(), ne_binary(), ne_binary(), ne_binary(), kz_data:options()) -> any().
put_attachment(Server, DbName, DocId, AName, Contents, Options) ->
    kz_couch_attachments:put_attachment(Server, DbName, DocId, AName, Contents, Options).

-spec delete_attachment(kz_data:connection(), ne_binary(), ne_binary(), ne_binary(), kz_data:options()) -> any().
delete_attachment(Server, DbName, DocId, AName, Options) ->
    kz_couch_attachments:delete_attachment(Server, DbName, DocId, AName, Options).

-spec attachment_url(kz_data:connection(), ne_binary(), ne_binary(), ne_binary(), kz_data:options()) -> any().
attachment_url(Server, DbName, DocId, AName, Options) ->
    kz_couch_attachments:attachment_url(Server, DbName, DocId, AName, Options).

%% View-related
-spec design_info(kz_data:connection(), ne_binary(), ne_binary()) -> any().
design_info(Server, DBName, Design) ->
    kz_couch_view:design_info(Server, DBName, Design).

-spec all_design_docs(kz_data:connection(), ne_binary(), kz_data:connection()) -> any().
all_design_docs(Server, DBName, Options) ->
    kz_couch_view:all_design_docs(Server, DBName, Options).

-spec get_results(kz_data:connection(), ne_binary(), ne_binary(), kz_data:options()) -> any().
get_results(Server, DbName, DesignDoc, ViewOptions) ->
    kz_couch_view:get_results(Server, DbName, DesignDoc, ViewOptions).

-spec get_results_count(kz_data:connection(), ne_binary(), ne_binary(), kz_data:options()) -> any().
get_results_count(Server, DbName, DesignDoc, ViewOptions) ->
    kz_couch_view:get_results_count(Server, DbName, DesignDoc, ViewOptions).

-spec all_docs(kz_data:connection(), ne_binary(), kz_data:options()) -> any().
all_docs(Server, DbName, Options) ->
    kz_couch_view:all_docs(Server, DbName, Options).

-spec version(server()) -> couch_version().
version(#server{options=Options}) ->
    props:get_value('driver_version', Options).

db_local_filter(List, Options) ->
    [DB || DB <- List,
           lists:all(fun(Option) ->
                             db_local_filter_option(Option, DB)
                     end, Options)].

db_local_filter_option({'start_key', Value}, DB) ->
    DB >= Value;
db_local_filter_option({'startkey', Value}, DB) ->
    DB >= Value;
db_local_filter_option({'end_key', Value}, DB) ->
    DB =< Value;
db_local_filter_option({'endkey', Value}, DB) ->
    DB =< Value;
db_local_filter_option(_Option, _DB) -> 'true'.
