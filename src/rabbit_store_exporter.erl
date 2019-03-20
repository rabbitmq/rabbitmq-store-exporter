%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Store Exporter.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2012-2012 VMware, Inc.  All rights reserved.
%%

-module(rabbit_store_exporter).

-export([export/0]).

-define(APP,                   rabbitmq_store_exporter).
-define(FILE_EXTENSION,        ".rdq").
-define(FILE_EXTENSION_TMP,    ".rdt").
-define(PERSISTENT_MSG_STORE,  msg_store_persistent).
-define(TRANSIENT_MSG_STORE,   msg_store_transient).

-rabbit_boot_step({store_export,
                   [{description, "exporting store"},
                    {mfa,         {?MODULE, export, []}},
                    {requires,    core_initialized},
                    {enables,     recovery}]}).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

export() ->
    case application:get_env(?APP, directory) of
        {ok, TargetDir} ->
            TargetMsgsDir = filename:join(TargetDir, "messages"),
            TargetQueuesDir = filename:join(TargetDir, "queues"),
            [ok = rabbit_file:ensure_dir(filename:join(Dir, "nothing"))
             || Dir <- [TargetMsgsDir, TargetQueuesDir]],
            Base = rabbit_mnesia:dir(),
            case rabbit_file:is_dir(Base) of
                true ->
                    QueuesDir = filename:join(rabbit_mnesia:dir(), "queues"),
                    {ok, Gatherer} = gatherer:start_link(),
                    [fork(Gatherer, fun () ->
                                            queue(TargetQueuesDir, QueuesDir,
                                                  QueueDirName)
                                    end)
                     || QueueDirName <- filelib:wildcard("*", QueuesDir)],
                    [fork(Gatherer,
                          fun () ->
                                  msg_store(TargetMsgsDir,
                                            filename:join(Base, Store))
                          end)
                     || Store <- [?PERSISTENT_MSG_STORE, ?TRANSIENT_MSG_STORE]],
                    empty = gatherer:out(Gatherer),
                    unlink(Gatherer),
                    ok = gatherer:stop(Gatherer),
                    ok;
                false ->
                    ok
            end;
        undefined ->
            rabbit_log:warning(
              "~s: No directory configured for export. Aborting~n", [?APP]),
            ok
    end.

fork(Gatherer, Fun) ->
    ok = gatherer:fork(Gatherer),
    ok = worker_pool:submit_async(
           fun () ->
                   link(Gatherer),
                   Fun(),
                   ok = gatherer:finish(Gatherer),
                   unlink(Gatherer),
                   ok
           end).

%%----------------------------------------------------------------------------
%% Queue Index
%%----------------------------------------------------------------------------

queue(TargetDir, QueuesDir, QueueDirName) ->
    QueueIndexDir = filename:join(QueuesDir, QueueDirName),
    TargetQueueDir = filename:join(TargetDir, QueueDirName),
    ok = rabbit_file:ensure_dir(filename:join(TargetQueueDir, "nothing")),
    case rabbit_file:is_dir(QueueIndexDir) of
        true ->
            ok = rabbit_queue_index:scan(
                   QueueIndexDir, dump_queue_fun(TargetQueueDir), ok);
        false ->
            ok
    end.

dump_queue_fun(TargetDir) ->
    fun (SeqId, MsgId, MsgProps, IsPersistent, IsDelivered, IsAcked, Acc) ->
            MsgProps1 =
                dump_fields(
                  MsgProps, record_info(fields, message_properties), []),
            ok = write_term_file(
                   filename:join(TargetDir, rabbit_misc:format("~w", [SeqId])),
                   [[{message_id, rabbit_guid:string(MsgId, "msg")},
                     {message_properties, MsgProps1},
                     {is_persistent, IsPersistent},
                     {is_delivered, del =:= IsDelivered},
                     {is_acknowledged, ack =:= IsAcked}]]),
            Acc
    end.

%%----------------------------------------------------------------------------
%% Msg Store
%%----------------------------------------------------------------------------

