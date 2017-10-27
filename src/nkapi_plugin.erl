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
-module(nkapi_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([plugin_deps/0, plugin_syntax/0, plugin_listen/2]).


%% ===================================================================
%% Plugin Callbacks
%% ===================================================================

plugin_deps() ->
	[].


%% @doc This function, if implemented, can offer a nklib_config:syntax()
%% that will be checked against service configuration. Entries passing will be
%% updated on the configuration with their parsed values
%% To debug, set api_server or {api_server, [nkpacket]} in the 'debug' config option
plugin_syntax() ->
    #{
        nkapi_server => {list,
        #{
            id => binary,
            url => fun nkapi_util:parse_url/1,
            opts => nkpacket_syntax:safe_syntax(),
            '__mandatory' => [id, url]
        }}
}.



%% @doc This function, if implemented, allows to add listening transports.
plugin_listen(Config, #{id:=SrvId}) ->
    Endpoints = maps:get(nkapi_server, Config, []),
    nkapi_util:make_listen(SrvId, Endpoints).

