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
	module = undefined :: module() | undefined
}).


-endif.