msg_store(TargetDir, MsgStoreDir) ->
    case rabbit_file:is_dir(MsgStoreDir) of
        true ->
            FileNames =
                filelib:wildcard("*" ++ ?FILE_EXTENSION, MsgStoreDir) ++
                filelib:wildcard("*" ++ ?FILE_EXTENSION_TMP, MsgStoreDir),
            lists:foreach(
              fun (FileName) ->
                      msg_store_file(TargetDir, MsgStoreDir, FileName)
              end, FileNames),
            ok;
        false ->
            ok
    end.

msg_store_file(TargetDir, SrcDir, FileName) ->
    Path = filename:join(SrcDir, FileName),
    Size = rabbit_file:file_size(Path),
    {ok, Hdl} = file_handle_cache:open(Path, [raw, binary, read], []),
    {ok, ok, Size1} = rabbit_msg_file:scan(
                        Hdl, Size, dump_msg_fun(Path, TargetDir), ok),
    ok = file_handle_cache:close(Hdl),
    case Size1 of
        Size -> ok;
        _    -> rabbit_log:warning(
                  "~s: In file ~s, detected corruption beyond file offset ~p~n",
                  [?APP, Path, Size1])
    end.

dump_msg_fun(SrcPath, TargetDir) ->
    Fields = record_info(fields, basic_message),
    fun ({MsgId, TotalSize, Offset, MsgBin}, ok) ->
            Dir = filename:join(TargetDir, rabbit_guid:string(MsgId, "msg")),
            ok = rabbit_file:ensure_dir(filename:join(Dir, "nothing")),
            ok = rabbit_file:write_file(filename:join(Dir, "raw"), MsgBin),
            case binary_to_term(MsgBin) of
                Msg = #basic_message{
                  content = #content { payload_fragments_rev = PayloadRev } } ->
                    Terms = dump_fields(Msg, Fields, [{path, SrcPath},
                                                      {offset, Offset},
                                                      {total_size, TotalSize}]),
                    ok = write_term_file(filename:join(Dir, "properties"),
                                         [Terms]),
                    ok = rabbit_file:write_file(
                           filename:join(Dir, "payload"),
                           list_to_binary(lists:reverse(PayloadRev))),
                    ok;
                _ -> %% Must remember to ignore other msgs - eg queue death
                    ok
            end
    end.


%%----------------------------------------------------------------------------
%% Misc
%%----------------------------------------------------------------------------

dump_fields(Record, Fields, Acc) ->
    {_, Terms} =
        lists:foldl(
          fun (Field, {N, TermsAcc}) ->
                  {N+1, [dump_msg_field(Record, Field, N)
                         | TermsAcc]}
          end, {2, Acc}, Fields),
    Terms.

dump_msg_field(Msg, content = FieldName, FieldIdx) ->
    Content = #content{ properties = Props } =
        rabbit_binary_parser:ensure_content_decoded(element(FieldIdx, Msg)),
    Props1 = case Props of
                 #'P_basic'{} ->
                     dump_fields(Props, record_info(fields, 'P_basic'), []);
                 _ ->
                     Props
             end,
    {FieldName, dump_fields(Content #content { properties = Props1 },
                            record_info(fields, content), [])};
dump_msg_field(Msg, id = FieldName, FieldIdx) ->
    {FieldName, rabbit_guid:string(element(FieldIdx, Msg), "msg")};
dump_msg_field(Msg, exchange_name, FieldIdx) ->
    {exchange, rabbit_misc:rs(element(FieldIdx, Msg))};
dump_msg_field(Msg, routing_keys = FieldName, FieldIdx) ->
    {FieldName,
     [rabbit_misc:format("~s", [Key]) || Key <- element(FieldIdx, Msg)]};
dump_msg_field(Msg, FieldName, FieldIdx) ->
    {FieldName, element(FieldIdx, Msg)}.

%% The write_file in rabbit_misc uses ~w not ~p which is wrong for our purposes
write_term_file(File, Terms) ->
    rabbit_file:write_file(
      File, list_to_binary([io_lib:format("~p.~n", [Term]) || Term <- Terms])).
