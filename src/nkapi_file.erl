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

-module(nkapi_file).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([filename_encode/3, filename_decode/1]).


%% ===================================================================
%% Types
%% ===================================================================


%% ===================================================================
%% Public
%% ===================================================================



%% @private
-spec filename_encode(Module::atom(), Id::term(), Name::term()) ->
    binary().

filename_encode(Module, ObjId, Name) ->
    ObjId2 = to_bin(ObjId),
    Name2 = to_bin(Name),
    Term1 = term_to_binary({Module, ObjId2, Name2}),
    Term2 = base64:encode(Term1),
    Term3 = http_uri:encode(binary_to_list(Term2)),
    list_to_binary(Term3).


%% @private
-spec filename_decode(binary()|string()) ->
    {Module::atom(), Id::term(), Name::term()}.

filename_decode(Term) ->
    try
        Uri = http_uri:decode(nklib_util:to_list(Term)),
        BinTerm = base64:decode(Uri),
        {Module, Id, Name} = binary_to_term(BinTerm),
        {Module, Id, Name}
    catch
        error:_ -> error
    end.



%% @private
to_bin(Term) -> nklib_util:to_binary(Term).



