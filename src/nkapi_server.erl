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
-behavior(nkservice_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([cmd/3, cmd_async/3, send_event/2, send_event2/2]).
-export([reply/2]).
-export([stop_session/2, stop_all/0, start_ping/2, stop_ping/1]).
-export([register/2, unregister/2]).
-export([subscribe/2, unsubscribe/2]).
-export([find_user/1, find_session/1, get_subscriptions/1]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4, 
         conn_handle_cast/3, conn_handle_info/3, conn_stop/3]).
-export([get_all/0, get_all/1, print/3]).
-export_type([session_meta/0]).

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
        [
            State#state.session_id,
            State#state.user_id
            | Args
        ])).

-define(MSG(Txt, Args, State),
    case erlang:get(nkapi_server_debug) of
        true -> print(Txt, Args, State);
        _ -> ok
    end).


-define(ACK_TIME, 180).         % Maximum operation time (with ACK)
-define(CALL_TIMEOUT, 180).     % Maximum sync call time

-include("nkapi.hrl").
-include_lib("nkservice/include/nkservice.hrl").
-include_lib("nkevent/include/nkevent.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type session_meta() :: #{
    local => binary(),
    remote => binary()
}.

-type tid() :: integer().


%% ===================================================================
%% nkservice_session behaviour
%% ===================================================================


%% @doc
cmd(Pid, Cmd, Data) ->
    do_call(Pid, {nkapi_send_req, Cmd, Data}).


%% @doc
cmd_async(Pid, Cmd, Data) ->
    do_cast(Pid, {nkapi_send_req, Cmd, Data}).


%% @doc
send_event(Pid, Data) ->
    case nkevent_util:parse(Data) of
        {ok, Event} ->
            Pid ! {nkevent, Event},
            ok;
        {error, Error} ->
            {error, Error}
    end.




send_event2(Pid, Data) ->
    case nkevent_util:parse(Data) of
        {ok, Event} ->
            do_cast(Pid, {nkapi_send_event2, Event});
        {error, Error} ->
            {error, Error}
    end.



%% doc
reply(Pid, {ok, Reply, Req}) ->
    do_cast(Pid, {nkapi_reply_ok, Reply, Req});

reply(Pid, {error, Error, Req}) ->
    do_cast(Pid, {nkapi_reply_error, Error, Req});

reply(Pid, {ack, Req}) ->
    do_cast(Pid, {nkapi_reply_ack, undefined, Req});

reply(Pid, {ack, AckPid, Req}) ->
    do_cast(Pid, {nkapi_reply_ack, AckPid, Req}).


%% @doc Start sending pings
start_ping(Pid, Secs) ->
    do_cast(Pid, {nkapi_start_ping, Secs}).


%% @doc Stop sending pings
stop_ping(Pid) ->
    do_cast(Pid, nkapi_stop_ping).


%% @doc Registers a process with the session
register(Pid, Link) ->
    do_cast(Pid, {nkapi_register, Link}).


%% @doc Unregisters a process with the session
unregister(Pid, Link) ->
    do_cast(Pid, {nkapi_unregister, Link}).


