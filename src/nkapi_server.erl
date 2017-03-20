%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Implementation of the NkAPI External Interface (server)
-module(nkapi_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/5, cmd_async/5, event/2]).
-export([reply_ok/3, reply_login/5, reply_error/3, reply_ack/2]).
-export([stop/1, stop_all/0, start_ping/2, stop_ping/1]).
-export([register/2, unregister/2]).
-export([subscribe/2, unsubscribe/2, unsubscribe_fun/2]).
-export([find_user/1, find_session/1, get_subscriptions/1]).
-export([do_register_http/1]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4, 
         conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).
-export([get_all/0, get_all/1, print/3]).
-export_type([user_state/0]).

% To debug, set debug => [nkapi_server]
% To debug nkpacket, set debug in listener (nkapi_util:get_api_sockets())

-define(DEBUG(Txt, Args, State),
    case erlang:get(nkapi_server_debug) of
        true -> ?LLOG(debug, Txt, Args, State);
        _ -> ok
    end).

-define(LLOG(Type, Txt, Args, State),
    lager:Type(
        [
            {session_id, State#state.session_id},
            {user_id, State#state.user_id}
        ],
        "NkAPI API Server ~s (~s) "++Txt, 
        [State#state.session_id, State#state.user_id | Args])).

-define(MSG(Txt, Args, State),
    case erlang:get(nkapi_server_debug) of
        true -> print(Txt, Args, State);
        _ -> ok
    end).


-define(ACK_TIME, 180).         % Maximum operation time (with ACK)
-define(CALL_TIMEOUT, 180).     % Maximum sync call time

-include("nkapi.hrl").
-include_lib("nkservice/include/nkservice.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type id() :: pid() | nkapi:id().

-type user_state() ::
    #{
        srv_id => nkservice:id(),
        session_type => atom(),
        session_id => binary(),
        remote => binary(),
        user_id => binary(),           % not present if not authenticated
        user_meta => map(),         % "
        module() => term()
    }.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Send a command to the client and wait a response
-spec cmd(id(), nkapi:class(), nkapi:subclass(), nkapi:cmd(), nkapi:data()) ->
    {ok, Result::binary(), Data::map()} | {error, term()}.

cmd(Id, Class, SubClass, Cmd, Data) ->
    Req = #nkapi_req{class=Class, subclass=SubClass, cmd=Cmd, data=Data},
    do_call(Id, {nkapi_send_req, Req}).


%% @doc Send a command and don't wait for a response
-spec cmd_async(id(), nkapi:class(), nkapi:subclass(), nkapi:cmd(), nkapi:data()) ->
    ok | {error, term()}.

cmd_async(Id, Class, SubClass, Cmd, Data) ->
    Req = #nkapi_req{class=Class, subclass=SubClass, cmd=Cmd, data=Data},
    do_cast(Id, {nkapi_send_req, Req}).


%% @doc Sends an event directly to the client (as it were subscribed)
%% Response is not expected from remote
%% Events can also be sent using class=event, cmd=send and a tid
-spec event(id(), map()|#event{}) ->
    ok | {error, term()}.

event(Id, Event) ->
    case parse_event(Event) of
        {ok, Event2} ->
            do_cast(Id, {nkapi_send_event, Event2});
        {error, Error} ->
            {error, Error}
    end.



%% @doc Sends an ok reply to a command (when you reply 'ack' in callbacks)
-spec reply_ok(id(), term(), map()) ->
    ok.

reply_ok(Id, TId, Data) ->
    case find(Id) of
        {ok, Pid} ->
            gen_server:cast(Pid, {nkapi_reply_ok, TId, Data});
        not_found ->
            case find_session_http(Id) of
                {ok, Pid} ->
                    Pid ! {nkapi_reply_ok, Data};
                _ ->
                    ok
            end
    end.


%% @doc Sends an "login ok" reply to a command (when you reply 'ack' in callbacks)
-spec reply_login(id(), term(), map(), binary(), map()) ->
    ok.

reply_login(Id, TId, Reply, User, MetaData) ->
    do_cast(Id, {nkapi_reply_login, TId, Reply, User, MetaData}).


%% @doc Sends an error reply to a command (when you reply 'ack' in callbacks)
-spec reply_error(id(), term(), nkapi:error()) ->
    ok.

reply_error(Id, TId, Code) ->
    case find(Id) of
        {ok, Pid} ->
            gen_server:cast(Pid, {nkapi_reply_error, TId, Code});
        not_found ->
            case find_session_http(Id) of
                {ok, Pid} ->
                    Pid ! {nkapi_reply_error, Code};
                _ ->
                    ok
            end
    end.


%% @doc Sends another ACK to a command (when you reply 'ack' in callbacks)
%% to extend timeout
-spec reply_ack(id(), term()) ->
    ok.

%% @doc Send to extend the timeout for the transaction 
reply_ack(Id, TId) ->
    do_cast(Id, {nkapi_reply_ack, TId}).


%% @doc Start sending pings
-spec start_ping(id(), integer()) ->
    ok.

start_ping(Id, Secs) ->
    do_cast(Id, {nkapi_start_ping, Secs}).


%% @doc Stop sending pings
-spec stop_ping(id()) ->
    ok.

%% @doc 
stop_ping(Id) ->
    do_cast(Id, nkapi_stop_ping).


%% @doc Stops the server
stop(Id) ->
    do_cast(Id, nkapi_stop).


%% @doc Stops all clients
stop_all() ->
    lists:foreach(fun({_User, _SessId, Pid}) -> stop(Pid) end, get_all()).


%% @doc Registers a process with the session
-spec register(id(), nklib:link()) ->
    {ok, pid()} | {error, nkapi:error()}.

register(Id, Link) ->
    do_cast(Id, {nkapi_register, Link}).


%% @doc Unregisters a process with the session
-spec unregister(id(), nklib:link()) ->
    ok | {error, nkapi:error()}.

unregister(Id, Link) ->
    do_cast(Id, {nkapi_unregister, Link}).


%% @doc Registers with the Events system
-spec subscribe(id(), nkapi:event()) ->
    ok.

subscribe(Id, Event) ->
    case parse_event(Event) of
        {ok, #event{type=[F|_]=Types}=Event2} when not is_integer(F) ->
            lists:foreach(
                fun(Type) -> subscribe(Id, Event2#event{type=Type}) end,
                Types);
        {ok, Event2} ->
            do_cast(Id, {nkapi_subscribe, Event2});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Unregisters with the Events system
-spec unsubscribe(id(),  nkapi:event()) ->
    ok.

unsubscribe(Id, Event) ->
    case parse_event(Event) of
        {ok, #event{type=[F|_]=Types}=Event2} when not is_integer(F) ->
            lists:foreach(
                fun(Type) -> unsubscribe(Id, Event2#event{type=Type}) end,
                Types);
        {ok, Event2} ->
            do_cast(Id, {nkapi_unsubscribe, Event2});
        {error, Error} ->
            {error, Error}
    end.


%% @doc Unregisters with the Events system
-spec unsubscribe_fun(id(), fun((#event{}) -> boolean())) ->
    ok.

unsubscribe_fun(Id, Fun) ->
    do_cast(Id, {nkapi_unsubscribe_fun, Fun}).



%% @private
-spec get_all() ->
    [{User::binary(), SessId::binary(), pid()}].

get_all() ->
    [{User, SessId, Pid} || {{User, SessId}, Pid} <- nklib_proc:values(?MODULE)].


%% @private
-spec get_all(nkapi:id()) ->
    [{User::binary(), SessId::binary(), pid()}].

get_all(SrvId) ->
    [{User, SessId, Pid} || {{User, SessId}, Pid} <- nklib_proc:values({?MODULE, SrvId})].


%% @private
get_subscriptions(Id) ->
    do_call(Id, nkapi_get_subscriptions).


%% @private
-spec find_user(string()|binary()) ->
    [{SessId::binary(), Meta::map(), pid()}].

find_user(User) ->
    User2 = nklib_util:to_binary(User),
    [
        {SessId, Meta, Pid} ||
        {{SessId, Meta}, Pid}<- nklib_proc:values({?MODULE, user, User2})
    ].


%% @private
-spec find_session(binary()) ->
    {ok, User::binary(), pid()} | not_found.

find_session(SessId) ->
    case nklib_proc:values({?MODULE, session, SessId}) of
        [{User, Pid}] -> {ok, User, Pid};
        [] -> not_found
    end.


%% @private
-spec find_session_http(binary()) ->
    {ok, pid()} | not_found.

find_session_http(SessId) ->
    case nklib_proc:values({?MODULE, http, SessId}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
do_register_http(SessId) ->
    true = nklib_proc:reg({?MODULE, http, SessId}).



%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-type tid() :: integer().

-record(trans, {
    op :: term(),
    timer :: reference(),
    from :: {pid(), term()} | {async, pid(), term()}
}).

-record(reg, {
    index :: integer(),
    event :: #event{},
    mon :: reference()
}).

-record(state, {
    srv_id :: nkapi:id(),
    user_id = <<>> :: binary(),
    session_id = <<>> :: binary(),
    trans = #{} :: #{tid() => #trans{}},
    tid = 1 :: integer(),
    ping :: integer() | undefined,
    op_time :: integer(),
    regs = [] :: [#reg{}],
    links :: nklib_links:links(),
    user_state :: nkapi:user_state()
}).


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [wss, tls, ws, tcp, http, https].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(ws) -> 9010;
default_port(wss) -> 9011;
default_port(tcp) -> 9010;
default_port(tls) -> 9011;
default_port(http) -> 9010;
default_port(https) -> 9011.


-spec conn_init(nkpacket:nkport()) ->
    {ok, #state{}}.

conn_init(NkPort) ->
    {ok, {nkapi_server, SrvId}, _} = nkpacket:get_user(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    SessId = nklib_util:luid(),
    UserState = #{
        srv_id => SrvId, 
        session_type => ?MODULE,
        session_id => SessId,
        remote => Remote
    },
    true = nklib_proc:reg({?MODULE, session, SessId}, <<>>),
    State1 = #state{
        srv_id = SrvId,
        session_id = SessId,
        user_state = UserState,
        links = nklib_links:new(),
        op_time = nkapi_app:get(api_cmd_timeout)
    },
    set_log(State1),
    nkservice_util:register_for_changes(SrvId),
    ?LLOG(info, "new connection (~s, ~p)", [Remote, self()], State1),
    {ok, State2} = handle(api_server_init, [NkPort], State1),
    {ok, State2}.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, Text}, NkPort, State) ->
    Msg = case nklib_json:decode(Text) of
        error ->
            ?LLOG(warning, "JSON decode error: ~p", [Text], State),
            error(json_decode);
        Json ->
            Json
    end,
    case Msg of
        #{<<"class">> := Class, <<"cmd">> := Cmd, <<"tid">> := TId} ->
            ?MSG("received ~s", [Msg], State),
            #state{srv_id=SrvId, user_id=User, session_id=Session} = State,
            Req = #nkapi_req{
                srv_id = SrvId,
                class = Class,
                subclass = maps:get(<<"subclass">>, Msg, <<>>),
                cmd = Cmd,
                tid = TId,
                data = maps:get(<<"data">>, Msg, #{}), 
                user_id = User,
                session_id = Session
            },
            process_client_req(Req, NkPort, State);
        #{<<"class">> := <<"event">>, <<"data">> := Data} ->
            ?MSG("received event ~s", [Data], State),
            #state{srv_id=SrvId, user_id=User, session_id=Session} = State,
            Req = #nkapi_req{
                srv_id = SrvId,
                class = event,
                data = Data,
                user_id = User,
                session_id = Session
            },
            process_client_event(Req, State);
        #{<<"result">> := Result, <<"tid">> := TId} ->
            case extract_op(TId, State) of
                {Trans, State2} ->
                    case Trans of
                        #trans{op=#{cmd:=ping}} -> ok;
                        _ -> ?MSG("received ~s", [Msg], State)
                    end,
                    Data = maps:get(<<"data">>, Msg, #{}),
                    process_client_resp(Result, Data, Trans, NkPort, State2);
                not_found ->
                    ?LLOG(info, 
                          "received client response for unknown req: ~p, ~p, ~p", 
                          [Msg, TId, State#state.trans], State),
                    {ok, State}
            end;
        #{<<"ack">> := TId} ->
            ?MSG("received ~s", [Msg], State),
            case extract_op(TId, State) of
                {Trans, State2} ->
                    {ok, extend_op(TId, Trans, State2)};
                not_found ->
                    ?LLOG(info, "received client ack for unknown req: ~p", 
                          [Msg], State),
                    {ok, State}
            end;
        _ ->
            ?LLOG(notice, "received unrecognized msg: ~p", [Msg], State),
            {stop, normal, State}
    end.


-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg); is_list(Msg) ->
    case nklib_json:encode(Msg) of
        error ->
            lager:warning("invalid json in ~p: ~p", [?MODULE, Msg]),
            {error, invalid_json};
        Json ->
            {ok, {text, Json}}
    end;

conn_encode(Msg, _NkPort) when is_binary(Msg) ->
    {ok, {text, Msg}}.


-spec conn_handle_call(term(), {pid(), term()}, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_call({nkapi_send_req, Req}, From, NkPort, State) ->
    send_request(Req, From, NkPort, State);
    
conn_handle_call(nkapi_get_subscriptions, From, _NkPort, #state{regs=Regs}=State) ->
    Data = [nkservice_events:unparse(Event) || #reg{event=Event} <- Regs],
    gen_server:reply(From, Data),
    {ok, State};

conn_handle_call(get_state, From, _NkPort, State) ->
    gen_server:reply(From, lager:pr(State, ?MODULE)),
    {ok, State};

conn_handle_call(Msg, From, _NkPort, State) ->
    handle(api_server_handle_call, [Msg, From], State).


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast({nkapi_send_req, Req}, NkPort, State) ->
    send_request(Req, undefined, NkPort, State);

conn_handle_cast({nkapi_send_event, Event}, NkPort, State) ->
    send_event(Event, NkPort, State);

conn_handle_cast({nkapi_reply_ok, TId, Data}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            send_reply_ok(Data, TId, NkPort, State2);
        not_found ->
            ?LLOG(notice, "received user reply_ok for unknown req: ~p ~p", 
                  [TId, State#state.trans], State), 
            {ok, State}
    end;

conn_handle_cast({nkapi_reply_login, TId, Reply, User, Meta}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            case State of
                #state{user_id = <<>>} ->
                    process_login(Reply, User, Meta, TId, NkPort, State2);
                _ ->
                    send_reply_error(already_authenticated, TId, NkPort, State2)
            end;
        not_found ->
            ?LLOG(notice, "received user nkapi_reply_login for unknown req: ~p ~p", 
                  [TId, State#state.trans], State), 
            {ok, State}
    end;

conn_handle_cast({nkapi_reply_error, TId, Code}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            send_reply_error(Code, TId, NkPort, State2);
        not_found ->
            ?LLOG(notice, "received user reply_error for unknown req: ~p ~p", 
                  [TId, State#state.trans], State), 
            {ok, State}
    end;

conn_handle_cast({nkapi_reply_ack, TId}, NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=ack}, State2} ->
            State3 = insert_ack(TId, State2),
            send_ack(TId, NkPort, State3);
        not_found ->
            ?LLOG(notice, "received user reply_ack for unknown req", [], State), 
            {ok, State}
    end;

conn_handle_cast(nkapi_stop, _NkPort, State) ->
    {stop, normal, State};

conn_handle_cast({nkapi_start_ping, Time}, _NkPort, #state{ping=Ping}=State) ->
    case Ping of
        undefined -> self() ! nkapi_send_ping;
        _ -> ok
    end,
    {ok, State#state{ping=Time}};

conn_handle_cast(nkapi_stop_ping, _NkPort, State) ->
    {ok, State#state{ping=undefined}};

conn_handle_cast({nkapi_subscribe, Event}, _NkPort, State) ->
    #state{regs=Regs} = State,
    Pid = nkservice_events:reg(Event),
    Index = event_index(Event),
    Regs2 = case lists:keyfind(Index, #reg.index, Regs) of
        false ->
            ?DEBUG("registered event ~p", [Event], State),
            Mon = monitor(process, Pid),
            [#reg{index=Index, event=Event, mon=Mon}|Regs];
        #reg{} ->
            ?DEBUG("event ~p already registered", [Event], State),
            Regs
    end,
    {ok, State#state{regs=Regs2}};

conn_handle_cast({nkapi_unsubscribe, Event}, _NkPort, State) ->
    #state{regs=Regs} = State,
    Index = event_index(Event),
    case lists:keytake(Index, #reg.index, Regs) of
        {value, #reg{mon=Mon}, Regs2} ->
            demonitor(Mon),
            ok = nkservice_events:unreg(Event),
            ?DEBUG("unregistered event ~p", [Event], State),
            {ok, State#state{regs=Regs2}};
        false ->
            {ok, State}
    end;

conn_handle_cast({nkapi_unsubscribe_fun, Fun}, _NkPort, State) ->
    #state{regs=Regs} = State,
    lists:foreach(
        fun(#reg{event=Event}) -> 
            case Fun(Event) of 
                true -> unsubscribe(self(), Event#event{body=#{}});
                false -> ok
            end
        end,
        Regs),
    {ok, State};

conn_handle_cast({nkapi_register, Link}, _NkPort, State) ->
    ?DEBUG("registered ~p", [Link], State),
    {ok, links_add(Link, State)};

conn_handle_cast({nkapi_unregister, Link}, _NkPort, State) ->
    ?DEBUG("unregistered ~p", [Link], State),
    {ok, links_remove(Link, State)};

conn_handle_cast(Msg, _NkPort, State) ->
    handle(api_server_handle_cast, [Msg], State).


-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info(nkapi_send_ping, _NkPort, #state{ping=undefined}=State) ->
    {ok, State};

conn_handle_info(nkapi_send_ping, NkPort, #state{ping=Time}=State) ->
    erlang:send_after(1000*Time, self(), nkapi_send_ping),
    Req = #nkapi_req{class=session, cmd=ping, data=#{time=>Time}},
    send_request(Req, undefined, NkPort, State);

%% This messages is received from nkservice_events when we receive an event
%% we are subscribed to.
conn_handle_info({nkservice_event, Event}, NkPort, State) ->
    case handle(api_server_forward_event, [Event], State) of
        {ok, Event2, State2} ->
            send_event(Event2, NkPort, State2);
        {ignore, State2} ->
            {ok, State2}
    end;

conn_handle_info({timeout, _, {nkapi_op_timeout, TId}}, _NkPort, State) ->
    case extract_op(TId, State) of
        {#trans{op=Op, from=From}, State2} ->
            nklib_util:reply(From, {error, timeout}),
            ?LLOG(notice, "operation ~p (~p) timeout!", [Op, TId], State),
            {stop, normal, State2};
        not_found ->
            {ok, State}
    end;

conn_handle_info({'EXIT', _PId, normal}, _NkPort, State) ->
    {ok, State};

conn_handle_info({'DOWN', Ref, process, _Pid, Reason}=Info, _NkPort, State) ->
    #state{regs=Regs} = State,
    case lists:keytake(Ref, #reg.mon, Regs) of
        {value, #reg{event=Event}, Regs2} ->
            subscribe(self(), Event),
            {ok, State#state{regs=Regs2}};
        false ->
            case links_down(Ref, State) of
                {ok, Link, State2} ->
                    handle(api_server_reg_down, [Link, Reason], State2);
                not_found ->
                    handle(api_server_handle_info, [Info], State)
            end
    end;

conn_handle_info({nkapi_updated, _SrvId}, _NkPort, State) ->
    {ok, set_log(State)};

conn_handle_info(Info, _NkPort, State) ->
    handle(api_server_handle_info, [Info], State).


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), #state{}) ->
    ok.

conn_stop(Reason, _NkPort, #state{trans=Trans}=State) ->
    lists:foreach(
        fun({_, #trans{from=From}}) -> nklib_util:reply(From, {error, stopped}) end,
        maps:to_list(Trans)),
    ?DEBUG("server stop (~p): ~p", [Reason, Trans], State),
    catch handle(api_server_terminate, [Reason], State).



%% ===================================================================
%% Requests
%% ===================================================================

%% @private
process_client_req(Req, NkPort, #state{user_id=User, user_state=UserState} = State) ->
    case nkapi_server_lib:process_req(Req, UserState) of
        {ok, Reply, UserState2} ->
            State2 = State#state{user_state=UserState2},
            send_reply_ok(Reply, Req, NkPort, State2);
        {ack, UserState2} ->
            State2 = State#state{user_state=UserState2},
            State3 = insert_ack(Req, State2),
            send_ack(Req, NkPort, State3);
        {login, Reply, User2, Meta, UserState2} when User == <<>> ->
            State2 = State#state{user_state=UserState2},
            process_login(Reply, User2, Meta, Req, NkPort, State2);
        {login, _Reply, _User, _Meta, UserState2} ->
            State2 = State#state{user_state=UserState2},
            send_reply_error(already_authenticated, Req, NkPort, State2);
        {error, Error, UserState2} ->
            State2 = State#state{user_state=UserState2},
            send_reply_error(Error, Req, NkPort, State2)
    end.


%% @private
process_client_event(Req, #state{user_state=UserState} = State) ->
    {ok, UserState2} = nkapi_server_lib:process_event(Req, UserState),
    {ok, State#state{user_state=UserState2}}.


%% @private
process_client_resp(Result, Data, #trans{from=From}, _NkPort, State) ->
    nklib_util:reply(From, {ok, Result, Data}),
    {ok, State}.



%% ===================================================================
%% Util
%% ===================================================================

%% @private
parse_event(#event{}=Event) ->
    {ok, Event};

parse_event(Data) ->
    case nkservice_events:parse(Data) of
        {ok, #event{}=Event, []} ->
            {ok, Event};
        {ok, _, Unrecognized} ->
            {error, {unrecognized_fields, Unrecognized}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
process_login(Reply, User, Meta, ReqOrTid, NkPort, State) ->
    #state{srv_id=SrvId, session_id=SessId, user_state=UserState} = State,
    UserState2 = UserState#{
        user_id => User,
        user_meta => Meta
    },
    State2 = State#state{
        user_id = User,
        user_state = UserState2
    },
    nklib_proc:put(?MODULE, {User, SessId}),
    nklib_proc:put({?MODULE, SrvId}, {User, SessId}),
    nklib_proc:put({?MODULE, user, User}, {SessId, Meta}),
    nklib_proc:put({?MODULE, session, SessId}, User),
    Event1 = #event{
        srv_id = SrvId,
        class = <<"api">>,
        subclass = <<"user">>,
        obj_id = User
    },
    subscribe(self(), Event1),
    Event2 = Event1#event{
        subclass = <<"session">>,
        obj_id = SessId
    },
    subscribe(self(), Event2),
    start_ping(self(), nkapi_app:get(api_ping_timeout)),
    send_reply_ok(Reply#{session_id=>SessId}, ReqOrTid, NkPort, State2).


%% @private
do_call(Id, Msg) ->
    case find(Id) of
        {ok, Pid} ->
            case self() of
                Pid -> {error, blocking_request};
                _ -> nklib_util:call(Pid, Msg, 1000*?CALL_TIMEOUT)
            end;
        not_found ->
            {error, not_found}
    end.


%% @private
do_cast(Id, Msg) ->
    case find(Id) of
        {ok, Pid} ->
            gen_server:cast(Pid, Msg);
        not_found ->
            ok
    end.


%% @private
find(Pid) when is_pid(Pid) ->
    {ok, Pid};

find(Id) ->
    case find_user(Id) of
        [{_SessId, _Meta, Pid}|_] ->
            {ok, Pid};
        [] ->
            case find_session(Id) of
                {ok, _, Pid} ->
                    {ok, Pid};
                not_found ->
                    not_found
            end
    end.


%% @private
set_log(#state{srv_id=SrvId}=State) ->
    Debug = case nkservice_util:get_debug_info(SrvId, ?MODULE) of
        {true, _} -> true;
        _ -> false
    end,
    put(nkapi_server_debug, Debug),
    State.


%% @private
insert_op(TId, Op, From, #state{trans=AllTrans, op_time=Time}=State) ->
    Trans = #trans{
        op = Op,
        from = From,
        timer = erlang:start_timer(1000*Time, self(), {nkapi_op_timeout, TId})
    },
    State#state{trans=maps:put(TId, Trans, AllTrans)}.


%% @private
insert_ack(#nkapi_req{tid=TId}, State) ->
    insert_ack(TId, State);

insert_ack(TId, #state{trans=AllTrans}=State) ->
    Trans = #trans{
        op = ack,
        timer = erlang:start_timer(1000*?ACK_TIME, self(), {nkapi_op_timeout, TId})
    },
    State#state{trans=maps:put(TId, Trans, AllTrans)}.


%% @private
extract_op(TId, #state{trans=AllTrans}=State) ->
    case maps:find(TId, AllTrans) of
        {ok, #trans{timer=Timer}=OldTrans} ->
            nklib_util:cancel_timer(Timer),
            State2 = State#state{trans=maps:remove(TId, AllTrans)},
            {OldTrans, State2};
        error ->
            not_found
    end.


%% @private
extend_op(TId, #trans{timer=Timer}=Trans, #state{trans=AllTrans}=State) ->
    nklib_util:cancel_timer(Timer),
    ?DEBUG("extended op, new time: ~p", [1000*?ACK_TIME], State),
    Timer2 = erlang:start_timer(1000*?ACK_TIME, self(), {nkapi_op_timeout, TId}),
    Trans2 = Trans#trans{timer=Timer2},
    State#state{trans=maps:put(TId, Trans2, AllTrans)}.


%% @private
send_request(Req, From, NkPort, #state{tid=TId}=State) ->
    #nkapi_req{class=Class, subclass=Sub, cmd=Cmd, data=Data} = Req,
    Msg1 = #{
        class => Class,
        cmd => Cmd,
        tid => TId
    },
    Msg2 = case Sub of
        <<>> -> Msg1;
        '' -> Msg1;
        _ -> Msg1#{subclass=>Sub}
    end,
    Msg3 = if 
        is_map(Data), map_size(Data)>0  ->
            Msg2#{data=>Data};
        is_list(Data) ->
            Msg2#{data=>Data};
        true ->
            Msg2
        end,
    State2 = insert_op(TId, Msg3, From, State),
    send(Msg3, NkPort, State2#state{tid=TId+1}).


%% @private
send_event(Event, NkPort, State) ->
    #state{srv_id=_SrvId} = State,
    Msg = #{
        class => event,
        data => nkservice_events:unparse(Event)
    },
    send(Msg, NkPort, State).


%% @private
send_reply_ok(Data, #nkapi_req{tid=TId}, NkPort, State) ->
    send_reply_ok(Data, TId, NkPort, State);

send_reply_ok(Data, TId, NkPort, State) ->
    Msg1 = #{
        result => ok,
        tid => TId
    },
    Msg2 = case Data of
        #{} when map_size(Data)==0 -> Msg1;
        #{} -> Msg1#{data=>Data};
        List when is_list(List) -> Msg1#{data=>Data}
    end,
    send(Msg2, NkPort, State).


%% @private
send_reply_error(Error, #nkapi_req{tid=TId}, NkPort, State) ->
    send_reply_error(Error, TId, NkPort, State);

send_reply_error(Error, TId, NkPort, #state{srv_id=SrvId}=State) ->
    {Code, Text} = nkapi_util:api_error(SrvId, Error),
    Msg = #{
        result => error,
        tid => TId,
        data => #{ 
            code => Code,
            error => Text
        }
    },
    send(Msg, NkPort, State).


%% @private
send_ack(#nkapi_req{tid=TId}, NkPort, State) ->
    send_ack(TId, NkPort, State);

send_ack(TId, NkPort, State) ->
    Msg = #{ack => TId},
    send(Msg, NkPort, State).


%% @private
send(Msg, NkPort, State) ->
    ?MSG("sending ~s", [Msg], State),
    case catch send(Msg, NkPort) of
        ok -> 
            {ok, State};
        _ -> 
            ?LLOG(notice, "error sending reply: ~p", [Msg], State),
            {stop, normal, State}
    end.


%% @private
send(Msg, NkPort) ->
    nkpacket_connection:send(NkPort, Msg).


%% @private
handle(Fun, Args, State) ->
    nklib_gen_server:handle_any(Fun, Args, State, #state.srv_id, #state.user_state).


%% @private
event_index(Event) ->
    erlang:phash2(Event#event{body=#{}, pid=undefined, meta=#{}}).


%% @private
links_add(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:add(Link, Links)}.


%% @private
links_remove(Link, #state{links=Links}=State) ->
    State#state{links=nklib_links:remove(Link, Links)}.


%% @private
links_down(Mon, #state{links=Links}=State) ->
    case nklib_links:down(Mon, Links) of
        {ok, Link, _Data, Links2} -> 
            {ok, Link, State#state{links=Links2}};
        not_found -> 
            not_found
    end.


% %% @private
% links_fold(Fun, Acc, #state{links=Links}) ->
%     nklib_links:fold(Fun, Acc, Links).


%% @private
print(_Txt, [#{cmd:=ping}], _State) ->
    ok;
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, State) ->
    ?LLOG(debug, Txt, Args, State).

 
