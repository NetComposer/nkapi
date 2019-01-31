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

-module(nkapi_api_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([syntax/2]).


%% ===================================================================
%% Public functions
%% ===================================================================


%% @private
syntax(<<"event/subscribe">>, Syntax) ->
    Ev = nkevent_util:syntax(true),
    maps:merge(Syntax, Ev);

syntax(<<"event/unsubscribe">>, Syntax) ->
    Ev = nkevent_util:syntax(true),
    maps:merge(Syntax, Ev);

syntax(<<"event/send">>, Syntax) ->
    Ev = nkevent_util:syntax(false),
    maps:merge(Syntax, Ev);

%%syntax(<<"event/send_to_user">>, Syntax) ->
%%    Syntax#{
%%        user_id => binary,
%%        type => binary,
%%        body => map,
%%        '__mandatory' => [user_id]
%%    };
%%
%%syntax(<<"event/send_to_session">>, Syntax) ->
%%    Syntax#{
%%        session_id => binary,
%%        type => binary,
%%        body => map,
%%        '__mandatory' => [session_id]
%%    };

syntax(<<"session/ping">>, Syntax) ->
    Syntax#{time=>integer};

syntax(<<"session/stop">>, Syntax) ->
    Syntax#{session_id => binary};

syntax(<<"session/cmd">>, Syntax) ->
    Syntax#{
        cmd => binary,
        data => map,
        '__mandatory' => [session_id, data, cmd]
    };

syntax(<<"session/log">>, Syntax) ->
    Syntax#{
        source => binary,
        message => binary,
        full_message => binary,
        level => {integer, 1, 7},
        meta => any,
        '__defaults' => #{level=>6},
        '__mandatory' => [source, message]
    };

syntax(<<"session/api_test">>, Syntax) ->
    Syntax#{
        data=>any,
        '__mandatory' => [data]
    };

syntax(<<"session/api_test.async">>, Syntax) ->
    Syntax#{
        data=>any,
        '__mandatory' => [data]
    };

syntax(<<"service/config/put">>, Syntax) ->
    Syntax#{
        service_id => atom,
        key => atom,
        value => any,
        '__mandatory' => [service_id, key, value]
    };


syntax(_Cmd, _Syntax) ->
    continue.



