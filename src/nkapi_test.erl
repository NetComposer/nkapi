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

%% @doc 
-module(nkapi_test).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-define(SRV, test).
%%-define(WS, "ws://127.0.0.1:9202/apiws").
-define(WS, "wss://127.0.0.1:9010/ws").
-define(HTTP, "https://127.0.0.1:9010/rpc/api").

-compile(export_all).

-include_lib("nkservice/include/nkservice.hrl").

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts the service
start() ->
    Spec = #{
        callback => ?MODULE,
        api_server => "wss:all:9010, ws:all:9011/ws, https://all:9010/rpc",
        api_server_timeout => 300,
        debug => [nkapi_client, nkapi_server, nkevent],
        %plugins => [nkapi_log_gelf],
        api_gelf_server => "c2.netc.io",
        % To test nkpacket config:
        tls_password => <<"1234">>,
        packet_no_dns_cache => false
    },
    nkservice:start(test, Spec).


%% @doc Stops the service
stop() ->
    nkservice:stop(test).


login(User) ->
    Fun = fun ?MODULE:api_client_fun/1,
    Login = #{
        user => nklib_util:to_binary(User),
        password=> <<"1234">>,
        meta => #{a=>User}
    },
    {ok, _Reply, _Pid} = nkapi_client:start(?SRV, ?WS, Login, Fun, #{}, nkapi_test_login).


%% @doc Gets all registered users and sessions
get_users() ->
    nkapi_server:get_all().


%% @doc Gets all sessions for a registered user
get_sessions(User) ->
    nkapi_server:find_user(User).


ping() ->
    cmd(session, ping, #{}).


%% @doc
event_get_subs() ->
    cmd(<<"event.get_subscriptions">>, #{invalid=>1}).

%% @doc
event_subscribe() ->
    event_subscribe(#{class=>class1, body=>#{k=>v}}),
    event_subscribe(#{class=>class2, subclass=>s2}),
    event_subscribe(#{class=>class3, subclass=>s3, type=>t3}),
    event_subscribe(#{class=>class4, subclass=>s4, type=>t4, obj_id=>o4}).

event_subscribe(Obj) ->
    cmd(<<"event.subscribe">>, Obj).


%% @doc
event_unsubscribe() ->
    event_unsubscribe(#{class=>class1}),
    event_unsubscribe(#{class=>class2, subclass=>s2}),
    event_unsubscribe(#{class=>class3, subclass=>s3, type=>t3}),
    event_unsubscribe(#{class=>class4, subclass=>s4, type=>t4, obj_id=>o4}).

event_unsubscribe(Obj) ->
    cmd(<<"event.unsubscribe">>, Obj).


%% @doc
event_send(Data) when is_map(Data) ->
    event(Data);

event_send(T) ->
    Ev = case T of
        s1 -> #{class=>class1, subclass=>s1, type=>t1, obj_id=>o1, body=>#{k1=>v1}};
        s2a -> #{class=>class2, subclass=>s2, type=>t2, obj_id=>o2, body=>#{k2=>v2}};
        s2b -> #{class=>class2, subclass=>s3, type=>t2, obj_id=>o2, body=>#{k2=>v2}};
        s3a -> #{class=>class3, subclass=>s3, type=>t3, obj_id=>o3, body=>#{k3=>v3}};
        s3b -> #{class=>class3, subclass=>s3, type=>t4, body=>#{k3=>v3}};
        s4a -> #{class=>class4, subclass=>s4, type=>t4, obj_id=>o4, body=>#{k4=>v4}};
        s4b -> #{class=>class4, subclass=>s4, type=>t4, obj_id=>o5, body=>#{k4=>v4}}
    end,
    event(Ev).

%% @doc Another way of sending events, as a command (with response)
event_send2() ->
    cmd(<<"event.send">>, #{class=>class1}).


%% @doc
event_send_user(User) ->
    event(#{class=>api, subclass=>user, obj_id=>User, type=>type1, body=>#{k=>v}}).


%% @doc
event_send_session(SessId) ->
    event(#{class=>api, subclass=>session, obj_id=>SessId, body=>#{k=>v}}).


%% @doc
session_stop() ->
    cmd(<<"session.stop">>, #{}).

%% @doc
session_stop(SessId) ->
    cmd(<<"session.stop">>, #{session_id => SessId}).


%% @doc Call back to the client (replied in callback fun bellow)
session_call(SessId) ->
    {ok, #{<<"client">> := #{<<"value">> := <<"v">>}}} =
        cmd(<<"session.cmd">>,
            #{session_id=>SessId, cmd=>"nkapi_test.cmd1", data=>#{value=>v}}),
    {error, {<<"not_implemented">>, <<"Not implemented">>}} =
        cmd(<<"session.cmd">>,
            #{session_id=>SessId, cmd=>"nkapi_test.cmd2", data=>#{value=>v}}),
    ok.


api_test() ->
    {ok, #{<<"reply">> := #{<<"k">> := 1}}} =
        cmd(<<"session.api_test">>, #{data=>#{k=>1}}).

api_test_async() ->
    {ok, #{<<"reply">> := #{<<"k">> := 1}}} =
        cmd(<<"session.api_test.async">>, #{data=>#{k=>1}}).


%% @doc
log(Source, Msg, Data) ->
    cmd(<<"session.log">>, Data#{source=>Source, message=>Msg}).





http_ping() ->
    http_cmd(session, <<>>, ping, #{a=>1}).

http_test_async() ->
    {ok,
        #{
            <<"result">> := <<"ok">>,
            <<"data">> := #{
                <<"reply">> := #{<<"a">> := 1}}
        }
    } =
        http_cmd(session, <<>>, api_test_async, #{data=>#{a=>1}}).


http_session_call(SessId) ->
    {ok,
        #{
            <<"result">> := <<"ok">>,
            <<"data">> := #{<<"k">> := <<"v">>}
        }
    } =
        http_cmd(session, <<>>, cmd,
            #{session_id=>SessId, class=>class1, cmd=>cmd1, data=>#{k=>v}}),
    {ok,
        #{
            <<"result">> := <<"error">>,
            <<"data">> := #{
                <<"code">> := <<"not_implemented">>,
                <<"error">> :=<<"Not implemented">>
            }
        }
    } =
        http_cmd(session, <<>>, cmd,
            #{session_id=>SessId, class=>class2, cmd=>cmd1, data=>#{k=>v}}),
    ok.

%% @doc
http_log(Source, Msg, Data) ->
    http_cmd(session, <<>>, log, Data#{source=>Source, message=>Msg}).


upload(File) ->
    {ok, Bin} = file:read_file(File),
    nkservice_util:http_upload(
        "https://127.0.0.1:9010/rpc",
        u1,
        p1,
        test,
        my_obj_id,
        File,
        Bin).


download(File) ->
    nkservice_util:http_download(
        "https://127.0.0.1:9010/rpc",
        u1,
        p1,
        test,
        my_obj_id,
        File).


get_client() ->
    [{_, Pid}|_] = nkapi_client:get_all(),
    Pid.


%% Test calling with class=test, cmd=op1, op2, data=#{nim=>1}
cmd(Cmd, Data) ->
    Pid = get_client(),
    cmd(Pid, Cmd, Data).

cmd(Pid, Cmd, Data) ->
    nkapi_client:cmd(Pid, Cmd, Data).


%% Test calling with class=test, cmd=op1, op2, data=#{nim=>1}
event(Data) ->
    Pid = get_client(),
    event(Pid, Data).

event(Pid, Data) ->
    nkapi_client:event(Pid, Data).



http_cmd(Class, Sub, Cmd, Data) ->
    Opts = #{
        user => <<"user1">>,
        pass => <<"1234">>,
        body => #{
            class => Class,
            subclass => Sub,
            cmd => Cmd,
            data => Data
        }
    },
    case nkapi_util:http(post, ?HTTP, Opts) of
        {ok, _Hds, Json, _Time} ->
            {ok, nklib_json:decode(Json)};
        {error, Error} ->
            {error, Error}
    end.



%% ===================================================================
%% Client fun
%% ===================================================================


api_client_fun(#nkreq{cmd = <<"event">>, data=Event}=Req) ->
    lager:notice("CLIENT event ~p", [lager:pr(Event, nkevent)]),
    {ok, Req};

api_client_fun(#nkreq{cmd = <<"nkapi_test.cmd1">>, data=Data}=Req) ->
    % lager:notice("API REQ: ~p", [lager:pr(_Req, ?MODULE)]),
    {ok, #{client=>Data}, Req};

api_client_fun(Req) ->
    % lager:error("API REQ: ~p", [lager:pr(_Req, ?MODULE)]),
    {error, not_implemented, Req}.




%% ===================================================================
%% API callbacks
%% ===================================================================

plugin_deps() ->
    [nkapi].



%% @doc
service_api_syntax(#nkreq{cmd = <<"nkapi_test_login">>}=Req, Syntax) ->
    {Syntax#{user=>binary, password=>binary, meta=>map}, Req};

service_api_syntax(_Req, _Syntax) ->
    continue.


%% @doc
service_api_allow(Req) ->
    {true, Req}.


%% @doc Called on any command
service_api_cmd(#nkreq{cmd = <<"nkapi_test_login">>, session_id=SessId, data=Data}=Req) ->
    case Data of
        #{user:=User, password:=<<"1234">>} ->
            Meta = maps:get(meta, Data, #{}),
            {login, #{login=>ok, sess=>SessId}, User, Meta, Req};
        _ ->
            {error, invalid_user, Req}
    end;

service_api_cmd(_Req) ->
    continue.


%% @doc
api_server_http_auth(Req, State) ->
    case nkapi_server_http:get_basic_auth(Req) of
        {basic, User, <<"1234">>} ->
            {true, User, #{data=>http}, State};
        _ ->
            continue
    end.


%% @private
api_server_http_upload(test, ObjId, Name, CT, Bin, State) ->
    lager:notice("Upload: ~p, ~p, ~s, ~s", [ObjId, Name, CT, Bin]),
    {ok, State};

api_server_http_upload(_Mod, _ObjId, _Name, _CT, _Bin, _State) ->
    continue.


%% @private
api_server_http_download(test, ObjId, Name, State) ->
    lager:notice("Download: ~p, ~p", [ObjId, Name]),
    {ok, <<>>, <<"test">>, State};

api_server_http_download(_Mod, _ObjId, _Name, _State) ->
    continue.
