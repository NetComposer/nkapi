-ifndef(NKAPI_HRL_).
-define(NKAPI_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================


-define(ADD_TO_API_SESSION(Key, Val, Session), Session#{Key=>Val}).



%% ===================================================================
%% Records
%% ===================================================================

-record(nkapi_req, {
	srv_id :: nkservice:id(),
	class :: nkapi:class(),
	subclass = '' :: nkapi:subclass(),
	cmd = '' :: nkapi:cmd(),
	data = #{} :: nkapi:data(),
	tid :: term(),
	user_id = <<>> :: binary(),
	session_id = <<>> :: binary(),
	%module = undefined :: module() | undefined,
    unknown_fields = [] :: [binary()]
}).


-record(nkapi_req2, {
	cmd = <<>> :: nkapi:cmd(),
	data = #{} :: nkapi:data(),
	tid :: term(),
	unknown_fields = [] :: [binary()]
}).



-record(nkapi_session, {
	srv_id :: nkservice:id(),
	session_type :: atom(),
	session_id = <<>> :: nkapi:session_id(),
	local = <<>> :: binary(),               % Transp:Ip:Port
	remote = <<>> :: binary(),
	user_id = <<>> :: nkapi:user_id(),      % <<>> if not authenticated
	user_meta = #{} :: map(),				% Login information
	data = #{} :: map()						% Service information
}).




-endif.

