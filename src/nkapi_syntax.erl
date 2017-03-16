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

%% @doc Default callbacks
-module(nkapi_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([syntax/3, events/1]).


%% ===================================================================
%% Syntax
%% ===================================================================

%% @private
syntax(user, login, Syntax) ->
    S2 = Syntax#{
        user => binary,
        password => binary,
        meta => map
    },
    nklib_syntax:add_mandatory([user, password], S2);

syntax(event, subscribe, Syntax) ->
    S2 = events(Syntax),
    S2#{type=>[binary, {list, binary}]};

syntax(event, unsubscribe, Syntax) ->
    S2 = events(Syntax),
    S2#{type=>[binary, {list, binary}]};

syntax(event, send, Syntax) ->
    events(Syntax);

syntax(event, send_to_user, Syntax) ->
    S2 = Syntax#{
        user_id => binary,
        type => binary,
        body => map
    },
    nklib_syntax:add_mandatory([user_id], S2);

syntax(event, send_to_session, Syntax) ->
    S2 = Syntax#{
        session_id => binary,
        type => binary,
        body => map
    },
    nklib_syntax:add_mandatory([session_id], S2);

syntax(session, ping, Syntax) ->
    Syntax#{time=>integer};

syntax(session, stop, Syntax) ->
    Syntax#{session_id => binary};

syntax(session, cmd, Syntax) ->
    S2 = Syntax#{
        session_id => binary,
        class => atom,
        subclass => atom,
        cmd => atom,
        data => map
    },
    nklib_syntax:add_mandatory([session_id, class, cmd], S2);

syntax(session, log, Syntax) ->
    S2 = Syntax#{
        source => binary,
        message => binary,
        full_message => binary,
        level => {integer, 1, 7},
        meta => any
    },
    S3 = nklib_syntax:add_defaults(#{level=>6}, S2),
    nklib_syntax:add_mandatory([source, message], S3);

syntax(session, api_test_async, Syntax) ->
    S2 = Syntax#{data=>any},
    nklib_syntax:add_mandatory([data], S2);

syntax(_Sub, _Cmd, Syntax) ->
    Syntax.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
events(Syntax) ->
    S2 = Syntax#{
        class => binary,
        subclass => binary,
        type => binary,
        obj_id => binary,
        body => map
    },
    nklib_syntax:add_mandatory([class], S2).