%% @doc Registers with the Events system
subscribe(Pid, #nkevent{}=Event) ->
    do_cast(Pid, {nkapi_subscribe, Event});

subscribe(Pid, Data) ->
    case nkevent_util:parse_reg(Data) of
        {ok, Events} ->
            lists:foreach(
                fun(#nkevent{}=Event) -> subscribe(Pid, Event) end,
                Events);
        {error, Error} ->
            {error, Error}
    end.


%% @doc Unregisters with the Events system
unsubscribe(Pid, #nkevent{}=Event) ->
    do_cast(Pid, {nkapi_unsubscribe, Event});

unsubscribe(Pid, Data) ->
    case nkevent_util:parse_reg(Data) of
        {ok, Events} ->
            lists:foreach(
                fun(#nkevent{}=Event) -> unsubscribe(Pid, Event) end,
                Events);
        {error, Error} ->
            {error, Error}
    end.


%%%% @doc Unregisters with the Events system
%%unsubscribe_fun(Pid, Fun) ->
%%    do_cast(Pid, {nkapi_unsubscribe_fun, Fun}).

%% @doc Gets all current subscriptions
get_subscriptions(Pid) ->
    do_call(Pid, nkapi_get_subscriptions).


%% @doc
stop_session(Pid, Reason) ->
    do_cast(Pid, {nkapi_stop, Reason}).


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


%% @doc Stops all clients
stop_all() ->
    lists:foreach(
        fun({_User, _SessId, Pid}) -> stop_session(Pid, stop_all) end,
        get_all()).



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



%% ===================================================================
%% Protocol callbacks
%% ===================================================================

-record(trans, {
    op :: term(),
    timer :: reference(),
    mon :: reference(),
    from :: {pid(), term()} | {async, pid(), term()}
}).

-record(reg, {
    index :: integer(),
    event :: #nkevent{},
    mon :: reference()
}).

-record(state, {
    srv_id :: nkservice:id(),
    session_id :: nkservice:session_id(),
    session_manager = undefined :: term(),
    trans = #{} :: #{tid() => #trans{}},
    tid = 1 :: integer(),
    ping :: integer() | undefined,
    op_time :: integer(),
    regs = [] :: [#reg{}],
    links :: nklib_links:links(),
    local :: binary(),
    remote :: binary(),
    user_id = <<>> :: nkservice:user_id(),
    user_state = #{} :: nkservice:user_state()
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
    {ok, Local} = nkpacket:get_local_bin(NkPort),
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    SessId = <<"session-", (nklib_util:luid())/binary>>,
    true = nklib_proc:reg({?MODULE, session, SessId}, <<>>),
    State1 = #state{
        srv_id = SrvId,
        session_id = SessId,
        local = Local,
        remote = Remote,
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
        #{<<"cmd">> := Cmd, <<"tid">> := TId} ->
            ?MSG("received ~s", [Msg], State),
            Cmd2 = get_cmd(Cmd, Msg),
            Data = maps:get(<<"data">>, Msg, #{}),
            process_client_req(Cmd2, Data, TId, NkPort, State);
        #{<<"cmd">> := <<"event">>, <<"data">> := Data} ->
            ?MSG("received event ~s", [Data], State),
            process_client_event(Data, State);
        #{<<"result">> := Result, <<"tid">> := TId} when is_binary(Result) ->
            case extract_op(TId, State) of
                {Trans, State2} ->
                    case Trans of
                        #trans{op=#{cmd:=<<"ping">>}} -> ok;
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
                    ?LLOG(info, "received client ack for unknown req: ~p ",
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

conn_handle_call({nkapi_send_req, Cmd, Data}, From, NkPort, State) ->
    send_request(Cmd, Data, From, NkPort, State);
    
conn_handle_call(nkapi_get_subscriptions, From, _NkPort, #state{regs=Regs}=State) ->
    Data = [nkevent_util:unparse2(Event) || #reg{event=Event} <- Regs],
    gen_server:reply(From, {ok, Data}),
    {ok, State};

conn_handle_call(get_state, From, _NkPort, State) ->
    gen_server:reply(From, lager:pr(State, ?MODULE)),
    {ok, State};

conn_handle_call(Msg, From, _NkPort, State) ->
    handle(api_server_handle_call, [Msg, From], State).


-spec conn_handle_cast(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_cast({nkapi_send_req, Cmd, Data}, NkPort, State) ->
    send_request(Cmd, Data, undefined, NkPort, State);

%%conn_handle_cast({nkapi_send_event, Event}, NkPort, State) ->
%%    send_event(Event, NkPort, State);

conn_handle_cast({nkapi_send_event2, Event}, NkPort, State) ->
    Msg = nkevent_util:unparse2(Event),
    send(Msg, NkPort, State);

conn_handle_cast({nkapi_reply_ok, Reply, Req}, NkPort, #state{user_id=UserId}=State) ->
    #nkreq{tid=TId, user_id=UserId2, unknown_fields=Unknown} = Req,
    State2 = update_req_state(Req, State),
    case extract_op(TId, State2) of
        {#trans{op=ack}, State3} ->
            case UserId == <<>> andalso UserId2 /= <<>> of
                true ->
                    State4 = State3#state{user_id=UserId2},
                    process_login(Reply, TId, Unknown, NkPort, State4);
                false when UserId /= UserId2 ->
                    send_reply_error(invalid_login_request, TId, NkPort, State3);
                false ->
                   send_reply_ok(Reply, TId, Unknown, NkPort, State3)
           end;
        not_found ->
            ?LLOG(notice, "received user reply_ok for unknown req: ~p ~p",
                  [TId, State#state.trans], State),
            {ok, State2}
    end;

conn_handle_cast({nkapi_reply_error, Code, Req}, NkPort, State) ->
    #nkreq{tid=TId, user_state=UserState} = Req,
    State2 = State#state{user_state=UserState},
    case extract_op(TId, State2) of
        {#trans{op=ack}, State3} ->
            send_reply_error(Code, TId, NkPort, State3);
        not_found ->
            ?LLOG(notice, "received user reply_error for unknown req: ~p ~p", 
                  [TId, State#state.trans], State2),
            {ok, State2}
    end;

conn_handle_cast({nkapi_reply_ack, Pid, Req}, NkPort, State) ->
    #nkreq{tid=TId, user_state=UserState, unknown_fields=Unknown} = Req,
    State2 = State#state{user_state=UserState},
    case extract_op(TId, State2) of
        {#trans{op=ack}, State3} ->
            State4 = insert_ack(TId, Pid, State3),
            send_ack(TId, Unknown, NkPort, State4);
        not_found ->
            ?LLOG(notice, "received user reply_ack for unknown req", [], State), 
            {ok, State2}
    end;

conn_handle_cast({nkapi_stop, Reason}, _NkPort, State) ->
    ?LLOG(info, "user stop: ~p", [Reason], State),
    {stop, normal, State};

conn_handle_cast({nkapi_start_ping, Time}, _NkPort, #state{ping=Ping}=State) ->
    case Ping of
        undefined -> self() ! nkapi_send_ping;
        _ -> ok
    end,
    {ok, State#state{ping=Time}};

conn_handle_cast(nkapi_stop_ping, _NkPort, State) ->
    {ok, State#state{ping=undefined}};

conn_handle_cast({nkapi_subscribe, Event}, _NkPort, #state{srv_id=SrvId}=State) ->
    #state{regs=Regs} = State,
    Event2 = Event#nkevent{srv_id=SrvId},
    {ok, [Pid]} = nkevent:reg(Event2),
    Index = event_index(Event2),
    Regs2 = case lists:keyfind(Index, #reg.index, Regs) of
        false ->
            ?DEBUG("registered event ~p", [Event2], State),
            Mon = monitor(process, Pid),
            [#reg{index=Index, event=Event2, mon=Mon}|Regs];
        #reg{} ->
            ?DEBUG("event ~p already registered", [Event2], State),
            Regs
    end,
    {ok, State#state{regs=Regs2}};

conn_handle_cast({nkapi_unsubscribe, Event}, _NkPort, #state{srv_id=SrvId}=State) ->
    #state{regs=Regs} = State,
    Event2 = Event#nkevent{srv_id=SrvId},
    Index = event_index(Event2),
    case lists:keytake(Index, #reg.index, Regs) of
        {value, #reg{mon=Mon}, Regs2} ->
            demonitor(Mon),
            ok = nkevent:unreg(Event2),
            ?DEBUG("unregistered event ~p", [Event2], State),
            {ok, State#state{regs=Regs2}};
        false ->
            {ok, State}
    end;

conn_handle_cast({nkapi_unsubscribe_fun, Fun}, _NkPort, State) ->
    #state{regs=Regs} = State,
    lists:foreach(
        fun(#reg{event=Event}) -> 
            case Fun(Event) of 
                true -> unsubscribe(self(), Event#nkevent{body=#{}});
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
    send_request(<<"ping">>, #{time=>Time}, undefined, NkPort, State);

%% We receive an event we are subscribed to.
conn_handle_info({nkevent, Event}, NkPort, State) ->
    process_server_event(Event, NkPort, State);

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

conn_handle_info({'DOWN', Ref, process, _Pid, Reason}=Info, NkPort, State) ->
    #state{regs=Regs} = State,
    case lists:keytake(Ref, #reg.mon, Regs) of
        {value, #reg{event=Event}, Regs2} ->
            subscribe(self(), Event),
            {ok, State#state{regs=Regs2}};
        false ->
            case links_down(Ref, State) of
                {ok, Link, State2} ->
                    case handle(api_server_reg_down, [Link, Reason], State2) of
                        {ok, State3} ->
                            {ok, State3};
                        {stop, Reason2, State3} ->
                            ?LLOG(notice, "linked process stop: ~p", [Reason2], State),
                            stop_session(self(), Reason2),
                            {ok, State3}
                    end;
                not_found ->
                    case extract_op_mon(Ref, State) of
                        {true, TId, #trans{op=Op}, State2} ->
                            ?LLOG(notice, "operation ~p (~p) process down!", [Op, TId], State),
                            send_reply_error(process_down, TId, NkPort, State2);
                        false ->
                            handle(api_server_handle_info, [Info], State)
                    end
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
    ?DEBUG("server conn_stop (~p): ~p", [Reason, Trans], State),
    catch handle(api_server_terminate, [Reason], State).



%% ===================================================================
%% Requests
%% ===================================================================

%% @private
process_client_req(Cmd, Data, TId, NkPort, #state{user_id=UserId}=State) ->
    Req = make_req(Cmd, Data, TId, State),
    case nkservice_api:api(Req) of
        {ok, Reply, #nkreq{user_id=UserId2, unknown_fields=Unknown}=Req2} ->
            case UserId == <<>> andalso UserId2 /= <<>> of
                true ->
                    State2 = State#state{user_id=UserId},
                    State3 = update_req_state(Req2, State2),
                    process_login(Reply, TId, Unknown, NkPort, State3);
                false when UserId /= UserId2 ->
                    send_reply_error(invalid_login_request, TId, NkPort, State);
                false ->
                    State2 = update_req_state(Req2, State),
                    send_reply_ok(Reply, TId, Unknown, NkPort, State2)
            end;
        {ack, Pid, #nkreq{unknown_fields=Unknown}=Req2} ->
            State2 = update_req_state(Req2, State),
            State3 = insert_ack(TId, Pid, State2),
            send_ack(TId, Unknown, NkPort, State3);
        {error, Error, Req2} ->
            State2 = update_req_state(Req2, State),
            send_reply_error(Error, TId, NkPort, State2)
    end.


%% @private
process_client_event(Data, State) ->
    Req = make_req(<<"event">>, Data, <<>>, State),
    case nkservice_api:api(Req) of
        {ok, _, _} ->
            {ok, State};
        {error, _Error, _} ->
            {ok, State}
    end.


%% @private
process_client_resp(Result, Data, #trans{from=From}, _NkPort, State) ->
    nklib_util:reply(From, {ok, Result, Data}),
    {ok, State}.


%% @private
process_server_event(Event, NkPort, State) ->
    Req = make_req(<<"event">>, nkevent_util:unparse(Event), <<>>, State),
    case nkservice_api:event(Req#nkreq{timeout_pending=false}) of
        ok ->
            {ok, State};
        {forward, #nkreq{data=Data2}} ->
            Msg = #{
                cmd => <<"event">>,
                data => Data2
            },
            send(Msg, NkPort, State)
    end.




%% ===================================================================
%% Util
%% ===================================================================

%% @private
get_cmd(Cmd, Msg) ->
    Cmd2 = case Msg of
        #{<<"subclass">> := Sub} -> <<Sub/binary, $/, Cmd/binary>>;
        _ -> Cmd
    end,
    case Msg of
        #{<<"class">> := Class} -> <<Class/binary, $/, Cmd2/binary>>;
        _ -> Cmd2
    end.


%% @private
make_req(Cmd, Data, TId, State) ->
    #state{
        srv_id = SrvId,
        session_id = SessId,
        user_id = UserId,
        user_state = UserState,
        session_manager = Manager,
        local = Local,
        remote = Remote
    } = State,
    #nkreq{
        srv_id = SrvId,
        session_module = ?MODULE,
        session_id = SessId,
        session_pid = self(),
        session_meta = #{local=>Local, remote=>Remote},
        session_manager = Manager,
        tid = TId,
        cmd = Cmd,
        data = Data,
        user_id = UserId,
        user_state = UserState,
        timeout_pending = true,
        debug = get(nkapi_server_debug)
    }.


%% @private
update_req_state(#nkreq{session_manager=Manager, user_state=UserState}, State) ->
    State#state{session_manager=Manager, user_state=UserState}.


%% @private
process_login(Reply, TId, Unknown, NkPort, State) ->
    #state{srv_id=SrvId, session_id=SessId, user_id=UserId, user_state=UserState} = State,
    nklib_proc:put(?MODULE, {UserId, SessId}),
    nklib_proc:put({?MODULE, SrvId}, {UserId, SessId}),
    nklib_proc:put({?MODULE, user, UserId}, {SessId, UserState}),
    nklib_proc:put({?MODULE, session, SessId}, UserId),
    Event1 = #nkevent{
        srv_id = SrvId,
        class = <<"api">>,
        subclass = <<"user">>,
        obj_id = UserId
    },
    subscribe(self(), Event1),
    Event2 = Event1#nkevent{
        subclass = <<"session">>,
        obj_id = SessId
    },
    subscribe(self(), Event2),
    start_ping(self(), nkapi_app:get(api_ping_timeout)),
    send_reply_ok(Reply, TId, Unknown, NkPort, State).


%% @private
do_call(Pid, Msg) ->
    case self() of
        Pid ->
            {error, blocking_request};
        _ ->
            nklib_util:call(Pid, Msg, 1000*?CALL_TIMEOUT)
    end.


%% @private
do_cast(Pid, Msg) ->
    gen_server:cast(Pid, Msg).


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
insert_ack(TId, Pid, #state{trans=AllTrans}=State) ->
    Mon = case is_pid(Pid) of
        true -> monitor(process, Pid);
        false -> undefined
    end,
    Trans = #trans{
        op = ack,
        mon = Mon,
        timer = erlang:start_timer(1000*?ACK_TIME, self(), {nkapi_op_timeout, TId})
    },
    State#state{trans=maps:put(TId, Trans, AllTrans)}.


%% @private
extract_op(TId, #state{trans=AllTrans}=State) ->
    case maps:find(TId, AllTrans) of
        {ok, #trans{mon=Mon, timer=Timer}=OldTrans} ->
            nklib_util:cancel_timer(Timer),
            nklib_util:demonitor(Mon),
            State2 = State#state{trans=maps:remove(TId, AllTrans)},
            {OldTrans, State2};
        error ->
            not_found
    end.

%% @private
extract_op_mon(Mon, #state{trans=AllTrans}=State) ->
    case [TId || {TId, #trans{mon=M}} <- maps:to_list(AllTrans), M==Mon] of
        [TId] ->
            {OldTrans, State2} = extract_op(TId, State),
            {true, TId, OldTrans, State2};
        [] ->
            false
    end.


%% @private
extend_op(TId, #trans{timer=Timer}=Trans, #state{trans=AllTrans}=State) ->
    nklib_util:cancel_timer(Timer),
    ?DEBUG("extended op, new time: ~p", [1000*?ACK_TIME], State),
    Timer2 = erlang:start_timer(1000*?ACK_TIME, self(), {nkapi_op_timeout, TId}),
    Trans2 = Trans#trans{timer=Timer2},
    State#state{trans=maps:put(TId, Trans2, AllTrans)}.




%% @private
send_request(Cmd, Data, From, NkPort, #state{tid=TId}=State) ->
    Msg1 = #{
        cmd => Cmd,
        tid => TId
    },
    Msg2 = if
        is_map(Data), map_size(Data)>0  ->
            Msg1#{data=>Data};
        is_list(Data) ->
            Msg1#{data=>Data};
        true ->
            Msg1
        end,
    State2 = insert_op(TId, Msg2, From, State),
    send(Msg2, NkPort, State2#state{tid=TId+1}).


%%%% @private
%%send_api_event(Type, Body, #nkreq{srv_id=SrvId, session_id=SessId}) ->
%%    Event = #nkevent{
%%        srv_id = SrvId,
%%        class = <<"api">>,
%%        subclass = <<"session">>,
%%        type = Type,
%%        obj_id = SessId,
%%        body = Body
%%    },
%%    event(self(), Event).


%%%% @private
%%send_event(Event, NkPort, State) ->
%%    #state{srv_id=_SrvId} = State,
%%    Msg = #{
%%        cmd => <<"event">>,
%%        data => nkevent_util:unparse(Event)
%%    },
%%    send(Msg, NkPort, State).


%% @private
send_reply_ok(Data, TId, Unknown, NkPort, State) ->
    Msg1 = #{
        result => ok,
        tid => TId
    },
    Msg2 = case Data of
        #{} when map_size(Data)==0 -> Msg1;
        #{} -> Msg1#{data=>Data};
        List when is_list(List) -> Msg1#{data=>Data}
    end,
    Msg3 = case Unknown of
        [] -> Msg2;
        _ -> Msg2#{unknown_fields=>Unknown}
    end,
    send(Msg3, NkPort, State).


%% @private
send_reply_error(Error, TId, NkPort, #state{srv_id=SrvId}=State) ->
    {Code, Text} = nkservice_util:error(SrvId, Error),
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
send_ack(TId, Unknown, NkPort, State) ->
    Msg1 = #{ack => TId},
    Msg2 = case Unknown of
        [] -> Msg1;
        _ -> Msg1#{unknown_fields=>Unknown}
    end,
    send(Msg2, NkPort, State).


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
    erlang:phash2(Event#nkevent{body=#{}, pid=undefined, meta=#{}}).


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
print(_Txt, [#{cmd:=<<"ping">>}], _State) ->
    ok;
print(Txt, [#{}=Map], State) ->
    print(Txt, [nklib_json:encode_pretty(Map)], State);
print(Txt, Args, State) ->
    ?LLOG(debug, Txt, Args, State).

 
